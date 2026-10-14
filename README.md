# tailnet-gateway

A Nix-built Tailscale + Caddy ingress sidecar. This repository owns the gateway only; Engram, Headroom, and Caveman packages and images live in their respective `nixpkg-*` repositories. The image is assembled with Nix `dockerTools`; no container-engine socket is needed during the build.

The OCI image is available as `packages.image` / `packages.default`. GHCR names remain `ghcr.io/rogernavelsaker/tailnet-gateway`, `ghcr.io/rogernavelsaker/ts-caddy-gateway`, and the compatibility alias `ghcr.io/rogernavelsaker/agent-services-gateway`.

## Runtime model

- Tailscale provides the tailnet connection; Caddy handles HTTPS and reverse proxying.
- Routes are explicit in the mounted Caddyfile. The gateway does not discover containers and receives no container-engine socket.
- Keep the gateway and backend on the same user-defined network so the Caddyfile can resolve the backend service name.
- In TUN mode, the container needs `/dev/net/tun`, `NET_ADMIN`, and `NET_RAW`. No host port publishing is needed when clients connect through the gateway's tailnet IP.
- Persist Tailscale state so restarts retain the node identity. Configure advertised tags in the tailnet ACL policy.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `TS_AUTHKEY` | unset | Tailscale auth key; authenticates only when set. |
| `TS_AUTHKEY_FILE` | unset | Read the auth key from a mounted secret file; takes precedence over `TS_AUTHKEY`. |
| `TS_HOSTNAME` | `tailnet-gateway` | Tailscale node hostname used during `tailscale up`. |
| `TS_STATE_DIR` | `/var/lib/tailscale` | Persistent Tailscale state directory. |
| `TS_SOCKET` | `/var/run/tailscale/tailscaled.sock` | Local `tailscaled` socket path. |
| `TS_DAEMON_ARGS` | empty | Additional whitespace-separated `tailscaled` arguments. |
| `TS_EXTRA_ARGS` | empty | Additional whitespace-separated `tailscale up` arguments; not evaluated as shell code. |
| `CADDYFILE` | `/etc/caddy/Caddyfile` | Mounted Caddy configuration path. |
| `CADDY_ADAPTER` | `caddyfile` | Caddy config adapter. |
| `CLOUDFLARE_API_TOKEN` | unset | Cloudflare token used by the DNS plugin. |
| `CLOUDFLARE_API_TOKEN_FILE` | unset | Read the Cloudflare token from a mounted secret file; takes precedence over the direct variable. |

The Caddyfile controls host routing and TLS. Example:

```caddyfile
{
  acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

app.example.net {
  reverse_proxy app:8080
}
```

## Run with Podman

Create secrets from local files and keep those files out of version control:

```sh
podman secret create tailscale-authkey ./tailscale-authkey
podman secret create cloudflare-api-token ./cloudflare-api-token
```

Start the gateway on the backend's network:

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

## Build and verify

```sh
nix flake check --accept-flake-config
nix build .#image --no-link
```

CI checks the flake, validates the entrypoint, and builds the gateway image. The publish workflow retains all three GHCR names and runs only on an explicit dispatch or version tag; ordinary main-branch pushes do not publish an image.
