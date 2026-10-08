# Provider login

Each provider CLI needs a login once per sandbox (or container). Logins are kept in the
sandbox's `/home/agent` until the sandbox is removed.

| Provider | Command |
| --- | --- |
| Claude Code | `claude auth login` |
| Codex | `codex login --device-auth` (by hand, see below) |
| OpenCode | `opencode auth login` |
| Copilot CLI | `copilot login` |

Run them in one of these places:

- **sandbox.sh:** `./sandbox.sh login <project> <provider>` runs them for you. `all` logs in to
  Claude Code, Codex, OpenCode and the Copilot CLI in turn and asks before each, so you can skip
  any.
- **T3 Code app:** open a terminal in the app once it's connected, and run the commands there.
- **Host, sbx:** `sbx exec -it <sandbox> claude auth login`
- **Host, plain Docker:** `docker exec -it <container> claude auth login`

**GitHub Copilot in T3 Code** goes through OpenCode: run `opencode auth login` and pick GitHub
Copilot. It's a device-code login at github.com/login/device and needs only a Copilot
subscription, no Copilot CLI. t3 sandboxes include the Copilot CLI too, but T3 Code doesn't use
it yet.

Each command prints a URL for a browser login. Any browser works, it doesn't have to be on the
same machine. Each login waits until you've finished in the browser; Claude Code asks you to paste
back a code.

Codex's browser login ends on a `localhost:1455` page inside the sandbox, which your browser can't
load. `sandbox.sh login <project> codex` handles that: sign in, then paste the URL of that failed
page into the terminal and the script finishes the login. By hand, use
`codex login --device-auth` (enter a code at auth.openai.com) instead.
