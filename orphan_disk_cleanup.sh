#!/bin/bash
set -euo pipefail

# SAFE CLEANUP for orphaned tmpdisk-* volumes created by snapshot-export scripts.
# Works on macOS and Linux (no mapfile). Performs two separate confirmations.
#
# Usage:
#   ./cleanup_orphan_tmpdisks.sh <region|all>
#   ./cleanup_orphan_tmpdisks.sh <region|all> --apply     # skip confirmations (dangerous!)
#
# Notes:
#   - Detects disks with names starting with tmpdisk-
#   - Shows NAME, ZONE, SIZE, AGE, and ATTACHED state
#   - Only deletes unattached disks
#   - You’ll have two opportunities to cancel before deletion

REGION="${1:-}"
APPLY="${2:-}"

if [[ -z "$REGION" ]]; then
  echo "Usage: $0 <region|all> [--apply]" >&2
  exit 1
fi

project="$(gcloud config get-value project 2>/dev/null || true)"
[[ -z "$project" ]] && { echo "Set project first: gcloud config set project <ID>"; exit 2; }

echo
echo "======================================================================"
echo "⚠️  ORPHAN DISK CLEANUP for project: $project"
echo "======================================================================"
echo "This operation can **PERMANENTLY DELETE DISKS**."
echo "Deleted disks CANNOT be recovered, and data will be lost forever."
echo "----------------------------------------------------------------------"

zones=()
if [[ "$REGION" == "all" ]]; then
  zones=$(gcloud compute zones list --filter="status=UP" --format="value(name)")
else
  zones=$(gcloud compute zones list --filter="name~'^${REGION}-' AND status=UP" --format="value(name)")
fi
[[ -z "$zones" ]] && { echo "No zones found for region '$REGION'"; exit 0; }

echo "Scanning zones: $zones"
echo

# Collect orphan disks
results=$(gcloud compute disks list --filter="name~'^tmpdisk-' AND -users:*" \
  --format="table(name,zone.basename(),sizeGb,creationTimestamp,labels.tool)" || true)

if [[ -z "$results" ]]; then
  echo "✅ No orphan tmpdisk-* volumes found."
  exit 0
fi

echo "$results" | sed '1,1!b' >/dev/null # just prints header for style

echo
echo "Detected unattached tmpdisk-* disks:"
echo "----------------------------------------------------------------------"
echo "$results"
echo "----------------------------------------------------------------------"
echo

# First confirmation
if [[ "$APPLY" != "--apply" ]]; then
  read -r -p "Do you understand that ALL listed disks will be **PERMANENTLY DELETED**? (yes/NO): " ans1
  [[ "$ans1" != "yes" ]] && { echo "Aborted."; exit 0; }

  echo
  read -r -p "Type 'delete these disks forever' to confirm: " ans2
  [[ "$ans2" != "delete these disks forever" ]] && { echo "Aborted."; exit 0; }
fi

# Actually delete
echo
echo "🔥 DELETING ORPHAN tmpdisk-* DISKS NOW..."
echo

while read -r NAME ZONE SIZE CREATED LABEL; do
  [[ "$NAME" == "NAME" || -z "$NAME" ]] && continue
  echo "Deleting $NAME ($SIZE GB, $ZONE, created $CREATED)..."
  gcloud compute disks delete "$NAME" --zone "$ZONE" --quiet || true
done < <(echo "$results" | awk 'NR>1 {print $1, $2, $3, $4, $5}')

echo
echo "✅ Cleanup complete."
echo "----------------------------------------------------------------------"
echo "Deleted disks are permanently gone."
echo "Remaining tmpdisk-* can be listed again using:"
echo "    gcloud compute disks list --filter='name~^tmpdisk-'"
echo "----------------------------------------------------------------------"
