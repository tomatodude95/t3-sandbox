#!/usr/bin/env bash
set -euo pipefail

# t3 serve fails with ENOENT if this directory is missing (its own mkdir
# isn't recursive), which has been seen when /home/agent starts out
# incompletely initialized under sbx.
mkdir -p "$HOME/.t3/userdata/logs"

# Since 0.0.45 the npm package's `t3` is a Node launcher that runs the
# native server binary as a child and doesn't pass signals on: stopping the
# launcher leaves the server running, holding the sandbox and its port. Run
# the binary directly when it's there.
T3_CMD=t3
t3_pkg="$(dirname "$(dirname "$(readlink -f "$(command -v t3)")")")"
native="$(cd "$t3_pkg" && node -p 'require("path").join(require("path").dirname(require.resolve(
  "@t3code/t3-" + process.platform + "-" + process.arch + "/package.json")), "t3")' 2>/dev/null || true)"
if [[ -x "$native" ]]; then
  T3_CMD="$native"
fi

# T3_HOST/T3_PORT override the bind address/port (`docker run -e`, or a kit's
# environment variables). 0.0.0.0 is needed so a published port can reach the
# server; 3773 is T3 Code's standard port.
#
# Arguments are passed through to t3 serve: the plain-Docker image passes
# /workspace (its CMD), which --auto-bootstrap-project-from-cwd turns into a
# project on first boot. Under sbx no path is passed; add the project from the
# T3 Code app instead.
exec "$T3_CMD" serve \
    --host "${T3_HOST:-0.0.0.0}" \
    --port "${T3_PORT:-3773}" \
    --no-browser \
    --auto-bootstrap-project-from-cwd \
    "$@"
