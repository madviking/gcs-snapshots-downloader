#!/usr/bin/env bash
set -euo pipefail

# GCE snapshot -> real files in GCS -> optional local sync
# - Mounts snapshot RO on a temp VM
# - Copies ONLY regular files (no symlinks) to GCS, preserving path
# - Root gsutil to avoid permission errors
# - Quota-aware VM fallback; pd-ssd temp disk
# - Robust cleanup via state file
#
# Usage:
#   ./export_gce_snapshot.sh <SNAPSHOT_NAME> <REGION> [options]
#
# Options:
#   --keep-remote               Keep GCS bucket/objects (skip storage cleanup)
#   --skip-local                Do not download locally
#   --out-dir PATH              Local download dir (default: ./exports/<prefix>)
#   --name NAME                 Friendly alias for session
#   --silent | -y | --yes       No confirmation
#   --delete-state-at-end       Delete local state/temp files on success (with --silent)
#   --machine-type TYPE         VM type; default auto-fallback
#   --disk-type TYPE            Temp disk type from snapshot (default: pd-ssd)
#   --cleanup STATEFILE         Cleanup using a previous state file and exit

usage(){ grep -E '^#' "$0"|sed 's/^# \{0,1\}//'; exit 0; }
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

if [[ "${1:-}" == "--cleanup" ]]; then
  STATE_FILE="${2:?Provide state file path}"
  CLEANUP_ONLY=1
else
  CLEANUP_ONLY=0
fi

log(){ echo "[$(date +%H:%M:%S)] $*"; }
hr_bytes(){ local b=$1 d='' s=0 S=(B KB MB GB TB PB); while [[ "$b" =~ ^[0-9]+$ ]] && ((b>1024 && s<${#S[@]}-1)); do d=$(printf ".%02d" $(( (b%1024)*100/1024 ))); b=$((b/1024)); s=$((s+1)); done; printf "%s%s %s" "$b" "$d" "${S[$s]}"; }
sanitize(){ echo "$1"|tr '[:upper:]' '[:lower:]'|sed -E 's/[^a-z0-9-]/-/g; s/-+/-/g; s/^-+//; s/-+$//'; }
sanitize_name(){ echo "$1"|tr '[:upper:]' '[:lower:]'|sed -E 's/[^a-z0-9._-]/-/g; s/-+/-/g; s/^-+//; s/-+$//'; }

cleanup_from_state(){
  local F="${1:?state file}" KEEP_OVERRIDE="${2:-0}"
  set +u
  # shellcheck disable=SC1090
  source <(grep -E '^(PROJECT|REGION|ZONE|VM|DISK|BUCKET|REMOTE_PREFIX|LOCAL_DIR|STATE_FILE|KEEP_REMOTE|SKIP_LOCAL)=' "$F" 2>/dev/null || true)
  set -u
  [[ "$KEEP_OVERRIDE" == "1" ]] && KEEP_REMOTE=1
  log "Cleanup: compute …; storage $( [[ "${KEEP_REMOTE:-1}" == "1" ]] && echo kept || echo may-delete )"
  if [[ -n "${VM:-}" && -n "${DISK:-}" && -n "${ZONE:-}" ]]; then
    gcloud compute instances detach-disk "$VM" --disk="$DISK" --zone="$ZONE" --quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "${VM:-}" && -n "${ZONE:-}" ]]; then
    gcloud compute instances delete "$VM" --zone="$ZONE" --quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "${DISK:-}" && -n "${ZONE:-}" ]]; then
    gcloud compute disks delete "$DISK" --zone="$ZONE" --quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "${BUCKET:-}" && -n "${REMOTE_PREFIX:-}" && "${KEEP_REMOTE:-1}" != "1" && "${SKIP_LOCAL:-0}" != "1" ]]; then
    gcloud storage rm -r "gs://${BUCKET}/${REMOTE_PREFIX}" >/dev/null 2>&1 || true
    gcloud storage buckets delete "gs://${BUCKET}" --quiet >/dev/null 2>&1 || true
  else
    log "Keeping remote bucket/objects."
  fi
  log "Cleanup done."
}

