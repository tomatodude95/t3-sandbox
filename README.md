# t3-sandbox

[T3 Code](https://github.com/pingdotgg/t3code), Claude Code, Codex and OpenCode, pre-installed in
one [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) (`sbx`). You drive all three providers
from the T3 Code app (desktop, mobile or web). The agents run in an isolated microVM that only sees
the project folder you mount.

Why: one sandbox and one pairing for all three providers, instead of installing and authorizing
each CLI on your own machine.

Below is the short way: `make` and `sandbox.sh`. Alternatives: [sbx directly](docs/sbx.md),
[plain Docker](docs/plain-docker.md), [manual builds](docs/building.md).

## Prerequisites

- macOS 14+ (Apple silicon) or Ubuntu 24.04+\*
- [sbx](https://docs.docker.com/ai/sandboxes/install/)
- Docker (Desktop or Engine)
- git
- bash
- jq
- make (macOS: `xcode-select --install`)

\* On Linux, KVM must be enabled and your user in the `kvm` group.

## Build the image

```bash
make sandbox      # builds the image and loads it into sbx
```

Repeat after changing `Dockerfile.sbx`. `make docker` builds the plain Docker image, `make all`
both. See [docs/building.md](docs/building.md).

## Run with sandbox.sh

`sandbox.sh` wraps the sbx commands. It picks a free host port (from 3773), reuses it on restart,
and prints a ready-to-use `Local URL` for pairing.
If you get "permission denied", run `chmod +x sandbox.sh` once.

```bash
./sandbox.sh create myapp ~/code/myapp t3        # new sandbox; t3 is the default and can be left out
./sandbox.sh start myapp                         # start it again later
./sandbox.sh start myapp -d                      # in the background; stop with ./sandbox.sh stop myapp
./sandbox.sh login myapp claude                  # log in to a provider (claude, codex, opencode, copilot or all)
./sandbox.sh upgrade-providers myapp             # update the provider CLIs while T3 Code runs
./sandbox.sh reload myapp                        # restart to pick up refreshed skills
./sandbox.sh ls                                  # list sandboxes managed by the script
./sandbox.sh rm myapp                            # delete the sandbox (asks first)
```

It also runs Docker's stock Claude Code, Codex, Copilot CLI and OpenCode sandboxes on their own,
without T3 Code:

```bash
./sandbox.sh create api ~/code/api claude        # interactive Claude Code
./sandbox.sh create cli ~/code/cli codex         # interactive Codex CLI
./sandbox.sh create tools ~/code/tools copilot   # interactive GitHub Copilot CLI
./sandbox.sh create web ~/code/web opencode      # OpenCode server
```

Settings go in `~/.config/t3-sandbox/config.conf` (see `config.example.conf`). Full reference:
[docs/sandbox.md](docs/sandbox.md).

## Pair and log in

**Pair the T3 Code app** with the `Local URL` line `create` prints. Then add the project in the
app. The workspace is mounted at its host path (e.g. `/Users/you/code/myapp`).

**Log in to the providers**, once per sandbox: `./sandbox.sh login myapp all`, or a terminal in the
T3 Code app. See [docs/providers.md](docs/providers.md).

## Security

Inside the sandbox, the agents run as `agent` with passwordless `sudo`. The isolation boundary is
the sandbox itself, and the mounted workspace is writable. Treat the pairing URL like a password.
See [docs/security.md](docs/security.md).
