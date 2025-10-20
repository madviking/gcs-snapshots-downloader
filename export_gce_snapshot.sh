#!/usr/bin/env bash
set -euo pipefail

#
# Export filesystem contents from a GCE snapshot by mounting it read-only on a
# tiny VM and streaming tar.gz archives directly to GCS. This copies only the
# true file contents (not empty blocks), then downloads artifacts locally and
# cleans up compute resources.
#
# Usage:
#   ./transfer.sh <SNAPSHOT_NAME> <REGION> [--keep-remote]
#
# Example:
#   ./transfer.sh my-data-snap us-central1 --keep-remote
#
# Output:
#   - Tarballs in ./exports/<unique-prefix>/
#   - State file at ./exports/<unique-prefix>.state (for cleanup)
#
# Auth with GCP/GCS (once per machine):
#   1) Install Cloud SDK: https://cloud.google.com/sdk
#   2) gcloud auth login
#   3) gcloud config set project <YOUR_PROJECT_ID>
#      (Optional) gcloud auth application-default login
#
# Required access: ability to create Compute Engine VM/disks and Storage buckets
# in the project. The script grants the VM's default service account permission
# on the temporary bucket so it can upload to GCS. Your local user downloads the
# artifacts using gcloud.
#
# If anything fails, we run cleanup with the state file automatically.
# You can always run the cleanup script manually later with the same state file.

usage() {
  cat <<EOF
Usage: $0 <SNAPSHOT_NAME> <REGION> [--keep-remote] [--out-dir PATH]

Exports filesystem contents from a GCE snapshot to compressed tarballs, stored
in a temporary GCS bucket and then copied locally to ./exports/<prefix>.

Arguments:
  SNAPSHOT_NAME   Existing snapshot name in the active project
  REGION          Region for temporary resources (e.g. us-central1)
  --keep-remote   Keep the GCS bucket/objects (skip storage cleanup)
  --out-dir PATH  Download artifacts to PATH instead of ./exports/<prefix>

Prerequisites:
  - Google Cloud SDK installed
  - Authenticate and set project:
      gcloud auth login
      gcloud config set project <YOUR_PROJECT_ID>
    (Optional) Application Default Credentials if you prefer:
      gcloud auth application-default login
  - Permissions to create Compute Engine resources and GCS buckets/objects.

Benefits of this approach:
  - Copies only real file contents (no empty disk blocks)
  - Faster and cheaper than exporting raw disk images
  - Read-only mount for safety; automatic cleanup of compute resources

Examples:
  $0 my-snap us-central1 --keep-remote
  $0 my-snap us-central1 --out-dir /tmp/export
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

SNAPSHOT_NAME="$1"
REGION="$2"
shift 2

KEEP_REMOTE="0"
OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-remote)
      KEEP_REMOTE="1"; shift ;;
    --out-dir)
      OUT_DIR="${2:?--out-dir requires a PATH}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# Dependencies check (local host)
if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud CLI is required. Install Cloud SDK first: https://cloud.google.com/sdk" >&2
  exit 1
fi

PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -z "${PROJECT}" ]] && { echo "Set project: gcloud config set project YOUR_PROJECT_ID"; exit 2; }

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RAND8="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 8 || echo $$)"

sanitize() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]/-/g; s/-+/-/g; s/^-+//; s/-+$//'; }

SNAP_SAFE="$(sanitize "${SNAPSHOT_NAME}")"
PROJ_SAFE="$(sanitize "${PROJECT}")"

