#!/usr/bin/env bash
set -euo pipefail

# t3 serve's own mkdir isn't recursive; under sbx this may not exist yet.
mkdir -p "$HOME/.t3/userdata/logs"

# Since 0.0.45 `t3` is a Node launcher that doesn't pass signals on to the
# native server, so stopping it would leave the server running.
T3_CMD=t3
t3_pkg="$(dirname "$(dirname "$(readlink -f "$(command -v t3)")")")"
native="$(cd "$t3_pkg" && node -p 'require("path").join(require("path").dirname(require.resolve(
  "@t3code/t3-" + process.platform + "-" + process.arch + "/package.json")), "t3")' 2>/dev/null || true)"
if [[ -x "$native" ]]; then
  T3_CMD="$native"
fi

# 0.0.0.0 so a published port reaches the server. The plain-Docker image
# passes /workspace, which becomes the first project.
exec "$T3_CMD" serve \
    --host "${T3_HOST:-0.0.0.0}" \
    --port "${T3_PORT:-3773}" \
    --no-browser \
    --auto-bootstrap-project-from-cwd \
    "$@"
