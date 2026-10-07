# Security notes

## Passwordless sudo inside the container

The `agent` user can run `sudo` without a password in both images. The plain-Docker
`Dockerfile` sets this up, and the sbx base image (`docker/sandbox-templates:shell-docker`)
ships with it. Any agent running in the container can therefore become root **inside the
container**. The isolation boundary is the container or sbx microVM, not the user account.
Mounted workspace folders are writable either way.

## Network exposure

T3 Code binds `0.0.0.0` inside the container. It has to: port forwarding (Docker's `-p`,
`sbx ports`) delivers traffic to the container's network interface, not to its loopback, so a
server bound to `127.0.0.1` inside is unreachable. That inside address only covers the
container's own network. Who can connect is decided by the host side of the published port:

- **Plain Docker:** `-p 3773:3773` listens on all host interfaces, so other machines on your
  network can reach the server. Use `-p 127.0.0.1:3773:3773` to keep it local, or a specific
  address (e.g. your Tailscale IP) to expose it only there.
- **sbx:** `sbx ports --publish` binds host loopback when no host IP is given, so it is local
  only by default. `sandbox.sh` publishes that way.

Treat the pairing URL/token like a password. See T3 Code's
[remote access docs](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md).

## Credentials

Provider logins (`~/.claude`, `~/.codex`, `~/.config/opencode`, …) and T3 Code's state (`~/.t3`)
live in the container's `/home/agent`. They stay there until the container (plain Docker) or the
sandbox (`sbx rm`) is removed.

## Outbound network (sbx)

`sbx-custom-kit/spec.yaml` declares no network allowlist. What the sandbox can reach depends on
your sbx policy preset (`sbx policy ls`). Blocked requests show up in `sbx policy log`. Extra
hosts for sandboxes created by `sandbox.sh` go in `NETWORK_ALLOW` (see [sandbox.md](sandbox.md)).
