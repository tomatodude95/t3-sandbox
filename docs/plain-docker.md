# Plain Docker

Runs the same tools with ordinary `docker build`/`docker run`, without sbx. The image is
`t3-code-sandbox`, built from `Dockerfile`, and works on arm64 and amd64.

## Build and run

```bash
docker build -t t3-code-sandbox .
docker run -d --name t3code -p 127.0.0.1:3773:3773 -v ~/code/myapp:/workspace t3-code-sandbox
```

- `/workspace` is your project. On first boot T3 Code creates a project for it.
- `-p 127.0.0.1:3773:3773` keeps the server local. Plain `-p 3773:3773` exposes it to your
  network (see [security.md](security.md)).
- `-e T3_HOST=… -e T3_PORT=…` change the bind address/port inside the container.

## Provider login (once per container)

```bash
docker exec -it t3code claude auth login
docker exec -it t3code codex login
docker exec -it t3code opencode auth login
```

## Pairing

`docker logs t3code` shows a `Pairing URL` with the container's internal IP. Swap the host for the
one you published and keep the token: `http://127.0.0.1:3773/pair#token=…`. The QR code also
encodes the internal IP. Tokens are one-time; get a new one with `docker exec -it t3code t3 pair`.

## Persistence

`/home/agent` (provider logins, T3 Code state) is an anonymous volume. It survives
`docker stop`/`start`/`restart` and is deleted with the container (`docker rm`, or a `--rm`
container stopping). With `docker rm -f`, add `-v` (`docker rm -fv`) to reliably delete it too.

To keep it beyond the container, use a named volume: `-v t3code-home:/home/agent`. Don't share one
named volume between containers that run at the same time. T3 Code keeps its state in a single
SQLite file.

## Multiple instances

Give each container its own name, host port and workspace. Leave `/home/agent` anonymous:

```bash
docker run -d --name t3code-a -p 127.0.0.1:3773:3773 -v ~/code/a:/workspace t3-code-sandbox
docker run -d --name t3code-b -p 127.0.0.1:3774:3773 -v ~/code/b:/workspace t3-code-sandbox
```
