#!/usr/bin/env python3
"""Minimal in-memory Rabbit chat endpoint for local development and tests.

Implements the contract the shell scripts expect:

    GET  /health
    POST /messages
    GET  /messages?channel=&limit=&since=

Usage:
    ./scripts/rabbit-mock-server.py --port 8787 [--token SECRET]
    RABBIT_CHAT_URL=http://127.0.0.1:8787 ./scripts/rabbit-health.sh
"""

from __future__ import annotations

import argparse
import json
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MESSAGES: list[dict] = []
LOCK = threading.Lock()
TOKEN: str | None = None


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "rabbit-mock/1.0"

    def log_message(self, fmt, *args):  # quieter than the default
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def _reply(self, status: int, payload: dict | list) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        if TOKEN is None:
            return True
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def do_GET(self) -> None:
        url = urlparse(self.path)
        if url.path == "/health":
            self._reply(200, {"status": "ok", "time": now()})
            return
        if url.path != "/messages":
            self._reply(404, {"error": "not found"})
            return
        if not self._authorized():
            self._reply(401, {"error": "unauthorized"})
            return

        query = parse_qs(url.query)
        channel = (query.get("channel") or ["general"])[0]
        limit = int((query.get("limit") or ["50"])[0])
        since = (query.get("since") or [None])[0]

        with LOCK:
            items = [m for m in MESSAGES if m["channel"] == channel]
        if since:
            index = next((i for i, m in enumerate(items) if m["id"] == since), None)
            items = items[index + 1:] if index is not None else items
        items = items[:limit]
        self._reply(200, {
            "messages": items,
            "next_cursor": items[-1]["id"] if items else since,
        })

    def do_POST(self) -> None:
        if urlparse(self.path).path != "/messages":
            self._reply(404, {"error": "not found"})
            return
        if not self._authorized():
            self._reply(401, {"error": "unauthorized"})
            return

        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError as exc:
            self._reply(400, {"error": f"invalid json: {exc}"})
            return
        if not payload.get("text"):
            self._reply(422, {"error": "text is required"})
            return

        with LOCK:
            message = {
                "id": f"msg-{len(MESSAGES) + 1:06d}",
                "channel": payload.get("channel", "general"),
                "agent": payload.get("agent", "unknown"),
                "text": payload["text"],
                "thread_id": payload.get("thread_id"),
                "metadata": payload.get("metadata", {}),
                "sent_at": payload.get("sent_at") or now(),
            }
            MESSAGES.append(message)
        self._reply(201, message)


def main() -> None:
    global TOKEN
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--token", default=None, help="require this bearer token")
    args = parser.parse_args()

    TOKEN = args.token
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"rabbit mock chat on http://{args.host}:{args.port}"
          f"{' (auth required)' if TOKEN else ''}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
