# OneDrive NAS mirror image: rclone + a tiny shell runtime. Restic no longer
# lives here — the backrest service owns all restic operations (backup,
# retention, prune), each with its own bundled restic binary. Multi-arch
# friendly so it builds/runs on Raspberry Pi (arm64).
#
# We start from the official rclone image because it already ships a correct,
# multi-arch rclone binary. This avoids pinning versions by hand.

ARG RCLONE_TAG=latest

FROM rclone/rclone:${RCLONE_TAG}

# The rclone image is based on Alpine and already contains /bin/sh, ca-certs,
# and fuse libs. Add coreutils + tzdata so date formatting and `df` behave
# predictably across arches, and bash for the orchestration script.
RUN apk add --no-cache bash coreutils tzdata findutils

# The rclone image sets an ENTRYPOINT of ["rclone"]. We override it so our
# orchestrator script is PID 1. Compose also overrides entrypoint per-service,
# but we set a sane default here too.
COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

# Verify rclone is present at build time (fails the build early if not).
RUN rclone version

ENTRYPOINT ["/bin/bash"]
CMD ["/opt/scripts/orchestrator.sh"]
