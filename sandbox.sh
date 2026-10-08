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
  OPENCODE_IMAGE CLAUDE_IMAGE CODEX_IMAGE COPILOT_IMAGE T3_KIT NETWORK_ALLOW
  UPDATE_CHECK)

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

# Agent/template names passed to `sbx create` for the non-t3 agents.
OPENCODE_IMAGE="${OPENCODE_IMAGE:-opencode}"
CLAUDE_IMAGE="${CLAUDE_IMAGE:-claude}"
CODEX_IMAGE="${CODEX_IMAGE:-codex}"
COPILOT_IMAGE="${COPILOT_IMAGE:-copilot}"

# Path to the kind:sandbox kit (see t3-kit/spec.yaml) that launches
# T3 Code's own server as the sandbox's agent process. Its `name:` field is
# "t3", passed as the AGENT positional to `sbx create`/`sbx run`.
T3_KIT="${T3_KIT:-$SCRIPT_DIR/t3-kit}"

# Optional comma-separated hosts allowed for every new sandbox
# ('sbx policy allow network --sandbox <name> ...'). Empty = no extra rules.
NETWORK_ALLOW="${NETWORK_ALLOW:-}"

# 1 = check for provider updates on create/start/reload and offer to install
# them, 0 = don't.
UPDATE_CHECK="${UPDATE_CHECK:-1}"

# Prints the help. Exits 0 when asked for (help/-h/--help), 1 otherwise.
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <command> [arguments]

Commands:
  create <project> <dir> [port] [agent]  Create a sandbox for <dir>, start it
  start <project> [port]                 Start an existing sandbox
  login <project> [provider]             Log in to a provider (see below)
  upgrade-providers <project>            t3 only; T3 Code itself needs a restart
  reload <project> [port]                Restart to pick up refreshed skills
  ls [all]                               List sandboxes ('all': all of sbx)
  rm <project>                           Remove a sandbox (asks first)

Agents (default t3; other commands only need one to tell sandboxes apart):
  t3        T3 Code server, port from ${T3_BASE_PORT}
  claude    Claude Code, interactive
  codex     Codex CLI, interactive
  copilot   GitHub Copilot CLI, interactive
  opencode  OpenCode server, port from ${BASE_PORT}

Providers for login: claude, codex, opencode, copilot, all

<project> is your name ('myapp') or the sandbox's ('t3-myapp').
Commands run in the foreground; the sandbox stops when they exit.

Examples:
  $SCRIPT_NAME create myapp ~/code/myapp
  $SCRIPT_NAME create api ~/code/api claude
  $SCRIPT_NAME login myapp codex

Settings: ~/.config/t3-sandbox/config.conf. Details: docs/sandbox.md
EOF
  exit "${1:-1}"
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

# True if 'sbx ls --json' reports the sandbox as running.
sandbox_running() {
  require_cmd jq
  "$SBX_BIN" ls --json 2>/dev/null \
    | jq -e --arg n "$1" '.sandboxes[] | select(.name == $n) | .status == "running"' >/dev/null
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
    echo "ERROR: host_port '$1' is not a number (agents: t3, claude, codex, copilot, opencode)." >&2
    exit 1
  fi
}

