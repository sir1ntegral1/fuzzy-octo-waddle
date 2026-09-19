# Rabbit chat integration scripts

Operational scripts for the Rabbit chat integration. Plain POSIX-flavoured
bash — the only hard dependency is `curl`; `jq` is optional but gives
formatted output and reliable cursor extraction.

## Layout

| Script | What it does |
| --- | --- |
| `rabbit-env.sh` | Shared library: config loading, logging, JSON helpers, HTTP with retry. Sourced by the others, not run directly. |
| `rabbit-setup.sh` | Bootstrap a fresh clone: `.env` from `.env.example`, executable bits, state dir, dependency check. |
| `rabbit-health.sh` | Config and endpoint checks. Use in CI or as a readiness probe. |
| `rabbit-send.sh` | Post a message to a channel. |
| `rabbit-listen.sh` | Poll a channel for new messages, resuming from a stored cursor. |
| `rabbit-smoke-test.sh` | End-to-end: health, send a unique marker, confirm it comes back. |
| `rabbit-mock-server.py` | Throwaway in-memory endpoint implementing the contract below, for local runs and CI. |

## Quick start

```sh
./scripts/rabbit-setup.sh          # creates .env, chmods scripts
$EDITOR .env                       # set RABBIT_CHAT_URL and RABBIT_API_KEY
./scripts/rabbit-health.sh
./scripts/rabbit-send.sh -m "hello from $(hostname)"
./scripts/rabbit-listen.sh --once
```

## Configuration

Every setting is an environment variable. `rabbit-env.sh` reads `.env` from the
repo root (override with `RABBIT_ENV_FILE`), and **the environment always wins
over the file**, so one-off overrides work:

```sh
RABBIT_CHANNEL=ops RABBIT_LOG_LEVEL=debug ./scripts/rabbit-send.sh -m "deploying"
```

See `.env.example` for the full list with defaults.

## Endpoint contract

The scripts assume a small HTTP API under `RABBIT_CHAT_URL`:

- `GET /health` → `200` with `{"status":"ok"}` (a `404` is tolerated as a warning)
- `POST /messages` with
  `{"channel","agent","text","thread_id"?,"metadata"?,"sent_at"}` → `2xx`,
  ideally echoing `{"id": "..."}`
- `GET /messages?channel=&limit=&since=` → either a bare array or
  `{"messages":[...]}` / `{"data":[...]}`, optionally with `next_cursor`

Message objects are read leniently: `sent_at`/`timestamp`, `agent`/`author`/`from`,
and `text`/`message`/`body` are all accepted. When `next_cursor` is absent, the
last message's `id` becomes the cursor.

If your endpoint differs, `rabbit_curl` in `rabbit-env.sh` is the single place
where paths and headers are built.

## Usage notes

`rabbit-send.sh` takes the body from an argument, `-m`, `-f FILE`, or stdin:

```sh
./scripts/rabbit-send.sh -c ops -m "build 1.4.2 is live"
git log -1 --pretty=%B | ./scripts/rabbit-send.sh -c releases -f -
./scripts/rabbit-send.sh --meta run_id=42 --meta env=prod -m "job finished"
./scripts/rabbit-send.sh -m "check the payload" --dry-run   # prints JSON, sends nothing
```

`rabbit-listen.sh` stores its cursor per channel under `$RABBIT_STATE_DIR`
(`.rabbit/` by default), so a restart does not replay old messages:

```sh
./scripts/rabbit-listen.sh                  # follow, polling every 5s
./scripts/rabbit-listen.sh --once --json    # single poll, raw JSON (scriptable)
./scripts/rabbit-listen.sh --from-start     # ignore the stored cursor
./scripts/rabbit-listen.sh --reset          # forget the cursor and exit
```

## Exit codes

`0` success · `1` usage or configuration error · `2` the remote call failed or
was rejected. `rabbit-health.sh` splits these deliberately: `1` means *your
config is wrong*, `2` means *the endpoint is unhappy* — handy for alerting.

## Trying it without a live endpoint

`rabbit-mock-server.py` (stdlib only) implements the contract above in memory:

```sh
./scripts/rabbit-mock-server.py --port 8787 --token dev &
RABBIT_CHAT_URL=http://127.0.0.1:8787 RABBIT_API_KEY=dev \
  ./scripts/rabbit-smoke-test.sh
```

## CI

```yaml
- run: ./scripts/rabbit-health.sh --local-only   # no network needed
- run: ./scripts/rabbit-smoke-test.sh            # needs a reachable endpoint
```
