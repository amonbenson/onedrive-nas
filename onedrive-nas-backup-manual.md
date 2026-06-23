# OneDrive → Raspberry Pi NAS Backup: Implementation Manual

**Audience:** Skilled developer implementing this system.
**Goal:** A dockerized application running on a Raspberry Pi with an attached HDD that continuously mirrors a personal OneDrive account to local storage, retains files that were deleted online, and maintains generational (GFS) version history — all within a **4 TB HDD budget** for a **~2 TB OneDrive source**.

---

## 1. Overview & Requirements

### 1.1 What this system must do

| Requirement | Behaviour |
|---|---|
| Mirror entire OneDrive locally | Full copy of all files/folders on the HDD |
| Near-instant sync | Pick up new/changed files within minutes of upload |
| **Never delete online-deleted files** | A file removed from OneDrive stays on the local mirror forever |
| Update on overwrite | If a file changes online, the mirror holds the newest version |
| Version history (GFS) | Keep daily / weekly / monthly historical versions of changed files |
| **Storage cap** | Mirror + all version history must stay **under 4 TB** for a 2 TB source |
| Runs alongside home automation | Docker Compose services on the same Pi, auto-start on boot |

### 1.2 Core design decision: two layers, two tools

This is **not** a single-tool job. The system is split into two cooperating stages, each using the right tool:

```
                  ┌─────────────────────────────────────────────┐
OneDrive (2 TB) ──┤ STAGE 1: rclone copy                         │
  personal acct   │  → /mnt/hdd/onedrive-mirror                  │
                  │  Live mirror. Never deletes online-deleted   │
                  │  files. Always holds newest version of       │
                  │  files that still exist online.              │
                  └───────────────────┬─────────────────────────┘
                                      │
                                      ▼
                  ┌─────────────────────────────────────────────┐
                  │ STAGE 2: restic snapshot + forget --prune    │
                  │  → /mnt/hdd/restic-repo                       │
                  │  Deduplicated, GFS-thinned version history.   │
                  │  Daily / weekly / monthly retention tiers.    │
                  └─────────────────────────────────────────────┘
```

**Why two stages instead of one:**

- **rclone `copy`** (deliberately *not* `sync`) gives the "never delete online-deleted files" behaviour for free: `copy` only ever adds or updates locally, it never propagates source deletions. This is the disaster-recovery mirror — the answer to *"OneDrive became unavailable"* or *"I cancelled my Microsoft subscription."*
- **restic** provides true generational version history with **content-addressed deduplication**, so months of snapshots of a mostly-static 2 TB dataset cost roughly "2 TB + churn," not "N × 2 TB." Its built-in `forget` policy implements GFS thinning in one command.

Do **not** attempt to build GFS retention out of rclone's `--backup-dir` alone — that flag keeps only flat, non-deduplicated copies and has no retention/thinning logic. Reimplementing snapshotting and dedup by hand is the wrong path; restic already does it correctly.

---

## 2. Hardware & Storage Budget

### 2.1 Target hardware

- Raspberry Pi (4 or 5 recommended; see memory note below).
- HDD attached via USB3 (strongly prefer USB3 + a good UASP-capable enclosure over USB2).
- HDD capacity: **4 TB**, formatted **ext4** (required for restic and for reliable hardlink/permissions behaviour; avoid exFAT/NTFS).

### 2.2 The 4 TB budget — this is the central constraint

The HDD must hold **both** the live mirror **and** the restic version repository:

```
4 TB HDD
├── /mnt/hdd/onedrive-mirror   ← live mirror, tracks OneDrive (~2 TB) + online-deleted files
└── /mnt/hdd/restic-repo       ← deduplicated GFS history of the mirror
```

Budget math the implementer must respect:

- **Live mirror:** starts at ~2 TB (current OneDrive). Grows slowly as online-deleted files accumulate (they are retained). Realistically stays in the 2–2.5 TB range for a long time unless there is heavy deletion churn.
- **restic repo:** because of dedup, its size ≈ *unique data ever seen* + *metadata overhead*. For a mostly-static archive this is modest. For high-churn data it grows faster.
- **Hard requirement:** mirror + repo **< 4 TB at all times.** The retention policy (Section 6) and the monitoring/safety guard (Section 8) exist specifically to enforce this.

