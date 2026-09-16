#!/usr/bin/env bash
# rabbit-setup.sh - bootstrap the Rabbit chat integration scripts in a clone.
set -euo pipefail
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/rabbit-env.sh"

usage() {
  cat <<'USAGE'
Usage: rabbit-setup.sh [options]

Prepare a fresh clone: create .env from .env.example, make the scripts
executable, create the state directory, and report missing dependencies.

Options:
  --force     Overwrite an existing .env
  --check     Report what would change without writing anything
  -h, --help  Show this help

Exit codes: 0 ready, 1 setup incomplete.
USAGE
}

force=0
check=0
while [ $# -gt 0 ]; do
  case $1 in
    --force) force=1; shift ;;
    --check) check=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

problems=0
example="$RABBIT_ROOT_DIR/.env.example"

# 1. dependencies
for cmd in curl awk sed date; do
  if command -v "$cmd" >/dev/null 2>&1; then
    log_debug "found $cmd"
  else
    log_error "missing required command: $cmd"
    problems=$((problems + 1))
  fi
done
has_jq || log_warn "jq not installed - install it for formatted output (apt install jq / brew install jq)"

# 2. .env
if [ ! -f "$example" ]; then
  log_warn "no .env.example found at $example"
elif [ -f "$RABBIT_ENV_FILE" ] && [ "$force" = "0" ]; then
  log_info ".env already exists - leaving it alone (use --force to overwrite)"
elif [ "$check" = "1" ]; then
  log_info "would create $RABBIT_ENV_FILE from .env.example"
else
  cp "$example" "$RABBIT_ENV_FILE"
  chmod 600 "$RABBIT_ENV_FILE" 2>/dev/null || true
  log_info "created $RABBIT_ENV_FILE - fill in RABBIT_CHAT_URL and RABBIT_API_KEY"
fi

# 3. executable bits
for script in "$RABBIT_SCRIPT_DIR"/*.sh; do
  [ -f "$script" ] || continue
  if [ -x "$script" ]; then
    continue
  elif [ "$check" = "1" ]; then
    log_info "would chmod +x $script"
  else
    chmod +x "$script" && log_debug "chmod +x $script"
  fi
done

# 4. state dir
if [ "$check" = "1" ]; then
  [ -d "$RABBIT_STATE_DIR" ] || log_info "would create $RABBIT_STATE_DIR"
else
  rabbit_state_dir >/dev/null
  log_debug "state dir ready: $RABBIT_STATE_DIR"
fi

# 5. summary
if [ "$problems" -gt 0 ]; then
  log_error "setup incomplete: $problems missing dependency/dependencies"
  exit 1
fi

if [ -z "$RABBIT_CHAT_URL" ]; then
  log_warn "RABBIT_CHAT_URL is still empty - edit $RABBIT_ENV_FILE before sending messages"
fi

cat <<NEXT
Setup complete. Next steps:
  1. Edit $RABBIT_ENV_FILE (RABBIT_CHAT_URL, RABBIT_API_KEY)
  2. ./scripts/rabbit-health.sh
  3. ./scripts/rabbit-send.sh -m "hello from \$(hostname)"
  4. ./scripts/rabbit-listen.sh --once
NEXT
