# Velociraptor - hardened server image

Hardening vs the upstream image (`Velocidex/velociraptor/Docker`):

| Aspect | Upstream | This image |
|--------|----------|------------|
| Base | `alpine:latest` (unpinned, shell, apk) | `gcr.io/distroless/static:nonroot` |
| User | root | `65532:65532` (rootless) |
| Config | generated at runtime (shell entrypoint) | generated in-cluster by the Helm chart (or out-of-band) → Secret mounted RO |
| Surface | shell, apk, init.vql, custom_artifacts | binary + empty `/custom_artifacts` mountpoint |

amd64 only (the musl binary is static; the arm64 asset is dynamic → out of scope).

## Published image

```
ghcr.io/maximewewer/velociraptor:<version>-distroless
ghcr.io/maximewewer/velociraptor:latest
```

`<version>` is read from the `ARG VELO_VERSION` in the Dockerfile (single source of
truth). `update-versions.yml` (weekly) bumps `VELO_VERSION` + recomputes `VELO_SHA256`
from the upstream release asset (`velociraptor-<version>-linux-amd64-musl.gz`, the only
form published since v0.77.3) and opens a PR; merging it builds and publishes the image.
The [velociraptor Helm chart](https://github.com/MaximeWewer/velociraptor-helm) consumes
this image (`image.repository: maximewewer/velociraptor`).

## Build (local)

```bash
docker build -t velociraptor:0.77.4-distroless .
# version / checksum are overridable:
docker build \
  --build-arg VELO_VERSION=v0.77.4 \
  --build-arg VELO_SHA256=b4699d7ecfd5c0d656d86379e41f0eb34b0f12c3cb45398f1e747f10844d7930 \
  -t velociraptor:0.77.4-distroless .
```

To update the version manually: change `VELO_VERSION`, recompute the sha256 of the
`.gz` asset (normally `update-versions.yml` does this automatically):
```bash
curl -fsSL "https://github.com/Velocidex/velociraptor/releases/download/v0.77.4/velociraptor-v0.77.4-linux-amd64-musl.gz" | sha256sum
```

## Server config

The distroless image has no shell, hence no runtime generation by an entrypoint. The server
config (which embeds the CA + private keys + nonces) lives in a Kubernetes Secret, mounted
read-only.

**With the Helm chart (default)**, nothing to do: a hook Job runs this image's own binary
(`velociraptor config generate`, driven by VQL) on first install, stores the config in a
Secret that is never regenerated, renews the server certificates before they expire, and the
chart renders the operational settings (bind addresses, ports, datastore path, URLs) from its
values. See the [chart README](https://github.com/MaximeWewer/velociraptor-helm/blob/main/chart/README.md).

**Out-of-band** (secret manager / your own tooling):
```bash
velociraptor config generate > server.config.yaml
kubectl create secret generic velociraptor-config \
  --from-file=server.config.yaml=./server.config.yaml -n <ns>
```
then set `config.existingSecret=velociraptor-config` in the chart. If the chart does not manage
the operational config (`config.manageServerConfig=false`), adjust before creating the Secret:
- `Frontend.bind_address: 0.0.0.0` / `bind_port: 8000`
- `GUI.bind_address: 0.0.0.0` / `bind_port: 8889`
- `Datastore.location` and `Datastore.filestore_directory: /datastore` (anything else is on
  the read-only root filesystem: `mkdir ...: read-only file system`)
- `Client.server_urls` = public frontend URL (LoadBalancer/Ingress) as seen by the endpoints

> **Never** commit `server.config.yaml` (it contains the CA + private keys).

## Custom artifacts & client packages

The image ships an **empty `/custom_artifacts/`** (uid 65532) as the default
mountpoint - the upstream image bakes this dir + `init.vql`; here it stays empty
and the two upstream behaviours that depended on it are opt-in chart features
(injected into the config via the chart's yq overlay-merge, base Secret untouched):

- **Custom VQL artifacts** - mount a ConfigMap at `/custom_artifacts/` and load it
  (`customArtifacts.enabled` → adds `defaults.artifact_definitions_directories`).
- **Client installer build** (`Container.InitializeServer`, the upstream first-boot
  step that produces downloadable MSI/DEB/RPM) - `config.initializeServer=true`. This image
  does not contain that artifact: the chart ships it (ConfigMap mounted at `/chart-artifacts`).

With a read-only rootfs, mount a volume at `/custom_artifacts/` to add files; the
baked dir only guarantees the path exists for configs that reference it.

## Expected runtime (chart)

- `securityContext`: `runAsNonRoot`, `runAsUser: 65532`, `readOnlyRootFilesystem: true`,
  `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`
- `/datastore` = writable volume (PVC RWO), `fsGroup: 65532`
- `/etc/velociraptor` = Secret mounted RO (or the config merged by the chart's init container)
- `/custom_artifacts` = optional ConfigMap mounted RO (else the baked empty dir)
- frontend (8000) exposed externally; GUI (8889) internal/VPN
