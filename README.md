# OneDrive → Raspberry Pi NAS Backup

Continuously mirrors a personal OneDrive to a local HDD as an **exact replica**
(including deletions), maintains GFS version history so older and deleted files
can be recovered, and exposes a web UI for browsing snapshots and downloading
files. Sized for a 1 TB OneDrive on a 2 TB HDD.

```
OneDrive ──► rclone sync (every 5 min) ──► /data/mirror (exact replica)
                                                │
                                     Backrest (own cron schedule)
                                                │
                                       restic backup ──► /data/restic-repo
                                                │
                                  Backrest web UI :9898 (browse/restore/prune)
```

`rclone sync` makes the local mirror an exact replica of OneDrive, including
deletions. The sync direction (OneDrive → local) means rclone never writes to
OneDrive. Backrest — a separate container — owns all restic backup, retention,
and prune scheduling against that same mirror directory, so a slow or stuck
OneDrive sync can never block a scheduled snapshot (the two containers share
no lock and run fully independently).

---

## Requirements

- Raspberry Pi (1 GB RAM min; 4 GB+ recommended). 64-bit Raspberry Pi OS.
- Docker + Compose. Add your user to the `docker` group and **reboot**.
- HDD formatted **ext4**, mounted at a stable path via `/etc/fstab` using
  `UUID=` (not PARTUUID). Example fstab line:
  ```
  UUID=xxxx  /mnt/hdd  ext4  defaults,noatime,nofail  0  2
  ```
- A browser machine available once for OneDrive OAuth.

---

## Install & first run

```bash
git clone <this-repo> onedrive-nas && cd onedrive-nas

cp .env.example .env
nano .env          # set DATA_DIR and RESTIC_PASSWORD (save the password elsewhere!)

docker compose build

./scripts/setup-rclone.sh   # one-time OneDrive OAuth — run on a machine with a browser
                             # remote name must be exactly: onedrive

docker compose up -d
docker compose logs -f      # first mirror (~1 TB) takes many hours
```

Then configure Backrest (see below) — this is now the only thing that
produces version history; the mirror alone does not retain deleted/changed
files.

---

## Configuration

All settings in `.env`. The most important:

| Variable | Default | Notes |
|---|---|---|
| `DATA_DIR` | `/mnt/hdd/onedrive-nas` | Host path for `mirror/` + `restic-repo/` |
| `RESTIC_PASSWORD` | — | Paste into the Backrest UI when adding the repository. **Unrecoverable if lost.** |
| `MIRROR_INTERVAL` | `300` | Seconds between rclone runs |
| `DISK_USAGE_WARN_PCT` | `85` | Mirror container logs a warning above this disk-usage % |
| `MEM_LIMIT` / `MEM_SWAP_LIMIT` / `CPU_LIMIT` | `256m` / `1024m` / `1.0` | Resource caps for the mirror container |
| `BACKREST_MEM_LIMIT` / `BACKREST_MEM_SWAP_LIMIT` / `BACKREST_CPU_LIMIT` | `320m` / `1280m` / `1.0` | Resource caps for the backrest container |

Backup schedule and GFS retention (daily/weekly/monthly/yearly) are no longer
`.env` variables — configure them in the Backrest UI (see below).

---

## Backrest web UI

Open `http://<pi-ip>:9898`. On first run:

1. Create a web UI admin account.
2. Add a repository:
   - **URI:** `/repos/onedrive-nas`
   - **Password:** your `.env`'s `RESTIC_PASSWORD`
   - **Forget Policy** — schedule: Cron `0 3 * * *` (daily, 04:00 — one hour
     after the backup). Choose **Retention Type: By Time Period**:
     - Hourly: `0` (disabled — meaningless with a once-daily backup schedule)
     - Daily: `7`
     - Weekly: `4`
     - Monthly: `6`
     - Yearly: `0` (disabled)
     Each field means "keep one snapshot per calendar period, for the last N
     periods that actually have a snapshot" (this is restic's own
     `--keep-daily`/`--keep-weekly`/etc. semantics, which Backrest's "By Time
     Period" option wraps directly — buckets are calendar-aligned, e.g. a
     week is Monday-Sunday, not a rolling 7 days from now). Sized to fit the
     ~600-800 GB repo budget in `.env.example`'s storage-budget note; loosen
     later once `make ui` → repository stats shows headroom.
   - **Prune Policy** — schedule: Cron `0 4 * * 0` (**weekly**, Sunday 05:00
     — deliberately *not* daily). Prune is the heavy step: it walks the repo
     and physically reclaims space forget marked as unreferenced. Its RAM
     cost scales with the size of the repo's index, not with how much there
     is to clean up, so running it more often doesn't lower peak memory per
     run — it just makes the Pi do the expensive operation more frequently.
     Keeping it weekly and off-peak is the actual mitigation for the
     1 GB-RAM constraint (see Caveats below).
   - **Check Policy** — schedule: Cron `0 5 1 * *` (**monthly**, 1st at
     06:00), with the read-data-subset % set to `0` (structural check only —
     reading actual pack data on a spinning HDD is slow; only raise this if
     you suspect corruption). Monthly is plenty for a personal backup.
