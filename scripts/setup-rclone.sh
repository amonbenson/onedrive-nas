#!/usr/bin/env bash
#
# setup-rclone.sh — one-time interactive OneDrive authorization.
#
# Run this on a machine WITH A BROWSER (your laptop), or on the Pi if it has a
# desktop browser. It launches `rclone config` inside the same image so the
# resulting rclone.conf is written into ./config/rclone/ on the host, ready for
# the main container to use.
#
# If you run it on a headless Pi, rclone will print a URL / ask you to run
# `rclone authorize "onedrive"` on a browser machine and paste the token back.
#
# Usage:
#   ./setup-rclone.sh
#
set -euo pipefail

IMAGE="${IMAGE:-onedrive-nas:latest}"
HOST_CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)/config/rclone"

mkdir -p "${HOST_CONFIG_DIR}"

echo "Launching interactive rclone config..."
echo "  -> Create a new remote named exactly:  onedrive"
echo "  -> Storage type:                       Microsoft OneDrive"
echo "  -> Leave client_id / client_secret blank (press Enter)"
echo "  -> Region:                             Microsoft Cloud Global (option 1)"
echo "  -> Account type:                       OneDrive Personal"
echo
echo "When done, choose 'q) Quit config'. The token is saved to:"
echo "  ${HOST_CONFIG_DIR}/rclone.conf"
echo

docker run --rm -it \
  -v "${HOST_CONFIG_DIR}:/config/rclone" \
  --entrypoint rclone \
  "${IMAGE}" \
  config

echo
if [ -f "${HOST_CONFIG_DIR}/rclone.conf" ]; then
  echo "OK: rclone.conf created. Verifying remote is reachable..."
  docker run --rm \
    -v "${HOST_CONFIG_DIR}:/config/rclone" \
    --entrypoint rclone \
    "${IMAGE}" \
    lsd onedrive: | head -n 20 || {
      echo "WARNING: could not list onedrive: — check the remote name is exactly 'onedrive'."
      exit 1
    }
  echo "Success. You can now run:  docker compose up -d"
else
  echo "ERROR: no rclone.conf was written. Re-run and complete the wizard."
  exit 1
fi