> ⚠️ **Critical:** restic dedups *within its own repo*, but the repo is *separate from* the mirror. The same bytes exist once in the mirror and (deduplicated) in the repo. Plan for mirror (~2–2.5 TB) + repo, and keep headroom. If projected usage approaches ~3.5 TB, the retention policy must be tightened. Never let it run to 100% — a full HDD will break both restic prune and rclone mid-write.

### 2.3 Memory note (affects tool choice)

restic's initial snapshot and especially `prune` are CPU- and memory-hungry over 2 TB.

- **Pi 5 / Pi 4 with 4–8 GB RAM:** fine. First snapshot may take many hours; subsequent incrementals are light.
- **Pi with ≤2 GB RAM:** restic `prune` may struggle. Consider `rsnapshot` (hardlink-based, far lighter, no dedup hashing) as an alternative for Stage 2. This manual uses restic as primary; `rsnapshot` is noted as a fallback in Section 10.

Avoid relying on swap on the HDD — paging into a spinning disk during restic prune can stall the container for hours. Prefer a Pi with 4+ GB RAM, or raise `PRUNE_EVERY_N` to reduce how often the heavy prune operation runs.

---

## 3. Prerequisites

1. Docker and Docker Compose installed on the Pi (the user already runs a home-automation compose stack — add to it or run a sibling stack).
2. HDD mounted at a stable path, e.g. `/mnt/hdd`, via `/etc/fstab` (mount by `UUID=` so it survives reboots/replug). Confirm it mounts before Docker starts.
3. A machine **with a web browser** available once, to complete the OneDrive OAuth flow (the Pi is assumed headless).
4. The `rclone/rclone` and `restic/restic` images are multi-arch and run natively on ARM.

### 3.1 Formatting the HDD (one-time)

```bash
sudo blkid                       # identify the disk (e.g. /dev/sdb)
sudo umount /dev/sdb1 2>/dev/null
sudo wipefs -a /dev/sdb          # clear any existing partition table / signatures
sudo parted /dev/sdb --script mklabel gpt mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L onedrive-nas -m 1 /dev/sdb1
# -L sets a volume label (makes blkid output readable)
# -m 1 reserves only 1 % for root (default 5 % wastes ~200 GB on a 4 TB disk)
```

### 3.2 Mounting the HDD

```bash
# Find UUID of the new partition
sudo blkid /dev/sdb1
# /etc/fstab line — noatime and commit=60 reduce journal seek overhead on HDD;
# nofail lets the Pi boot normally if the drive is absent (the orchestrator
# detects a missing mount and exits rather than writing to the SD card).
UUID=xxxx-xxxx  /mnt/hdd  ext4  defaults,noatime,commit=60,nofail  0  2

sudo mkdir -p /mnt/hdd/onedrive-mirror /mnt/hdd/restic-repo /mnt/hdd/config
sudo mount -a
```

---

## 4. Stage 1 — rclone Live Mirror

### 4.1 Configure the OneDrive remote (one-time, on a browser machine)

Generate the rclone config interactively, then copy `rclone.conf` to the Pi.

```bash
# On any machine with a browser + rclone installed:
rclone config
#  n) New remote
#  name> onedrive
#  Storage> Microsoft OneDrive
#  client_id> (leave blank, press Enter)
#  client_secret> (leave blank, press Enter)
#  Choose account type: OneDrive Personal
#  Complete the browser OAuth flow
rclone config file   # prints the path to rclone.conf
```

Copy the resulting `rclone.conf` to the Pi at `/mnt/hdd/config/rclone/rclone.conf`.

> Alternatively, run config inside the container and use `rclone authorize "onedrive"` on the browser machine to obtain the token to paste back:
> ```bash
> docker run --rm -it -v /mnt/hdd/config/rclone:/config/rclone rclone/rclone config
> ```

