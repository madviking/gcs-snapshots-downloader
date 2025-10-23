# Copy archived Google Cloud (GCS) Compute Engine archived snapshots to local disk reliably

## Overview

- Mounts a GCE persistent disk snapshot read‑only on a VM, streams the filesystem contents as compressed tarballs to a temporary GCS bucket, then downloads the artifacts locally and tears everything down.
- Copies only the true contents of files, not empty disk blocks. This makes exports faster, smaller, and cheaper than raw image exports while preserving file data.

### Why “only true contents” helps

- Efficiency: Skips unused disk space and sparse regions, reducing network egress, GCS storage, and local disk usage.
- Speed: Streams only real file data to GCS using tar + gzip; no need to copy raw blocks.
- Safety: Mounts snapshots read‑only and excludes volatile/system paths to avoid transient data.
- Portability: Produces standard `.tar.gz` archives that are easy to browse, verify, and restore.

### How it works (flow)

1) Enable required APIs (`compute.googleapis.com`, `storage.googleapis.com`).
2) Pick an `UP` zone in your target region.
3) Create a temporary GCS bucket and grant the project’s default Compute service account object admin on it.
4) Create a temporary disk from the snapshot (read‑only), and a temporary VM (with fallback machine types).
5) Attach the disk and push a small worker script to the VM.
6) Stream the filesystem to GCS as `.tar.gz` archives (one per partition, or `root.tar.gz`/`ntfs-root.tar.gz`). Live progress is printed.
7) Immediately delete the VM and temp disk to stop compute costs.
8) Download artifacts to your machine with a resumable sync (can be resumed later).
9) Optionally delete remote objects and the bucket (or keep them with `--keep-remote`).

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

- Export: `./export_gce_snapshot.sh <SNAPSHOT_NAME> <REGION> [options]`
- Download only: `./download_gce_snapshot_export.sh <SESSION|STATE_FILE> [--out-dir PATH] [--only NAME]`
- Cleanup: `./cleanup_gce_snapshot_export.sh [--include-compute] <SESSION|STATE_FILE>`
 - Optional: install compiled crcmod for faster downloads: `./install_crcmod.sh`

Examples
- Export with confirmation: `./export_gce_snapshot.sh my-snap us-central1`
- Export to custom dir and keep remote: `./export_gce_snapshot.sh my-snap us-central1 --out-dir /tmp/export --keep-remote`
- Export with a friendly name: `./export_gce_snapshot.sh my-snap us-central1 --name docker`
- Non‑interactive and delete state on success: `./export_gce_snapshot.sh my-snap us-central1 --silent --delete-state-at-end`
- Download everything later (resumable): `./download_gce_snapshot_export.sh docker`
- Download one archive and keep filename: `./download_gce_snapshot_export.sh docker --only root.tar.gz --out-dir /tmp/`
- Cleanup storage (default): `./cleanup_gce_snapshot_export.sh docker`
- Cleanup including compute (if needed): `./cleanup_gce_snapshot_export.sh --include-compute docker`

### Export options

- `SNAPSHOT_NAME` (positional): Existing snapshot name in the active project
- `REGION` (positional): Region for temporary resources (e.g. `us-central1`)
- `--out-dir PATH`: Local destination root. The export creates `PATH/<snapshot-or-name>/` and `PATH/<snapshot-or-name>.state`.
- `--name NAME`: Friendly alias; creates symlinks `./exports/NAME` and `./exports/NAME.state`.
- `--keep-remote`: Keep bucket/objects (skip storage cleanup).
- `--skip-local`: Skip the local download step; leave data only in GCS.
- `--silent` (`-y`, `--yes`): Skip the upfront cost prompt.
- `--delete-state-at-end`: With `--silent`, delete local state/temp files on successful download.
- `--machine-type TYPE`: VM type; default is automatic fallback among fast, quota‑friendly types.
- `--disk-type TYPE`: Temporary disk type for the snapshot (default `pd-ssd`).
- `--mode archive|files`: Default `archive` streams tar.gz to GCS (fast and compact). `files` copies per‑file (slower for many small files).
- `--cleanup STATEFILE`: Run cleanup immediately using a previous state file and exit.

### Download options

- `--out-dir PATH`: Override destination (default is the state file’s `LOCAL_DIR`).
- `--only NAME`: Download a single archive (e.g., `root.tar.gz`). The downloader creates a folder named after the archive and saves the file inside with the same name.

### Faster downloads (crcmod)

- macOS/Linux: run `./install_crcmod.sh` to build crcmod with a C extension and print an `export CLOUDSDK_PYTHON=…` hint so gsutil uses that Python.
- Verify: `gsutil version -l` should show compiled crcmod; sliced downloads will be enabled and rsync checksums speed up.

### Outputs

- Local artifacts:
  - Default: `./exports/<prefix>/`
  - With `--out-dir`: `<out-dir>/<snapshot-or-name>/`
- State file:
  - Default: `./exports/<prefix>.state`
  - With `--out-dir`: `<out-dir>/<snapshot-or-name>.state`
- Remote artifacts in GCS: `gs://<bucket>/<prefix>/`

## Cleanup

- Automatic:
  - VM and temp disk are deleted immediately after the remote upload finishes (before local download) to save costs.
  - Storage cleanup runs at the very end only if not `--keep-remote` and the local download succeeded.
- Manual:
  - Storage only (default): `./cleanup_gce_snapshot_export.sh <SESSION|STATE_FILE>`
  - Include compute (idempotent): `./cleanup_gce_snapshot_export.sh --include-compute <SESSION|STATE_FILE>`

## Notes and limitations

- The script attempts to detect and mount partitions; if none are found, it falls back to mounting the whole device. It also tries NTFS via `ntfs-3g` for Windows snapshots.
- Excludes transient/system paths (e.g., `/proc`, `/sys`, `/dev`, etc.) when creating tarballs.
- APIs `compute.googleapis.com` and `storage.googleapis.com` are enabled idempotently by the script.

### Why stage in GCS?

- Reliability and resumability: VM→GCS uploads are resumable; local downloads resume with `gsutil rsync`.
- Cost efficiency: VM can be deleted immediately after upload; you only pay short‑lived GCS storage while downloading.
- Permissions: grant the VM’s service account temporary object admin on one bucket; no long SSH streams to your local.

## Troubleshooting

- “Set project”: run `gcloud config set project <YOUR_PROJECT_ID>`.
- Auth errors: run `gcloud auth login` again (and optionally `gcloud auth application-default login`). Ensure your user has permissions to create Compute Engine resources and Storage buckets.
- SSH readiness timeout: ensure your region has an `UP` zone and SSH is allowed.
- macOS + gsutil warnings about crcmod: install the C extension `python3 -m pip install -U crcmod` for fast checksums.
- If `gsutil -m rsync` multiprocessing is problematic on macOS: `-o "GSUtil:parallel_process_count=1"` keeps multithreading.

## License

MIT License © Timo Railo, 2025
