#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# Symlinks resolved, so the default T3_KIT works when called via a symlink.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Settings from this file (see config.example.conf); the environment wins.
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

# Parsed, never sourced.
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

SBX_BIN="${SBX_BIN:-sbx}"

SKILLS_DIR="${SKILLS_DIR:-}"

if [[ -z "${SKILLS_IMPORT:-}" ]]; then
  if [[ -n "$SKILLS_DIR" ]]; then SKILLS_IMPORT=1; else SKILLS_IMPORT=0; fi
fi

# Starts above 8080, which many dev servers use.
BASE_PORT="${BASE_PORT:-8081}"

T3_BASE_PORT="${T3_BASE_PORT:-3773}"

OPENCODE_IMAGE="${OPENCODE_IMAGE:-opencode}"
CLAUDE_IMAGE="${CLAUDE_IMAGE:-claude}"
CODEX_IMAGE="${CODEX_IMAGE:-codex}"
COPILOT_IMAGE="${COPILOT_IMAGE:-copilot}"

T3_KIT="${T3_KIT:-$SCRIPT_DIR/t3-kit}"

NETWORK_ALLOW="${NETWORK_ALLOW:-}"

UPDATE_CHECK="${UPDATE_CHECK:-1}"

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
  stop <project>                         Stop a running sandbox
  rm <project>                           Remove a sandbox (asks first)

Options:
  --detached                             t3 start/create in the background (-d)
  --verbose                              Show T3 Code's full server log (-v)

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
  $SCRIPT_NAME start myapp -d

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
  # Captured first: with pipefail, 'sbx ls | grep -q' can fail on SIGPIPE.
  # Exact match, as grep -w would find 'claude-temp' in 'claude-temp-oai'.
  out="$("$SBX_BIN" ls 2>/dev/null || true)"
  awk -v n="$name" 'NR > 1 && $1 == n { found = 1 } END { exit !found }' <<<"$out"
}

sandbox_running() {
  require_cmd jq
  "$SBX_BIN" ls --json 2>/dev/null \
    | jq -e --arg n "$1" '.sandboxes[] | select(.name == $n) | .status == "running"' >/dev/null
}