> 🔑 **Token refresh:** OneDrive access tokens refresh automatically, and rclone **writes the refreshed token back into `rclone.conf`**. The config mount **must be read-write** (not `:ro`), or refresh will eventually fail and sync will stop.

### 4.2 The mirror command — design notes

```sh
rclone copy onedrive: /data/onedrive-mirror \
  --create-empty-src-dirs \
  --transfers 1 \
  --checkers 2 \
  --buffer-size 16M \
  --log-level INFO
```

- **`copy`, not `sync`** — this is the whole reason online-deleted files are retained. Do not change this to `sync`.
- **`--create-empty-src-dirs`** — preserves empty folders.
- **`--transfers 1 --checkers 2`** — a spinning HDD has one physical read/write head; multiple concurrent transfers cause random seeking which destroys throughput. Keep transfers at 1 for sequential access. A larger `--buffer-size 16M` lets rclone batch data into bigger sequential writes.
- rclone decides a file *changed* by comparing modification time + size (and can use OneDrive's hash). When a newer version appears online, the local copy is overwritten with the newest version — exactly the intended behaviour. The only files that accumulate beyond the live OneDrive set are the **online-deleted** ones, which `copy` never removes.

### 4.3 Continuous operation — the loop pattern

A container has no systemd, so scheduling is a loop with `sleep` **after** the copy completes. This is what prevents overlapping runs: a multi-hour initial sync simply delays the next cycle; it cannot trigger a second concurrent run.

`stage1-mirror-loop.sh`:

```sh
#!/bin/sh
set -e

INTERVAL="${MIRROR_INTERVAL:-300}"   # seconds between mirror runs (default 5 min)

echo "[mirror] starting loop, interval ${INTERVAL}s"

while true; do
  echo "[mirror] $(date -Iseconds) starting rclone copy"
  rclone copy onedrive: /data/onedrive-mirror \
    --create-empty-src-dirs \
    --transfers 1 \
    --checkers 2 \
    --buffer-size 16M \
    --log-level INFO \
    || echo "[mirror] $(date -Iseconds) copy exited non-zero (will retry next cycle)"
  echo "[mirror] $(date -Iseconds) copy finished, sleeping ${INTERVAL}s"
  sleep "$INTERVAL"
done
```

- The `|| echo …` ensures a transient network error logs but does **not** kill the loop.
- `sleep` after completion = built-in overlap protection (equivalent to the systemd oneshot+timer guarantee on a non-container host).

> **On "instant" sync:** OneDrive's API does not push change events to rclone, so true instant sync isn't available via this path. A 5-minute poll is the practical "near-instant" approach. Each poll is cheap once the initial download is done, because rclone only transfers changed files. Lower `MIRROR_INTERVAL` for tighter latency at the cost of more API polling; 5 minutes is a sane default.

---

## 5. Stage 2 — restic GFS Version History

### 5.1 Concept

restic snapshots the **local mirror** (not OneDrive directly) on a schedule, into its own repository. Key properties:

- **Content-addressed dedup:** unchanged files across snapshots are stored once. A snapshot where nothing changed costs metadata only, not a full copy.
- **Snapshots are point-in-time tree states**, not per-file age tracking. "What did the tree look like at last Tuesday's daily snapshot" — not "the 1-week-old version of this specific file." This is the standard, feasible way to do generational history.
- **`forget --prune`** implements GFS thinning natively: dense recent history, sparse old history.

### 5.2 Initialize the repo (one-time)

```bash
# Set a strong password; store it in the env file (Section 7). DO NOT LOSE IT —
# the repo is encrypted and unrecoverable without the password.
docker run --rm -it \
  -e RESTIC_REPOSITORY=/repo \
  -e RESTIC_PASSWORD='CHANGE_ME_STRONG_PASSWORD' \
  -v /mnt/hdd/restic-repo:/repo \
  restic/restic init
```

### 5.3 Snapshot + GFS forget — the script

`stage2-restic-loop.sh`:

```sh
#!/bin/sh
set -e

INTERVAL="${RESTIC_INTERVAL:-86400}"   # seconds between snapshots (default 24h)

echo "[restic] starting loop, interval ${INTERVAL}s"

while true; do
  echo "[restic] $(date -Iseconds) starting snapshot"

  restic backup /data/onedrive-mirror \
    --tag onedrive-gfs \
    --host raspberrypi \
    --verbose \
    || echo "[restic] $(date -Iseconds) backup exited non-zero (will retry next cycle)"

  echo "[restic] $(date -Iseconds) applying GFS retention"

  # GFS thinning. Tune these numbers against the 4 TB budget (Section 6).
  restic forget \
    --tag onedrive-gfs \
    --keep-daily   7 \
    --keep-weekly  4 \
    --keep-monthly 12 \
    --prune \
    || echo "[restic] $(date -Iseconds) forget/prune exited non-zero"

  echo "[restic] $(date -Iseconds) snapshot cycle done, sleeping ${INTERVAL}s"
  sleep "$INTERVAL"
done
```

> **Ordering matters:** Stage 1 (mirror) and Stage 2 (snapshot) run independently. A snapshot simply captures whatever state the mirror is in at that moment. There is no need to tightly couple them; a daily restic cycle over a mirror that refreshes every 5 minutes is fine. If you want snapshots to never run mid-mirror-write, you can add a lockfile shared between the two scripts, but it is not required for correctness — restic snapshots are consistent over whatever it reads, and the next snapshot will pick up anything in flight.

---

## 6. GFS Retention & The 4 TB Budget

### 6.1 What GFS gives you

The retention policy `--keep-daily 7 --keep-weekly 4 --keep-monthly 12` yields, at steady state:

- **7** daily snapshots (last week, day-by-day)
- **4** weekly snapshots (last month, week-by-week)
- **12** monthly snapshots (last year, month-by-month)

≈ 23 retained snapshots forming the "exponential increment" curve: fine-grained recent history, coarse old history. This directly implements the *"1-day-old, 1-week-old, 1-month-old version"* intent — generalised correctly to snapshot tiers rather than fragile per-file age tracking.

### 6.2 Why this fits in 4 TB (and how to keep it there)

Because of dedup, total repo size ≈ **unique data ever captured + churn between snapshots**, not 23 × 2 TB. For a personal OneDrive that is mostly photos/documents (low churn), the repo overhead on top of the ~2 TB of unique content is typically modest.

**The budget must be actively defended, not assumed.** The implementer must:

1. **Estimate churn first.** Before committing to 12 monthly snapshots, observe repo growth over the first few weeks (`restic stats`). Extrapolate.
2. **Tune retention to fit.** If projected `mirror + repo` approaches ~3.5 TB, reduce retention — e.g. `--keep-monthly 6` instead of 12, or `--keep-weekly 2`. Retention numbers are the primary lever for staying under 4 TB.
3. **Account for the mirror separately.** Remember the live mirror (~2–2.5 TB) is *not* in the repo. Repo budget is effectively `4 TB − mirror size − safety headroom`. Plan the repo to stay under roughly **1.3–1.5 TB** to leave headroom.

### 6.3 Recommended starting policy

Given a 2 TB source and 4 TB cap, start **conservative** and loosen only after observing real churn:

```
--keep-daily 7 --keep-weekly 4 --keep-monthly 6
```

Then, if `restic stats` after several weeks shows comfortable headroom, extend `--keep-monthly` toward 12. It is far easier to *add* retention than to discover the HDD filled up.

---

## 7. Docker Compose Setup

### 7.1 Directory layout on the Pi

```
/mnt/hdd/
├── config/
│   └── rclone/
│       └── rclone.conf            # generated in 4.1 (read-write!)
├── onedrive-mirror/               # Stage 1 output (~2 TB)
└── restic-repo/                   # Stage 2 repository

~/onedrive-backup/                 # compose + scripts (can live on Pi SD card)
├── docker-compose.yml
├── stage1-mirror-loop.sh
├── stage2-restic-loop.sh
└── backup.env                     # secrets (gitignore this!)
```

### 7.2 `backup.env`

```env
# rclone
MIRROR_INTERVAL=300

# restic
RESTIC_INTERVAL=86400
RESTIC_REPOSITORY=/repo
RESTIC_PASSWORD=CHANGE_ME_STRONG_PASSWORD
```

> 🔐 Keep `backup.env` out of version control. The `RESTIC_PASSWORD` is the only way to decrypt the repo — back it up somewhere safe and separate (a password manager). Losing it means losing all version history.

### 7.3 `docker-compose.yml`

Add these two services to the existing home-automation compose file, or run as a sibling stack.

```yaml
services:
  onedrive-mirror:
    image: rclone/rclone:latest
    container_name: onedrive-mirror
    restart: unless-stopped
    entrypoint: /scripts/stage1-mirror-loop.sh
    env_file: ./backup.env
    volumes:
      - /mnt/hdd/config/rclone:/config/rclone          # read-write (token refresh)
      - ./stage1-mirror-loop.sh:/scripts/stage1-mirror-loop.sh:ro
      - /mnt/hdd/onedrive-mirror:/data/onedrive-mirror

  onedrive-restic:
    image: restic/restic:latest
    container_name: onedrive-restic
    restart: unless-stopped
    entrypoint: /bin/sh        # override restic's default entrypoint to run our loop
    command: /scripts/stage2-restic-loop.sh
    env_file: ./backup.env
    volumes:
      - ./stage2-restic-loop.sh:/scripts/stage2-restic-loop.sh:ro
      - /mnt/hdd/onedrive-mirror:/data/onedrive-mirror:ro   # restic reads mirror read-only
      - /mnt/hdd/restic-repo:/repo
    depends_on:
      - onedrive-mirror
```

Notes:

- The restic container mounts the mirror **read-only** (`:ro`) — Stage 2 only ever reads it.
- The `restic/restic` image's default entrypoint is the `restic` binary; override it to `/bin/sh` so the loop script runs. Verify the image contains `/bin/sh` (it does in current releases); if a future image is distroless, switch to a tiny `alpine` image with restic installed, or bake a small custom image.
- Make scripts executable on the host: `chmod +x stage1-mirror-loop.sh stage2-restic-loop.sh`.

### 7.4 Start & observe

```bash
cd ~/onedrive-backup
chmod +x stage1-mirror-loop.sh stage2-restic-loop.sh
docker compose up -d onedrive-mirror onedrive-restic
docker compose logs -f onedrive-mirror     # watch the (multi-hour) initial sync first
docker compose logs -f onedrive-restic     # first snapshot runs after mirror is populated
```

The initial mirror download of ~2 TB will take **many hours** (USB3 SSD, Pi-class CPU, OneDrive throttling). Let it complete before judging restic timing.

---

## 8. Safety Guard: Enforce the 4 TB Cap

Retention tuning is the *primary* control, but add an automated guard so a runaway repo can never fill the HDD and break both tools.

### 8.1 Disk-usage check (cron on the host, or a third tiny container)

```sh
#!/bin/sh
# /usr/local/bin/disk-guard.sh  — run via host cron every hour
USAGE=$(df --output=pcent /mnt/hdd | tail -1 | tr -dc '0-9')
echo "$(date -Iseconds) HDD usage ${USAGE}%"
if [ "$USAGE" -ge 90 ]; then
  echo "WARNING: HDD at ${USAGE}% — tighten restic retention or investigate."
  # Hook in a notification: ntfy / Home Assistant webhook / email, etc.
fi
```

Recommended thresholds:
- **≥ 85 %** → warn (notification).
- **≥ 90 %** → warn loudly; consider auto-reducing `--keep-monthly`.
- **Never** allow 100 %: a full disk corrupts in-flight rclone writes and aborts restic prune.

### 8.2 Periodic integrity check

restic can verify repo integrity. Run occasionally (e.g. weekly, low-priority):

```bash
restic check                      # structural integrity (cheap)
restic check --read-data-subset=5%   # samples actual data (heavier; schedule sparingly on a Pi)
```

---

## 9. Restore / Disaster-Recovery Procedures

Document these for the end user — the whole point of the system.

### 9.1 OneDrive gone / subscription cancelled

The **live mirror** at `/mnt/hdd/onedrive-mirror` *is* the recovery copy. It is a plain directory tree of every file — just copy it off the HDD. No tool required to read it.

### 9.2 Recover a previous version of a file (GFS)

```bash
# List snapshots
docker run --rm -it --env-file backup.env \
  -v /mnt/hdd/restic-repo:/repo restic/restic snapshots

# Restore one path from a chosen snapshot into a scratch dir
docker run --rm -it --env-file backup.env \
  -v /mnt/hdd/restic-repo:/repo \
  -v /mnt/hdd/restore-scratch:/restore \
  restic/restic restore <SNAPSHOT_ID> \
    --include /data/onedrive-mirror/path/to/file.ext \
    --target /restore
```

### 9.3 Browse a snapshot interactively

```bash
restic mount /mnt/hdd/restic-browse    # FUSE-mount all snapshots as a browsable tree
```

---

## 10. Alternative for low-memory Pis: rsnapshot (Stage 2 swap-in)

If the Pi has ≤2 GB RAM, restic `prune` may be too heavy. Replace **Stage 2 only** with `rsnapshot`, which uses **hardlink-based snapshots**: each snapshot is a full tree, but unchanged files are hardlinks to the previous snapshot, so they cost no extra space. `rsnapshot` is built around exactly the hourly/daily/weekly/monthly tiers.

Trade-offs vs restic:
- ✅ Far lighter on CPU/RAM (no dedup hashing).
- ✅ Snapshots are plain directories — restore is just `cp`.
- ❌ No compression or encryption.
- ❌ No integrity verification; a corrupted file is shared across all snapshots that hardlink it.
- ❌ Dedup is only "identical unchanged files," not block-level — slightly less space-efficient for partially-changed large files.

Stage 1 (rclone mirror) is unchanged. This manual treats restic as primary; `rsnapshot` is the documented fallback if memory profiling shows restic prune is unviable.

---

## 11. Implementation Checklist

- [ ] HDD formatted ext4 (see Section 3.1), mounted at `/mnt/hdd` via `/etc/fstab` by UUID with `noatime,commit=60,nofail`, auto-mounts on boot.
- [ ] `rclone.conf` generated via browser OAuth, placed at `/mnt/hdd/config/rclone/`, mounted **read-write**.
- [ ] Stage 1 loop script in place; `copy` (not `sync`) confirmed.
- [ ] restic repo initialized; `RESTIC_PASSWORD` stored safely **and** backed up separately.
- [ ] Stage 2 loop script in place with GFS `forget --prune`.
- [ ] Retention started **conservative** (`--keep-monthly 6`); to be loosened only after observing churn.
- [ ] Compose services added with correct mounts (mirror RW for rclone, RO for restic; repo RW for restic).
- [ ] Scripts `chmod +x`.
- [ ] Initial ~2 TB mirror completed (monitor logs; expect many hours).
- [ ] First restic snapshot verified (`restic snapshots`).
- [ ] `restic stats` checked after several weeks; retention tuned to keep `mirror + repo < ~3.5 TB`.
- [ ] HDD-usage guard (Section 8) scheduled with notifications; thresholds at 85/90 %.
- [ ] Periodic `restic check` scheduled.
- [ ] Restore procedure (Section 9) tested at least once with a real file.

---

## 12. Key Constraints Summary (do not violate)

1. **Use `rclone copy`, never `sync`** — this is what preserves online-deleted files.
2. **Config mount must be read-write** — OneDrive token refresh writes back to `rclone.conf`.
3. **`mirror + restic-repo` must stay under 4 TB at all times** — retention policy + SSD guard enforce this; never run to a full disk.
4. **`RESTIC_PASSWORD` is unrecoverable if lost** — back it up separately.
5. **First sync takes hours; the `sleep`-after-copy loop prevents overlapping runs** — do not "fix" this by removing the post-run sleep.
6. **OneDrive has no push API for rclone** — 5-minute polling is the realistic "near-instant" mechanism; it is not literally instantaneous.
