# t3-sandbox

[T3 Code](https://github.com/pingdotgg/t3code), Claude Code, Codex and OpenCode, pre-installed in
one [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) (`sbx`). You drive all three providers
from the T3 Code app (desktop, mobile or web). The agents run in an isolated microVM that only sees
the project folder you mount.

Why: one sandbox and one pairing for all three providers, instead of installing and authorizing
each CLI on your own machine.

There are two ways to run a sandbox, both using the same image:
[with sandbox.sh](#run-with-sandboxsh) (recommended) or [with sbx directly](#run-with-sbx-directly).
It also runs as a plain Docker container, without sbx: see [docs/plain-docker.md](docs/plain-docker.md).

## Prerequisites

- macOS 14+ (Apple silicon) or Ubuntu 24.04+\*
- [sbx](https://docs.docker.com/ai/sandboxes/install/)
- Docker (Desktop or Engine)
- git
- bash
- jq

\* On Linux, KVM must be enabled and your user in the `kvm` group.

## Build the image

sbx has its own image store, so a local build isn't visible to it until loaded. Repeat after
changing `Dockerfile.sbx`.

```bash
docker build -f Dockerfile.sbx -t t3-sandbox-sbx .
docker image save t3-sandbox-sbx -o t3-sandbox-sbx.tar
sbx template load t3-sandbox-sbx.tar
```

## Run with sandbox.sh

`sandbox.sh` wraps the sbx commands. It picks a free host port (from 3773), reuses it on restart,
and prints a ready-to-use `Local URL` for pairing.

```bash
./sandbox.sh create myapp ~/code/myapp t3        # new sandbox; t3 is the default and can be left out
./sandbox.sh start myapp                         # start it again later
./sandbox.sh upgrade myapp                       # update T3 Code inside the sandbox
./sandbox.sh reload myapp                        # restart to pick up refreshed skills
./sandbox.sh ls                                  # list sandboxes managed by the script
./sandbox.sh rm myapp                            # delete the sandbox (asks first)
```

It also runs Docker's stock Claude Code and OpenCode sandboxes on their own, without T3 Code:

```bash
./sandbox.sh create api ~/code/api claude        # interactive Claude Code
./sandbox.sh create web ~/code/web opencode      # OpenCode server
```

Settings go in `~/.config/t3-sandbox/config.conf` (see `config.example.conf`). Full reference:
[docs/sandbox.md](docs/sandbox.md).

## Run with sbx directly

```bash
sbx create --name t3-myapp --kit ./sbx-custom-kit/ t3 ~/code/myapp
sbx exec t3-myapp true                           # start it
sbx ports t3-myapp --publish 3773:3773           # publish T3 Code's port on 127.0.0.1
sbx run --name t3-myapp                          # attach to T3 Code's log
sbx rm t3-myapp                                  # delete the sandbox
```

## Pair and log in

Both ways attach to T3 Code's log. The sandbox keeps running while it's attached.

**Pair the T3 Code app.** With `sandbox.sh`, use the `Local URL` line from the log. With sbx
directly, take the `Pairing URL` line and swap its host for `127.0.0.1:3773`, keeping the token.
Get a new token with `sbx exec t3-myapp t3 pair`. Then add the project in the app. The
workspace is mounted at its host path (e.g. `/Users/you/code/myapp`).

**Log in to the providers**, once per sandbox. The easiest way is a terminal in the T3 Code app,
connected to the sandbox. Or run them from the host:

```bash
sbx exec -it t3-myapp claude auth login
sbx exec -it t3-myapp codex login
sbx exec -it t3-myapp opencode auth login
```

See [docs/providers.md](docs/providers.md).

## Security

Inside the sandbox, the agents run as `agent` with passwordless `sudo`. The isolation boundary is
the sandbox itself, and the mounted workspace is writable. Treat the pairing URL like a password.
See [docs/security.md](docs/security.md).
