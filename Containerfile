# Base Image (default to 'stable')
ARG BASE_IMAGE=ghcr.io/ublue-os/bazzite:stable

# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /

FROM ${BASE_IMAGE}

ARG BUILD_SCRIPT=build.sh

ARG VARIANT=stable
ENV VARIANT=${VARIANT}

ARG CANONICAL_TAG=""

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
  --mount=type=cache,dst=/var/cache \
  --mount=type=cache,dst=/var/log \
  /ctx/"${BUILD_SCRIPT}"

### LINTING
RUN bootc container lint
