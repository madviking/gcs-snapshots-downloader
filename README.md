# gcs_transfer — Export GCE snapshot contents efficiently

## Overview

- Mounts a GCE persistent disk snapshot read‑only on a tiny VM, streams the filesystem contents as compressed tarballs to a temporary GCS bucket, then downloads the artifacts locally and tears everything down.
- Copies only the true contents of files, not empty disk blocks. This makes exports faster, smaller, and cheaper than raw image exports while preserving file data.

### Why “only true contents” helps

- Efficiency: Skips unused disk space and sparse regions, reducing network egress, GCS storage, and local disk usage.
- Speed: Streams only real file data to GCS using tar + gzip; no need to copy raw blocks.
- Safety: Mounts snapshots read‑only and excludes volatile/system paths to avoid transient data.
- Portability: Produces standard `.tar.gz` archives that are easy to browse, verify, and restore.

### How it works

- Creates a temporary bucket and grants the Compute Engine default service account object admin on that bucket.
- Creates a tiny VM, attaches a temporary disk from the snapshot, mounts partitions read‑only, and streams each partition to `gs://<bucket>/<prefix>/<partition>.tar.gz`.
- Downloads the artifacts to `./exports/<prefix>/` locally and deletes compute resources. Optionally keeps the bucket/objects if `--keep-remote` is used.

## Prerequisites

- Google Cloud SDK installed: https://cloud.google.com/sdk
- Permissions in the target project to create Compute Engine instances/disks and Storage buckets/objects. Project Owner works; otherwise grant equivalent roles (e.g., Compute Admin + Service Account User + Storage Admin).

## Authenticate with GCP/GCS

- Authenticate your local gcloud and set the active project:
  - `gcloud auth login`
  - `gcloud config set project <YOUR_PROJECT_ID>`
- Optional (if you prefer Application Default Credentials on your machine):
  - `gcloud auth application-default login`
- The VM uses the project’s default Compute Engine service account; the script grants it temporary `roles/storage.objectAdmin` on the temp bucket so it can upload to GCS.

## Usage

- Command: `./transfer.sh <SNAPSHOT_NAME> <REGION> [--keep-remote] [--out-dir PATH]`
- Examples:
  - `./transfer.sh my-data-snap us-central1 --keep-remote`
  - `./transfer.sh my-data-snap us-central1 --out-dir /tmp/export`

### Arguments

- `SNAPSHOT_NAME`: Existing snapshot name in the active project
- `REGION`: Region for the temporary resources (e.g., `us-central1`)
- `--keep-remote`: Keep the temporary bucket and objects (skip storage cleanup)
 - `--out-dir PATH`: Download artifacts to `PATH` instead of `./exports/<prefix>`

### Outputs

- Local artifacts at `./exports/<unique-prefix>/` (or `PATH` if `--out-dir` is used)
- State file at `./exports/<unique-prefix>.state` (or `PATH.state` if `--out-dir` is used)

## Cleanup

- Automatic: On success, compute resources are deleted. If `--keep-remote` is not used, the bucket/objects are removed.
- Manual: If anything fails or you want to retry cleanup later:
  - `./cleanup_gce_snapshot_export.sh ./exports/<unique-prefix>.state`

## Notes and limitations

- The script attempts to detect and mount partitions; if none are found, it falls back to mounting the whole device. It also tries NTFS via `ntfs-3g` for Windows snapshots.
- Excludes transient/system paths (e.g., `/proc`, `/sys`, `/dev`, etc.) to keep exports clean and reproducible.
- APIs `compute.googleapis.com` and `storage.googleapis.com` are enabled idempotently by the script.

## Troubleshooting

- “Set project”: run `gcloud config set project <YOUR_PROJECT_ID>`.
- Auth errors: run `gcloud auth login` again (and optionally `gcloud auth application-default login`). Ensure your user has permissions to create Compute Engine resources and Storage buckets.
- SSH readiness timeout: ensure your region has an `UP` zone available and that firewall rules allow SSH for the project (defaults typically suffice when using `gcloud compute ssh`).

## License

MIT License © Timo Railo, 2025
