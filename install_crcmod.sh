#!/usr/bin/env bash
set -euo pipefail

# Installs compiled crcmod for faster gsutil transfers and prints
# instructions to point Cloud SDK to the Python that has it.

log() { echo "[$(date +%H:%M:%S)] $*"; }

OS="$(uname -s 2>/dev/null || echo unknown)"
PY="${PYTHON:-${PYTHON3:-$(command -v python3 || true)}}"
[[ -z "${PY}" ]] && { echo "python3 not found. Install Python 3 first."; exit 1; }

log "Using Python: ${PY} ($(${PY} -V 2>&1))"

if [[ "${OS}" == "Darwin" ]]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    log "Xcode Command Line Tools not found. Installing (GUI prompt)…"
    xcode-select --install || true
    echo "Re-run this script after CLT installation completes."; exit 1
  fi
fi

log "Upgrading pip/setuptools/wheel…"
"${PY}" -m pip install -U pip setuptools wheel >/dev/null

log "Installing crcmod with C extension (no binary wheel)…"
"${PY}" -m pip install -U --no-binary crcmod crcmod

log "Verifying crcmod extension…"
EXT_OK=$("${PY}" - <<'PY'
import sys
try:
    import crcmod
    ok = getattr(crcmod, '_usingExtension', None)
    print('True' if ok else 'False')
except Exception as e:
    print('False')
PY
)

if [[ "${EXT_OK}" != "True" ]]; then
  echo "[!] crcmod installed, but C extension not detected. Performance may still be slow."
  echo "    Ensure build tools are present, then re-run:"
  echo "    ${PY} -m pip install -U --no-binary crcmod crcmod"
  exit 1
fi

cat <<EOF
[✓] crcmod with C extension is installed for ${PY}.

To have gsutil use this Python, set (and optionally persist) the environment:

  export CLOUDSDK_PYTHON="${PY}"
  gsutil version -l | grep -Ei 'crcmod|python'

You should see compiled crcmod enabled. Sliced downloads will be used and
rsync checksumming will be faster.
EOF

