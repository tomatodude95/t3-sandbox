# sbx with mixin kits

No custom image. You stack two kits onto one of Docker's stock agent templates, and T3 Code
connects over SSH, starting its own server inside the sandbox:

1. `docker.io/sbx/t3code-kit:latest`: Docker's official kit (build toolchain and the `t3` package).
2. `sbx-kit/`: this repo's kit, which adds the Codex and OpenCode CLIs.

```bash
sbx setup ssh                                    # once: makes <name>.sbx reachable over SSH
sbx create --name t3sandbox claude ~/code/myapp \
  --kit docker.io/sbx/t3code-kit:latest \
  --kit ./sbx-kit/
sbx exec t3sandbox -- sh -lc 'command -v claude && command -v codex && command -v opencode && command -v t3'
```

In the T3 Code app, add an SSH environment for host `t3sandbox.sbx`, then add a project using the
workspace's host path (e.g. `/Users/you/code/myapp`). T3 Code forwards its port itself, so there's
no port publishing or pairing token.

- `claude` as the base agent can be swapped for `codex` or `opencode`.
- `--kit` only applies at creation. For an existing sandbox use `sbx kit add t3sandbox ./sbx-kit/`
  (it restarts the sandbox but keeps its state).
- `sbx-kit/` allows `registry.npmjs.org:443` for its `npm install`.
