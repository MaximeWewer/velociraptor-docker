# syntax=docker/dockerfile:1
#
# Velociraptor server — hardened image.
# Baseline: distroless, rootless (uid 65532), minimal attack surface.
# Unlike the upstream image (alpine:latest, root, runtime config generation via
# a shell entrypoint), we ship only the statically-linked binary on distroless.
# Config is generated out-of-band and mounted from a Secret (see README.md).
#
# amd64 only: the linux-amd64-musl asset is fully static and runs on
# distroless/static. The arm64 release is dynamically linked (no musl variant),
# so it would need a glibc base — out of scope for this image.

# ---- fetch + verify stage ----
FROM alpine:3.24 AS fetch

ARG VELO_VERSION=v0.76.6
# sha256 of velociraptor-${VELO_VERSION}-linux-amd64-musl (pinned, verified at build)
ARG VELO_SHA256=84ad1652ff6e79694441a06a6af4040aae6a982080d2ef583a31bda52f58e299
ARG TARGETARCH=amd64

RUN apk add --no-cache curl
WORKDIR /out
RUN set -eux; \
    if [ "${TARGETARCH}" != "amd64" ]; then \
      echo "ERROR: only amd64 supported (static musl build). arm64 has no musl asset." >&2; \
      exit 1; \
    fi; \
    curl -fsSL -o velociraptor \
      "https://github.com/Velocidex/velociraptor/releases/download/${VELO_VERSION}/velociraptor-${VELO_VERSION}-linux-amd64-musl"; \
    echo "${VELO_SHA256}  velociraptor" | sha256sum -c -; \
    chmod 0755 velociraptor; \
    # Empty custom-artifacts dir so a config referencing it works on a
    # read-only rootfs (matches the upstream image). Override by mounting a
    # ConfigMap/volume here (see the chart's `customArtifacts`).
    mkdir -p /custom_artifacts

# ---- runtime stage ----
FROM gcr.io/distroless/static:nonroot

LABEL org.opencontainers.image.title="velociraptor"
LABEL org.opencontainers.image.description="Velociraptor DFIR server"
LABEL org.opencontainers.image.source="https://github.com/Velocidex/velociraptor"
LABEL org.opencontainers.image.licenses="AGPL-3.0-or-later"

COPY --from=fetch /out/velociraptor /velociraptor
# Empty dir, owned by the runtime uid (default mountpoint for custom VQL artifacts).
COPY --from=fetch --chown=65532:65532 /custom_artifacts /custom_artifacts

# distroless/static:nonroot == uid/gid 65532, no shell, no package manager
USER 65532:65532

# 8000 = frontend (client gRPC/mTLS), 8889 = GUI
EXPOSE 8000 8889

# Config is mounted read-only from a Secret; datastore is a writable volume.
# `frontend` starts both the client frontend and the admin GUI for a server config.
ENTRYPOINT ["/velociraptor"]
CMD ["--config", "/etc/velociraptor/server.config.yaml", "frontend", "-v"]
