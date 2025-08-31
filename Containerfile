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
  # extras installed:
  # - qt5-qttools (to fix 'xdg-mime-update')
  # - ghostty (for a sane modern terminal)
  dnf5 install --enable-repo=terra -y qt5-qttools ghostty && \
  # prevent dnf from polluting the new layers
  dnf5 clean all && \
  rm -rf /var/cache/dnf /var/lib/dnf /var/lib/waydroid /var/lib/selinux /var/log/* && \
  ostree container commit

### LINTING
RUN bootc container lint
