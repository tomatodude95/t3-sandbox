# t3-code-sandbox

[T3 Code](https://github.com/pingdotgg/t3code), Claude Code, Codex and OpenCode, pre-installed in
one [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) (`sbx`). You drive all three providers
from the T3 Code app (desktop, mobile or web). The agents run in an isolated microVM that only sees
the project folder you mount.

Why: one sandbox and one pairing for all three providers, instead of installing and authorizing
each CLI on your own machine.

## Ways to run it

| Way | Use it when | Files |
| --- | --- | --- |
| **sbx, custom image** (this README) | Default | `Dockerfile.sbx`, `sbx-custom-kit/`, `sandbox.sh` |
| sbx, mixin kits | You prefer T3 Code's SSH integration on Docker's stock agent images | `sbx-kit/`, see [docs/sbx-mixin-kits.md](docs/sbx-mixin-kits.md) |
| Plain Docker | You don't use sbx | `Dockerfile`, see [docs/plain-docker.md](docs/plain-docker.md) |

## Prerequisites

- git
- Docker (Desktop or Engine), to build the image
- [sbx](https://docs.docker.com/ai/sandboxes/install/), signed in to Docker
- bash and jq, for `sandbox.sh`

macOS:

- macOS 14 or later on Apple silicon (required by sbx)
- `brew install jq`

Linux:

- Ubuntu 24.04 or later, x86-64 or arm64 (required by sbx)
- KVM enabled, and your user in the `kvm` group (`sudo usermod -aG kvm $USER`)
- `sudo apt install jq`

## Quick start

**1. Build the image and load it into sbx.** sbx has its own image store, so a local build isn't
visible to it until loaded. Repeat after changing `Dockerfile.sbx`.

```bash
docker build -f Dockerfile.sbx -t t3-code-sandbox-sbx .
docker image save t3-code-sandbox-sbx -o t3-code-sandbox-sbx.tar
sbx template load t3-code-sandbox-sbx.tar
```

**2. Create a sandbox, publish T3 Code's port and attach to its log.**

```bash
sbx create --name t3-code-myapp --kit ./sbx-custom-kit/ t3-code ~/code/myapp
sbx exec t3-code-myapp true                      # start it
sbx ports t3-code-myapp --publish 3773:3773
sbx run --name t3-code-myapp                     # T3 Code's server log, incl. pairing URL
```

The sandbox keeps running only while `sbx run` is attached.

**3. Log in to the providers** (once per sandbox):

```bash
sbx exec -it t3-code-myapp claude auth login
sbx exec -it t3-code-myapp codex login
sbx exec -it t3-code-myapp opencode auth login
```

**4. Pair the T3 Code app.** The log prints a `Pairing URL` with the sandbox's internal address.
Swap the host for the published one and keep the token:
`http://127.0.0.1:3773/pair#token=…`. Get a new token with `sbx exec t3-code-myapp t3 pair`.
Then add the project in the app. The workspace is mounted at its host path (e.g.
`/Users/you/code/myapp`).

## sandbox.sh

A shortcut for steps 2 and 4. It picks a free port, reuses it on restart, and prints a ready-to-use
`Local URL` for pairing.

```bash
./sandbox.sh create myapp ~/code/myapp t3-code
./sandbox.sh start myapp
./sandbox.sh upgrade myapp        # update T3 Code inside the sandbox
```

Settings go in `~/.config/t3-sandbox/config.sh` (see `config.example.sh`). The script also manages
plain OpenCode and Claude Code sandboxes. See [docs/sandbox.md](docs/sandbox.md).

## Security

Inside the sandbox, the agents run as `agent` with passwordless `sudo`. The isolation boundary is
the sandbox itself, and the mounted workspace is writable. Treat the pairing URL like a password.
See [docs/security.md](docs/security.md).

## What's inside

| Tool | npm package | Binary |
| --- | --- | --- |
| T3 Code | `t3` | `t3` |
| Claude Code | `@anthropic-ai/claude-code` | `claude` |
| Codex | `@openai/codex` | `codex` |
| OpenCode | `opencode-ai` | `opencode` |

## License

GPL-3.0, see [LICENSE](LICENSE).
