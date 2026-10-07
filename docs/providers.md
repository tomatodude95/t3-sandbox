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

Each command prints a URL for a browser login. Any browser works, it doesn't have to be on the
same machine.
