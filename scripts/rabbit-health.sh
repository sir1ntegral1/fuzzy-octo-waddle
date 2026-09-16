#!/usr/bin/env bash
# rabbit-health.sh - check that the Rabbit chat integration is reachable and configured.
set -euo pipefail
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/rabbit-env.sh"

usage() {
  cat <<'USAGE'
Usage: rabbit-health.sh [options]

Verify local configuration and probe the Rabbit chat endpoint.

Options:
  -q, --quiet       Only report failures
      --local-only  Skip the network probe (config checks only)
      --json        Emit a JSON summary
  -h, --help        Show this help

Exit codes: 0 healthy, 1 config problem, 2 endpoint unreachable/unhealthy.
USAGE
}

quiet=0
local_only=0
as_json=0

while [ $# -gt 0 ]; do
  case $1 in
    -q|--quiet) quiet=1; shift ;;
    --local-only) local_only=1; shift ;;
    --json) as_json=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

checks=""
failures=0

record() {
  name=$1; status=$2; detail=$3
  [ -n "$checks" ] && checks="$checks,"
  checks="$checks{\"check\":$(json_escape "$name"),\"status\":$(json_escape "$status"),\"detail\":$(json_escape "$detail")}"
  [ "$status" = "fail" ] && failures=$((failures + 1))
  if [ "$as_json" = "0" ]; then
    case $status in
      ok)   [ "$quiet" = "1" ] || printf '  ok    %-22s %s\n' "$name" "$detail" ;;
      warn) printf '  warn  %-22s %s\n' "$name" "$detail" >&2 ;;
      fail) printf '  FAIL  %-22s %s\n' "$name" "$detail" >&2 ;;
    esac
  fi
}

# --- local configuration ---------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  record curl ok "$(curl --version 2>/dev/null | head -n 1)"
else
  record curl fail "curl is required but not installed"
fi

if has_jq; then
  record jq ok "$(jq --version 2>/dev/null)"
else
  record jq warn "jq not installed - output will not be formatted"
fi

if [ -f "$RABBIT_ENV_FILE" ]; then
  record env-file ok "$RABBIT_ENV_FILE"
else
  record env-file warn "$RABBIT_ENV_FILE not found - using environment only"
fi

if [ -n "$RABBIT_CHAT_URL" ]; then
  case $RABBIT_CHAT_URL in
    https://*) record chat-url ok "$RABBIT_CHAT_URL" ;;
    http://*)  record chat-url warn "$RABBIT_CHAT_URL (plaintext http)" ;;
    *)         record chat-url fail "not an http(s) URL: $RABBIT_CHAT_URL" ;;
  esac
else
  record chat-url fail "RABBIT_CHAT_URL is not set"
fi

if [ -n "$RABBIT_API_KEY" ]; then
  record api-key ok "set (${#RABBIT_API_KEY} chars)"
else
  record api-key warn "RABBIT_API_KEY is empty - requests will be unauthenticated"
fi

record channel ok "$RABBIT_CHANNEL"
record agent-id ok "$RABBIT_AGENT_ID"

# --- endpoint probe --------------------------------------------------------
if [ "$local_only" = "0" ] && [ "$failures" -eq 0 ]; then
  set +e
  raw=$(rabbit_curl GET /health)
  set -e
  status=$(rabbit_status "$raw")
  response=$(rabbit_body "$raw")
  case $status in
    2*)
      state=$(printf '%s' "$response" | json_field status)
      record endpoint ok "HTTP $status${state:+ ($state)}"
      ;;
    000) record endpoint fail "no response from $RABBIT_CHAT_URL" ;;
    401|403) record endpoint fail "HTTP $status - check RABBIT_API_KEY" ;;
    404) record endpoint warn "HTTP 404 - /health not implemented by this endpoint" ;;
    *) record endpoint fail "HTTP $status" ;;
  esac
elif [ "$local_only" = "1" ]; then
  record endpoint warn "skipped (--local-only)"
fi

if [ "$as_json" = "1" ]; then
  printf '{"healthy":%s,"failures":%d,"checks":[%s]}\n' \
    "$([ "$failures" -eq 0 ] && printf 'true' || printf 'false')" "$failures" "$checks" | json_pretty
fi

if [ "$failures" -eq 0 ]; then
  [ "$quiet" = "1" ] || [ "$as_json" = "1" ] || printf 'rabbit chat integration: healthy\n'
  exit 0
fi

[ -n "$RABBIT_CHAT_URL" ] || exit 1
exit 2