3. Add a plan:
   - **Source path:** `/data/mirror`
   - **Backup schedule:** `0 2 * * *` (daily, 03:00).
4. Click **"Index Snapshots"** if you have pre-existing snapshots to import.

The four jobs are staggered by an hour each to avoid lock
contention if they ever land on the same day:

| Job | Cron | Frequency |
|-------|------|-----------|
| Backup | 0 2 * * * | daily |
| Forget | 0 3 * * 0 | weekly (Sunday) |
| Prune | 0 4 * * 0 | weekly (Sunday) |
| Check | 0 5 1 * * | monthly (1st) |

---

## Restoring files

**Recover the whole OneDrive** (e.g. subscription cancelled): pick the most
recent restic snapshot and restore it via the Backrest UI, or copy the mirror
directly if it hasn't diverged yet. The mirror is a plain directory tree — no
tooling needed to read it.

**Recover an older version of a file**: open the snapshot in the Backrest UI
and restore or download the file directly.

---

## Day-2 operations

```bash
make logs        # follow mirror container logs
make ui          # print the Backrest URL
```

Everything else — repository stats, snapshot listing, integrity checks, lock
management, retention tuning — lives in the Backrest UI. After a few weeks,
check repo size there, check `df -h /mnt/hdd`, and tune the repository's
Forget Policy to keep `mirror + repo` comfortably under 2 TB.

---

## Caveats

- **No cross-container write coordination.** The mirror's `rclone sync` and
  Backrest's restic operations run in separate containers with no shared lock,
  so they can now run concurrently — a change from the original single-
  container design. Mitigated by giving each container its own `mem_limit`/
  `cpus` cap (see `.env.example`), so a worst-case overlap OOM-kills only one
  container (auto-restarted by `restart: unless-stopped`), not the whole Pi;
  further mitigated by scheduling Backrest's prune at a fixed off-peak hour.
  If you observe real contention on your hardware, consider lowering
  `BACKREST_MEM_LIMIT`'s companion cap or moving prune to a quieter time.
- **Live mirror is unencrypted.** Files in `mirror/` are plain files — anyone
  with the HDD can read them. The restic repo is always encrypted; `RESTIC_PASSWORD`
  is mandatory and there is no opt-out.
- **1 GB Pi:** restic `prune` is memory-hungry — that's why it now runs in its
  own capped container (`BACKREST_MEM_LIMIT`) separate from the mirror. Avoid
  HDD swap — paging during prune on a spinning disk stalls for hours. If prune
  still OOMs, raise `BACKREST_MEM_LIMIT` if the Pi has headroom, or move it to
  a less frequent/quieter schedule in the Backrest UI.
- **Not a 3-2-1 backup.** This is one copy on one device. Add an offsite target
  for true resilience.
- **`config/rclone/` must stay writable.** rclone writes refreshed OAuth tokens
  back to `rclone.conf` — do not mount it `:ro`.

---

## Project layout

```
├── Dockerfile
├── docker-compose.yml       # onedrive-nas (mirror) + backrest services
├── .env.example             # copy to .env and edit
├── Makefile                 # make help for all targets
├── scripts/
│   ├── orchestrator.sh      # main loop: rclone mirror + mount guard
│   └── setup-rclone.sh      # one-time OneDrive auth
├── config/rclone/           # rclone.conf (gitignored)
├── backrest-config/         # Backrest state (gitignored)
└── restore/                 # restore scratch space (gitignored)
```
