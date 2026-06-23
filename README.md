# Velociraptor — hardened server image

Hardening vs the upstream image (`Velocidex/velociraptor/Docker`):

| Aspect | Upstream | This image |
|--------|----------|------------|
| Base | `alpine:latest` (unpinned, shell, apk) | `gcr.io/distroless/static:nonroot` |
| User | root | `65532:65532` (rootless) |
| Config | generated at runtime (shell entrypoint) | generated out-of-band → Secret mounted RO |
| Surface | shell, apk, init.vql, custom_artifacts | binary + empty `/custom_artifacts` mountpoint |

amd64 only (the musl binary is static; the arm64 asset is dynamic → out of scope).

## Published image

```
ghcr.io/maximewewer/velociraptor:<version>-distroless
ghcr.io/maximewewer/velociraptor:latest
```

`<version>` is read from the `ARG VELO_VERSION` in the Dockerfile (single source of
truth). `update-versions.yml` (weekly) bumps `VELO_VERSION` + recomputes `VELO_SHA256`
from the upstream release and opens a PR. The [velociraptor Helm chart](../../charts/velociraptor)
consumes this image (`image.repository: maximewewer/velociraptor`).

## Build (local)

```bash
docker build -t velociraptor:0.76.6-distroless .
# version / checksum are overridable:
docker build \
  --build-arg VELO_VERSION=v0.76.6 \
  --build-arg VELO_SHA256=84ad1652ff6e79694441a06a6af4040aae6a982080d2ef583a31bda52f58e299 \
  -t velociraptor:0.76.6-distroless .
```

To update the version manually: change `VELO_VERSION`, recompute the sha256
(normally `update-versions.yml` does this automatically):
```bash
curl -fsSL "https://github.com/Velocidex/velociraptor/releases/download/v0.76.6/velociraptor-v0.76.6-linux-amd64-musl" | sha256sum
```

## Config generation (out-of-band)

The distroless image has no shell: there is no runtime generation. The server config
(which embeds the CA + private keys + secrets) is generated once, then stored in a
Kubernetes Secret mounted read-only at `/etc/velociraptor/server.config.yaml`.

Generate with the official binary (non-interactive via a response file):
```bash
# interactive
velociraptor config generate -i

# or non-interactive from a YAML merge
velociraptor config generate > server.config.yaml
```

Settings to adjust in `server.config.yaml` before turning it into a Secret:
- `Frontend.bind_address: 0.0.0.0` / `bind_port: 8000`
- `GUI.bind_address: 0.0.0.0` / `bind_port: 8889`
- `Datastore.location` and `Datastore.filestore_directory: /datastore`
- `Client.server_urls` = public frontend URL (LoadBalancer/Ingress) as seen by the endpoints
- keep the `CA`, `Frontend.certificate/private_key` sections (secrets)

Create the Secret:
```bash
kubectl create secret generic velociraptor-config \
  --from-file=server.config.yaml=./server.config.yaml -n <ns>
```

> **Never** commit `server.config.yaml` (it contains the CA + private keys). In production:
> External Secrets Operator / Vault.

## Custom artifacts & client packages

The image ships an **empty `/custom_artifacts/`** (uid 65532) as the default
mountpoint — the upstream image bakes this dir + `init.vql`; here it stays empty
and the two upstream behaviours that depended on it are opt-in chart features
(injected into the config via the chart's yq overlay-merge, base Secret untouched):

- **Custom VQL artifacts** — mount a ConfigMap at `/custom_artifacts/` and load it
  (`customArtifacts.enabled` → adds `defaults.artifact_definitions_directories`).
- **Client installer build** (`Container.InitializeServer`, the upstream first-boot
  step that produces downloadable MSI/DEB/RPM) — `config.initializeServer=true`.

With a read-only rootfs, mount a volume at `/custom_artifacts/` to add files; the
baked dir only guarantees the path exists for configs that reference it.

## Expected runtime (chart)

- `securityContext`: `runAsNonRoot`, `runAsUser: 65532`, `readOnlyRootFilesystem: true`,
  `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`
- `/datastore` = writable volume (PVC RWO), `fsGroup: 65532`
- `/etc/velociraptor` = Secret mounted RO
- `/custom_artifacts` = optional ConfigMap mounted RO (else the baked empty dir)
- frontend (8000) exposed externally; GUI (8889) internal/VPN
