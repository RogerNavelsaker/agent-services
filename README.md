# Agent Services

This repository builds four independent Nix container images: the existing Tailscale + Caddy gateway, plus Engram Cloud, Headroom, and Caveman. The three application images run as unprivileged users; the gateway remains a separate ingress sidecar. CLI derivations are exported separately for use from devenv. Images are assembled with Nix `dockerTools`; no container-engine socket is needed during the build.

**Gateway image:** `tailnet-gateway` (GHCR: `ghcr.io/rogernavelsaker/tailnet-gateway`). The workflow keeps `ghcr.io/rogernavelsaker/ts-caddy-gateway` as a compatibility alias.

## Service outputs

| CLI package | OCI image package | Image name | Purpose |
| --- | --- | --- | --- |
| `engram` | `engram-image` | `agent-services-engram:latest` | Engram Cloud server; uses an external PostgreSQL database. |
| `headroom` | `headroom-image` | `agent-services-headroom:latest` | Headroom proxy, pinned to upstream commit `3c418f6f0b190ad1060413c0eadd77f20ab3cf46` containing the Caveman retrieval safeguard from [PR #4014](https://github.com/headroomlabs-ai/headroom/pull/4014). |
| `caveman` | `caveman-image` | `agent-services-caveman:latest` | Caveman proxy and MCP binaries, sharing persistent recovery state. |
| — | `image` | `tailnet-gateway:latest` | Existing Tailscale + Caddy ingress sidecar. |

The CLI outputs are standard flake packages that consuming `devenv` configurations can select independently of the OCI images. The Headroom package runs `tests/test_headroom_caveman_safeguard.py` during its Nix check: it verifies the bare and MCP-prefixed tool names are excluded from both lossy and verbatim transforms, recovery results stay byte-exact for OpenAI and Anthropic message shapes, and unrelated retrieval tools are not blanket-excluded.

The separate `caveman-cli` package (x86_64 Linux) ships the official `@caveman-ai/cli` 4.0.1 via Bun with matching `bin-v4.0.1` runtime helpers. It is included in this repo's `devenv shell` as `caveman` and `cave`; the wrapper defaults `DO_NOT_TRACK=1`. This developer CLI is distinct from the `caveman` v2.1.0 proxy/MCP package used by the service image.

### Runtime requirements

- **Engram:** provide `ENGRAM_DATABASE_URL`, `ENGRAM_JWT_SECRET`, and `ENGRAM_CLOUD_ALLOWED_PROJECTS` at runtime. The image binds to `0.0.0.0:7437`; it does not bundle PostgreSQL or migrate existing data.
- **Headroom:** persist `/data` and `/config`. The anonymous beacon is disabled; persistent memory and learning are not enabled. CCR originals are unencrypted and use Headroom's documented 30-minute default retention, so protect the mounted state accordingly.
- **Caveman:** persist `/data` for the recovery store. Because the proxy listens on the container network, provide `CAVEMAN_AUTH_TOKEN` as a secret; Caveman requires at least 16 characters for non-loopback access. Keep provider credentials runtime-only.

Caveman's MCP server is stdio-only and must use the same persistent store as its proxy. Run it through the container runtime's exec-based MCP transport, for example `podman exec -i caveman caveman-mcp`. Headroom MCP is separate from the proxy and can connect to that proxy with `podman exec -i headroom headroom mcp serve --proxy-url http://127.0.0.1:8787`; neither MCP process needs an additional network listener.

## Configuration model

- **OCI labels** identify the built image (title, source, revision, description). They are metadata, not runtime service configuration.
- **Environment variables** configure Tailscale and provide secrets. Use Podman/Docker secrets and the `_FILE` variables when possible.
- **Mounted files** carry Caddy configuration. Cloudflare's plugin reads its token from the environment referenced in the Caddyfile.
- **No engine labels/socket discovery:** services are routed explicitly in the Caddyfile. This keeps the sidecar independent of the container engine and avoids granting it access to the engine socket.

| Variable | Default | Purpose |
| --- | --- | --- |
| `TS_AUTHKEY` | unset | Tailscale auth key; authenticates only when set. |
| `TS_AUTHKEY_FILE` | unset | Read the auth key from a mounted secret file; takes precedence over `TS_AUTHKEY`. |
| `TS_HOSTNAME` | `tailnet-gateway` | Tailscale node hostname used during `tailscale up`. |
| `TS_STATE_DIR` | `/var/lib/tailscale` | Persistent Tailscale state directory. Mount a persistent volume here. |
| `TS_SOCKET` | `/var/run/tailscale/tailscaled.sock` | Local `tailscaled` socket path. |
| `TS_DAEMON_ARGS` | empty | Additional whitespace-separated arguments for `tailscaled` (for example `--tun=userspace-networking`). |
| `TS_EXTRA_ARGS` | empty | Additional whitespace-separated arguments for `tailscale up` (for example `--accept-routes`). Arguments are not evaluated as shell code. |
| `CADDYFILE` | `/etc/caddy/Caddyfile` | Path to the mounted Caddyfile or other Caddy config. |
| `CADDY_ADAPTER` | `caddyfile` | Caddy config adapter. |
| `CLOUDFLARE_API_TOKEN` | unset | Cloudflare token used by Caddy's DNS module. |
| `CLOUDFLARE_API_TOKEN_FILE` | unset | Read the Cloudflare token from a mounted secret file; takes precedence over the direct variable. |

The Caddyfile controls host routing and TLS. For example:

```caddyfile
{
  acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

app.example.net {
  reverse_proxy app:8080
}
```

Attach the gateway and backend to the same user-defined container network so the Caddyfile can resolve the backend service name. In TUN mode, the container needs `/dev/net/tun` and `NET_ADMIN`; `NET_RAW` is included for Tailscale networking. No host port publishing is required when clients connect over the gateway's tailnet IP.

## Run with Podman

Create Podman secrets from local files (keep these files out of version control):

```sh
podman secret create tailscale-authkey ./tailscale-authkey
podman secret create cloudflare-api-token ./cloudflare-api-token
```

Then start the sidecar on the same network as the service:

```sh
podman run -d \
  --name=tailnet-gateway \
  --network=app-network \
  --device=/dev/net/tun:/dev/net/tun \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --secret=tailscale-authkey,type=mount,target=/run/secrets/ts-authkey \
  --secret=cloudflare-api-token,type=mount,target=/run/secrets/cloudflare-token \
  -e TS_AUTHKEY_FILE=/run/secrets/ts-authkey \
  -e TS_HOSTNAME=app-gateway \
  -e TS_EXTRA_ARGS="--advertise-tags=tag:gateway" \
  -e CLOUDFLARE_API_TOKEN_FILE=/run/secrets/cloudflare-token \
  -v tailscale-state:/var/lib/tailscale:rw \
  -v ./Caddyfile:/etc/caddy/Caddyfile:ro \
  -v caddy-data:/data:rw \
  -v caddy-config:/config:rw \
  ghcr.io/rogernavelsaker/tailnet-gateway:latest
```

The Tailscale auth key should be reusable only as needed for the deployment; the persisted state volume keeps the node identity across restarts. Configure advertised tags in the tailnet ACL policy.

## Build locally

Build all four images; the Headroom build also runs the Caveman retrieval safeguard regression tests:

```sh
nix build .#image .#engram-image .#headroom-image .#caveman-image --no-link
```

Load an individual image into Podman for local inspection:

```sh
nix build .#engram-image --out-link /tmp/agent-services-engram
podman load < /tmp/agent-services-engram
```

## GitHub Actions publishing

`.github/workflows/ci.yml` checks the flake and builds all images on pull requests and manual runs. Default-branch pushes and version tags build, inspect, and publish each image through `.github/workflows/publish.yml`. The Headroom package's Nix check verifies PR #4014's retrieval safeguards. Published tags include branch, commit-SHA, and semantic-version forms. The gateway retains its `tailnet-gateway` and `ts-caddy-gateway` image names, with `agent-services-gateway` added; the app images publish as `agent-services-engram`, `agent-services-headroom`, and `agent-services-caveman`.

Publishing requires GitHub Actions and the workflow's `packages: write` permission.
