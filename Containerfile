# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

# Base Image
FROM ghcr.io/ublue-os/bazzite:testing-42

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
  --mount=type=cache,dst=/var/cache \
  --mount=type=cache,dst=/var/log \
  --mount=type=tmpfs,dst=/tmp \
  /ctx/build.sh && \
  # nix installer enablement
  mkdir -p /nix && \
  # pick up any outstanding updates since the last base image
  dnf5 up --refresh -y && \
  ostree container commit

### LINTING
RUN bootc container lint
