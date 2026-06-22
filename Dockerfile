# OneDrive NAS backup image: rclone (mirror) + restic (GFS history) + a tiny
# shell runtime. Multi-arch friendly so it builds/runs on Raspberry Pi (arm64).
#
# We start from the official rclone image because it already ships a correct,
# multi-arch rclone binary, then copy in the restic binary from its official
# image. This avoids pinning versions by hand and keeps both tools current.

ARG RCLONE_TAG=latest
ARG RESTIC_TAG=latest

FROM restic/restic:${RESTIC_TAG} AS restic_src

FROM rclone/rclone:${RCLONE_TAG}

# The rclone image is based on Alpine and already contains /bin/sh, ca-certs,
# and fuse libs. Add coreutils + tzdata so date formatting and `df` behave
# predictably across arches, and bash for the orchestration scripts.
RUN apk add --no-cache bash coreutils tzdata findutils

# Bring in the restic binary from its official image.
COPY --from=restic_src /usr/bin/restic /usr/local/bin/restic

# The rclone image sets an ENTRYPOINT of ["rclone"]. We override it so our
# orchestrator script is PID 1. Compose also overrides entrypoint per-service,
# but we set a sane default here too.
COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

# Verify both tools are present at build time (fails the build early if not).
RUN rclone version && restic version

ENTRYPOINT ["/bin/bash"]
CMD ["/opt/scripts/orchestrator.sh"]
