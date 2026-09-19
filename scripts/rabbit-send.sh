#!/usr/bin/env bash
# rabbit-send.sh - post a message into a Rabbit chat channel.
set -euo pipefail
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/rabbit-env.sh"

usage() {
  cat <<'USAGE'
Usage: rabbit-send.sh [options] [message]

Send a message to the Rabbit chat integration. The message is taken from the
positional argument, from -m, or from stdin (in that order).

Options:
  -c, --channel NAME    Channel to post to (default: $RABBIT_CHANNEL)
  -m, --message TEXT    Message body
  -f, --file PATH       Read the message body from PATH ('-' for stdin)
  -t, --thread ID       Post as a reply in thread ID
      --meta KEY=VALUE  Attach a metadata field (repeatable)
      --raw             Treat the body as a complete JSON payload
      --dry-run         Print the payload instead of sending it
  -h, --help            Show this help

Exit codes: 0 sent, 1 usage/config error, 2 rejected by the server.
USAGE
}

channel=$RABBIT_CHANNEL
message=
thread=
raw=0
dry_run=0
meta_keys=()
meta_vals=()

while [ $# -gt 0 ]; do
  case $1 in
    -c|--channel) channel=${2:?--channel needs a value}; shift 2 ;;
    -m|--message) message=${2:?--message needs a value}; shift 2 ;;
    -f|--file)
      path=${2:?--file needs a value}
      if [ "$path" = "-" ]; then message=$(cat)
      else [ -r "$path" ] || die "cannot read file: $path"; message=$(cat "$path"); fi
      shift 2 ;;
    -t|--thread) thread=${2:?--thread needs a value}; shift 2 ;;
    --meta)
      pair=${2:?--meta needs KEY=VALUE}
      case $pair in *=*) ;; *) die "--meta expects KEY=VALUE, got: $pair" ;; esac
      meta_keys+=("${pair%%=*}"); meta_vals+=("${pair#*=}"); shift 2 ;;
    --raw) raw=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) break ;;
  esac
done

[ $# -gt 0 ] && message="$*"
if [ -z "$message" ] && [ ! -t 0 ]; then message=$(cat); fi
[ -n "$message" ] || { usage >&2; die "no message given"; }

if [ "$raw" = "1" ]; then
  payload=$message
else
  payload="{\"channel\":$(json_escape "$channel"),\"agent\":$(json_escape "$RABBIT_AGENT_ID"),\"text\":$(json_escape "$message")"
  [ -n "$thread" ] && payload="$payload,\"thread_id\":$(json_escape "$thread")"
  if [ ${#meta_keys[@]} -gt 0 ]; then
    payload="$payload,\"metadata\":{"
    i=0
    while [ "$i" -lt ${#meta_keys[@]} ]; do
      [ "$i" -gt 0 ] && payload="$payload,"
      payload="$payload$(json_escape "${meta_keys[$i]}"):$(json_escape "${meta_vals[$i]}")"
      i=$((i + 1))
    done
    payload="$payload}"
  fi
  payload="$payload,\"sent_at\":$(json_escape "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")}"
fi

if [ "$dry_run" = "1" ]; then
  printf '%s\n' "$payload" | json_pretty
  exit 0
fi

require_var RABBIT_CHAT_URL
log_info "sending to channel '$channel' (${#message} chars)"

set +e
raw=$(rabbit_curl POST /messages "$payload")
set -e
status=$(rabbit_status "$raw")
response=$(rabbit_body "$raw")

case $status in
  2*)
    id=$(printf '%s' "$response" | json_field id)
    log_info "delivered${id:+ (id=$id)}"
    printf '%s\n' "$response" | json_pretty
    ;;
  *)
    log_error "send failed with status $status"
    printf '%s\n' "$response" >&2
    exit 2
    ;;
esac
