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
  # ensure 'qtpaths' exists to fix issues with 'xdg-mime default ...'
  # also install ghostty and alacritty
  dnf5 install --enable-repo=terra -y qt5-qttools ghostty alacritty && \
  # prevent dnf from polluting the new layers
  dnf5 clean all && \
  rm -rf /var/cache/dnf /var/lib/dnf /var/lib/waydroid /var/lib/selinux /var/log/* && \
  ostree container commit

### LINTING
RUN bootc container lint