# Best effort: only sees listeners on 127.0.0.1.
find_free_port() {
  local port="$1"
  while (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; do
    exec 3>&- 3<&-
    port=$((port + 1))
  done
  echo "$port"
}

# Not opencode: sbx stopped detached opencode sandboxes after a short while.
check_detached() {
  if [[ "$DETACHED" -eq 1 && "$1" != "t3" ]]; then
    echo "ERROR: --detached only works for t3 sandboxes." >&2
    exit 1
  fi
}

check_port() {
  if [[ -n "$1" && ! "$1" =~ ^[0-9]+$ ]]; then
    echo "ERROR: host_port '$1' is not a number (agents: t3, claude, codex, copilot, opencode)." >&2
    exit 1
  fi
}

# Sets AGENT from the existing sandbox unless one was given. Also accepts the
# full sandbox name ('t3-foo'); a trailing agent contradicting its prefix is
# an error unless that names a sandbox too ('claude-x t3' with 't3-claude-x').
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

require_tty() {
  if [[ ! -t 0 ]]; then
    echo "ERROR: $1 needs an interactive terminal." >&2
    exit 1
  fi
}

# Prints "<status> <redirect target>" for a URL fetched inside the sandbox.
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

# Codex's login callback goes to localhost:1455 inside the sandbox, which the
# host's browser can't reach. The user pastes the failed callback URL and it's
# replayed inside the sandbox. Codex only exits once its /success redirect is
# fetched too.
codex_login() {
  local name="$1" out pid url callback status location rc
  out="$(mktemp "${TMPDIR:-/tmp}/sandbox-codex.XXXXXX")"
  "$SBX_BIN" exec "$name" codex login </dev/null >"$out" 2>&1 &
  pid=$!
  # /cancel stops the login server; killing the sbx client may not.
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

# No TTY is an error, not consent.
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

# Runs inside a sandbox. 'check' prints "<cli> <installed> <latest>" per
# outdated CLI ("missing" for an npm package left without its command by an
# interrupted install), or OFFLINE. npm has every CLI's latest version, but
# 'update' uses the CLI's own updater for native installs (sbx's claude and
# copilot templates).
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

# Sets UPDATES; returns 1 if offline.
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

install_provider_updates() {
  local clis
  clis="$(awk '{ printf "%s ", $1 }' <<<"$UPDATES")"
  # shellcheck disable=SC2086 # one word per CLI
  "$SBX_BIN" exec "$1" sh -c "$PROVIDERS_SH" sh update $clis
}

# Its 'sbx exec' starts the sandbox without T3 Code; 'sbx run --detached'
# would start it, and the later 'sbx run' a second one. Stops the sandbox if
# T3 Code was updated, so the caller's start runs the new version.
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

# Running sandboxes see the refreshed store only after a restart.
reload_skills_store() {
  "$SBX_BIN" skills import --force
}

maybe_reload_skills_store() {
  if [[ "$SKILLS_IMPORT" == "1" ]]; then
    reload_skills_store
  fi
}

# Sets PUBLISHED_PORT, reusing the binding sbx restores on start. Needs a
# running sandbox.
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
    if ! grep -q "already published" <<<"$out"; then
      echo "$out" >&2
      exit 1
    fi
  fi
}

port_users() {
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP +c 0 -iTCP:"$1" -sTCP:LISTEN -Fpc 2>/dev/null | awk '
    /^p/ { pid = substr($0, 2) }
    /^c/ {
      c = substr($0, 2); gsub(/\\x20/, " ", c)
      if (c != "sbx" && c !~ /^com\.docker/) print c " (PID " pid ")"
    }' || true
}

# sbx re-publishes a remembered port even if another program took it while
# the sandbox was stopped (e.g. the T3 Code desktop app, also from 3773 up).
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

# T3 Code's Pairing URL shows the sandbox's internal address. [:cntrl:] keeps
# ANSI color codes out of the token.
add_local_pairing_url() {
  local host_port="$1"
  awk -v port="$host_port" '
    { print; fflush() }
    /Pairing URL:/ && match($0, /#token=[^[:space:][:cntrl:]]+/) {
      print "Local URL:   http://127.0.0.1:" port "/pair" substr($0, RSTART, RLENGTH)
      fflush()
    }'
}

t3_running() {
  sandbox_running "$1" && "$SBX_BIN" exec "$1" pgrep -f "t3 serve" >/dev/null 2>&1
}

print_pairing_url() {
  local name="$1" token=""
  for _ in $(seq 1 30); do
    token="$("$SBX_BIN" exec "$name" t3 pair 2>/dev/null \
      | grep -o '#token=[^[:space:][:cntrl:]]*' | head -n 1 || true)"
    [[ -n "$token" ]] && break
    sleep 1
  done
  if [[ -z "$token" ]]; then
    echo "WARNING: no pairing token yet; get one with 'sbx exec ${name} t3 pair'." >&2
    return 0
  fi
  echo "Local URL: http://127.0.0.1:${PUBLISHED_PORT}/pair${token} (valid 5 minutes)"
}

# $3 = 1: also print a pairing URL.
run_detached() {
  local name="$1" host_port="$2" pair="$3"

  maybe_update_providers "$name"
  if ! t3_running "$name"; then
    # Not 'sbx run --detached': its agent process stops when that call returns.
    "$SBX_BIN" exec -e "T3CODE_LOG_LEVEL=${T3_LOG_LEVEL}" "$name" sh -c \
      'setsid nohup /usr/local/bin/entrypoint.sh >/tmp/t3-serve.log 2>&1 </dev/null &'
  fi
  publish_port "$name" "$host_port" 3773 "$T3_BASE_PORT"
  check_port_conflict "$name" 3773 "$T3_BASE_PORT"

  echo "T3 Code '${name}' runs in the background: http://127.0.0.1:${PUBLISHED_PORT}"
  [[ "$pair" == "1" ]] && print_pairing_url "$name"
  echo "Stop it with: $SCRIPT_NAME stop ${PROJECT_NAME}"
}

run_foreground() {
  local name="$1"
  local host_port="$2"
  local agent="$3"

  if [[ "$agent" == "t3" ]] && t3_running "$name"; then
    echo "ERROR: '${name}' is already running in the background. Stop it first: $SCRIPT_NAME stop ${PROJECT_NAME}" >&2
    exit 1
  fi

  # sbx doesn't reliably stop a sandbox that was already running when
  # 'sbx run' attached.
  # shellcheck disable=SC2064 # expand name now
  trap "echo; echo 'Stopping ${name}...'; \"\$SBX_BIN\" stop '${name}' >/dev/null 2>&1 || true" EXIT

  maybe_update_providers "$name"

  if [[ "$agent" == "claude" || "$agent" == "codex" || "$agent" == "copilot" ]]; then
    local label="Claude Code"
    [[ "$agent" == "codex" ]] && label="Codex CLI"
    [[ "$agent" == "copilot" ]] && label="Copilot CLI"
    echo "${label} sandbox '${name}': interactive session (no web server)."
    echo "Running in the foreground. Ctrl+C or 'exit' to stop."
    echo

    # 'sbx exec' has no TTY, which breaks the interactive CLIs.
    "$SBX_BIN" run "$name"
  elif [[ "$agent" == "t3" ]]; then
    # T3 Code is the kit's agent process, started by 'sbx run' below. The
    # sandbox is started first so the port can be published.
    "$SBX_BIN" exec "$name" true
    publish_port "$name" "$host_port" 3773 "$T3_BASE_PORT"
    check_port_conflict "$name" 3773 "$T3_BASE_PORT"

    echo "T3 Code sandbox '${name}': server published at http://127.0.0.1:${PUBLISHED_PORT}"
    echo "Use the 'Local URL' line below to pair -- the Pairing URL/QR show the"
    echo "sandbox's internal address."
    echo "Running in the foreground. Ctrl+C or 'exit' to stop."
    echo

    "$SBX_BIN" run --name "$name" -e "T3CODE_LOG_LEVEL=${T3_LOG_LEVEL}" \
      | add_local_pairing_url "$PUBLISHED_PORT"
  else
    "$SBX_BIN" exec "$name" true
    publish_port "$name" "$host_port" 8080 "$BASE_PORT"
    check_port_conflict "$name" 8080 "$BASE_PORT"

    echo "OpenCode server '${name}': http://127.0.0.1:${PUBLISHED_PORT}"
    echo "Running in the foreground. Ctrl+C to stop."
    echo

    "$SBX_BIN" exec "$name" opencode serve --hostname 0.0.0.0 --port 8080
  fi
}

DETACHED=0
VERBOSE=0
ARGS=()
for ARG in "$@"; do
  case "$ARG" in
    --detached|-d) DETACHED=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    *) ARGS+=("$ARG") ;;
  esac