if [[ $CLEANUP_ONLY -eq 1 ]]; then cleanup_from_state "$STATE_FILE" 0; exit 0; fi
[[ $# -lt 2 ]] && usage

SNAPSHOT_NAME="$1"; REGION="$2"; shift 2
KEEP_REMOTE=0; SKIP_LOCAL=0; OUT_DIR=""; SESSION_NAME=""; SILENT=0; DELETE_STATE_AT_END=0
MODE="archive"
MACHINE_TYPE="auto"; DISK_TYPE="pd-ssd"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-remote) KEEP_REMOTE=1; shift;;
    --skip-local) SKIP_LOCAL=1; shift;;
    --out-dir) OUT_DIR="${2:?}"; shift 2;;
    --name) SESSION_NAME="${2:?}"; shift 2;;
    --silent|--yes|-y) SILENT=1; shift;;
    --delete-state-at-end) DELETE_STATE_AT_END=1; shift;;
    --machine-type) MACHINE_TYPE="${2:?}"; shift 2;;
    --disk-type) DISK_TYPE="${2:?}"; shift 2;;
    --mode) MODE="${2:?archive|files}"; shift 2;;
    --cleanup) STATE_FILE="${2:?}"; cleanup_from_state "$STATE_FILE" 0; exit 0;;
    -h|--help) usage;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

