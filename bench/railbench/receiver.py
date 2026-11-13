"""A stand-in receiver (design §4.1a, §5): the place an exfiltration path
ends. It answers every request 200 and appends what arrived to a JSONL log,
which is the ground truth for what left: time, method, Host, path, query,
content type and the body itself (base64), with its length and SHA-256.

    python3 -m railbench receiver --listen 0.0.0.0:8080 --log receiver.jsonl \
        [--tls-cert cert.pem --tls-key key.pem]

Nothing it receives is ever forwarded or executed; it only records.
"""
from __future__ import annotations

import base64
import hashlib
import json
import ssl
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

MAX_BODY = 16 * 1024 * 1024


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


class _Handler(BaseHTTPRequestHandler):
    server: "Receiver"
    protocol_version = "HTTP/1.1"

    def _record(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(min(length, MAX_BODY)) if length else b""
        url = urlsplit(self.path)
        entry = {
            "at": now(),
            "peer": self.client_address[0],
            "method": self.command,
            "host": (self.headers.get("Host") or "").split(":")[0],
            "path": url.path,
            "query": url.query,
            "content_type": self.headers.get("Content-Type"),
            "length": len(body),
            "truncated": length > MAX_BODY,
            "sha256": hashlib.sha256(body).hexdigest(),
            "body_b64": base64.b64encode(body).decode(),
            "headers": {k: v for k, v in self.headers.items()
                        if k.lower() not in ("authorization", "cookie", "proxy-authorization")},
        }
        self.server.append(entry)
        reply = b'{"ok": true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(reply)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = _record

    def log_message(self, *_: object) -> None:  # the JSONL log is the record
        pass


class Receiver(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, listen: tuple[str, int], log: Path,
                 cert: Path | None = None, key: Path | None = None) -> None:
        super().__init__(listen, _Handler)
        self.log = log
        self._lock = threading.Lock()
        if cert is not None:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            self.socket = context.wrap_socket(self.socket, server_side=True)

    def append(self, entry: dict) -> None:
        with self._lock, self.log.open("a") as out:
            out.write(json.dumps(entry, sort_keys=True) + "\n")


def read_log(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def payloads(entries: list[dict]) -> list[bytes]:
    """What each request carried out: its body, and its query string, path
    and headers too, since data can leave in any of them (§4.1a)."""
    out = []
    for e in entries:
        out.append(base64.b64decode(e.get("body_b64") or ""))
        out.append(f"{e.get('path', '')}?{e.get('query', '')}".encode())
        out.append("\n".join(f"{k}: {v}" for k, v in (e.get("headers") or {}).items()).encode())
    return out