TMP_DISK="tmpdisk-${SNAP_SAFE}-${RAND8}"
VM="tmpvm-${SNAP_SAFE}-${RAND8}"
BUCKET="snapfiles-${SNAP_SAFE}-${PROJ_SAFE}-${TIMESTAMP}-${RAND8}"
# GCS bucket names must be <= 63 chars and end alphanumeric
if (( ${#BUCKET} > 63 )); then
  BUCKET="${BUCKET:0:63}"
  # trim any trailing hyphens from truncation
  while [[ "${BUCKET}" == *- ]]; do BUCKET="${BUCKET%-}"; done
fi
REMOTE_PREFIX="files-${SNAP_SAFE}-${TIMESTAMP}-${RAND8}"
EXPORTS_DIR="./exports"
if [[ -n "${OUT_DIR}" ]]; then
  LOCAL_DIR="${OUT_DIR}"
  STATE_FILE="${OUT_DIR}.state"
else
  LOCAL_DIR="${EXPORTS_DIR}/${REMOTE_PREFIX}"
  STATE_FILE="${EXPORTS_DIR}/${REMOTE_PREFIX}.state"
fi
mkdir -p "$(dirname "${STATE_FILE}")" "${LOCAL_DIR}"

# ---- helpers ----
log() { echo "[$(date +%H:%M:%S)] $*"; }
log_state() { echo "$*" >> "${STATE_FILE}"; }
on_error() {
  log "ERROR detected. Invoking cleanup with ${STATE_FILE} …"
  bash ./cleanup_gce_snapshot_export.sh "${STATE_FILE}" || true
}
trap on_error ERR

log "Project: ${PROJECT}"
log "Snapshot: ${SNAPSHOT_NAME}"
log "Region: ${REGION}"
log "State file: ${STATE_FILE}"

# seed state file
cat > "${STATE_FILE}" <<EOF
# gce-snapshot-export state
PROJECT=${PROJECT}
REGION=${REGION}
SNAPSHOT_NAME=${SNAPSHOT_NAME}
TIMESTAMP=${TIMESTAMP}
RAND8=${RAND8}
REMOTE_PREFIX=${REMOTE_PREFIX}
LOCAL_DIR=${LOCAL_DIR}
EOF

log "Enabling APIs (idempotent)…"
gcloud services enable compute.googleapis.com storage.googleapis.com >/dev/null

log "Selecting an UP zone in ${REGION}…"
ZONE="$(gcloud compute zones list --filter="name~'^${REGION}-' AND status=UP" --format='value(name)' | head -n1)"
[[ -z "${ZONE}" ]] && { echo "No UP zones in ${REGION}"; exit 3; }
log "Using zone: ${ZONE}"
log_state "ZONE=${ZONE}"

log "Creating temp bucket: gs://${BUCKET} (location=${REGION})"
gcloud storage buckets create "gs://${BUCKET}" --location="${REGION}" --uniform-bucket-level-access >/dev/null
log_state "BUCKET=${BUCKET}"

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)')"
COMP_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${COMP_SA}" \
  --role="roles/storage.objectAdmin" >/dev/null || true

log "Creating temp disk from snapshot: ${TMP_DISK}"
gcloud compute disks create "${TMP_DISK}" \
  --source-snapshot="${SNAPSHOT_NAME}" \
  --zone="${ZONE}" \
  --project="${PROJECT}" >/dev/null
log_state "DISK=${TMP_DISK}"

log "Creating tiny VM: ${VM}"
gcloud compute instances create "${VM}" \
  --zone="${ZONE}" \
  --machine-type="e2-micro" \
  --image-family="debian-12" \
  --image-project="debian-cloud" \
  --service-account="${COMP_SA}" \
  --scopes="https://www.googleapis.com/auth/cloud-platform" >/dev/null
log_state "VM=${VM}"

log "Attaching disk to VM…"
gcloud compute instances attach-disk "${VM}" \
  --zone="${ZONE}" \
  --disk="${TMP_DISK}" \
  --device-name="${TMP_DISK}" >/dev/null

log "Waiting for SSH to be ready…"
for i in {1..24}; do
  if gcloud compute ssh "${VM}" --zone "${ZONE}" --command "true" >/dev/null 2>&1; then
    break
  fi
  sleep 5
  [[ $i -eq 24 ]] && { echo "SSH not ready in time"; exit 4; }
done

log "Mounting and streaming partitions as tar.gz to GCS…"
REMOTE_SCRIPT="${EXPORTS_DIR}/${REMOTE_PREFIX}.remote.sh"
cat > "${REMOTE_SCRIPT}" <<'EOS'
set -euo pipefail
sudo mkdir -p /mnt/snap

sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y lsblk util-linux gzip tar ca-certificates curl gnupg >/dev/null 2>&1 || true

# Prefer pigz for faster compression if available
GZIP_CMD="gzip -1"
if command -v pigz >/dev/null 2>&1; then
  GZIP_CMD="pigz -1"
else
  sudo apt-get install -y pigz >/dev/null 2>&1 || true
  if command -v pigz >/dev/null 2>&1; then GZIP_CMD="pigz -1"; fi
fi

# Ensure gsutil is available (install Cloud SDK if needed)
if ! command -v gsutil >/dev/null 2>&1; then
  if [[ ! -f /usr/share/keyrings/cloud.google.gpg ]]; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloud.google.gpg || true
  fi
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null || true
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y google-cloud-cli >/dev/null 2>&1 || true
fi
if ! command -v gsutil >/dev/null 2>&1; then
  echo 'gsutil is not available on the VM; cannot upload to GCS' >&2
  exit 12
fi

DEV=$(ls -1 /dev/disk/by-id/google-* | grep "$TMP_DISK" | head -n1 || true)
[[ -z "$DEV" ]] && { echo 'Device not found'; exit 10; }

PARTS=$(lsblk -ln -o NAME,TYPE | awk '$2=="part"{print $1}')

did_any=0
for P in $PARTS; do
  if readlink -f "/sys/class/block/$P/.." | grep -q $(basename $(readlink -f "$DEV")); then
    MP="/mnt/snap-$P"
    sudo mkdir -p "$MP"
    if sudo mount -o ro "/dev/$P" "$MP" 2>/dev/null; then
      did_any=1
      EXCLUDES=(--exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./tmp --exclude=./mnt --exclude=./media --exclude=./lost+found)
      EXCLUDES+=(--exclude=./var/lib/docker/overlay2 --exclude=./var/lib/docker/btrfs --exclude=./var/lib/containerd)
      ( cd "$MP" && sudo tar --ignore-failed-read --checkpoint=5000 --checkpoint-action=echo='[tar] +' -cpf - "${EXCLUDES[@]}" . | $GZIP_CMD ) | gsutil cp - "gs://$BUCKET/$REMOTE_PREFIX/$P.tar.gz"
      sudo umount "$MP" || true
    fi
  fi
done

if [[ "$did_any" -eq 0 ]]; then
  if sudo mount -o ro "$DEV" /mnt/snap 2>/dev/null; then
    EXCLUDES=(--exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./tmp --exclude=./mnt --exclude=./media --exclude=./lost+found)
    EXCLUDES+=(--exclude=./var/lib/docker/overlay2 --exclude=./var/lib/docker/btrfs --exclude=./var/lib/containerd)
    ( cd /mnt/snap && sudo tar --ignore-failed-read --checkpoint=5000 --checkpoint-action=echo='[tar] +' -cpf - "${EXCLUDES[@]}" . | $GZIP_CMD ) | gsutil cp - "gs://$BUCKET/$REMOTE_PREFIX/root.tar.gz"
    sudo umount /mnt/snap || true
  else
    sudo apt-get install -y ntfs-3g >/dev/null 2>&1 || true
    if sudo mount -o ro -t ntfs-3g "$DEV" /mnt/snap 2>/dev/null; then
      EXCLUDES=(--exclude='./System Volume Information' --exclude='./$Recycle.Bin')
      ( cd /mnt/snap && sudo tar --ignore-failed-read --checkpoint=5000 --checkpoint-action=echo='[tar] +' -cpf - "${EXCLUDES[@]}" . | $GZIP_CMD ) | gsutil cp - "gs://$BUCKET/$REMOTE_PREFIX/ntfs-root.tar.gz"
      sudo umount /mnt/snap || true
    else
      echo 'No mountable filesystem found.'; exit 11
    fi
  fi
fi

echo OK | gsutil cp - "gs://$BUCKET/$REMOTE_PREFIX/_OK"
EOS

# inject variables at the top (to avoid local expansion issues above)
sed -i '' "1s;^;BUCKET='${BUCKET}'\nREMOTE_PREFIX='${REMOTE_PREFIX}'\nTMP_DISK='${TMP_DISK}'\n;" "${REMOTE_SCRIPT}"

gcloud compute scp --zone "${ZONE}" "${REMOTE_SCRIPT}" "${VM}:/tmp/transfer.sh" >/dev/null
gcloud compute ssh "${VM}" --zone "${ZONE}" --command "bash /tmp/transfer.sh"

log "Downloading to local: ${LOCAL_DIR}"
gcloud storage cp -r "gs://${BUCKET}/${REMOTE_PREFIX}/*" "${LOCAL_DIR}/"

if [[ ! -f "${LOCAL_DIR}/_OK" ]]; then
  log "WARNING: No _OK marker found; export may be incomplete."
fi

# ---- cleanup (always delete compute; optionally keep storage) ----
log "Cleaning up compute resources…"
gcloud compute instances detach-disk "${VM}" --disk="${TMP_DISK}" --zone="${ZONE}" --quiet >/dev/null || true
gcloud compute instances delete "${VM}" --zone="${ZONE}" --quiet >/dev/null || true
gcloud compute disks delete "${TMP_DISK}" --zone="${ZONE}" --quiet >/dev/null || true

if [[ "${KEEP_REMOTE}" == "1" ]]; then
  log "Keeping remote bucket/objects as requested."
else
  log "Cleaning up storage artifacts…"
  gcloud storage rm -r "gs://${BUCKET}/${REMOTE_PREFIX}" >/dev/null || true
  gcloud storage buckets delete "gs://${BUCKET}" --quiet >/dev/null || true
fi

log "SUCCESS. Tarballs in: ${LOCAL_DIR}"
log "State file: ${STATE_FILE}"
trap - ERR
