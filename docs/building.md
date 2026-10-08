# Building the images

| Command | Builds | For |
| --- | --- | --- |
| `make sandbox` | `t3-sandbox-sbx` from `Dockerfile.sbx`, loaded into sbx | `sandbox.sh`, [sbx directly](sbx.md) |
| `make docker` | `t3-sandbox` from `Dockerfile` | [plain Docker](plain-docker.md) |
| `make all` | both | |

`make sandbox` removes its temporary tarball and the image's Docker copy once sbx has it.

Existing sandboxes keep the image they were created with. Recreate one to use a new build. Its
provider CLIs are kept up to date by the update check on `start` either way.

Builds use Docker's cache. For a fully fresh build: `make sandbox BUILD_FLAGS=--no-cache`.

## Manually

```bash
docker build -f Dockerfile.sbx -t t3-sandbox-sbx .
docker image save t3-sandbox-sbx -o t3-sandbox-sbx.tar
sbx template load t3-sandbox-sbx.tar
rm t3-sandbox-sbx.tar

docker build -t t3-sandbox .
```
