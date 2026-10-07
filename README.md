# t3-code-sandbox

Claude Code, Codex, OpenCode, and T3 Code, pre-installed together so you can drive all three
providers from T3 Code's app (desktop/mobile/web).

There are three ways to use this, and they use different images/Dockerfiles:

- **[Docker Sandboxes (`sbx`), mixin kits](#using-with-docker-sandboxes-sbx)** — the
  officially-supported path. T3 Code has no dedicated `sbx` integration; it just SSHes into a
  normal sandbox and starts its own server there. You stack lightweight *kits* onto one of Docker's
  own agent templates instead of building a custom image.
- **[Docker Sandboxes (`sbx`), custom sandbox image](#alternative-a-fully-custom-sandbox-image)** —
  `Dockerfile.sbx`, for making your own image (with `t3 serve` as the sandbox's own process) launch
  under `sbx` via a `kind: sandbox` kit, bypassing T3 Code's SSH integration entirely.
- **[Plain Docker](#using-with-plain-docker)** — this repo's `Dockerfile`, built and run with
  ordinary `docker build`/`docker run`, for when you're not using `sbx` at all.

## Using with Docker Sandboxes (`sbx`)

Verified against Docker's own docs (`docs.docker.com/ai/sandboxes/...`) and the real
`docker/sbx-kits-contrib` kit source, since this is Early Access tooling and worth double-checking
against `sbx --help` on your installed version.

**This path does not use the `Dockerfile` in this repo at all.** `sbx run`/`sbx create` attach to
one of Docker's own base agent images (`docker/sandbox-templates:<claude|codex|opencode|...>`), and
T3 Code's SSH integration expects that base image's own init/entrypoint to stay in control — not a
custom process like our `t3 serve` entrypoint. Instead, you get all four tools into one sandbox by
stacking two small *kits* onto a standard agent template at creation time:

1. `docker.io/sbx/t3code-kit:latest` — Docker's official kit. Pre-installs the build toolchain
   (`g++`, `make`, `python3`) and the `t3` npm package, so T3 Code's first SSH connection doesn't
   have to compile `node-pty` from source (confirmed this is the same node-pty/arm64 issue I hit
   building the plain-Docker image below).
2. `sbx-kit/spec.yaml` (in this repo) — installs the Codex and OpenCode CLIs, so all three
   providers exist alongside whichever agent you pick as the sandbox's base.

```bash
# one-time: lets your SSH client reach any sandbox at <name>.sbx
sbx setup ssh

# create the sandbox — claude is the base agent here, but codex/opencode work as the base too
sbx create --name t3sandbox claude ~/path/to/project \
  --kit docker.io/sbx/t3code-kit:latest \
  --kit ./sbx-kit/

# confirm all four tools landed
sbx exec t3sandbox -- sh -lc 'command -v claude && command -v codex && command -v opencode && command -v t3'
```

Then in the T3 Code app: add an SSH environment for host `t3sandbox.sbx`, add a project, and pick
the mounted workspace folder (it keeps its absolute host path inside the sandbox — e.g. select
`/Users/you/path/to/project`, not `/workspace`). T3 Code installs/starts its own server inside over
that SSH connection and port-forwards it back automatically — there's no manual port-publish or
pairing-token step here, unlike the plain-Docker path below.

Some things worth knowing:

- `--kit` only takes effect at sandbox creation. To add the `sbx-kit/` mixin to a sandbox you
  already created, use `sbx kit add t3sandbox ./sbx-kit/` instead — it restarts the sandbox but
  keeps installed packages, volumes, and agent history.
- Because sandboxes default to deny-by-default egress, `sbx-kit/spec.yaml` explicitly allows
  `registry.npmjs.org:443` for its own `npm install -g`. The official `t3code` kit separately
  allows the npm registry plus the apt sources it needs.
- If you'd rather use `codex` or `opencode` as the sandbox's base agent instead of `claude`, swap
  it in the `sbx create` command — both kits are agent-agnostic.

### Alternative: a fully custom sandbox image

If you'd rather have T3 Code's own `t3 serve` be the sandbox's actual process (pairing-token flow,
like the plain-Docker path below) instead of going through T3 Code's SSH integration, `sbx` supports
that too via a `kind: sandbox` kit — a different mechanism from the mixin kits above. A plain
`--template` swap doesn't get you this: `sbx run <agent> --template <image>` still execs that
agent's normal launch command inside your image, ignoring the image's own `ENTRYPOINT`. A
`kind: sandbox` kit is what actually lets `sbx` launch *your* entrypoint.

**What I verified, and what I couldn't:** `sbx` requires KVM to launch its microVMs, and the sandbox
I'm running in doesn't expose `/dev/kvm` — confirmed all the way down to `sailor: KVM is not
available` when I actually tried creating a real sandbox here, after installing `sbx` and
authenticating. So I built and fully verified `Dockerfile.sbx` (the image builds, all four tools
install and run, `entrypoint.sh` binds port 3773 and prints a pairing token correctly) with plain
`docker run` — the furthest I could go. The `sbx template load` / `sbx run --kit` steps below are
untested by me; that needs a real run on your Mac (which has actual virtualization, so it isn't
subject to this limitation).

`Dockerfile.sbx` is the same idea as the plain-Docker `Dockerfile`, but based on
`docker/sandbox-templates:shell-docker` instead of `node:22-bookworm-slim`. That base image already
provides what a `kind: sandbox` image needs (non-root
`agent` user at UID 1000, passwordless sudo, `/home/agent`, proxy env forwarding) plus Node.js, npm,
git, `make`, and `python3` — only `g++` was missing for `node-pty` to compile. Its own entrypoint is
`tini --` with CMD `bash`; `Dockerfile.sbx` keeps `tini` as PID1 and points it at our
`entrypoint.sh` instead of dropping it.

```bash
# build the image
docker build -f Dockerfile.sbx -t t3-code-sandbox:sbx .

# sbx's daemon has its own separate image store — a plain local build isn't visible to it.
# Load it in directly, no registry needed:
docker image save t3-code-sandbox:sbx -o t3-code-sandbox.tar
sbx template load t3-code-sandbox.tar

# launch it — the positional name must match `name:` in sbx-custom-kit/spec.yaml
sbx run --kit ./sbx-custom-kit/ t3-code
```

`sbx-custom-kit/spec.yaml` doesn't declare any ports, so publish one yourself with
`sbx ports t3-code --publish 3773:3773` (check with `sbx ports t3-code`). `sbx` remembers published
ports and restores them when the sandbox starts again. `sandbox.sh` handles all of this itself:
it reuses a restored binding, or picks a free port from 3773 up, and adds a
`Local URL: http://127.0.0.1:<port>/pair#token=…` line after T3 Code's own Pairing URL.

To update T3 Code inside an existing sandbox, run `sandbox.sh upgrade <name>`. It installs
`t3@latest` with npm inside the sandbox and restarts the sandbox (after asking) if the version changed.
The update survives stop/start. A recreated sandbox starts at the image's version again. Since `sbx run` attaches to whatever the entrypoint prints
(there's no separate "logs" command), attaching shows the same startup output as the plain-Docker
path — including the pairing token — and `sbx exec t3-code -- t3 pair` mints a fresh one anytime.

This kit doesn't declare any `permissions.network` rules — T3 Code, Claude, Codex, and OpenCode all
need outbound access to their own APIs/relays, and I didn't want to guess an allowlist I hadn't
verified. Watch `sbx policy log` for what gets blocked and add rules with `sbx policy allow network
<host>` as needed.

Note the image itself is noticeably bigger than the plain-Docker one (`shell-docker` bundles a full
Docker-in-Docker setup) — expect a longer first build/load.

## Using with plain Docker

Built and verified on Docker Desktop for Apple Silicon (arm64); `node:22-bookworm-slim` is
multi-arch, so it also builds on amd64 hosts. Starts T3 Code's headless server on boot, with a
manual pairing-token flow instead of `sbx`'s automatic SSH port-forwarding.

### Build

```bash
docker build -t t3-code-sandbox .
```

This is a normal local image build — once it finishes, the image is registered in your local
Docker daemon's image store. There's no separate "import" step; `docker run t3-code-sandbox`
immediately uses what you just built.

### Run

```bash
docker run -d --name t3code --rm \
  -p 3773:3773 \
  -v "$(pwd)/projects":/workspace \
  t3-code-sandbox
```

- No `-v` is given for `/home/agent`. The Dockerfile declares `VOLUME /home/agent`, so Docker
  creates an **anonymous** volume for it automatically — this covers T3 Code's own state
  (`~/.t3`), and each provider's auth/config (`~/.claude`, `~/.claude.json`, `~/.codex`,
  `~/.config/opencode`, `~/.cache/opencode`, `~/.local/share/opencode`,
  `~/.local/state/opencode`).
- `-v "$(pwd)/projects":/workspace` — your actual project code, bind-mounted so T3 Code (and the
  providers it drives) can read/write real files. Swap in whatever host path you want to work on.
- `-p 3773:3773` — T3 Code's default HTTP/WebSocket port.

### Persistence model

Verified this behaves the way you'd want: the anonymous volume survives `docker stop`/`start`,
`docker restart`, and a host reboot (with a restart policy) — the container isn't removed by any
of those, so its volume sticks around. It's tied to *that one container*, though, not to the image
or any shared name:

- `docker stop t3code` then `docker start t3code` → auth/state intact.
- `docker rm t3code` (after a plain stop) or letting a `--rm` container stop normally → the
  anonymous volume is deleted along with it. Re-running `docker run` afterward starts clean.
- **Gotcha I hit while verifying this:** `docker rm -f` on a `--rm` container does *not* reliably
  clean up its anonymous volume — some race in how forced removal interacts with the
  auto-remove path. If you need to force-remove and want the volume gone too, use
  `docker rm -fv t3code` (the explicit `-v` makes it reliable) rather than plain `docker rm -f`.

If you *want* auth/state to outlive a `docker rm`, opt in explicitly with a named volume instead:
`-v t3code-home:/home/agent`. Don't reuse one named volume across multiple containers, though (see
below) — T3 Code keeps its state in a single SQLite file, and two containers writing to the same
file concurrently is a real corruption risk, not just a config mix-up.

### Running multiple instances at once

Each instance needs its own host port (container port is always 3773) and its own `/workspace`.
Leave `/home/agent` as the default anonymous volume — every container gets its own automatically,
so there's no state collision between instances:

```bash
docker run -d --name t3code-alice --rm -p 3773:3773 -v ~/projects/alice:/workspace t3-code-sandbox
docker run -d --name t3code-bob   --rm -p 3774:3773 -v ~/projects/bob:/workspace   t3-code-sandbox
```

Verified both run simultaneously with independent tokens, independent provider auth, and no
cross-talk.

The container's entrypoint runs:

```bash
t3 serve --host 0.0.0.0 --port 3773 --no-browser --auto-bootstrap-project-from-cwd /workspace
```

`--auto-bootstrap-project-from-cwd` creates a project for `/workspace` on first boot so you don't
have to do it by hand. Override the bind host/port without rebuilding via `-e T3_HOST=... -e
T3_PORT=...`.

### First-time provider auth

Provider CLIs need their own login before you can start a session with them. Do this once per
container (it survives stop/restart, but not a `docker rm` of that container — see the
persistence model above):

```bash
docker exec -it t3code claude auth login
docker exec -it t3code codex login
docker exec -it t3code opencode auth login
```

Each opens a device-code/OAuth flow that prints a URL — open it in a browser on any machine, it
doesn't have to be inside the container.

### Connecting from your T3 Code app

```bash
docker logs t3code
```

prints, on every boot:

```
Connection string: http://172.18.0.2:3773        <- container's internal Docker IP, ignore this
Token: XXXXXXXXXXXX
Pairing URL: http://172.18.0.2:3773/pair#token=XXXXXXXXXXXX   <- ignore this host part too
```

**The printed host is the container's internal Docker network IP — it's not reachable from outside
Docker.** Since you published the port with `-p 3773:3773`, replace that part with an address your
client can actually reach, keeping the same token:

- Same machine: `http://localhost:3773/pair#token=XXXXXXXXXXXX`
- Another device on your LAN: `http://<mac-lan-ip>:3773/pair#token=XXXXXXXXXXXX`
- Over Tailscale/a tailnet: `http://<tailnet-ip-or-magicdns-name>:3773/pair#token=XXXXXXXXXXXX`

Paste that URL into the T3 Code desktop/mobile app's pairing screen, or scan the QR code T3 prints
(note the QR still encodes the container-internal address — for anything but same-machine access,
type the corrected URL in manually instead of scanning). Tokens are one-time; mint a fresh one
anytime the server is already running with:

```bash
docker exec -it t3code t3 pair
```

Exposing this beyond your own LAN/tailnet is not recommended — treat the pairing URL/token like a
password (see T3 Code's [remote access docs](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md)
for the full security model).

### What's inside

| Tool | Package | Binary |
| --- | --- | --- |
| T3 Code | `t3` | `t3` |
| Claude Code | `@anthropic-ai/claude-code` | `claude` |
| Codex | `@openai/codex` | `codex` |
| OpenCode | `opencode-ai` | `opencode` |

`python3`/`make`/`g++` are installed at build time because `node-pty` (a T3 Code dependency used
to drive provider CLIs in a PTY) has no prebuilt binary for every platform (notably arm64) and
compiles from source via `node-gyp` — confirmed this is what happens on Apple Silicon.

The container runs as a non-root `agent` user (passwordless `sudo` available if you need to
install something ad hoc via `docker exec`).