done

# Info is noisy; Error still prints the startup banner with the pairing URL.
T3_LOG_LEVEL=Error
[[ "$VERBOSE" -eq 1 ]] && T3_LOG_LEVEL=Info
set -- ${ARGS[@]+"${ARGS[@]}"}

[[ $# -lt 1 ]] && usage
case "$1" in help|-h|--help) usage 0 ;; esac
require_cmd "$SBX_BIN" SBX_BIN

CMD="$1"; shift
if [[ "$DETACHED" -eq 1 && "$CMD" != "start" && "$CMD" != "create" ]]; then
  echo "ERROR: --detached only works with start and create." >&2
  exit 1
fi

# Optional trailing agent. Not for login, whose last argument is a provider.
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
    check_detached "$AGENT"

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
    if [[ "$DETACHED" -eq 1 ]]; then
      run_detached "$NAME" "$HOST_PORT" 1
    else
      run_foreground "$NAME" "$HOST_PORT" "$AGENT"
    fi
    ;;

  start)
    [[ $# -lt 1 ]] && usage
    PROJECT_NAME="$1"
    resolve_agent "$PROJECT_NAME"
    NAME="${AGENT}-${PROJECT_NAME}"
    check_detached "$AGENT"

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
    if [[ "$DETACHED" -eq 1 ]]; then
      run_detached "$NAME" "$HOST_PORT" 0
    else
      run_foreground "$NAME" "$HOST_PORT" "$AGENT"
    fi
    ;;

  stop)
    [[ $# -lt 1 ]] && usage
    PROJECT_NAME="$1"
    resolve_agent "$PROJECT_NAME"
    NAME="${AGENT}-${PROJECT_NAME}"

    if ! sandbox_exists "$NAME"; then
      echo "ERROR: sandbox '${NAME}' does not exist. Run '$SCRIPT_NAME ls' to see what does." >&2
      exit 1
    fi
    if ! sandbox_running "$NAME"; then
      echo "'${NAME}' isn't running."
      exit 0
    fi
    "$SBX_BIN" stop "$NAME" >/dev/null
    echo "Stopped '${NAME}'."
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

    # New sessions use updated CLIs right away; T3 Code itself only after a
    # restart.
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

    # Older sandboxes may lack CLIs added to the image later.
    FAILED=()
    DONE=()
    for P in "${PROVIDERS[@]}"; do
      if ! "$SBX_BIN" exec "$NAME" sh -c "command -v $P" >/dev/null 2>&1; then
        echo "== ${P} isn't installed in '${NAME}', skipped."
        echo
        [[ "$PROVIDER" != "all" ]] && FAILED+=("$P")
        continue
      fi
      if [[ ${#PROVIDERS[@]} -gt 1 ]]; then
        read -r -p "Log in to ${P}? [Y/n] " ANSWER
        if [[ "$ANSWER" == [nN]* ]]; then
          echo
          continue
        fi
      fi
      case "$P" in
        claude) LOGIN_CMD=(claude auth login) ;;
        codex) LOGIN_CMD=(codex login) ;;  # run by codex_login
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

    # Matches name prefixes only; the columns pass through as-is.
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
      # --force: we already asked.
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
