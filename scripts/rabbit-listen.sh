#!/usr/bin/env bash
# rabbit-listen.sh - poll a Rabbit chat channel for new messages.
set -euo pipefail
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/rabbit-env.sh"

usage() {
  cat <<'USAGE'
Usage: rabbit-listen.sh [options]

Poll the Rabbit chat integration for messages and print them as they arrive.
The last seen cursor is stored under $RABBIT_STATE_DIR so restarts resume
where the previous run stopped.

Options:
  -c, --channel NAME    Channel to read (default: $RABBIT_CHANNEL)
  -i, --interval SECS   Seconds between polls (default: 5)
  -n, --limit N         Max messages per poll (default: 50)
  -s, --since CURSOR    Start from CURSOR instead of the stored one
      --from-start      Ignore the stored cursor and read from the beginning
      --once            Poll a single time and exit
      --json            Print raw JSON instead of formatted lines
      --reset           Delete the stored cursor and exit
  -h, --help            Show this help

Exit codes: 0 clean exit, 1 usage/config error, 2 poll failed.
USAGE
}

channel=$RABBIT_CHANNEL
interval=5
limit=50
since=
once=0
as_json=0
from_start=0
reset=0

while [ $# -gt 0 ]; do
  case $1 in
    -c|--channel) channel=${2:?--channel needs a value}; shift 2 ;;
    -i|--interval) interval=${2:?--interval needs a value}; shift 2 ;;
    -n|--limit) limit=${2:?--limit needs a value}; shift 2 ;;
    -s|--since) since=${2:?--since needs a value}; shift 2 ;;
    --from-start) from_start=1; shift ;;
    --once) once=1; shift ;;
    --json) as_json=1; shift ;;
    --reset) reset=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case $interval in *[!0-9]*|'') die "--interval must be a whole number of seconds" ;; esac
case $limit in *[!0-9]*|'') die "--limit must be a whole number" ;; esac

cursor_file="$(rabbit_state_dir)/cursor-$(printf '%s' "$channel" | tr -c 'A-Za-z0-9_.-' '_')"

if [ "$reset" = "1" ]; then
  rm -f "$cursor_file"
  log_info "cursor cleared for channel '$channel'"
  exit 0
fi

if [ -z "$since" ] && [ "$from_start" = "0" ] && [ -f "$cursor_file" ]; then
  since=$(cat "$cursor_file")
  log_debug "resuming from cursor $since"
fi

require_var RABBIT_CHAT_URL

print_messages() {
  body=$1
  if [ "$as_json" = "1" ] || ! has_jq; then
    rabbit_payload_empty "$body" && return 0
    printf '%s\n' "$body" | json_pretty
    return 0
  fi
  printf '%s' "$body" | jq -r '
    (if type == "array" then . else (.messages // .data // []) end)[]
    | [ (.sent_at // .timestamp // ""),
        (.agent // .author // .from // "?"),
        (.text // .message // .body // "") ]
    | @tsv' | while IFS=$'\t' read -r ts who text; do
      printf '%s  %-16s %s\n' "${ts:-–}" "$who" "$text"
    done
}

next_cursor() {
  body=$1
  if has_jq; then
    printf '%s' "$body" | jq -r '
      .next_cursor // .cursor //
      ((if type == "array" then . else (.messages // .data // []) end)
       | last | (.id // .cursor // empty)) // empty' 2>/dev/null
  else
    printf '%s' "$body" | json_field next_cursor
  fi
}

poll_once() {
  query="channel=$(url_encode "$channel")&limit=$limit"
  [ -n "$since" ] && query="$query&since=$(url_encode "$since")"

  set +e
  raw=$(rabbit_curl GET "/messages?$query")
  set -e
  status=$(rabbit_status "$raw")
  response=$(rabbit_body "$raw")

  case $status in
    2*) ;;
    *) log_error "poll failed with status $status"
       printf '%s\n' "$response" >&2
       return 2 ;;
  esac

  count=0
  if has_jq; then
    count=$(printf '%s' "$response" \
      | jq -r '(if type == "array" then . else (.messages // .data // []) end) | length' 2>/dev/null || printf '0')
  fi

  if [ "${count:-0}" != "0" ] || ! has_jq; then
    print_messages "$response"
  fi

  cursor=$(next_cursor "$response")
  if [ -n "$cursor" ] && [ "$cursor" != "$since" ]; then
    since=$cursor
    printf '%s' "$cursor" > "$cursor_file"
    log_debug "cursor advanced to $cursor"
  fi
  return 0
}

trap 'log_info "stopping"; exit 0' INT TERM

if [ "$once" = "1" ]; then
  poll_once
  exit $?
fi

log_info "listening on '$channel' every ${interval}s (ctrl-c to stop)"
while :; do
  poll_once || exit 2
  sleep "$interval"
done
