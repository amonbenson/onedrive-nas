#!/usr/bin/env bash
#
# orchestrator.sh — entrypoint for the onedrive-nas container.
#
# Runs two independent background loops in a single container:
#   1. mirror loop  (rclone copy onedrive -> /data/mirror)   — frequent
#   2. snapshot loop (restic backup + GFS forget/prune)      — daily-ish
#
# Why one container with two loops instead of two containers?
#   - Both loops must coordinate via a shared lock so that a restic *prune*
#     (which locks the repo and is I/O heavy) never overlaps a mirror run in a
#     way that thrashes the Pi's USB bus or the HDD. A shared in-process lock
#     file is the simplest way to guarantee that.
#   - It keeps the moving parts and the compose file smaller.
#
# Everything is driven by environment variables (see .env.example).

set -uo pipefail

# ----------------------------------------------------------------------------
# Configuration (with defaults). All overridable via environment.
# ----------------------------------------------------------------------------
: "${RCLONE_REMOTE:=onedrive:}"          # rclone remote + optional path
: "${MIRROR_DIR:=/data/mirror}"          # where the live mirror is written
: "${RESTIC_REPOSITORY:=/data/restic-repo}"
: "${MIRROR_INTERVAL:=300}"              # seconds between mirror runs (5 min)
: "${SNAPSHOT_INTERVAL:=86400}"          # seconds between restic snapshots (24h)
: "${RESTIC_HOST:=onedrive-nas}"         # restic --host tag
: "${RESTIC_TAG:=onedrive}"              # restic --tag
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"
: "${KEEP_YEARLY:=0}"
: "${RCLONE_TRANSFERS:=1}"
: "${RCLONE_CHECKERS:=2}"
: "${RCLONE_TPSLIMIT:=10}"               # cap transactions/sec (OneDrive throttling)
: "${RCLONE_EXTRA_FLAGS:=}"              # power-user escape hatch
: "${LOG_LEVEL:=INFO}"
: "${DISK_USAGE_WARN_PCT:=85}"           # warn threshold for the disk guard
: "${DISK_USAGE_HALT_PCT:=92}"           # above this, skip snapshots to protect disk
: "${DISABLE_SNAPSHOTS:=0}"              # set to 1 to run mirror-only (stage 1)
: "${RESTIC_PACK_SIZE:=128}"             # MB per pack file; larger = smaller index = less RAM
: "${PRUNE_EVERY_N:=7}"                 # run forget--prune only every N snapshots (weekly on daily schedule)

LOCK_DIR="/tmp/onedrive-nas.lock"        # mkdir-based mutex shared by both loops

log() { echo "$(date -Iseconds) [$1] ${2}"; }

# ----------------------------------------------------------------------------
# Mutex: mkdir is atomic, so it works as a simple cross-process lock. A loop
# acquires it before doing heavy work and releases it after. The mirror loop
# yields to an in-progress snapshot/prune and vice-versa.
# ----------------------------------------------------------------------------
acquire_lock() {
  # $1 = human label, $2 = max seconds to wait
  local label="$1" timeout="${2:-3600}" waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ "$waited" -ge "$timeout" ]; then
      log "$label" "could not acquire lock within ${timeout}s, skipping this cycle"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "$label $$" > "$LOCK_DIR/owner"
  return 0
}

release_lock() { rm -rf "$LOCK_DIR"; }

# ----------------------------------------------------------------------------
# Disk guard: returns the integer % used of the filesystem holding /data.
# ----------------------------------------------------------------------------
disk_used_pct() {
  df -P /data | awk 'NR==2 {gsub("%","",$5); print $5}'
}

# ----------------------------------------------------------------------------
# STAGE 1 — mirror loop
# ----------------------------------------------------------------------------
mirror_loop() {
  log mirror "loop started; remote=${RCLONE_REMOTE} dest=${MIRROR_DIR} interval=${MIRROR_INTERVAL}s"
  while true; do
    if acquire_lock "mirror" 1800; then
      log mirror "starting rclone copy"
      # copy (NOT sync): never deletes locally files removed online.
      # shellcheck disable=SC2086
      rclone copy "${RCLONE_REMOTE}" "${MIRROR_DIR}" \
        --create-empty-src-dirs \
        --transfers "${RCLONE_TRANSFERS}" \
        --checkers "${RCLONE_CHECKERS}" \
        --tpslimit "${RCLONE_TPSLIMIT}" \
        --log-level "${LOG_LEVEL}" \
        ${RCLONE_EXTRA_FLAGS}
      rc=$?
      if [ $rc -eq 0 ]; then
        log mirror "rclone copy completed cleanly"
      else
        log mirror "rclone copy exited rc=${rc} (will retry next cycle)"
      fi
      release_lock
    fi
    log mirror "sleeping ${MIRROR_INTERVAL}s"
    sleep "${MIRROR_INTERVAL}"
  done
}

