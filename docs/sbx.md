# Using sbx directly

What `sandbox.sh` does, by hand. Needs the image from `make sandbox`.

```bash
sbx create --name t3-myapp --kit ./t3-kit/ t3 ~/code/myapp
sbx exec t3-myapp true                           # start it
sbx ports t3-myapp --publish 3773:3773           # publish T3 Code's port on 127.0.0.1
sbx run --name t3-myapp                          # start T3 Code and show its log
sbx rm t3-myapp                                  # delete the sandbox
```

**Pairing:** take the `Pairing URL` line from the log and swap its host for `127.0.0.1:3773`,
keeping the token. Tokens are one-time and expire after 5 minutes; get a new one with
`sbx exec t3-myapp t3 pair`. Then add the project in the app. The workspace is mounted at its
host path (e.g. `/Users/you/code/myapp`).

**Provider login:** see [providers.md](providers.md), e.g. `sbx exec -it t3-myapp claude auth login`.
