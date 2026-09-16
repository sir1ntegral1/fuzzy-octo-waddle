#!/usr/bin/env bash
# rabbit-smoke-test.sh - end-to-end check of the Rabbit chat integration.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/rabbit-env.sh"

usage() {
  cat <<'USAGE'
Usage: rabbit-smoke-test.sh [options]

Run health, send and receive against the configured endpoint. Sends a unique
marker message and confirms it comes back on the next poll.

Options:
  -c, --channel NAME   Channel to test (default: $RABBIT_CHANNEL)
      --no-send        Health and poll only; do not post a message
      --timeout SECS   How long to wait for the marker (default: 20)
  -h, --help           Show this help

Exit codes: 0 all passed, 1 config error, 2 a step failed.
USAGE
}

channel=$RABBIT_CHANNEL
do_send=1
wait_for=20

while [ $# -gt 0 ]; do
  case $1 in
    -c|--channel) channel=${2:?--channel needs a value}; shift 2 ;;
    --no-send) do_send=0; shift ;;
    --timeout) wait_for=${2:?--timeout needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case $wait_for in *[!0-9]*|'') die "--timeout must be a whole number of seconds" ;; esac

passed=0
failed=0

step() {
  name=$1; shift
  printf '\n--- %s\n' "$name"
  if "$@"; then
    passed=$((passed + 1))
    printf '    PASS %s\n' "$name"
    return 0
  fi
  failed=$((failed + 1))
  printf '    FAIL %s\n' "$name" >&2
  return 1
}

marker="smoke-$(date -u '+%Y%m%dT%H%M%SZ')-$$"

step "health" "$SCRIPT_DIR/rabbit-health.sh" --quiet || true

if [ "$do_send" = "1" ] && [ "$failed" -eq 0 ]; then
  step "send" "$SCRIPT_DIR/rabbit-send.sh" \
    --channel "$channel" --meta "smoke=1" \
    --message "rabbit smoke test $marker" || true
fi

roundtrip() {
  deadline=$(( $(date +%s) + wait_for ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if "$SCRIPT_DIR/rabbit-listen.sh" --channel "$channel" --once --json --from-start \
        | grep -q -- "$marker"; then
      return 0
    fi
    sleep 2
  done
  log_error "marker '$marker' did not come back within ${wait_for}s"
  return 1
}

if [ "$failed" -eq 0 ]; then
  if [ "$do_send" = "1" ]; then
    step "round-trip" roundtrip || true
  else
    step "poll" "$SCRIPT_DIR/rabbit-listen.sh" --channel "$channel" --once --json || true
  fi
fi

printf '\n=== smoke test: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 2