# ----------------------------------------------------------------------------
# STAGE 2 — snapshot loop (restic backup + GFS forget/prune)
# ----------------------------------------------------------------------------
snapshot_loop() {
  if [ "${DISABLE_SNAPSHOTS}" = "1" ]; then
    log snapshot "DISABLE_SNAPSHOTS=1 — stage 2 disabled, running mirror-only"
    return 0
  fi

  log snapshot "loop started; repo=${RESTIC_REPOSITORY} interval=${SNAPSHOT_INTERVAL}s pack_size=${RESTIC_PACK_SIZE}MB prune_every=${PRUNE_EVERY_N}"
  snap_count=0
  while true; do
    sleep "${SNAPSHOT_INTERVAL}"   # snapshot AFTER first interval, lets mirror populate first

    used=$(disk_used_pct)
    if [ "${used:-0}" -ge "${DISK_USAGE_HALT_PCT}" ]; then
      log snapshot "DISK GUARD: /data at ${used}% >= halt ${DISK_USAGE_HALT_PCT}%; SKIPPING snapshot to protect disk. Tighten retention!"
      continue
    fi

    if acquire_lock "snapshot" 3600; then
      log snapshot "starting restic backup (disk at ${used}%)"
      restic backup "${MIRROR_DIR}" \
        --host "${RESTIC_HOST}" \
        --tag "${RESTIC_TAG}" \
        --pack-size "${RESTIC_PACK_SIZE}" \
        --verbose
      brc=$?
      if [ $brc -ne 0 ]; then
        log snapshot "restic backup exited rc=${brc} (will retry next cycle)"
      else
        snap_count=$((snap_count + 1))
        # Prune every PRUNE_EVERY_N successful snapshots (default 7 = weekly).
        # Prune is the most RAM-hungry restic operation; decoupling it from the
        # daily backup keeps peak memory spikes infrequent on low-RAM Pis.
        if [ $((snap_count % PRUNE_EVERY_N)) -eq 0 ]; then
          log snapshot "restic backup ok (snap #${snap_count}); applying GFS retention"
          keep_flags=(--keep-daily "${KEEP_DAILY}" --keep-weekly "${KEEP_WEEKLY}" --keep-monthly "${KEEP_MONTHLY}")
          if [ "${KEEP_YEARLY}" -gt 0 ]; then
            keep_flags+=(--keep-yearly "${KEEP_YEARLY}")
          fi
          restic forget \
            --host "${RESTIC_HOST}" \
            --tag "${RESTIC_TAG}" \
            "${keep_flags[@]}" \
            --prune
          frc=$?
          [ $frc -ne 0 ] && log snapshot "restic forget/prune exited rc=${frc}"
        else
          log snapshot "restic backup ok (snap #${snap_count}); prune deferred (runs every ${PRUNE_EVERY_N} snapshots)"
        fi
      fi
      release_lock
    fi

    # Post-cycle disk warning.
    used=$(disk_used_pct)
    if [ "${used:-0}" -ge "${DISK_USAGE_WARN_PCT}" ]; then
      log snapshot "DISK WARNING: /data at ${used}% >= warn ${DISK_USAGE_WARN_PCT}%. Consider tightening KEEP_* retention."
    fi
  done
}

# ----------------------------------------------------------------------------
# Startup: sanity checks, then launch both loops.
# ----------------------------------------------------------------------------
log main "onedrive-nas starting"
log main "mirror -> ${MIRROR_DIR} | repo -> ${RESTIC_REPOSITORY}"

# Stale lock from an unclean shutdown? Clear it.
[ -d "$LOCK_DIR" ] && { log main "clearing stale lock"; rm -rf "$LOCK_DIR"; }

# Guard: verify /data is on a different filesystem than /. If they share the
# same device the HDD is not mounted — nofail in fstab lets the Pi boot without
# the drive, leaving /data as a bare directory on the SD card root. Writing
# mirror data or initialising a restic repo there would silently fill the SD
# card, so we refuse to start instead.
data_dev=$(df --output=source /data 2>/dev/null | tail -1)
root_dev=$(df --output=source /     2>/dev/null | tail -1)
if [ "${data_dev}" = "${root_dev}" ]; then
  log main "FATAL: /data is on the same filesystem as / (device: ${data_dev})."
  log main "FATAL: The HDD is probably not mounted. Fix the mount and restart."
  exit 1
fi
log main "mount guard passed (/data on ${data_dev}, / on ${root_dev})"

# Ensure restic repo exists; init if missing. RESTIC_PASSWORD must be set.
if [ -z "${RESTIC_PASSWORD:-}" ] && [ -z "${RESTIC_PASSWORD_FILE:-}" ]; then
  log main "FATAL: neither RESTIC_PASSWORD nor RESTIC_PASSWORD_FILE is set"
  exit 1
fi

if [ "${DISABLE_SNAPSHOTS}" != "1" ]; then
  if ! restic cat config >/dev/null 2>&1; then
    log main "restic repo not found at ${RESTIC_REPOSITORY}; initializing"
    if ! restic init; then
      log main "FATAL: restic init failed"
      exit 1
    fi
    log main "restic repo initialized"
  else
    log main "restic repo present"
  fi
fi

# Trap signals for clean shutdown.
trap 'log main "shutting down"; release_lock; kill 0; exit 0' SIGTERM SIGINT

mirror_loop &
MIRROR_PID=$!
snapshot_loop &
SNAP_PID=$!

log main "loops running (mirror pid=${MIRROR_PID}, snapshot pid=${SNAP_PID})"
wait -n
log main "a loop exited unexpectedly; shutting down container"
release_lock
kill 0
