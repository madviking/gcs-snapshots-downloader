#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./download_gce_snapshot_export.sh <SESSION|STATE_FILE> [--out-dir PATH] [--only NAME]
#
# Resumes or performs a local download of previously uploaded artifacts using
# resumable, incremental sync (gsutil rsync if available).

usage() {
  cat <<EOF
Usage: $0 <SESSION|STATE_FILE> [--out-dir PATH] [--only NAME]

Downloads artifacts for a prior export session using the state file recorded
during export. You can pass either the path to a .state file or a friendly
session name created with --name (e.g., 'docker', 'docker-2').

Arguments:
  SESSION|STATE_FILE  Name (resolves ./exports/NAME.state) or an absolute/relative
                      path to a state file containing BUCKET and REMOTE_PREFIX.
  --out-dir PATH      Download to PATH instead of the state file's LOCAL_DIR
  --only NAME         Download only a single archive (e.g., root.tar.gz or sda1.tar.gz).
                      When used, the destination will be a folder named after the
                      archive (basename without common tar/compress suffixes), and the
                      file will be saved inside it with its original filename.

Examples:
  $0 docker
  $0 ./exports/files-foo-20250101-000000-abc123.state --out-dir ./exports/foo
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 ]]; then
  usage
  exit 0
fi

TARGET="$1"; shift || true
OUT_DIR=""
ONLY_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="${2:?--out-dir requires a PATH}"; shift 2 ;;
    --only)
      ONLY_NAME="${2:?--only requires an archive NAME}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

STATE_FILE=""
if [[ -f "$TARGET" ]]; then
  STATE_FILE="$TARGET"
elif [[ -f "./exports/${TARGET}.state" ]]; then
  STATE_FILE="./exports/${TARGET}.state"
else
  echo "Could not resolve session or state file: $TARGET" >&2
  echo "Hint: check ./exports/*.state or provide a full path." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$STATE_FILE"

if [[ -z "${BUCKET:-}" || -z "${REMOTE_PREFIX:-}" ]]; then
  echo "State file missing BUCKET/REMOTE_PREFIX: $STATE_FILE" >&2
  exit 2
fi

if [[ -n "$ONLY_NAME" ]]; then
  # Single-object download; create a folder named after the archive and save file inside
  SRC="gs://${BUCKET}/${REMOTE_PREFIX}/${ONLY_NAME}"
  NAME_BASENAME="$(basename "$ONLY_NAME")"
  # Derive folder name from archive name without common suffixes
  FOLDER_NAME="$NAME_BASENAME"
  FOLDER_NAME="${FOLDER_NAME%.tar.gz}"
  FOLDER_NAME="${FOLDER_NAME%.tgz}"
  FOLDER_NAME="${FOLDER_NAME%.tar.zst}"
  FOLDER_NAME="${FOLDER_NAME%.tar.bz2}"
  FOLDER_NAME="${FOLDER_NAME%.tar.xz}"
  FOLDER_NAME="${FOLDER_NAME%.tar}"

  ROOT_DIR="${OUT_DIR:-${LOCAL_DIR:-./exports/${REMOTE_PREFIX}}}"
  DEST_DIR="$ROOT_DIR/$FOLDER_NAME"
  mkdir -p "$DEST_DIR"
  DEST="$DEST_DIR/$NAME_BASENAME"

  echo "[*] Downloading single archive to: $DEST"
  if command -v gsutil >/dev/null 2>&1; then
    gsutil cp -n "$SRC" "$DEST"
  else
    gcloud storage cp "$SRC" "$DEST"
  fi
  echo "[✓] Download complete: $DEST"
else
  DEST_DIR="${OUT_DIR:-${LOCAL_DIR:-./exports/${REMOTE_PREFIX}}}"
  mkdir -p "$DEST_DIR"
  echo "[*] Resumable download to: $DEST_DIR"
  if command -v gsutil >/dev/null 2>&1; then
    gsutil -m rsync -r -c "gs://${BUCKET}/${REMOTE_PREFIX}" "$DEST_DIR/"
  elif gcloud storage rsync --help >/dev/null 2>&1; then
    gcloud storage rsync "gs://${BUCKET}/${REMOTE_PREFIX}" "$DEST_DIR/"
  else
    echo "Neither gsutil nor gcloud storage rsync available; falling back to cp -r" >&2
    gcloud storage cp -r "gs://${BUCKET}/${REMOTE_PREFIX}/*" "$DEST_DIR/"
  fi
  if [[ ! -f "$DEST_DIR/_OK" ]]; then
    echo "[!] WARNING: _OK marker not found; export may be incomplete." >&2
  fi
  echo "[✓] Download complete."
fi
