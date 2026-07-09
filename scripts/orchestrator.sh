#!/usr/bin/env bash
#
# orchestrator.sh — entrypoint for the onedrive-nas container.
#
# Runs a single loop: rclone sync (OneDrive -> /data/mirror). Restic backup,
# retention, and prune are no longer handled here — the backrest service owns
# all of that on its own cron schedule (see docker-compose.yml / README).
#
# Everything is driven by environment variables (see .env.example).

set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration (with defaults). All overridable via environment.
# ----------------------------------------------------------------------------
: "${RCLONE_REMOTE:=onedrive:}"          # rclone remote + optional path
: "${MIRROR_DIR:=/data/mirror}"          # where the live mirror is written
: "${MIRROR_INTERVAL:=300}"              # seconds between mirror runs (5 min)
: "${RCLONE_TRANSFERS:=1}"
: "${RCLONE_CHECKERS:=2}"
: "${RCLONE_TPSLIMIT:=10}"               # cap transactions/sec (OneDrive throttling)
: "${RCLONE_EXTRA_FLAGS:=}"              # power-user escape hatch
: "${LOG_LEVEL:=INFO}"
: "${DISK_USAGE_WARN_PCT:=85}"           # warn threshold for the disk guard

log() { echo "$(date -Iseconds) [$1] ${2}"; }

# ----------------------------------------------------------------------------
# Disk guard: warns (does not block) when the filesystem holding /data is
# nearly full. Scoped to protecting the mirror only — retention/space for the
# restic repo is backrest's own concern now.
# ----------------------------------------------------------------------------
disk_used_pct() {
  df -P /data | awk 'NR==2 {gsub("%","",$5); print $5}'
}

# ----------------------------------------------------------------------------
# Mirror loop
# ----------------------------------------------------------------------------
mirror_loop() {
  log mirror "loop started; remote=${RCLONE_REMOTE} dest=${MIRROR_DIR} interval=${MIRROR_INTERVAL}s"
  while true; do
    used=$(disk_used_pct)
    if [ "${used:-0}" -ge "${DISK_USAGE_WARN_PCT}" ]; then
      log mirror "DISK WARNING: /data at ${used}% >= warn ${DISK_USAGE_WARN_PCT}%. Consider tightening Backrest retention."
    fi

    log mirror "starting rclone sync"
    # sync: local mirror becomes an exact replica of OneDrive, including deletions.
    # The source→destination direction means rclone never writes to OneDrive.
    # --delete-after: finish all downloads before removing anything locally,
    # so a partial run never leaves the mirror in a half-deleted state.
    # shellcheck disable=SC2086
    rclone sync "${RCLONE_REMOTE}" "${MIRROR_DIR}" \
      --create-empty-src-dirs \
      --delete-after \
      --transfers "${RCLONE_TRANSFERS}" \
      --checkers "${RCLONE_CHECKERS}" \
      --tpslimit "${RCLONE_TPSLIMIT}" \
      --log-level "${LOG_LEVEL}" \
      --ignore-size \
      ${RCLONE_EXTRA_FLAGS}
    rc=$?
    if [ $rc -eq 0 ]; then
      log mirror "rclone sync completed cleanly"
    else
      log mirror "rclone sync exited rc=${rc} (will retry next cycle)"
    fi

    log mirror "sleeping ${MIRROR_INTERVAL}s"
    sleep "${MIRROR_INTERVAL}"
  done
}

# ----------------------------------------------------------------------------
# Startup: sanity checks, then launch the mirror loop.
# ----------------------------------------------------------------------------
log main "onedrive-nas starting"
log main "mirror -> ${MIRROR_DIR}"

# Guard: verify /data is on a different filesystem than /. If they share the
# same device the HDD is not mounted — nofail in fstab lets the Pi boot without
# the drive, leaving /data as a bare directory on the SD card root. Writing
# mirror data there would silently fill the SD card, so we refuse to start
# instead.
data_dev=$(df --output=source /data 2>/dev/null | tail -1)
root_dev=$(df --output=source /     2>/dev/null | tail -1)
if [ "${data_dev}" = "${root_dev}" ]; then
  log main "FATAL: /data is on the same filesystem as / (device: ${data_dev})."
  log main "FATAL: The HDD is probably not mounted. Fix the mount and restart."
  exit 1
fi
log main "mount guard passed (/data on ${data_dev}, / on ${root_dev})"

trap 'log main "shutting down"; exit 0' SIGTERM SIGINT

mirror_loop
