# OneDrive → Raspberry Pi NAS Backup

Continuously mirrors a personal OneDrive to a local HDD, **keeps files deleted
online**, maintains GFS version history, and exposes a web UI for browsing
snapshots and downloading files. Sized for a 1 TB OneDrive on a 2 TB HDD.

```
OneDrive ──► rclone copy (every 5 min) ──► /data/mirror (live mirror)
                                                │
                                     restic backup (daily) ──► /data/restic-repo
                                                │
                                     Backrest web UI :9898 (read-only viewer)
```

`rclone copy` (never `sync`) is what keeps online-deleted files — it only ever
adds or updates locally, never removes. `restic` adds deduplicated GFS history
on top. Both run in one container; Backrest is a second, read-only service.

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

---

## Configuration

All settings in `.env`. The most important:

| Variable | Default | Notes |
|---|---|---|
| `DATA_DIR` | `/mnt/hdd/onedrive-nas` | Host path for `mirror/` + `restic-repo/` |
| `RESTIC_PASSWORD` | — | Encrypts version history. **Unrecoverable if lost.** |
| `KEEP_DAILY/WEEKLY/MONTHLY` | `7/4/6` | Primary lever for staying under 2 TB |
| `PRUNE_EVERY_N` | `7` | Run `forget --prune` every N snapshots (weekly) |
| `MIRROR_INTERVAL` | `300` | Seconds between rclone runs |
| `DISABLE_SNAPSHOTS` | `0` | Set `1` for mirror-only (no restic) |
| `MEM_LIMIT` / `MEM_SWAP_LIMIT` | `512m` / `2048m` | Tune for your Pi's RAM |
| `DISK_USAGE_HALT_PCT` | `92` | Skip snapshots above this % to protect the disk |

---

## Backrest web UI

Open `http://<pi-ip>:9898`. On first run:

1. Create a web UI admin account.
2. Add a repository:
   - **URI:** `/repos/onedrive-nas`
   - **Password:** your `RESTIC_PASSWORD`
   - **Extra restic flags:** `--no-lock`  ← required; the repo is mounted read-only
3. Leave all schedule fields **empty** — the orchestrator owns all writes.
4. Click **"Index Snapshots"** to import existing snapshots.

From the UI you can browse any snapshot and download individual files.

---

## Restoring files

**Recover the whole OneDrive** (e.g. subscription cancelled): the mirror is a
plain directory tree — just copy it off the HDD. No tooling needed.

**Recover an older version of a file**: use the Backrest UI (easiest), or:

```bash
make snapshots                                          # find snapshot ID
./scripts/admin.sh restore <SNAPSHOT_ID> "path/to/file"
# result lands in ./restore/
```

---

## Day-2 operations

```bash
make logs        # follow container logs
make stats       # restic repo size + dedup stats  (run after a few weeks)
make snapshots   # list all snapshots
make check       # restic integrity check
make unlock      # clear a stale restic lock
```

After a few weeks, run `make stats`, check `df -h /mnt/hdd`, and tune `KEEP_*`
in `.env` to keep `mirror + repo` comfortably under 2 TB.

---

## Caveats

- **Live mirror is unencrypted.** Files in `mirror/` are plain files — anyone
  with the HDD can read them. The restic repo is always encrypted; `RESTIC_PASSWORD`
  is mandatory and there is no opt-out.
- **1 GB Pi:** restic `prune` is memory-hungry. The defaults (`PRUNE_EVERY_N=7`,
  `RESTIC_PACK_SIZE=128`) reduce peak RAM. Avoid HDD swap — paging during prune
  on a spinning disk stalls for hours. If it still OOMs, set `DISABLE_SNAPSHOTS=1`.
- **Not a 3-2-1 backup.** This is one copy on one device. Add an offsite target
  for true resilience.
- **`config/rclone/` must stay writable.** rclone writes refreshed OAuth tokens
  back to `rclone.conf` — do not mount it `:ro`.

---

## Project layout

```
├── Dockerfile
├── docker-compose.yml       # onedrive-nas + backrest services
├── .env.example             # copy to .env and edit
├── Makefile                 # make help for all targets
├── scripts/
│   ├── orchestrator.sh      # main loop: rclone + restic + lock + disk guard
│   ├── setup-rclone.sh      # one-time OneDrive auth
│   └── admin.sh             # restic admin tasks (snapshots/restore/check/…)
├── config/rclone/           # rclone.conf (gitignored)
├── backrest-config/         # Backrest state (gitignored)
└── restore/                 # restore scratch space (gitignored)
```
