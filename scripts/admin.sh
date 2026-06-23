#!/usr/bin/env bash
#
# admin.sh — convenience wrapper for restic administrative tasks against the
# running setup. Runs restic inside the same image with the repo + env mounted.
#
# Usage:
#   ./admin.sh snapshots                 # list snapshots
#   ./admin.sh stats                     # repository statistics
#   ./admin.sh check                     # structural integrity check
#   ./admin.sh check-data                # check + read 5% of data (heavier)
#   ./admin.sh restore <SNAPSHOT_ID> <TARGET_SUBPATH>
#                                        # restore into ./restore on the host
#   ./admin.sh mount                     # FUSE-mount snapshots (needs --privileged; see notes)
#   ./admin.sh unlock                    # remove stale restic locks
#   ./admin.sh raw -- <any restic args>  # run an arbitrary restic command
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
IMAGE="${IMAGE:-onedrive-nas:latest}"

[ -f "${ENV_FILE}" ] || { echo "Missing ${ENV_FILE}"; exit 1; }

# Resolve the HDD data path from .env (DATA_DIR on the host).
set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a
: "${DATA_DIR:?DATA_DIR must be set in .env}"
: "${RESTIC_REPOSITORY:=/data/restic-repo}"

run_restic() {
  docker run --rm -it \
    --env-file "${ENV_FILE}" \
    -e RESTIC_REPOSITORY="${RESTIC_REPOSITORY}" \
    -v "${DATA_DIR}:/data" \
    -v "${PROJECT_DIR}/restore:/restore" \
    --entrypoint restic \
    "${IMAGE}" "$@"
}

cmd="${1:-}"; shift || true
case "${cmd}" in
  snapshots)   run_restic snapshots ;;
  stats)       run_restic stats ;;
  check)       run_restic check ;;
  check-data)  run_restic check --read-data-subset=5% ;;
  unlock)      run_restic unlock ;;
  restore)
    SNAP="${1:?need snapshot id}"; SUB="${2:-}"
    mkdir -p "${PROJECT_DIR}/restore"
    if [ -n "${SUB}" ]; then
      run_restic restore "${SNAP}" --include "/data/mirror/${SUB}" --target /restore
    else
      run_restic restore "${SNAP}" --target /restore
    fi
    echo "Restored into ${PROJECT_DIR}/restore"
    ;;
  mount)
    echo "Mounting snapshots at /restore inside a privileged container."
    echo "Browse them on the host under ${PROJECT_DIR}/restore. Ctrl-C to unmount."
    mkdir -p "${PROJECT_DIR}/restore"
    docker run --rm -it \
      --env-file "${ENV_FILE}" \
      -e RESTIC_REPOSITORY="${RESTIC_REPOSITORY}" \
      --cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor:unconfined \
      -v "${DATA_DIR}:/data" \
      -v "${PROJECT_DIR}/restore:/restore:shared" \
      --entrypoint restic \
      "${IMAGE}" mount /restore
    ;;
  raw)
    [ "${1:-}" = "--" ] && shift
    run_restic "$@"
    ;;
  *)
    grep '^#   ' "$0" | sed 's/^#   //'
    exit 1
    ;;
esac
