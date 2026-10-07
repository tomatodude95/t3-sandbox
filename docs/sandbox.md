# sandbox.sh

A wrapper around `sbx` that creates, starts and removes Docker Sandboxes for three agents:

| Agent | Sandbox name | What runs | Port |
| --- | --- | --- | --- |
| `opencode` (default) | `opencode-<project>` | `opencode serve` | published from `BASE_PORT` (8081) |
| `claude` | `claude-<project>` | interactive Claude Code via `sbx run` | none |
| `t3-code` | `t3-code-<project>` | `t3 serve` from the `sbx-custom-kit/` kit | published from `T3_BASE_PORT` (3773) |

Every command runs in the foreground. The sandbox stops when the command exits.

## Requirements

`bash`, `sbx` and `jq` on `PATH`. The `t3-code` agent also needs the `t3-code-sandbox-sbx` image loaded
into sbx (see the README).

## Commands

The agent (`claude` or `t3-code`) is an optional **last** argument. It is required on `create`.
Other commands infer it from the existing sandbox and only need it when several agents share a
project name. Commands that take a project name also accept the full sandbox name (`t3-code-myapp`).

| Command | Does |
| --- | --- |
| `create <project> <workspace> [port] [agent]` | Create and start a sandbox for `<workspace>` |
| `start <project> [port]` | Start an existing sandbox |
| `reload <project> [port] [agent]` | Stop (asks first), refresh the skills store, start again |
| `upgrade <project> [port]` | `t3-code` only: update `t3` to the latest npm release, restart if it changed (asks first) |
| `ls [all]` | List sandboxes managed by this script (`all`: raw `sbx ls`) |
| `rm <project> [agent]` | Remove a sandbox (asks first). Aliases: `remove`, `delete` |

Without `[port]`, a port that sbx restored from an earlier run is reused. Otherwise the first
free port from the base port up is used.

For `t3-code`, the startup log shows T3 Code's Pairing URL with the sandbox's internal address.
The script adds a `Local URL: http://127.0.0.1:<port>/pair#token=…` line after it. Use that one.

```bash
sandbox.sh create webapp ~/code/webapp t3-code
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
| `T3_BASE_PORT` | `3773` | First host port tried for `t3-code` |
| `OPENCODE_IMAGE` | `opencode` | sbx agent used for `opencode` sandboxes |
| `CLAUDE_IMAGE` | `claude` | sbx agent used for `claude` sandboxes |
| `T3CODE_KIT` | `sbx-custom-kit/` next to the script | Kit used for `t3-code` sandboxes |
| `NETWORK_ALLOW` | unset | Comma-separated hosts allowed for each new sandbox (`sbx policy allow network --sandbox`). Applied on `create` only |

`reload` always refreshes the skills store, whatever `SKILLS_IMPORT` says. To refresh the store
without touching a sandbox, run `sbx skills import --force`. Running sandboxes pick it up on their
next start.