# Sets AGENT from whichever sandbox exists, unless an agent was passed
# explicitly. Errors out if more than one variant exists and none was chosen.
# Also accepts the full sandbox name (e.g. 't3-foo' for 'foo'): if that
# exact sandbox exists, PROJECT_NAME is stripped to 'foo' and AGENT is set
# from the prefix. A trailing agent argument that contradicts the prefix is
# an error, unless it names a sandbox of its own ('start claude-x t3' with
# 't3-claude-x' existing).
resolve_agent() {
  local project="$1" agent
  for agent in claude codex copilot opencode t3; do
    if [[ "$project" == "${agent}-"* ]] && sandbox_exists "$project"; then
      if [[ -n "$AGENT_ARG" && "$AGENT_ARG" != "$agent" ]]; then
        sandbox_exists "${AGENT_ARG}-${project}" && break
        echo "ERROR: '${project}' is a ${agent} sandbox. Drop '${AGENT_ARG}' or use '${AGENT_ARG}-${project#"${agent}-"}'." >&2
        exit 1
      fi
      PROJECT_NAME="${project#"${agent}-"}"
      AGENT="$agent"
      AGENT_EXPLICIT=1
      return 0
    fi
  done
  [[ "$AGENT_EXPLICIT" -eq 1 ]] && return 0

  local found=()
  sandbox_exists "claude-${project}" && found+=("claude")
  sandbox_exists "codex-${project}" && found+=("codex")
  sandbox_exists "copilot-${project}" && found+=("copilot")
  sandbox_exists "opencode-${project}" && found+=("opencode")
  sandbox_exists "t3-${project}" && found+=("t3")

  if [[ ${#found[@]} -gt 1 ]]; then
    echo "ERROR: multiple sandboxes exist for '${project}': ${found[*]}." >&2
    if [[ "$CMD" == "login" ]]; then
      echo "Use the full sandbox name, e.g. '${found[0]}-${project}'." >&2
    else
      echo "Add one of those as the last argument to disambiguate." >&2
    fi
    exit 1
  elif [[ ${#found[@]} -eq 1 ]]; then
    AGENT="${found[0]}"
  fi
}

# Exits unless stdin is a terminal (needed for interactive prompts/logins).
require_tty() {
  if [[ ! -t 0 ]]; then
    echo "ERROR: $1 needs an interactive terminal." >&2
    exit 1
  fi
}

# Fetches a URL from inside the sandbox without following redirects and
# prints "<status> <redirect target>". Uses curl if the sandbox has it,
# Node's fetch otherwise (always there).
sandbox_fetch() {
  # shellcheck disable=SC2016 # $1 is expanded by the sandbox's sh
  "$SBX_BIN" exec "$1" sh -c '
    if command -v curl >/dev/null 2>&1; then
      curl -s -o /dev/null -w "%{http_code} %{redirect_url}" "$1"
    else
      node -e "fetch(process.argv[1], { redirect: \"manual\" }).then(r => process.stdout.write(
        r.status + \" \" + new URL(r.headers.get(\"location\") || \"\", process.argv[1]).href))" "$1"
    fi' sh "$2" 2>/dev/null || true
}

# Codex's browser login ends on a callback to http://localhost:1455 inside
# the sandbox, which the host's browser can't reach. So: run `codex login` in
# the background, show its sign-in URL, let the user paste the callback URL
# their browser failed to load, and replay that URL inside the sandbox.
# A wrong or stale URL is rejected by Codex (HTTP 400) and can be retried.
# After a successful sign-in Codex redirects to its own /success page and
# only exits once that page is requested, so the script follows it.
codex_login() {
  local name="$1" out pid url callback status location rc
  out="$(mktemp "${TMPDIR:-/tmp}/sandbox-codex.XXXXXX")"
  "$SBX_BIN" exec "$name" codex login </dev/null >"$out" 2>&1 &
  pid=$!
  # On Ctrl+C, also stop the login server inside the sandbox via its /cancel
  # endpoint (stopping the local sbx client may leave it running).
  # shellcheck disable=SC2064 # expand now: name/pid/out are locals
  trap "sandbox_fetch '$name' http://127.0.0.1:1455/cancel >/dev/null; kill $pid 2>/dev/null || true; rm -f '$out'; exit 130" INT TERM

  url=""
  for _ in $(seq 1 60); do
    url="$(grep -o 'https://auth\.openai\.com/oauth/authorize[^[:space:]]*' "$out" | head -n 1 || true)"
    [[ -n "$url" ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if [[ -z "$url" ]]; then
    echo "ERROR: codex login didn't print a sign-in URL:" >&2
    cat "$out" >&2
    kill "$pid" 2>/dev/null || true
    rm -f "$out"
    trap - INT TERM
    return 1
  fi

  echo "1. Open this URL in your browser and sign in:"
  echo
  echo "   $url"
  echo
  echo "2. Your browser then fails to load a page on localhost:1455. That's expected."
  echo "   Copy the full URL from its address bar and paste it here."
  echo
  while true; do
    read -r -p "Callback URL: " callback
    callback="$(trim "$callback")"
    callback="${callback#\"}"; callback="${callback%\"}"
    if [[ ! "$callback" =~ ^http://(localhost|127\.0\.0\.1):1455/auth/callback\?.*code= ]]; then
      echo "That isn't the localhost:1455/auth/callback URL. Try again (Ctrl+C to cancel)."
      continue
    fi
    read -r status location <<<"$(sandbox_fetch "$name" "$callback")"
    if [[ "$status" == "400" ]]; then
      echo "Codex rejected that URL (from an older attempt?). Paste the one from this sign-in."
      continue
    fi
    if [[ "$status" == 3* && "$location" =~ ^http://(localhost|127\.0\.0\.1):1455/ ]]; then
      sandbox_fetch "$name" "$location" >/dev/null
    fi
    break
  done

  if wait "$pid"; then rc=0; else rc=$?; fi
  [[ "$rc" -ne 0 ]] && grep -i 'error' "$out" | tail -n 2 >&2
  rm -f "$out"
  trap - INT TERM
  return "$rc"
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

# Runs inside a sandbox (sh). 'check' prints "<cli> <installed> <latest>" for
# each provider CLI with a newer npm release, or OFFLINE if the npm registry
# doesn't answer within 2s. An npm package whose CLI isn't on PATH (left by an
# interrupted npm install) shows as "<cli> missing <latest>". 'update <cli>...' updates those CLIs: npm installs
# via npm, the rest (sbx's claude and copilot templates use native installs)
# via their own updater. The npm registry has every CLI's latest version,
# native ones included.
# shellcheck disable=SC2016 # expanded by the sandbox's sh
PROVIDERS_SH='
pkg() {
  case "$1" in
    t3) echo t3 ;;
    claude) echo @anthropic-ai/claude-code ;;
    codex) echo @openai/codex ;;
    opencode) echo opencode-ai ;;
    copilot) echo @github/copilot ;;
  esac
}
check() {
  if ! command -v "$1" >/dev/null 2>&1; then
    if [ -d "$(npm root -g)/$(pkg "$1")" ]; then
      new="$(npm view "$(pkg "$1")" version 2>/dev/null)"
      [ -n "$new" ] && echo "$1 missing $new"
    fi
    return 0
  fi
  cur="$("$1" --version 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -n 1)"
  new="$(npm view "$(pkg "$1")" version 2>/dev/null)"
  [ -n "$cur" ] && [ -n "$new" ] && [ "$cur" != "$new" ] || return 0
  [ "$(printf "%s\n%s\n" "$cur" "$new" | sort -V | tail -n 1)" = "$new" ] && echo "$1 $cur $new"
}
CLIS="t3 claude codex opencode copilot"
case "$1" in
  check)
    if ! curl -sf -m 2 -o /dev/null https://registry.npmjs.org/-/ping; then
      echo OFFLINE
      exit 0
    fi
    dir="$(mktemp -d)"
    for cli in $CLIS; do check "$cli" >"$dir/$cli" & done
    wait
    for cli in $CLIS; do cat "$dir/$cli"; done
    rm -rf "$dir"
    ;;
  update)
    shift
    root="$(npm root -g)"
    pkgs=""
    rc=0
    for cli in "$@"; do
      bin="$(command -v "$cli")" && bin="$(readlink -f "$bin")"
      case "$bin" in
        ""|"$root"/*)
          p="$(pkg "$cli")"
          # An interrupted npm install leaves the old copy npm set aside
          # (.<name>-<8 chars>), and the next install fails with ENOTEMPTY.
          rm -rf "$root/$(dirname "$p")/.$(basename "$p")-"???????? \
            "$(npm prefix -g)/bin/.$cli-"????????
          pkgs="$pkgs $p@latest"
          ;;
        *) "$cli" update || rc=1 ;;
      esac
    done
    if [ -n "$pkgs" ]; then
      npm install -g $pkgs --no-fund --no-audit || rc=1
    fi
    exit "$rc"
    ;;
esac'

# Sets UPDATES to the outdated provider CLIs in sandbox $1 ("<cli> <installed>
# <latest>" lines, empty if none). Starts the sandbox if it's stopped.
# Returns 1 if the npm registry can't be reached.
check_provider_updates() {
  UPDATES="$("$SBX_BIN" exec "$1" sh -c "$PROVIDERS_SH" sh check 2>/dev/null || true)"
  [[ "$UPDATES" != "OFFLINE" ]]
}

print_provider_updates() {
  local cli cur new
  while read -r cli cur new; do
    printf '  %-9s %s -> %s\n' "$cli" "$cur" "$new"
  done <<<"$UPDATES"
}

# Updates every CLI listed in UPDATES inside sandbox $1.
install_provider_updates() {
  local clis
  clis="$(awk '{ printf "%s ", $1 }' <<<"$UPDATES")"
  # shellcheck disable=SC2086 # one word per CLI
  "$SBX_BIN" exec "$1" sh -c "$PROVIDERS_SH" sh update $clis
}

# The check on create/start/reload, controlled by UPDATE_CHECK. Skipped
# without a terminal. Its 'sbx exec' starts a stopped sandbox without the
# agent; 'sbx run --detached' would launch the agent too, and the later
# 'sbx run' would then start a second T3 Code server next to it. Leaves the sandbox stopped if T3 Code itself was
# updated, so the caller's start runs the new version.
maybe_update_providers() {
  local name="$1"
  [[ "$UPDATE_CHECK" == "1" && -t 0 ]] || return 0
  echo "Checking for provider updates..."
  if ! check_provider_updates "$name"; then
    echo "Can't reach registry.npmjs.org, skipping the update check."
    return 0
  fi
  [[ -z "$UPDATES" ]] && return 0

  echo "Updates available:"
  print_provider_updates
  confirm "Update all?" || return 0
  if ! install_provider_updates "$name"; then
    echo "WARNING: some updates failed, starting anyway." >&2
  elif grep -q '^t3 ' <<<"$UPDATES"; then
    echo "Restarting '${name}' to run the new T3 Code."
    "$SBX_BIN" stop "$name"
  fi
  echo
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

# Prints "<command> (PID <pid>)" for each process besides sbx listening on
# host port $1. Empty if there are none or lsof isn't installed.
port_users() {
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP +c 0 -iTCP:"$1" -sTCP:LISTEN -Fpc 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2) }
    /^c/ {
      c = substr($0, 2); gsub(/\\x20/, " ", c)
      if (c != "sbx" && c !~ /^com\.docker/) print c " (PID " pid ")"
    }' || true
}

# sbx re-publishes a sandbox's remembered port on start, even if another
# program took it while the sandbox was stopped (e.g. the T3 Code desktop
# app, which also picks ports from 3773 up). Connections may then reach
# that program instead. Warns, and offers to move the sandbox to a free
# port. Updates PUBLISHED_PORT.
check_port_conflict() {
  local name="$1" sandbox_port="$2" base_port="$3" users new
  users="$(port_users "$PUBLISHED_PORT")"
  [[ -z "$users" ]] && return 0
  echo "WARNING: port ${PUBLISHED_PORT} is also used by ${users//$'\n'/, }."
  [[ -t 0 ]] || return 0
  new="$(find_free_port "$base_port")"
  if confirm "Move '${name}' to port ${new}? Clients have to reconnect."; then
    "$SBX_BIN" ports "$name" --unpublish "${PUBLISHED_PORT}:${sandbox_port}" >/dev/null
    "$SBX_BIN" ports "$name" --publish "${new}:${sandbox_port}" >/dev/null
    PUBLISHED_PORT="$new"
    echo "Moved to ${new}. Connect again with the new port."
  fi
  echo
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

  maybe_update_providers "$name"

  if [[ "$agent" == "claude"|| "$agent" == "codex" || "$agent" == "copilot" ]]; then
    local label="Claude Code"
    [[ "$agent" == "codex" ]] && label="Codex CLI"
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
    check_port_conflict "$name" 3773 "$T3_BASE_PORT"

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
    check_port_conflict "$name" 8080 "$BASE_PORT"

    echo "OpenCode server '${name}': http://127.0.0.1:${PUBLISHED_PORT}"
    echo "Running in the foreground. Ctrl+C to stop."
    echo

    "$SBX_BIN" exec "$name" opencode serve --hostname 0.0.0.0 --port 8080
  fi
}

[[ $# -lt 1 ]] && usage
case "$1" in help|-h|--help) usage 0 ;; esac
require_cmd "$SBX_BIN" SBX_BIN

CMD="$1"; shift

# Optional trailing agent argument (t3, claude, codex, copilot, opencode); t3 is the
# default. Outside `create` it's only needed for disambiguation, see
# resolve_agent. Not parsed for `login`, whose last argument is a provider
# (`login myapp claude` means Claude's login in the t3 sandbox).
AGENT="t3"
AGENT_EXPLICIT=0
AGENT_ARG=""
ARGS=("$@")
if [[ "$CMD" != "login" && ${#ARGS[@]} -gt 0 ]]; then
  LAST="${ARGS[$((${#ARGS[@]} - 1))]}"
  case "$LAST" in t3|claude|codex|copilot|opencode) IS_AGENT=1 ;; *) IS_AGENT=0 ;; esac
  if [[ "$IS_AGENT" -eq 1 ]]; then
    AGENT="$LAST"
    AGENT_ARG="$LAST"
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

    if [[ "$AGENT" == "claude" || "$AGENT" == "codex" || "$AGENT" == "copilot" ]]; then
      HOST_PORT=""
      IMAGE="$CLAUDE_IMAGE"
      [[ "$AGENT" == "codex" ]] && IMAGE="$CODEX_IMAGE"
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

    if [[ "$AGENT" == "claude" || "$AGENT" == "codex" || "$AGENT" == "copilot" ]]; then
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

    if [[ "$AGENT" == "claude" || "$AGENT" == "codex" || "$AGENT" == "copilot" ]]; then
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

  upgrade-providers)
    [[ $# -lt 1 ]] && usage
    PROJECT_NAME="$1"
    AGENT="t3"
    AGENT_EXPLICIT=1
    resolve_agent "$PROJECT_NAME"
    NAME="${AGENT}-${PROJECT_NAME}"

    if [[ "$AGENT" != "t3" ]]; then
      echo "ERROR: upgrade-providers only supports t3 sandboxes, not '${NAME}'." >&2
      echo "Other sandboxes check for updates on '$SCRIPT_NAME start'." >&2
      exit 1
    fi
    if ! sandbox_exists "$NAME"; then
      echo "ERROR: sandbox '${NAME}' does not exist. Run '$SCRIPT_NAME ls' to see what does." >&2
      exit 1
    fi

    # T3 Code starts the provider CLIs from PATH for each new session, so
    # updated ones are used right away. T3 Code itself keeps running the old
    # version until the sandbox restarts. A stopped sandbox is started for
    # the update (with 'sbx run --detached', which also launches T3 Code)
    # and stopped again.
    STARTED=0
    if ! sandbox_running "$NAME"; then
      echo "'${NAME}' isn't running. Starting it for the update; it stops again after."
      "$SBX_BIN" run --name "$NAME" --detached >/dev/null
      STARTED=1
    fi

    RC=0
    if ! check_provider_updates "$NAME"; then
      echo "ERROR: '${NAME}' can't reach registry.npmjs.org." >&2
      RC=1
    elif [[ -z "$UPDATES" ]]; then
      echo "All providers in '${NAME}' are up to date."
    else
      echo "Updating:"
      print_provider_updates
      if install_provider_updates "$NAME"; then
        echo
        echo "Done."
        if [[ "$STARTED" -eq 0 ]]; then
          echo "New sessions use the updated providers."
          if grep -q '^t3 ' <<<"$UPDATES"; then
            echo "T3 Code runs the new version after a restart (stop, then '$SCRIPT_NAME start ${PROJECT_NAME}')."
          fi
        fi
      else
        echo "ERROR: the update failed, see the output above." >&2
        RC=1
      fi
    fi

    if [[ "$STARTED" -eq 1 ]]; then
      "$SBX_BIN" stop "$NAME" >/dev/null
    fi
    exit "$RC"
    ;;

  login)
    [[ $# -lt 1 ]] && usage
    PROJECT_NAME="$1"
    PROVIDER="${2:-}"
    resolve_agent "$PROJECT_NAME"
    NAME="${AGENT}-${PROJECT_NAME}"

    if ! sandbox_exists "$NAME"; then
      echo "ERROR: sandbox '${NAME}' does not exist. Run '$SCRIPT_NAME ls' to see what does." >&2
      exit 1
    fi

    case "$PROVIDER" in
      ""|claude|codex|opencode|copilot|all) ;;
      *)
        echo "ERROR: unknown provider '${PROVIDER}' (claude, codex, opencode, copilot, all)." >&2
        exit 1
        ;;
    esac

    # A t3 sandbox has several providers, so one must be picked ('all' logs
    # in to each in turn). Other sandboxes only have their own agent, so any
    # other choice is redirected to it.
    if [[ "$AGENT" == "t3" ]]; then
      if [[ -z "$PROVIDER" ]]; then
        echo "Pick a provider to log in to in '${NAME}': claude, codex, opencode, copilot or all." >&2
        echo "Example: $SCRIPT_NAME login ${PROJECT_NAME} claude" >&2
        exit 1
      elif [[ "$PROVIDER" == "all" ]]; then
        PROVIDERS=(claude codex opencode copilot)
      else
        PROVIDERS=("$PROVIDER")
      fi
    else
      if [[ -n "$PROVIDER" && "$PROVIDER" != "$AGENT" ]]; then
        echo "NOTE: '${NAME}' only has ${AGENT}, so '${PROVIDER}' logs in to ${AGENT} instead."
        echo "      Next time: $SCRIPT_NAME login ${NAME}"
      fi
      PROVIDERS=("$AGENT")
    fi
    require_tty "login"

    # Sandboxes created before a CLI was added to the image don't have it.
    FAILED=()
    DONE=()
    for P in "${PROVIDERS[@]}"; do
      if ! "$SBX_BIN" exec "$NAME" sh -c "command -v $P" >/dev/null 2>&1; then
        echo "== ${P} isn't installed in '${NAME}', skipped."
        echo
        [[ "$PROVIDER" != "all" ]] && FAILED+=("$P")
        continue
      fi
      # With several providers ('all'), each one can be skipped.
      if [[ ${#PROVIDERS[@]} -gt 1 ]]; then
        read -r -p "Log in to ${P}? [Y/n] " ANSWER
        if [[ "$ANSWER" == [nN]* ]]; then
          echo
          continue
        fi
      fi
      case "$P" in
        claude) LOGIN_CMD=(claude auth login) ;;
        codex) LOGIN_CMD=(codex login) ;;  # run by codex_login, see there
        opencode) LOGIN_CMD=(opencode auth login) ;;
        copilot) LOGIN_CMD=(copilot login) ;;
      esac
      echo "== ${P} in '${NAME}': ${LOGIN_CMD[*]}"
      if [[ "$P" == "codex" ]]; then
        if codex_login "$NAME"; then DONE+=("$P"); else FAILED+=("$P"); fi
      elif "$SBX_BIN" exec -it "$NAME" "${LOGIN_CMD[@]}"; then
        DONE+=("$P")
      else
        FAILED+=("$P")
      fi
      echo
    done

    if [[ ${#FAILED[@]} -gt 0 ]]; then
      echo "ERROR: login failed for: ${FAILED[*]}." >&2
      exit 1
    fi
    echo "Logged in: ${DONE[*]:-none}."
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
    FILTERED="$(grep -E '(^|[[:space:]])(opencode|claude|codex|copilot|t3)-' <<<"$OUT" || true)"

    if [[ -z "${FILTERED//[[:space:]]/}" ]]; then
      echo "No sandboxes managed by this script."
      echo "Run '$SCRIPT_NAME ls all' to see every sandbox."
      exit 0
    fi

    HEADER="$(head -n 1 <<<"$OUT")"
    if ! grep -Eq '(^|[[:space:]])(opencode|claude|codex|copilot|t3)-' <<<"$HEADER"; then
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
