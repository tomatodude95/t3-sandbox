# sandbox.sh

A wrapper around `sbx` that creates, starts and removes Docker Sandboxes for five agents:

| Agent | Sandbox name | What runs | Port |
| --- | --- | --- | --- |
| `t3` (default) | `t3-<project>` | `t3 serve` from the `t3-kit/` kit | published from `T3_BASE_PORT` (3773) |
| `claude` | `claude-<project>` | interactive Claude Code via `sbx run` | none |
| `codex` | `codex-<project>` | interactive Codex CLI via `sbx run` | none |
| `copilot` | `copilot-<project>` | interactive GitHub Copilot CLI via `sbx run` | none |
| `opencode` | `opencode-<project>` | `opencode serve` | published from `BASE_PORT` (8081) |

Every command runs in the foreground. The sandbox stops when the command exits.

## Requirements

`bash`, `sbx` and `jq` on `PATH`. The `t3` agent also needs the `t3-sandbox-sbx` image loaded
into sbx (see the README).

## Commands

The agent (`t3`, `claude`, `codex`, `copilot` or `opencode`) is an optional **last** argument. On `create` it
defaults to `t3`. Other commands infer it from the existing sandbox and only need it when
several agents share a project name. Commands that take a project name also accept the full sandbox name (`t3-myapp`).

| Command | Does |
| --- | --- |
| `create <project> <workspace> [port] [agent]` | Create and start a sandbox for `<workspace>` |
| `start <project> [port]` | Start an existing sandbox |
| `reload <project> [port] [agent]` | Stop (asks first), refresh the skills store, start again |
| `login <project> [provider]` | Log in to `claude`, `codex`, `opencode` or `copilot` inside the sandbox; `all` logs in to each of the sandbox's providers in turn. Required for `t3` sandboxes; other sandboxes default to their own agent. With several agents per project name, pass the full sandbox name |
| `upgrade-providers <project>` | `t3` sandboxes only: update T3 Code and the provider CLIs in place. New sessions use the new CLIs; T3 Code itself needs a restart. A stopped sandbox is started for the update and stopped again |
| `ls [all]` | List sandboxes managed by this script (`all`: raw `sbx ls`) |
| `rm <project> [agent]` | Remove a sandbox (asks first). Aliases: `remove`, `delete` |
| `help` | Show the short help (also `-h`, `--help`) |

Without `[port]`, a port that sbx restored from an earlier run is reused. Otherwise the first
free port from the base port up is used.

On `create`, `start` and `reload` the script checks for newer versions of the sandbox's CLIs
(`t3`, `claude`, `codex`, `opencode`, `copilot`) and asks before updating them all. It skips the
check if `registry.npmjs.org` doesn't answer within 2s, or without a terminal. Turn it off with
`UPDATE_CHECK=0`.

For `t3`, the startup log shows T3 Code's Pairing URL with the sandbox's internal address.
The script adds a `Local URL: http://127.0.0.1:<port>/pair#token=…` line after it. Use that one.

```bash
sandbox.sh create webapp ~/code/webapp
sandbox.sh create api ~/code/api opencode
sandbox.sh start webapp
sandbox.sh rm webapp
```

## Configuration

Settings are read from `~/.config/t3-sandbox/config.conf` (see
[`config.example.conf`](../config.example.conf)). Environment variables of the same name override it.

The file holds `KEY=value` lines. Lines starting with `#` are comments, quotes around a value are
optional and a leading `~` means your home folder. The file is parsed, not executed, and unknown
keys are an error.

| Setting | Default | Meaning |
| --- | --- | --- |
| `SBX_BIN` | `sbx` | sbx binary, a name on `PATH` or an absolute path |
| `SKILLS_DIR` | unset | Host folder mounted read-only into new sandboxes at its host path. Unset = no mount |
| `SKILLS_IMPORT` | `1` if `SKILLS_DIR` is set, else `0` | Run `sbx skills import --force` before `create`/`start` |
| `BASE_PORT` | `8081` | First host port tried for `opencode` (8080 is left free on purpose) |
| `T3_BASE_PORT` | `3773` | First host port tried for `t3` |
| `OPENCODE_IMAGE` | `opencode` | sbx agent used for `opencode` sandboxes |
| `CLAUDE_IMAGE` | `claude` | sbx agent used for `claude` sandboxes |
| `CODEX_IMAGE` | `codex` | sbx agent used for `codex` sandboxes |
| `COPILOT_IMAGE` | `copilot` | sbx agent used for `copilot` sandboxes |
| `T3_KIT` | `t3-kit/` next to the script | Kit used for `t3` sandboxes |
| `NETWORK_ALLOW` | unset | Comma-separated hosts allowed for each new sandbox (`sbx policy allow network --sandbox`). Applied on `create` only |
| `UPDATE_CHECK` | `1` | Check for provider updates on `create`/`start`/`reload` |

`reload` always refreshes the skills store, whatever `SKILLS_IMPORT` says. To refresh the store
without touching a sandbox, run `sbx skills import --force`. Running sandboxes pick it up on their
next start.
