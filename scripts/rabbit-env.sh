#!/usr/bin/env bash
# rabbit-env.sh - shared configuration and helpers for the Rabbit chat scripts.
#
# This file is meant to be sourced, not executed:
#   . "$(dirname "$0")/rabbit-env.sh"

# Guard against double-sourcing.
if [ -n "${RABBIT_ENV_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
RABBIT_ENV_LOADED=1

RABBIT_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RABBIT_ROOT_DIR=$(CDPATH= cd -- "$RABBIT_SCRIPT_DIR/.." && pwd)

# ---------------------------------------------------------------------------
# Config file: .env in the repo root, overridable with RABBIT_ENV_FILE.
# Only KEY=VALUE lines are read; everything else is ignored.
# ---------------------------------------------------------------------------
RABBIT_ENV_FILE=${RABBIT_ENV_FILE:-$RABBIT_ROOT_DIR/.env}

rabbit_load_env_file() {
  file=$1
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      ''|'#'*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case $key in
      *[!A-Za-z0-9_]*|'') continue ;;
    esac
    # Strip surrounding quotes and trailing whitespace.
    value=${value%"${value##*[![:space:]]}"}
    case $value in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    # Environment always wins over the file, so `RABBIT_CHANNEL=x ./script` works.
    if [ -z "$(eval "printf '%s' \"\${$key:-}\"")" ]; then
      export "$key=$value"
    fi
  done < "$file"
}

rabbit_load_env_file "$RABBIT_ENV_FILE"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
: "${RABBIT_CHAT_URL:=}"           # e.g. https://rabbit.example.com/api/v1/chat
: "${RABBIT_API_KEY:=}"            # bearer token for the chat endpoint
: "${RABBIT_CHANNEL:=general}"     # default channel/room
: "${RABBIT_AGENT_ID:=rabbit}"     # identity messages are sent as
: "${RABBIT_TIMEOUT:=30}"          # per-request timeout, seconds
: "${RABBIT_RETRIES:=3}"           # attempts per request (1 = no retry)
: "${RABBIT_LOG_LEVEL:=info}"      # debug | info | warn | error
: "${RABBIT_STATE_DIR:=$RABBIT_ROOT_DIR/.rabbit}"
: "${RABBIT_INSECURE:=0}"          # 1 to skip TLS verification (dev only)

export RABBIT_CHAT_URL RABBIT_API_KEY RABBIT_CHANNEL RABBIT_AGENT_ID \
       RABBIT_TIMEOUT RABBIT_RETRIES RABBIT_LOG_LEVEL RABBIT_STATE_DIR RABBIT_INSECURE

# ---------------------------------------------------------------------------
# Logging (stderr, so stdout stays pipeable)
# ---------------------------------------------------------------------------
rabbit_log_level_num() {
  case ${1:-info} in
    debug) printf '10' ;;
    info)  printf '20' ;;
    warn)  printf '30' ;;
    error) printf '40' ;;
    *)     printf '20' ;;
  esac
}

rabbit_log() {
  level=$1; shift
  want=$(rabbit_log_level_num "$RABBIT_LOG_LEVEL")
  have=$(rabbit_log_level_num "$level")
  [ "$have" -ge "$want" ] || return 0
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >&2
}

log_debug() { rabbit_log debug "$@"; }
log_info()  { rabbit_log info  "$@"; }
log_warn()  { rabbit_log warn  "$@"; }
log_error() { rabbit_log error "$@"; }

die() { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

require_var() {
  for name in "$@"; do
    value=$(eval "printf '%s' \"\${$name:-}\"")
    [ -n "$value" ] || die "$name is not set (add it to $RABBIT_ENV_FILE or export it)"
  done
}

has_jq() { command -v jq >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
# Escape a string for embedding in JSON. Uses jq when available, falls back to
# a sed pipeline that covers quotes, backslashes and control characters.
json_escape() {
  if has_jq; then
    printf '%s' "$1" | jq -Rs .
  else
    printf '%s' "$1" | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
      -e 's/\t/\\t/g' -e 's/\r/\\r/g' | awk 'BEGIN{ORS=""; print "\""} {print (NR>1 ? "\\n" : "") $0} END{print "\""}'
  fi
}

# Pretty-print JSON on stdout when jq is available, otherwise pass through.
json_pretty() {
  if has_jq; then jq . 2>/dev/null || cat; else cat; fi
}

# Read a top-level field out of a JSON document on stdin.
json_field() {
  if has_jq; then
    jq -r --arg f "$1" '.[$f] // empty' 2>/dev/null
  else
    LC_ALL=C sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -n 1
  fi
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
# rabbit_curl METHOD PATH [BODY]
# Prints "STATUS\nBODY" on stdout - callers run this in a command
# substitution, and a subshell cannot export a variable back to its parent,
# so the status code rides along on the output. Split it with rabbit_status
# and rabbit_body. Retries connection errors and 5xx with exponential backoff.
rabbit_curl() {
  require_cmd curl
  require_var RABBIT_CHAT_URL

  method=$1
  path=$2
  body=${3:-}

  base=${RABBIT_CHAT_URL%/}
  case $path in
    /*) url="$base$path" ;;
    *)  url="$base/$path" ;;
  esac

  set -- --silent --show-error --location \
         --max-time "$RABBIT_TIMEOUT" \
         --request "$method" \
         --header 'Accept: application/json' \
         --header "X-Rabbit-Agent: $RABBIT_AGENT_ID" \
         --write-out '\n%{http_code}'
  [ -n "$RABBIT_API_KEY" ] && set -- "$@" --header "Authorization: Bearer $RABBIT_API_KEY"
  [ "$RABBIT_INSECURE" = "1" ] && set -- "$@" --insecure
  if [ -n "$body" ]; then
    set -- "$@" --header 'Content-Type: application/json' --data-binary "$body"
  fi

  err_file=${TMPDIR:-/tmp}/rabbit-curl-$$.err
  trap 'rm -f "$err_file"' RETURN 2>/dev/null || true

  attempt=1
  delay=1
  while :; do
    log_debug "$method $url (attempt $attempt/$RABBIT_RETRIES)"
    if raw=$(curl "$@" "$url" 2>"$err_file"); then
      status=${raw##*$'\n'}
      resp_body=${raw%$'\n'*}
      case $status in
        [0-9][0-9][0-9]) ;;
        *) status=000; resp_body=$raw ;;
      esac
      case $status in
        5*) log_warn "server error $status from $url" ;;
        *)  rm -f "$err_file"; printf '%s\n%s' "$status" "$resp_body"; return 0 ;;
      esac
    else
      status=000
      resp_body=$(cat "$err_file" 2>/dev/null)
      log_warn "request failed: ${resp_body:-curl exited non-zero}"
    fi

    if [ "$attempt" -ge "$RABBIT_RETRIES" ]; then
      rm -f "$err_file"
      printf '%s\n%s' "$status" "$resp_body"
      return 1
    fi
    log_debug "retrying in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# True when a messages payload carries no messages. Used on the no-jq path,
# where we cannot count the array properly but can still avoid printing an
# empty envelope on every poll.
rabbit_payload_empty() {
  case $(printf '%s' "$1" | tr -d ' \n\t\r') in
    ''|'[]'|*'"messages":[]'*|*'"data":[]'*) return 0 ;;
  esac
  return 1
}

# Split a rabbit_curl result into its parts.
rabbit_status() { printf '%s' "${1%%$'\n'*}"; }
rabbit_body() {
  case $1 in
    *$'\n'*) printf '%s' "${1#*$'\n'}" ;;
    *) printf '' ;;
  esac
}

# URL-encode a string for use in a query parameter.
url_encode() {
  LC_ALL=C awk -v s="$1" 'BEGIN{
    for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
    n = length(s)
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c ~ /[A-Za-z0-9._~-]/) printf "%s", c
      else printf "%%%02X", ord[c]
    }
  }'
}

rabbit_state_dir() {
  mkdir -p "$RABBIT_STATE_DIR" 2>/dev/null || die "cannot create state dir: $RABBIT_STATE_DIR"
  printf '%s' "$RABBIT_STATE_DIR"
}
