#!/usr/bin/env bash
set -euo pipefail

# Used in usage/error messages instead of $0, so they read "sandbox.sh ..."
# even when invoked via a full or relative path.
SCRIPT_NAME="$(basename "$0")"

# Absolute path to this script's real directory (symlinks resolved), so
# T3_KIT below resolves correctly whether sandbox.sh is invoked directly,
# from another directory, or via a symlink like /usr/local/bin/sandbox.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Every setting below can be set in this config file (see
# config.example.conf) or as an environment variable. The environment wins.
CONFIG_FILE="$HOME/.config/t3-sandbox/config.conf"
CONFIG_VARS=(SBX_BIN SKILLS_DIR SKILLS_IMPORT BASE_PORT T3_BASE_PORT
  OPENCODE_IMAGE CLAUDE_IMAGE COPILOT_IMAGE T3_KIT NETWORK_ALLOW)

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Reads KEY=value lines from CONFIG_FILE. The file is parsed, never executed:
# blank lines and lines starting with # are skipped, one pair of surrounding
# quotes is stripped and a leading ~ expands to $HOME. Unknown keys are an
# error. Keys already set in the environment are left alone.
load_config() {
  local line key value var known lineno=0 from_env=" "
  for var in "${CONFIG_VARS[@]}"; do
    [[ -n "${!var+x}" ]] && from_env+="${var} "
  done

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="$(trim "${line%$'\r'}")"
    [[ -z "$line" || "$line" == "#"* ]] && continue

    if [[ "$line" != *=* ]]; then
      echo "ERROR: ${CONFIG_FILE}:${lineno}: expected KEY=value." >&2
      exit 1
    fi
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"

    known=0
    for var in "${CONFIG_VARS[@]}"; do
      [[ "$key" == "$var" ]] && known=1
    done
    if [[ "$known" -eq 0 ]]; then
      echo "ERROR: ${CONFIG_FILE}:${lineno}: unknown setting '${key}'." >&2
      exit 1
    fi

    if [[ ${#value} -ge 2 && ( ( "$value" == \"*\" ) || ( "$value" == \'*\' ) ) ]]; then
      value="${value:1:${#value}-2}"
    fi
    # shellcheck disable=SC2088 # matching a literal ~ on purpose
    if [[ "$value" == "~" || "$value" == "~/"* ]]; then
      value="${HOME}${value:1}"
    fi

    [[ "$from_env" == *" ${key} "* ]] && continue
    printf -v "$key" '%s' "$value"
  done < "$CONFIG_FILE"
}

if [[ -f "$CONFIG_FILE" ]]; then
  load_config
fi

# sbx binary. A bare name is looked up on PATH.
SBX_BIN="${SBX_BIN:-sbx}"

# Optional host folder (e.g. shared skills and AGENTS.md/CLAUDE.md files),
# mounted read-only into every new sandbox at its host path. Empty = no mount.
SKILLS_DIR="${SKILLS_DIR:-}"

# 1 = refresh sbx's skills store ('sbx skills import --force') before every
# create/start. Defaults to on when SKILLS_DIR is set, off otherwise.
if [[ -z "${SKILLS_IMPORT:-}" ]]; then
  if [[ -n "$SKILLS_DIR" ]]; then SKILLS_IMPORT=1; else SKILLS_IMPORT=0; fi
fi

# Auto-picked host ports for opencode start here. 8080 is left free since
# many dev servers default to it.
BASE_PORT="${BASE_PORT:-8081}"

# Auto-picked host ports for t3 start here (3773 is T3 Code's own
# port inside the sandbox, see entrypoint.sh).
T3_BASE_PORT="${T3_BASE_PORT:-3773}"

# Agent/template names passed to `sbx create` for opencode, claude and copilot.
OPENCODE_IMAGE="${OPENCODE_IMAGE:-opencode}"
CLAUDE_IMAGE="${CLAUDE_IMAGE:-claude}"
COPILOT_IMAGE="${COPILOT_IMAGE:-copilot}"

# Path to the kind:sandbox kit (see t3-kit/spec.yaml) that launches
# T3 Code's own server as the sandbox's agent process. Its `name:` field is
# "t3", passed as the AGENT positional to `sbx create`/`sbx run`.
T3_KIT="${T3_KIT:-$SCRIPT_DIR/t3-kit}"

# Optional comma-separated hosts allowed for every new sandbox
# ('sbx policy allow network --sandbox <name> ...'). Empty = no extra rules.
NETWORK_ALLOW="${NETWORK_ALLOW:-}"

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME create <project_name> <workspace_path> [host_port] [agent]
      New sandbox, foreground (Ctrl+C to stop). Port auto-picked from
      ${T3_BASE_PORT} (t3) or ${BASE_PORT} (opencode) if omitted.
      Mounts SKILLS_DIR read-only and allows NETWORK_ALLOW hosts if set.
      Refreshes the skills store if SKILLS_IMPORT=1.

  $SCRIPT_NAME start <project_name|sandbox_name> [host_port]
      Same, for an existing sandbox. Accepts the project name ('foo') or
      the full sandbox name ('t3-foo'). Agent inferred; port optional
      (opencode/t3 only) -- if sbx restored an earlier binding on
      restart, that port is reused. Refreshes the skills store if
      SKILLS_IMPORT=1.

  $SCRIPT_NAME reload <project_name|sandbox_name> [host_port] [agent]
      Refresh an already-running sandbox's skills: stops it (confirms
      first), refreshes the skills store, starts it back up. Agent
      inferred like start/rm.

  $SCRIPT_NAME upgrade <project_name|sandbox_name> [host_port]
      t3 only. Updates T3 Code inside the sandbox to the latest npm
      release (starts it first if stopped). If the version changed, the
      sandbox is restarted (confirms first) so the server runs the new
      version. Survives stop/start; a recreated sandbox starts at the
      image's version again.

  $SCRIPT_NAME ls [all]
      List managed sandboxes (t3-/claude-/copilot-/opencode- prefix). 'all'
      shows raw 'sbx ls'.

  $SCRIPT_NAME rm <project_name|sandbox_name> [agent]
      Remove a sandbox (confirms, then 'sbx rm --force'). Not undoable.
      Aliases: remove, delete.

  agent (optional, must be the LAST argument): t3, claude, copilot or opencode
      On create it picks the agent (default: t3). Elsewhere it's inferred
      from the existing sandbox and only needed when several agents share
      a project name.

      t3        Sandbox 't3-<project>'. T3 Code's server from the
                t3-kit/ kit, port auto-picked from ${T3_BASE_PORT}.
                Attaching shows its log with the pairing token; a 'Local
                URL' line with 127.0.0.1:<port> is added after T3 Code's
                Pairing URL.
      claude    Sandbox 'claude-<project>'. Interactive Claude Code via
                'sbx run'. No port.
      copilot   Sandbox 'copilot-<project>'. Interactive GitHub Copilot CLI
                via 'sbx run'. No port.
      opencode  Sandbox 'opencode-<project>'. 'opencode serve', port
                auto-picked from ${BASE_PORT}.

Examples:
  $SCRIPT_NAME create webapp ~/code/webapp [3773]
  $SCRIPT_NAME create myapp ~/code/myapp [8082] claude
  $SCRIPT_NAME create tools ~/code/tools copilot
  $SCRIPT_NAME create api ~/code/api opencode
  $SCRIPT_NAME start webapp [3774]
  $SCRIPT_NAME start claude-myapp
  $SCRIPT_NAME reload webapp
  $SCRIPT_NAME upgrade webapp
  $SCRIPT_NAME ls [all]
  $SCRIPT_NAME rm myapp [claude]

Note: the sandbox stops once the command returns, so the agent runs in
the foreground -- keep the terminal open.

Settings (SBX_BIN, SKILLS_DIR, SKILLS_IMPORT, BASE_PORT, T3_BASE_PORT,
OPENCODE_IMAGE, CLAUDE_IMAGE, COPILOT_IMAGE, T3_KIT, NETWORK_ALLOW) are read from
${CONFIG_FILE} or the environment.
EOF
  exit 1
}

require_cmd() {
  local cmd="$1" setting="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' not found. Install it and put it on PATH." >&2
    [[ -n "$setting" ]] && echo "Or set ${setting} in ${CONFIG_FILE}." >&2
    exit 1
  fi
}

sandbox_exists() {
  local name="$1" out
  # Note: `sbx ls | grep -q` is unsafe under `set -o pipefail` -- grep exits
  # on first match, sbx gets SIGPIPE (141), and pipefail turns that into a
  # false "not found". Capture the output first instead.
  # Exact match on the SANDBOX column: `grep -w` would also match prefixes
  # like 'claude-temp' against 'claude-temp-oai', since '-' is a word boundary.
  out="$("$SBX_BIN" ls 2>/dev/null || true)"
  awk -v n="$name" 'NR > 1 && $1 == n { found = 1 } END { exit !found }' <<<"$out"
}

# Best-effort free-port scan using bash's /dev/tcp. Only detects TCP
# listeners on 127.0.0.1; there's a small race window between check and use.
# Takes the starting port to scan from (BASE_PORT for opencode, T3_BASE_PORT
# for t3) since the two agents shouldn't collide on the same range.
find_free_port() {
  local port="$1"
  while (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; do
    exec 3>&- 3<&-
    port=$((port + 1))
  done
  echo "$port"
}

# Rejects a host_port that isn't a number, e.g. a mistyped agent name.
check_port() {
  if [[ -n "$1" && ! "$1" =~ ^[0-9]+$ ]]; then
    echo "ERROR: host_port '$1' is not a number (agents: t3, claude, copilot, opencode)." >&2
    exit 1
  fi
}

# Sets AGENT from whichever sandbox exists, unless an agent was passed
# explicitly. Errors out if more than one variant exists and none was chosen.
# Also accepts the full sandbox name (e.g. 't3-foo' for 'foo'): if that
# exact sandbox exists, PROJECT_NAME is stripped to 'foo' and AGENT is set
# from the prefix.
resolve_agent() {
  local project="$1" agent
  for agent in claude copilot opencode t3; do
    if [[ "$project" == "${agent}-"* ]] && sandbox_exists "$project"; then
      PROJECT_NAME="${project#"${agent}-"}"
      AGENT="$agent"
      AGENT_EXPLICIT=1
      return 0
    fi
  done
  [[ "$AGENT_EXPLICIT" -eq 1 ]] && return 0

  local found=()
  sandbox_exists "claude-${project}" && found+=("claude")
  sandbox_exists "copilot-${project}" && found+=("copilot")
  sandbox_exists "opencode-${project}" && found+=("opencode")
  sandbox_exists "t3-${project}" && found+=("t3")

  if [[ ${#found[@]} -gt 1 ]]; then
    echo "ERROR: multiple sandboxes exist for '${project}': ${found[*]}." >&2
    echo "Add one of those as the last argument to disambiguate." >&2
    exit 1
  elif [[ ${#found[@]} -eq 1 ]]; then
    AGENT="${found[0]}"
  fi
}

# Returns 0 only on a literal y/Y. Refuses to proceed with no TTY rather
# than silently treating a closed stdin as consent.
confirm() {
  local prompt="$1" reply
  if [[ ! -t 0 ]]; then
    echo "ERROR: no TTY for confirmation; refusing to proceed." >&2
    echo "Run this from an interactive terminal, or call '${SBX_BIN}' directly to script it." >&2
    exit 1
  fi
  read -r -p "${prompt} [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# Refreshes sbx's shared skills store from the host's per-agent skill dirs
# (~/.claude/skills, ~/.agents/skills, ...). A running sandbox won't see the
# update -- only its next start re-reads the store.
reload_skills_store() {
  "$SBX_BIN" skills import --force
}

# The automatic refresh before create/start, controlled by SKILLS_IMPORT.
# The explicit reload command always refreshes.
maybe_reload_skills_store() {
  if [[ "$SKILLS_IMPORT" == "1" ]]; then
    reload_skills_store
  fi
}

# Publishes sandbox_port on the host and sets PUBLISHED_PORT to the host port
# in use. sbx remembers a sandbox's published ports and restores them when it
# starts again, so an existing binding is reused instead of failing with
# "already published": a requested port that's already bound is kept as-is,
# and with no port requested, whatever sbx restored is reused. Only if
# nothing is bound yet is a free port picked, starting at base_port. Must run
# after the sandbox is started ('sbx ports' only sees running sandboxes).
publish_port() {
  local name="$1" requested="$2" sandbox_port="$3" base_port="$4" existing out
  require_cmd jq
  existing="$("$SBX_BIN" ports "$name" --json 2>/dev/null \
    | jq -r --arg p "$sandbox_port" \
        '.[] | select((.sandbox_port | tostring) == $p) | .host_port // empty' \
    || true)"

  if [[ -n "$requested" ]] && grep -qx -- "$requested" <<<"$existing"; then
    PUBLISHED_PORT="$requested"
    return 0
  elif [[ -z "$requested" && -n "$existing" ]]; then
    PUBLISHED_PORT="$(head -n 1 <<<"$existing")"
    return 0
  fi

  PUBLISHED_PORT="${requested:-$(find_free_port "$base_port")}"
  if ! out="$("$SBX_BIN" ports "$name" --publish "${PUBLISHED_PORT}:${sandbox_port}" 2>&1)"; then
    # Fallback in case the --json lookup above missed an existing binding.
    if ! grep -q "already published" <<<"$out"; then
      echo "$out" >&2
      exit 1
    fi
  fi
}

# Passes T3 Code's startup log through unchanged, adding a copyable
# 127.0.0.1 pairing URL after the "Pairing URL:" line -- t3 serve prints the
# sandbox's internal address, and only the host knows the published port.
# The token match stops at whitespace/control chars so trailing ANSI color
# codes aren't copied into the URL.
add_local_pairing_url() {
  local host_port="$1"
  awk -v port="$host_port" '
    { print; fflush() }
    /Pairing URL:/ && match($0, /#token=[^[:space:][:cntrl:]]+/) {
      print "Local URL:   http://127.0.0.1:" port "/pair" substr($0, RSTART, RLENGTH)
      fflush()
    }'
}

run_foreground() {
  local name="$1"
  local host_port="$2"
  local agent="$3"

  if [[ "$agent" == "claude" || "$agent" == "copilot" ]]; then
    local label="Claude Code"
    [[ "$agent" == "copilot" ]] && label="Copilot CLI"
    echo "${label} sandbox '${name}': interactive session (no web server)."
    echo "Running in the foreground. Ctrl+C or 'exit' to stop."
    echo

    # 'sbx exec' is non-interactive (no TTY), which makes Claude Code fall back
    # to --print mode and fail with no stdin. 'sbx run' is the interactive
    # attach path sbx itself suggests, and it starts a stopped sandbox.
    "$SBX_BIN" run "$name"
  elif [[ "$agent" == "t3" ]]; then
    # Unlike opencode, T3 Code's server isn't launched via a separate 'sbx
    # exec ... serve' call -- it's the sandbox's own agent process (the
    # kind:sandbox kit's `sandbox.entrypoint`). 'sbx exec ... true' starts
    # the sandbox so the port can be published first; 'sbx run' then
    # attaches to that process's live log, which is where the pairing
    # token gets printed on startup.
    "$SBX_BIN" exec "$name" true
    publish_port "$name" "$host_port" 3773 "$T3_BASE_PORT"

    echo "T3 Code sandbox '${name}': server published at http://127.0.0.1:${PUBLISHED_PORT}"
    echo "Use the 'Local URL' line below to pair -- the Pairing URL/QR show the"
    echo "sandbox's internal address."
    echo "Running in the foreground. Ctrl+C or 'exit' to stop."
    echo

    "$SBX_BIN" run --name "$name" | add_local_pairing_url "$PUBLISHED_PORT"
  else
    # 'sbx ports' doesn't start a stopped sandbox itself -- 'sbx exec' does
    # ("if the sandbox is stopped, it is started first"). Force it up first.
    "$SBX_BIN" exec "$name" true

    # Publish the port before the blocking exec, since we won't get another
    # chance once this call takes over the terminal.
    publish_port "$name" "$host_port" 8080 "$BASE_PORT"

    echo "OpenCode server '${name}': http://127.0.0.1:${PUBLISHED_PORT}"
    echo "Running in the foreground. Ctrl+C to stop."
    echo

    "$SBX_BIN" exec "$name" opencode serve --hostname 0.0.0.0 --port 8080
  fi
}

require_cmd "$SBX_BIN" SBX_BIN
[[ $# -lt 1 ]] && usage

CMD="$1"; shift

# Optional trailing agent argument (t3, claude, copilot, opencode); t3 is the
# default. Outside `create` it's only needed for disambiguation, see
# resolve_agent.
AGENT="t3"
AGENT_EXPLICIT=0
ARGS=("$@")
if [[ ${#ARGS[@]} -gt 0 ]]; then
  LAST="${ARGS[$((${#ARGS[@]} - 1))]}"
  if [[ "$LAST" == "t3" || "$LAST" == "claude" || "$LAST" == "copilot" || "$LAST" == "opencode" ]]; then
    AGENT="$LAST"
    AGENT_EXPLICIT=1
    unset 'ARGS[$((${#ARGS[@]} - 1))]'
  fi
fi
set -- ${ARGS[@]+"${ARGS[@]}"}

case "$CMD" in
  create)
    [[ $# -lt 2 ]] && usage
    PROJECT_NAME="$1"
    WORKSPACE="$2"
    NAME="${AGENT}-${PROJECT_NAME}"

    if [[ "$AGENT" == "claude" || "$AGENT" == "copilot" ]]; then
      HOST_PORT=""
      IMAGE="$CLAUDE_IMAGE"
      [[ "$AGENT" == "copilot" ]] && IMAGE="$COPILOT_IMAGE"
      [[ $# -ge 3 ]] && echo "NOTE: host_port '${3}' ignored in ${AGENT} mode." >&2
    else
      HOST_PORT="${3:-}"
      check_port "$HOST_PORT"
      IMAGE="$OPENCODE_IMAGE"
      [[ "$AGENT" == "t3" ]] && IMAGE=""
    fi

    if sandbox_exists "$NAME"; then
      SUFFIX=""; [[ "$AGENT" != "t3" ]] && SUFFIX=" ${AGENT}"
      echo "ERROR: sandbox '${NAME}' already exists. Use '$SCRIPT_NAME start ${PROJECT_NAME}${SUFFIX}' instead." >&2
      exit 1
    fi

    MOUNTS=()
    if [[ -n "$SKILLS_DIR" ]]; then
      if [[ ! -d "$SKILLS_DIR" ]]; then
        echo "ERROR: SKILLS_DIR '${SKILLS_DIR}' not found. Fix or unset it in ${CONFIG_FILE}." >&2
        exit 1
      fi
      MOUNTS+=("${SKILLS_DIR}:ro")
    fi

    if [[ "$AGENT" == "t3" ]]; then
      if [[ ! -d "$T3_KIT" ]]; then
        echo "ERROR: T3_KIT '${T3_KIT}' not found. Fix it in ${CONFIG_FILE}." >&2
        exit 1
      fi
      "$SBX_BIN" create --name "$NAME" --kit "$T3_KIT" t3 "$WORKSPACE" ${MOUNTS[@]+"${MOUNTS[@]}"}
    else
      "$SBX_BIN" create --name "$NAME" "$IMAGE" "$WORKSPACE" ${MOUNTS[@]+"${MOUNTS[@]}"}
    fi
    if [[ -n "$NETWORK_ALLOW" ]]; then
      "$SBX_BIN" policy allow network --sandbox "$NAME" "$NETWORK_ALLOW"
    fi
    maybe_reload_skills_store
    run_foreground "$NAME" "$HOST_PORT" "$AGENT"
    ;;

  start)
    [[ $# -lt 1 ]] && usage
    PROJECT_NAME="$1"
    resolve_agent "$PROJECT_NAME"
    NAME="${AGENT}-${PROJECT_NAME}"

    if [[ "$AGENT" == "claude" || "$AGENT" == "copilot" ]]; then
      HOST_PORT=""
      [[ $# -ge 2 ]] && echo "NOTE: host_port '${2}' ignored in ${AGENT} mode." >&2
    else
      HOST_PORT="${2:-}"
      check_port "$HOST_PORT"
    fi

    if ! sandbox_exists "$NAME"; then
      SUFFIX=""; [[ "$AGENT_EXPLICIT" -eq 1 ]] && SUFFIX=" ${AGENT}"
      echo "ERROR: sandbox '${NAME}' does not exist. Use '$SCRIPT_NAME create ${PROJECT_NAME} <workspace_path>${SUFFIX}' first." >&2
      exit 1
    fi

    maybe_reload_skills_store
    run_foreground "$NAME" "$HOST_PORT" "$AGENT"
    ;;

  reload)
    [[ $# -lt 1 ]] && usage
    PROJECT_NAME="$1"
    resolve_agent "$PROJECT_NAME"
    NAME="${AGENT}-${PROJECT_NAME}"

    if [[ "$AGENT" == "claude" || "$AGENT" == "copilot" ]]; then
      HOST_PORT=""
      [[ $# -ge 2 ]] && echo "NOTE: host_port '${2}' ignored in ${AGENT} mode." >&2
    else
      HOST_PORT="${2:-}"
      check_port "$HOST_PORT"
    fi

    if ! sandbox_exists "$NAME"; then
      SUFFIX=""; [[ "$AGENT_EXPLICIT" -eq 1 ]] && SUFFIX=" ${AGENT}"
      echo "ERROR: sandbox '${NAME}' does not exist. Use '$SCRIPT_NAME create ${PROJECT_NAME} <workspace_path>${SUFFIX}' first." >&2
      exit 1
    fi

    echo "This stops '${NAME}' to refresh its skills, then starts it back up."
    if confirm "Stop '${NAME}' and reload skills?"; then
      "$SBX_BIN" stop "$NAME"
      reload_skills_store
      run_foreground "$NAME" "$HOST_PORT" "$AGENT"
    else
      echo "Aborted; nothing was reloaded."
      exit 1
    fi
    ;;

  upgrade)
    [[ $# -lt 1 ]] && usage
    PROJECT_NAME="$1"
    HOST_PORT="${2:-}"
    check_port "$HOST_PORT"
    AGENT="t3"
    AGENT_EXPLICIT=1
    resolve_agent "$PROJECT_NAME"
    NAME="${AGENT}-${PROJECT_NAME}"

    if [[ "$AGENT" != "t3" ]]; then
      echo "ERROR: upgrade only supports t3 sandboxes, not '${NAME}'." >&2
      exit 1
    fi
    if ! sandbox_exists "$NAME"; then
      echo "ERROR: sandbox '${NAME}' does not exist. Run '$SCRIPT_NAME ls' to see what does." >&2
      exit 1
    fi

    # npm's global prefix in the image is owned by the agent user, so no
    # sudo is needed. The running server keeps the old version loaded until
    # its process restarts, hence the stop/start below.
    OLD_VERSION="$("$SBX_BIN" exec "$NAME" t3 --version)"
    "$SBX_BIN" exec "$NAME" npm install -g t3@latest --no-fund --no-audit
    NEW_VERSION="$("$SBX_BIN" exec "$NAME" t3 --version)"

    if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
      echo "T3 Code in '${NAME}' is already up to date (${NEW_VERSION})."
      exit 0
    fi

    echo "T3 Code in '${NAME}' upgraded: ${OLD_VERSION} -> ${NEW_VERSION}."
    if confirm "Restart '${NAME}' so the server runs ${NEW_VERSION}?"; then
      "$SBX_BIN" stop "$NAME"
      run_foreground "$NAME" "$HOST_PORT" "$AGENT"
    else
      echo "Not restarted; the new version is used on the next '$SCRIPT_NAME start ${PROJECT_NAME}'."
    fi
    ;;

  ls|list)
    OUT="$("$SBX_BIN" ls 2>/dev/null || true)"

    if [[ "${1:-}" == "all" ]]; then
      echo "$OUT"
      exit 0
    fi

    # Keep the header line (if any) plus rows for sandboxes this script
    # manages. The exact `sbx ls` column layout isn't parsed -- lines are
    # matched on the name prefix only, so extra columns pass through as-is.
    FILTERED="$(grep -E '(^|[[:space:]])(opencode|claude|copilot|t3)-' <<<"$OUT" || true)"

    if [[ -z "${FILTERED//[[:space:]]/}" ]]; then
      echo "No sandboxes managed by this script."
      echo "Run '$SCRIPT_NAME ls all' to see every sandbox."
      exit 0
    fi

    HEADER="$(head -n 1 <<<"$OUT")"
    if ! grep -Eq '(^|[[:space:]])(opencode|claude|copilot|t3)-' <<<"$HEADER"; then
      echo "$HEADER"
    fi
    echo "$FILTERED"
    ;;

  rm|remove|delete)
    [[ $# -lt 1 ]] && usage
    PROJECT_NAME="$1"
    resolve_agent "$PROJECT_NAME"
    NAME="${AGENT}-${PROJECT_NAME}"

    if ! sandbox_exists "$NAME"; then
      echo "ERROR: sandbox '${NAME}' does not exist. Run '$SCRIPT_NAME ls' to see what does." >&2
      exit 1
    fi

    echo "This stops '${NAME}', removes its container, cleans up any Git"
    echo "worktrees, and deletes its state. It cannot be undone."
    if confirm "Remove sandbox '${NAME}'?"; then
      # --force because we've already taken the confirmation ourselves;
      # without it sbx would prompt a second time.
      "$SBX_BIN" rm --force "$NAME"
      echo "Removed '${NAME}'."
    else
      echo "Aborted; nothing was removed."
      exit 1
    fi
    ;;

  *)
    usage
    ;;
esac