command -v gcloud >/dev/null || { echo "Install Google Cloud SDK first"; exit 1; }
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[[ -z "${PROJECT}" ]] && { echo "Set project: gcloud config set project <ID>"; exit 2; }

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"; RAND8="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 8 || echo $$)"
SNAP_SAFE="$(sanitize "$SNAPSHOT_NAME")"; PROJ_SAFE="$(sanitize "$PROJECT")"
TMP_DISK="tmpdisk-${SNAP_SAFE}-${RAND8}"; VM="tmpvm-${SNAP_SAFE}-${RAND8}"
BUCKET="snapfiles-${SNAP_SAFE}-${PROJ_SAFE}-${TIMESTAMP}-${RAND8}"; [[ ${#BUCKET} -gt 63 ]] && BUCKET="${BUCKET:0:63}"; while [[ "$BUCKET" == *- ]]; do BUCKET="${BUCKET%-}"; done
REMOTE_PREFIX="files-${SNAP_SAFE}-${TIMESTAMP}-${RAND8}"; EXPORTS_DIR="./exports"

if [[ -n "$OUT_DIR" ]]; then
  BASE_NAME="${SESSION_NAME:-$SNAPSHOT_NAME}"
  LOCAL_DIR="${OUT_DIR%/}/$(sanitize_name "$BASE_NAME")"
  STATE_FILE="${LOCAL_DIR}.state"
else
  LOCAL_DIR="${EXPORTS_DIR}/${REMOTE_PREFIX}"
  STATE_FILE="${EXPORTS_DIR}/${REMOTE_PREFIX}.state"
fi
mkdir -p "$(dirname "$STATE_FILE")" "$LOCAL_DIR"

# seed state for crash-safe cleanup
cat > "$STATE_FILE" <<EOF
PROJECT=${PROJECT}
REGION=${REGION}
SNAPSHOT_NAME=${SNAPSHOT_NAME}
TIMESTAMP=${TIMESTAMP}
RAND8=${RAND8}
REMOTE_PREFIX=${REMOTE_PREFIX}
LOCAL_DIR=${LOCAL_DIR}
STATE_FILE=${STATE_FILE}
BUCKET=${BUCKET}
KEEP_REMOTE=${KEEP_REMOTE}
SKIP_LOCAL=${SKIP_LOCAL}
EOF

on_error(){
  log "Arrr, something blew up — running cleanup using ${STATE_FILE} …"
  # Inline best-effort compute cleanup first (handles cases where state is incomplete)
  if [[ -n "${VM:-}" && -n "${ZONE:-}" ]]; then
    log "Cleanup (inline): delete VM ${VM} in ${ZONE}"
    gcloud compute instances delete "${VM}" --zone "${ZONE}" --quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "${TMP_DISK:-}" && -n "${ZONE:-}" ]]; then
    log "Cleanup (inline): delete Disk ${TMP_DISK} in ${ZONE}"
    gcloud compute disks delete "${TMP_DISK}" --zone "${ZONE}" --quiet >/dev/null 2>&1 || true
  fi
  cleanup_from_state "$STATE_FILE" 1 || true
}
trap on_error ERR

log "Project: ${PROJECT}"
log "Snapshot: ${SNAPSHOT_NAME} | Region: ${REGION}"
SNAP_DISK_GB="$(gcloud compute snapshots describe "$SNAPSHOT_NAME" --format='value(diskSizeGb)' 2>/dev/null || true)"
SNAP_STORAGE_BYTES="$(gcloud compute snapshots describe "$SNAPSHOT_NAME" --format='value(storageBytes)' 2>/dev/null || true)"
[[ -n "$SNAP_STORAGE_BYTES" ]] && log "Snapshot storage: $(hr_bytes "$SNAP_STORAGE_BYTES")"
[[ -n "$SNAP_DISK_GB" ]] && log "Snapshot disk size: ${SNAP_DISK_GB} GB"

if [[ $SILENT -ne 1 ]]; then
  echo "Will create temp VM/disk/bucket in '${PROJECT}/${REGION}'. Costs apply."
  [[ -n "$SNAP_STORAGE_BYTES" ]] && echo "Estimated bytes: $(hr_bytes "$SNAP_STORAGE_BYTES")"
  read -r -p "Proceed? [y/N]: " RESP; [[ "$RESP" =~ ^(y|Y|yes|YES)$ ]] || { echo "Aborted."; exit 0; }
fi

log "Enable APIs"; gcloud services enable compute.googleapis.com storage.googleapis.com >/dev/null

log "Pick UP zone"
ZONE="$(gcloud compute zones list --filter="name~'^${REGION}-' AND status=UP" --format='value(name)' | head -n1)"
[[ -z "$ZONE" ]] && { echo "No UP zones in ${REGION}"; exit 3; }
log "Zone: ${ZONE}"; echo "ZONE=${ZONE}" >> "$STATE_FILE"

log "Create bucket: gs://${BUCKET}"
gcloud storage buckets create "gs://${BUCKET}" --location="${REGION}" --uniform-bucket-level-access >/dev/null || true

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
COMP_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" --member="serviceAccount:${COMP_SA}" --role="roles/storage.objectAdmin" >/dev/null || true

log "Create disk from snapshot (${DISK_TYPE})"
gcloud compute disks create "${TMP_DISK}" --type="${DISK_TYPE}" --source-snapshot="${SNAPSHOT_NAME}" --zone="${ZONE}" --project="${PROJECT}" >/dev/null
echo "DISK=${TMP_DISK}" >> "$STATE_FILE"

pick_machine_types(){
  if [[ "$MACHINE_TYPE" != "auto" ]]; then echo "$MACHINE_TYPE"; else
    echo "c3-standard-8 n2-standard-8 e2-highcpu-8 e2-standard-8 e2-standard-4"; fi
}

create_vm_with_fallback(){
  local last_err=""
  for t in $(pick_machine_types); do
    log "Try VM type: ${t}"
    if gcloud compute instances create "${VM}" \
         --zone="${ZONE}" --machine-type="${t}" \
         --image-family="debian-12" --image-project="debian-cloud" \
         --service-account="${COMP_SA}" \
         --scopes="https://www.googleapis.com/auth/cloud-platform" >/dev/null 2> >(tee /tmp/vm_create.err >&2); then
      echo "VM=${VM}" >> "$STATE_FILE"; echo "MACHINE_TYPE=${t}" >> "$STATE_FILE"; return 0
    else
      last_err="$(cat /tmp/vm_create.err || true)"
      if echo "$last_err" | grep -qi 'Quota'; then log "Quota blocked ${t}; trying next…"; else
        log "Create failed on ${t}:"; echo "$last_err" >&2; return 1; fi
    fi
  done
  echo "$last_err" >&2; return 1
}

log "Create VM (with fallback)"; create_vm_with_fallback

log "Attach disk"
gcloud compute instances attach-disk "${VM}" --zone="${ZONE}" --disk="${TMP_DISK}" --device-name="${TMP_DISK}" >/dev/null

log "Wait for SSH"
for i in {1..24}; do
  if gcloud compute ssh "${VM}" --zone "${ZONE}" --command "true" >/dev/null 2>&1; then break; fi
  sleep 5; [[ $i -eq 24 ]] && { echo "SSH not ready"; exit 4; }
done

log "Push remote worker (mode: ${MODE})"
REMOTE_BODY="$(mktemp)"; trap 'rm -f "$REMOTE_BODY"' EXIT

if [[ "$MODE" == "archive" ]]; then
cat > "$REMOTE_BODY" <<'EOS'
set -euo pipefail

sudo mkdir -p /mnt/snap
sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y util-linux tar gzip ca-certificates curl gnupg >/dev/null 2>&1 || true

# Install pigz for faster compression if possible
if ! command -v pigz >/dev/null 2>&1; then sudo apt-get install -y pigz >/dev/null 2>&1 || true; fi
GZ="gzip -1"; command -v pigz >/dev/null 2>&1 && GZ="pigz -1"

# Install gsutil if missing
if ! command -v gsutil >/dev/null 2>&1; then
  if [[ ! -f /usr/share/keyrings/cloud.google.gpg ]]; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloud.google.gpg || true
  fi
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null || true
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y google-cloud-cli >/dev/null 2>&1 || true
fi
sudo -H env HOME=/root gsutil version -l >/dev/null 2>&1 || { echo "gsutil not usable as root"; exit 12; }

echo "[worker] Locating device for $TMP_DISK …" >&2
DEV=$(ls -1 /dev/disk/by-id/google-* 2>/dev/null | grep "$TMP_DISK" | head -n1 || true)
[[ -z "$DEV" ]] && { echo "Device not found"; exit 10; }
PARENT=$(basename "$(readlink -f "$DEV")")
echo "[worker] Found device: $DEV (parent=$PARENT)" >&2

do_tar_stream(){
  local SRC="$1" OUT="$2"
  echo "[worker] Archiving $SRC -> $OUT" >&2
  local EX=(--exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run --exclude=./tmp --exclude=./mnt --exclude=./media --exclude=./lost+found)
  tar --ignore-failed-read --checkpoint=5000 --checkpoint-action=echo='[tar] +' -cpf - "${EX[@]}" -C "$SRC" . \
    | $GZ \
    | sudo -H env HOME=/root gsutil cp - "$OUT"
}

did_any=0
for P in $(lsblk -ln -o NAME,TYPE | awk '$2=="part"{print $1}'); do
  if readlink -f "/sys/class/block/$P/.." | grep -q "$PARENT"; then
    MP="/mnt/snap-$P"; sudo mkdir -p "$MP"
    if sudo mount -o ro "/dev/$P" "$MP" 2>/dev/null; then
      did_any=1
      do_tar_stream "$MP" "gs://$BUCKET/$REMOTE_PREFIX/$P.tar.gz"
      sudo umount "$MP" || true
    fi
  fi
done

if [[ "$did_any" -eq 0 ]]; then
  if sudo mount -o ro "$DEV" /mnt/snap 2>/dev/null; then
    do_tar_stream "/mnt/snap" "gs://$BUCKET/$REMOTE_PREFIX/root.tar.gz"
    sudo umount /mnt/snap || true
  else
    sudo apt-get install -y ntfs-3g >/dev/null 2>&1 || true
    if sudo mount -o ro -t ntfs-3g "$DEV" /mnt/snap 2>/dev/null; then
      # No system dirs on NTFS; include as-is
      tar --ignore-failed-read --checkpoint=5000 --checkpoint-action=echo='[tar] +' -cpf - -C /mnt/snap . \
        | $GZ \
        | sudo -H env HOME=/root gsutil cp - "gs://$BUCKET/$REMOTE_PREFIX/ntfs-root.tar.gz"
      sudo umount /mnt/snap || true
    else
      echo 'No mountable filesystem found.'; exit 11
    fi
  fi
fi

echo OK | sudo -H env HOME=/root gsutil cp - "gs://$BUCKET/$REMOTE_PREFIX/_OK"
EOS
else
cat > "$REMOTE_BODY" <<'EOS'
set -euo pipefail

sudo mkdir -p /mnt/snap
sudo apt-get update -y >/dev/null 2>&1 || true
sudo apt-get install -y util-linux findutils ca-certificates curl gnupg >/dev/null 2>&1 || true

# Install gsutil if missing
if ! command -v gsutil >/dev/null 2>&1; then
  if [[ ! -f /usr/share/keyrings/cloud.google.gpg ]]; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloud.google.gpg || true
  fi
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null || true
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y google-cloud-cli >/dev/null 2>&1 || true
fi
sudo -H env HOME=/root gsutil version -l >/dev/null 2>&1 || { echo "gsutil not usable as root"; exit 12; }

# From header: BUCKET, REMOTE_PREFIX, TMP_DISK
# Copy files while pruning system/container paths; avoid crossing devices
copy_tree_files() {
  local SRC="$1" DEST_PREFIX="$2"
  (
    set -euo pipefail
    cd "$SRC"
    echo "[worker] Scanning and uploading files from $SRC to gs://$BUCKET/$REMOTE_PREFIX/$DEST_PREFIX …" >&2
    local count=0 last_print=0
    sudo find . -xdev \
      \( -path './proc' -o -path './sys' -o -path './dev' -o -path './run' -o -path './tmp' -o -path './mnt' -o -path './media' -o -path './lost+found' \
         -o -path './var/lib/docker/overlay2' -o -path './var/lib/docker/btrfs' -o -path './var/lib/containerd' \) -prune -o \
         -type f -print0 \
      | while IFS= read -r -d '' f; do
          rel="${f#./}"
          sudo -H env HOME=/root gsutil -q cp "$f" "gs://${BUCKET}/${REMOTE_PREFIX}/${DEST_PREFIX}/${rel}" && count=$((count+1)) || true
          if (( count % 1000 == 0 )); then echo "[worker] ${DEST_PREFIX}: uploaded ${count} files…" >&2; fi
        done
    echo "[worker] ${DEST_PREFIX}: uploaded ${count} files total." >&2
  )
}

echo "[worker] Locating device for $TMP_DISK …" >&2
DEV=$(ls -1 /dev/disk/by-id/google-* 2>/dev/null | grep "$TMP_DISK" | head -n1 || true)
[[ -z "$DEV" ]] && { echo "Device not found"; exit 10; }
PARENT=$(basename "$(readlink -f "$DEV")")
echo "[worker] Found device: $DEV (parent=$PARENT)" >&2
did_any=0

for P in $(lsblk -ln -o NAME,TYPE | awk '$2=="part"{print $1}'); do
  if readlink -f "/sys/class/block/$P/.." | grep -q "$PARENT"; then
    MP="/mnt/snap-$P"; sudo mkdir -p "$MP"
    if sudo mount -o ro "/dev/$P" "$MP" 2>/dev/null; then
      did_any=1
      echo "[worker] Mounted /dev/$P at $MP (read-only)." >&2
      copy_tree_files "$MP" "$P"
      sudo umount "$MP" || true
    fi
  fi
done

if [[ "$did_any" -eq 0 ]]; then
  if sudo mount -o ro "$DEV" /mnt/snap 2>/dev/null; then
    echo "[worker] Mounted whole device at /mnt/snap (read-only)." >&2
    copy_tree_files "/mnt/snap" "root"
    sudo umount /mnt/snap || true
  else
    sudo apt-get install -y ntfs-3g >/dev/null 2>&1 || true
    if sudo mount -o ro -t ntfs-3g "$DEV" /mnt/snap 2>/dev/null; then
      echo "[worker] Mounted NTFS device at /mnt/snap (read-only)." >&2
      copy_tree_files "/mnt/snap" "ntfs-root"
      sudo umount /mnt/snap || true
    else
      echo 'No mountable filesystem found.'; exit 11
    fi
  fi
fi

echo OK | sudo -H env HOME=/root gsutil cp - "gs://$BUCKET/$REMOTE_PREFIX/_OK"
EOS
fi

REMOTE_SCRIPT="${EXPORTS_DIR}/${REMOTE_PREFIX}.remote.sh"
{
  echo "BUCKET='${BUCKET}'"
  echo "REMOTE_PREFIX='${REMOTE_PREFIX}'"
  echo "TMP_DISK='${TMP_DISK}'"
  cat "$REMOTE_BODY"
} > "$REMOTE_SCRIPT"

gcloud compute scp --zone "$ZONE" "$REMOTE_SCRIPT" "${VM}:/tmp/worker.sh" >/dev/null
# 6h timeout on remote worker to avoid hanging forever; on timeout, compute cleanup still runs and storage is kept
gcloud compute ssh "$VM" --zone "$ZONE" --command "timeout 21600 bash /tmp/worker.sh"

# Session symlinks
if [[ -n "${SESSION_NAME:-}" ]]; then
  NAME_SAFE="$(sanitize_name "$SESSION_NAME")"
  ln -sfn "$STATE_FILE" "${EXPORTS_DIR}/${NAME_SAFE}.state" || true
  case "$LOCAL_DIR" in
    ${EXPORTS_DIR}/*) ln -sfn "$LOCAL_DIR" "${EXPORTS_DIR}/${NAME_SAFE}" || true ;;
  esac
  echo -e "${NAME_SAFE}\t${STATE_FILE}\t${BUCKET}\t${REMOTE_PREFIX}\t${TIMESTAMP}" >> "${EXPORTS_DIR}/sessions.tsv"
fi

# Compute cleanup immediately after remote upload to save costs
log "Cleanup compute… (post-upload)"
gcloud compute instances detach-disk "$VM" --disk="$TMP_DISK" --zone="$ZONE" --quiet >/dev/null || true
gcloud compute instances delete "$VM" --zone="$ZONE" --quiet >/dev/null || true
gcloud compute disks delete "$TMP_DISK" --zone="$ZONE" --quiet >/dev/null || true

# Local download (runs after compute cleanup)
trap - ERR
DL_RC=0
if [[ $SKIP_LOCAL -eq 1 ]]; then
  log "Skip local download. Artifacts: gs://${BUCKET}/${REMOTE_PREFIX}"
else
  log "Download from GCS → ${LOCAL_DIR}"
  set +e
  if command -v gsutil >/dev/null 2>&1; then
    gsutil -m rsync -r -c "gs://${BUCKET}/${REMOTE_PREFIX}" "${LOCAL_DIR}/"; DL_RC=$?
    if [[ $DL_RC -ne 0 ]]; then
      log "gsutil rsync failed (rc=$DL_RC); fallback to gcloud storage rsync/cp"
      if gcloud storage rsync --help >/dev/null 2>&1; then
        gcloud storage rsync "gs://${BUCKET}/${REMOTE_PREFIX}" "${LOCAL_DIR}/"; DL_RC=$?
      else
        gcloud storage cp -r "gs://${BUCKET}/${REMOTE_PREFIX}/*" "${LOCAL_DIR}/"; DL_RC=$?
      fi
    fi
  else
    if gcloud storage rsync --help >/dev/null 2>&1; then
      gcloud storage rsync "gs://${BUCKET}/${REMOTE_PREFIX}" "${LOCAL_DIR}/"; DL_RC=$?
    else
      gcloud storage cp -r "gs://${BUCKET}/${REMOTE_PREFIX}/*" "${LOCAL_DIR}/"; DL_RC=$?
    fi
  fi
  set -e
  [[ -f "${LOCAL_DIR}/_OK" ]] || log "WARNING: _OK marker missing; export may be incomplete."
fi

SUCCESS=0
if [[ $SKIP_LOCAL -ne 1 && ${DL_RC:-0} -eq 0 && -f "${LOCAL_DIR}/_OK" ]]; then SUCCESS=1; fi

# Cleanup storage unless kept
if [[ $KEEP_REMOTE -eq 1 || $SKIP_LOCAL -eq 1 || ${DL_RC:-0} -ne 0 ]]; then
  log "Keeping remote bucket/objects."
else
  log "Cleanup storage…"
  gcloud storage rm -r "gs://${BUCKET}/${REMOTE_PREFIX}" >/dev/null || true
  gcloud storage buckets delete "gs://${BUCKET}" --quiet >/dev/null || true
fi

log "DONE. Output: ${LOCAL_DIR}"
log "State: ${STATE_FILE}"

# Optional local state cleanup
if [[ $SUCCESS -eq 1 ]]; then
  if [[ $SILENT -eq 1 && $DELETE_STATE_AT_END -eq 1 ]]; then DO_DELETE=1
  elif [[ $SILENT -ne 1 ]]; then
    read -r -p "Delete local state/temp files now? [y/N]: " RESP
    [[ "$RESP" =~ ^(y|Y|yes|YES)$ ]] && DO_DELETE=1 || DO_DELETE=0
  fi
  if [[ "${DO_DELETE:-0}" -eq 1 ]]; then
    rm -f "$STATE_FILE" "$REMOTE_SCRIPT" 2>/dev/null || true
    if [[ -n "${SESSION_NAME:-}" ]]; then
      NAME_SAFE="$(sanitize_name "$SESSION_NAME")"
      [[ -L "${EXPORTS_DIR}/${NAME_SAFE}.state" ]] && rm -f "${EXPORTS_DIR}/${NAME_SAFE}.state" || true
      [[ -L "${EXPORTS_DIR}/${NAME_SAFE}" ]] && rm -f "${EXPORTS_DIR}/${NAME_SAFE}" || true
    fi
    log "Deleted local state and temp files."
  fi
fi
