#!/usr/bin/env bash
set -euo pipefail

# Defensive: t3 serve's own startup has been observed failing with ENOENT on
# this exact path (mkdir not recursive) when /home/agent starts out
# incompletely initialized — seen under sbx's erofs-based sandbox storage.
mkdir -p "$HOME/.t3/userdata/logs"

# T3_HOST/T3_PORT let `docker run -e` (or a kit's `environment.variables`)
# override the bind address/port without editing the image. Defaults match
# T3 Code's own defaults (0.0.0.0 so a published port is reachable, 3773 is
# T3 Code's standard port). No cwd argument is passed — under sbx this runs
# as a `setup.startup` command, not as the container's own entrypoint, so
# the real host-mounted workspace path isn't known here; add the project
# from the T3 Code app instead, the same as the plain-Docker path's
# `--auto-bootstrap-project-from-cwd` project just gets used as a fallback.
exec t3 serve \
    --host "${T3_HOST:-0.0.0.0}" \
    --port "${T3_PORT:-3773}" \
    --no-browser \
    --auto-bootstrap-project-from-cwd \
    "$@"
