# OneDrive → Raspberry Pi NAS Backup

A dockerized backup appliance for a Raspberry Pi with an attached SSD. It
continuously mirrors a **personal OneDrive** account to a local SSD, **keeps
files that were deleted online**, and maintains **GFS (grandfather-father-son)
version history** — all sized to fit a **2 TB SSD** backing up a **1 TB
OneDrive**.

It is designed to run as one extra service alongside an existing Home
Assistant / smart-home Docker Compose stack.

---

## Table of contents

1. [What it does](#what-it-does)
2. [How it works](#how-it-works)
3. [Storage budget (1 TB → 2 TB)](#storage-budget)
4. [Prerequisites](#prerequisites)
5. [Install & first run](#install--first-run)
6. [Configuration reference](#configuration-reference)
7. [Day-2 operations](#day-2-operations)
8. [Restoring files](#restoring-files)
9. [How the storage stays bounded](#how-the-storage-stays-bounded)
10. [Troubleshooting](#troubleshooting)
11. [Design notes & caveats](#design-notes--caveats)
12. [Project layout](#project-layout)

---

## What it does

| Requirement | Behaviour |
|---|---|
| Mirror entire OneDrive locally | Full copy on the SSD, refreshed continuously |
| Near-real-time sync | Polls every 5 minutes (configurable) |
| **Never delete online-deleted files** | Uses `rclone copy` (not `sync`) — local deletions never happen |
| Update on overwrite | Newest version of a still-existing file replaces the old one in the mirror |
| Version history (GFS) | `restic` keeps daily/weekly/monthly snapshots, deduplicated |
| Fits the SSD | Conservative retention + an automatic disk guard keep usage bounded |
| Runs with home automation | A single Compose service; `restart: unless-stopped` |

> **Use case:** this is a *disaster mirror* — protection for "OneDrive becomes
> unavailable" or "I cancel my Microsoft subscription" — plus a modest version
> history. It is not a substitute for the 3-2-1 rule on its own (it is one
> copy on one device); see [caveats](#design-notes--caveats).

---

## How it works

Two cooperating stages run inside one container (`scripts/orchestrator.sh`):

```
                  ┌──────────────────────────────────────────────┐
OneDrive (1 TB) ──┤ STAGE 1 — rclone copy  (every 5 min)          │
  personal acct   │   → /data/mirror                              │
                  │   Live mirror. copy, never sync, so files     │
                  │   deleted online are KEPT locally forever.    │
                  └───────────────────┬──────────────────────────┘
                                      │ (reads the mirror)
                                      ▼
                  ┌──────────────────────────────────────────────┐
                  │ STAGE 2 — restic backup + forget --prune      │
                  │   → /data/restic-repo   (daily)               │
                  │   Deduplicated, encrypted GFS version history.│
                  └──────────────────────────────────────────────┘
```

**Why two tools?**

- `rclone copy` is what guarantees online-deleted files are retained. `copy`
  only ever *adds/updates* the destination; it never propagates deletions. (If
  this were `sync`, deletions would mirror across — the opposite of what we
  want.)
- `restic` provides real version history with **content-addressed
  deduplication**, so months of snapshots of a mostly-static dataset cost
  roughly "unique data + churn", not "N × full size". Its `forget --prune`
  implements GFS thinning in one command.

A shared lock (`mkdir`-based mutex) ensures a heavy restic `prune` and an
rclone run never collide on the Pi's USB/SSD bus.

---

## Storage budget

**Source: ~1 TB OneDrive. Target: 2 TB SSD.** Both the mirror and the version
repo live on the same SSD:

```
2 TB SSD  (mounted at DATA_DIR, e.g. /mnt/ssd/onedrive-nas)
├── mirror/        ~1 TB now; grows slowly as online-deleted files accumulate
└── restic-repo/   deduplicated GFS history — the rest of the budget
```

The defaults (`KEEP_DAILY=7 KEEP_WEEKLY=4 KEEP_MONTHLY=6`, no yearly) are
deliberately **conservative** so the repo stays comfortably under the remaining
~1 TB. Target: keep the repo under **~600–800 GB** to leave headroom above the
~1 TB mirror.

The container also runs a **disk guard**: if `/data` usage reaches
`SSD_USAGE_HALT_PCT` (default 92 %), it **skips** new snapshots to avoid filling
the disk (a full disk breaks both rclone writes and restic prune). At
`SSD_USAGE_WARN_PCT` (85 %) it logs a warning to tighten retention.

See [How the storage stays bounded](#how-the-storage-stays-bounded) for the
tuning procedure.

---

## Prerequisites

- Raspberry Pi 4/5 (4 GB+ RAM recommended; see [caveats](#design-notes--caveats)
  for low-memory notes). 64-bit Raspberry Pi OS.
- Docker + Docker Compose plugin installed.
- An SSD attached over USB3, formatted **ext4**, mounted at a stable path via
  `/etc/fstab` by `UUID=`. ext4 is required: restic needs POSIX
  permissions/ownership, and a 24/7 write workload needs a journaled filesystem.
  (exFAT/NTFS are **not** suitable here — see the FAQ.)
- A machine with a web browser available **once**, for OneDrive OAuth.

### SSD mount example

```bash
sudo blkid                       # find the SSD's UUID
echo 'UUID=xxxx /mnt/ssd ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /mnt/ssd/onedrive-nas
sudo mount -a
```

---

## Install & first run

```bash
# 1. Get the project onto the Pi
git clone <your-repo> onedrive-nas && cd onedrive-nas
#    (or copy this directory over)

# 2. Configure
cp .env.example .env
nano .env
#    REQUIRED edits:
#      DATA_DIR=/mnt/ssd/onedrive-nas        # your SSD path
#      RESTIC_PASSWORD=<long random phrase>  # SAVE THIS SEPARATELY!

# 3. Build the image (multi-arch; builds natively on the Pi)
docker compose build           # or: make build

# 4. One-time OneDrive authorization
#    Run on a machine WITH a browser. Creates config/rclone/rclone.conf.
./scripts/setup-rclone.sh      # or: make setup
#    In the wizard:
#      name:        onedrive            (exactly)
#      storage:     Microsoft OneDrive
#      client id/secret: blank
#      region:      Microsoft Cloud Global
#      account:     OneDrive Personal
#    Copy config/rclone/rclone.conf to the Pi if you ran this elsewhere.

# 5. Start it
docker compose up -d           # or: make up
docker compose logs -f         # watch the initial sync (HOURS for ~1 TB)
```

The first mirror run downloads ~1 TB and will take **many hours** depending on
your connection and OneDrive throttling. The first restic snapshot runs after
`SNAPSHOT_INTERVAL` (default 24 h), by which point the mirror is populated.

---

## Configuration reference

All settings live in `.env` (copied from `.env.example`). Key ones:

| Variable | Default | Meaning |
|---|---|---|
| `DATA_DIR` | `/mnt/ssd/onedrive-nas` | **Host** SSD path holding `mirror/` + `restic-repo/` |
| `RESTIC_PASSWORD` | — | Encrypts the repo. **Unrecoverable if lost.** |
| `RCLONE_REMOTE` | `onedrive:` | rclone remote; append a subpath to mirror part of OneDrive |
| `MIRROR_INTERVAL` | `300` | Seconds between mirror runs (5 min) |
| `SNAPSHOT_INTERVAL` | `86400` | Seconds between restic snapshots (24 h) |
| `KEEP_DAILY/WEEKLY/MONTHLY/YEARLY` | `7/4/6/0` | GFS retention (primary storage control) |
| `RCLONE_TRANSFERS` / `RCLONE_CHECKERS` | `4` / `8` | Concurrency (kept low for the Pi) |
| `RCLONE_TPSLIMIT` | `10` | Transactions/sec cap (OneDrive throttling) |
| `SSD_USAGE_WARN_PCT` / `SSD_USAGE_HALT_PCT` | `85` / `92` | Disk-guard thresholds |
| `DISABLE_SNAPSHOTS` | `0` | Set `1` to run the mirror only (stage 1) |
| `MEM_LIMIT` / `CPU_LIMIT` | `1500m` / `1.5` | Container resource caps |
| `TZ` | `Europe/Berlin` | Timezone for log timestamps & GFS day boundaries |

---

## Day-2 operations

A `Makefile` and `scripts/admin.sh` wrap the common tasks:

```bash
make logs                 # follow logs
make ps                   # service status
make snapshots            # list restic snapshots
make stats                # repository size / dedup stats
make check                # restic integrity check
make unlock               # clear a stale restic lock

# raw restic, anything:
./scripts/admin.sh raw -- snapshots --compact
```

Run `make stats` after a few weeks to see real repo growth, then tune retention
(next section).

---

## Restoring files

### Scenario A — OneDrive gone / subscription cancelled

The live mirror **is** your data. It's a plain directory tree on the SSD:

```bash
ls /mnt/ssd/onedrive-nas/mirror/
cp -a /mnt/ssd/onedrive-nas/mirror/ /wherever/you/want/
```

No tooling required.

### Scenario B — recover an earlier version of a file

```bash
make snapshots                                   # find the snapshot ID + date
./scripts/admin.sh restore <SNAPSHOT_ID> "Documents/2024/report.docx"
#   -> restored under ./restore/ on the host
```

Or browse all snapshots as a mounted filesystem:

```bash
./scripts/admin.sh mount      # needs FUSE; Ctrl-C to unmount
```

---

## How the storage stays bounded

Because restic **deduplicates**, total repo size ≈ *unique data ever captured +
churn between snapshots*, **not** (number of snapshots × dataset size). A
snapshot where nothing changed costs only metadata.

**Tuning procedure:**

1. Run for 2–4 weeks. Then `make stats`.
2. Compute `mirror + repo` against the 2 TB SSD (`df -h /mnt/ssd`).
3. **Headroom?** Loosen retention for deeper history: raise `KEEP_MONTHLY`
   toward 12, or set `KEEP_YEARLY=1`–`2`. Restart: `docker compose up -d`.
4. **Tight (approaching ~1.6–1.7 TB)?** Tighten: lower `KEEP_MONTHLY`, drop
   `KEEP_WEEKLY` to 2. It is far easier to add history than to recover from a
   full disk.

The disk guard is a backstop, not the primary control — retention is. If you
ever see "DISK GUARD … SKIPPING snapshot" in the logs, tighten retention and run
a manual `./scripts/admin.sh raw -- forget … --prune`.

---

## Troubleshooting

**Initial sync seems stuck / very slow.** ~1 TB over USB3 + OneDrive throttling
legitimately takes many hours. Watch `docker compose logs -f`; rclone logs
per-file progress at `INFO`.

**`429 Too Many Requests` in logs.** OneDrive throttling. Lower
`RCLONE_TRANSFERS`/`RCLONE_CHECKERS` and/or `RCLONE_TPSLIMIT`.

**Auth fails after ~90 days.** OneDrive refresh tokens expire after 90 days of
non-use; continuous operation keeps them alive, but if the container was off for
months, re-run `./scripts/setup-rclone.sh` (or
`./scripts/admin.sh raw -- ...` won't help here — it's an rclone reconnect:
`docker run --rm -it -v "$PWD/config/rclone:/config/rclone" --entrypoint rclone onedrive-nas:latest config reconnect onedrive:`).

**`config/rclone` must stay writable.** rclone writes refreshed tokens back to
`rclone.conf`. The compose mount is intentionally read-write — don't make it
`:ro`.

**restic complains about a lock.** A previous run was interrupted. `make unlock`.

**Disk guard keeps skipping snapshots.** You're near capacity. Tighten retention
(see above) and prune.

---

## Design notes & caveats

- **"Instant" isn't literally possible.** OneDrive's API doesn't push change
  events to rclone, so a 5-minute poll is the practical near-real-time approach.
  Lower `MIRROR_INTERVAL` for tighter latency at the cost of more API calls.
- **One device = one copy.** This appliance is a robust local mirror with
  history, but it lives on a single SSD in one location. For true resilience,
  follow 3-2-1: add an offsite copy (e.g. a second restic repo target). The
  same restic repo design makes that straightforward later.
- **Overwrites lose the *online* version, not your history.** When a file
  changes online, the mirror takes the newest version — but the previous
  version is preserved in the restic snapshots (within your retention window).
- **Low-memory Pis (≤2 GB):** restic `prune` is memory-hungry over ~1 TB.
  Options: add swap; run prune less often (decouple by raising
  `SNAPSHOT_INTERVAL` and pruning manually weekly); or switch stage 2 to
  `rsnapshot` (hardlink snapshots, far lighter, but no dedup/encryption).
- **Filesystem must be ext4.** exFAT/NTFS lack journaling and POSIX
  permissions; exFAT in particular risks corruption under continuous writes and
  breaks restic's permission model. Use ext4 on the SSD and, if you need to read
  the drive on Windows/macOS occasionally, use a third-party ext4 driver there
  rather than reformatting.
- **Back up the `RESTIC_PASSWORD` and ideally `rclone.conf`** somewhere off the
  SSD. The password is the only key to the encrypted history.

---

## Project layout

```
onedrive-nas/
├── Dockerfile               # rclone base + restic binary + bash runtime
├── docker-compose.yml       # single service: onedrive-nas
├── .env.example             # copy to .env and edit
├── .gitignore / .dockerignore
├── Makefile                 # convenience targets (make help)
├── scripts/
│   ├── orchestrator.sh      # entrypoint: runs both loops + lock + disk guard
│   ├── setup-rclone.sh      # one-time OneDrive OAuth helper
│   └── admin.sh             # restic snapshots/stats/check/restore/mount
├── config/
│   └── rclone/              # rclone.conf lands here (RW; gitignored)
└── restore/                 # scratch space for restores (gitignored)
```

---

### One-line summary for the operator

Edit `.env` (set `DATA_DIR` + `RESTIC_PASSWORD`), `make build`, `make setup`
(OneDrive login), `make up`. Watch `make logs`. After a few weeks, `make stats`
and tune `KEEP_*` to taste within the 2 TB budget.
