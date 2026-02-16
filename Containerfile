# Base Image (default to 'stable')
ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable
ARG BUILD_SCRIPT=build.sh

# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

FROM ${BASE_IMAGE}

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
  --mount=type=cache,dst=/var/cache \
  --mount=type=cache,dst=/var/log \
  --mount=type=tmpfs,dst=/tmp \
  /ctx/"${BUILD_SCRIPT}" && \
  ostree container commit

### LINTING
RUN bootc container lint
