#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--include-compute] <STATE_FILE|SESSION_NAME>

Cleans up artifacts created by export_gce_snapshot.sh using the recorded state.
By default only Storage artifacts are removed (objects + bucket). The exporter
already deletes compute resources right after upload to GCS. Pass
--include-compute to also attempt VM/disk cleanup (idempotent).

Examples:
  $0 ./exports/<prefix>.state
  $0 docker
  $0 --include-compute docker
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

INCLUDE_COMPUTE=0
if [[ "${1:-}" == "--include-compute" ]]; then
  INCLUDE_COMPUTE=1; shift || true
fi

ARG1="${1:?Usage: $0 [--include-compute] <STATE_FILE|SESSION_NAME>}"

if [[ -f "${ARG1}" ]]; then
  STATE_FILE="${ARG1}"
elif [[ -f "./exports/${ARG1}.state" ]]; then
  STATE_FILE="./exports/${ARG1}.state"
else
  STATE_FILE="${ARG1}"
fi

if [[ ! -f "${STATE_FILE}" ]]; then
  echo "[!] State file not found: ${STATE_FILE}"
  echo "[i] Nothing to clean."
  exit 0
fi

# shellcheck disable=SC1090
source "${STATE_FILE}"

# Required fields from state file:
# PROJECT, REGION, ZONE, BUCKET, DISK, VM, REMOTE_PREFIX (some may be missing if creation failed early)
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"

echo "[*] Cleanup using state: ${STATE_FILE}"
echo "[*] Project: ${PROJECT}"
echo "[*] Zone: ${ZONE:-<unknown>}"
echo "[*] VM: ${VM:-<none>}"
echo "[*] Disk: ${DISK:-<none>}"
echo "[*] Bucket: ${BUCKET:-<none>}"
echo "[*] Prefix: ${REMOTE_PREFIX:-<none>}"

if [[ ${INCLUDE_COMPUTE} -eq 1 ]]; then
  # Detach disk (if both VM and DISK exist)
  if [[ -n "${VM:-}" && -n "${DISK:-}" && -n "${ZONE:-}" ]]; then
    echo "[*] Detach disk ${DISK} from VM ${VM} (if attached)…"
    gcloud compute instances detach-disk "${VM}" --disk="${DISK}" --zone="${ZONE}" --quiet >/dev/null 2>&1 || true
  fi

  # Delete VM
  if [[ -n "${VM:-}" && -n "${ZONE:-}" ]]; then
    echo "[*] Delete VM ${VM}…"
    gcloud compute instances delete "${VM}" --zone="${ZONE}" --quiet >/dev/null 2>&1 || true
  fi

  # Delete Disk
  if [[ -n "${DISK:-}" && -n "${ZONE:-}" ]]; then
    echo "[*] Delete Disk ${DISK}…"
    gcloud compute disks delete "${DISK}" --zone="${ZONE}" --quiet >/dev/null 2>&1 || true
  fi
else
  echo "[*] Skipping compute cleanup (use --include-compute to enable)."
fi

# Delete objects under prefix
if [[ -n "${BUCKET:-}" && -n "${REMOTE_PREFIX:-}" ]]; then
  echo "[*] Delete objects gs://${BUCKET}/${REMOTE_PREFIX}…"
  gcloud storage rm -r "gs://${BUCKET}/${REMOTE_PREFIX}" >/dev/null 2>&1 || true
fi

# Delete bucket
if [[ -n "${BUCKET:-}" ]]; then
  echo "[*] Delete bucket gs://${BUCKET}…"
  gcloud storage buckets delete "gs://${BUCKET}" --quiet >/dev/null 2>&1 || true
fi

echo "[✓] Cleanup complete."
