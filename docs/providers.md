# Provider login

Each provider CLI needs a login once per sandbox (or container). Logins are kept in the
sandbox's `/home/agent` until the sandbox is removed.

| Provider | Command |
| --- | --- |
| Claude Code | `claude auth login` |
| Codex | `codex login` |
| OpenCode | `opencode auth login` |

Run them in one of these places:

- **T3 Code app:** open a terminal in the app once it's connected, and run the commands there.
- **Host, sbx:** `sbx exec -it <sandbox> claude auth login`
- **Host, plain Docker:** `docker exec -it <container> claude auth login`

**GitHub Copilot in T3 Code** goes through OpenCode: run `opencode auth login` and pick GitHub
Copilot. It's a device-code login at github.com/login/device and needs only a Copilot
subscription, no Copilot CLI.

Each command prints a URL for a browser login. Any browser works, it doesn't have to be on the
same machine.
