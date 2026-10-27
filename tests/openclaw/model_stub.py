"""An OpenAI-compatible model for the openclaw job, served over HTTPS.

It answers every turn the way a real model does when it uses a tool: the
first reply of a turn streams one `write` call, and the reply to that
call's result streams a short answer. Both are server-sent events in a
chunked body, which is what railmon#70 was about. Every reply's chunk id
starts with `stubreply-tool-` or `stubreply-text-`: an agent never sends a
completion id back, so the marker found in a captured exchange can only
come from its reply.

Usage: model_stub.py CERT KEY [PORT]
"""
import json
import ssl
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "stub-1"
NOTE = {"path": "notes/turn.txt", "content": "The stub model asked for this note.\n"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"{self.command} {self.path} {fmt % args}", flush=True)

    def do_GET(self):
        body = json.dumps({"object": "list", "data": [{"id": MODEL, "object": "model"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request.get("messages") or []
        tools = {(t.get("function") or {}).get("name") for t in request.get("tools") or []}
        asks_tool = bool(messages) and messages[-1].get("role") == "user" and "write" in tools
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        kind = "tool" if asks_tool else "text"
        base = {"id": f"stubreply-{kind}-{uuid.uuid4().hex[:12]}",
                "object": "chat.completion.chunk", "created": int(time.time()), "model": MODEL}
        if asks_tool:
            arguments = json.dumps(NOTE)
            half = len(arguments) // 2
            self._event({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [
                {"index": 0, "id": f"call_{uuid.uuid4().hex[:12]}", "type": "function",
                 "function": {"name": "write", "arguments": arguments[:half]}}]}}]})
            self._event({**base, "choices": [{"index": 0, "delta": {"tool_calls": [
                {"index": 0, "function": {"arguments": arguments[half:]}}]}}]})
            self._event({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})
        else:
            self._event({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": "Saved "}}]})
            self._event({**base, "choices": [{"index": 0, "delta": {"content": "the note."}}]})
            self._event({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        self._event({**base, "choices": [],
                     "usage": {"prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110}})
        self._chunk(b"data: [DONE]\n\n")
        self._chunk(b"")

    def _event(self, event):
        self._chunk(f"data: {json.dumps(event)}\n\n".encode())
        # A model streams its reply over time, not in one write.
        time.sleep(0.05)

    def _chunk(self, data):
        self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
        self.wfile.flush()


class Server(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # The agent closes a kept-alive connection when its turn ends.
        if not isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            super().handle_error(request, client_address)


def main():
    cert, key = sys.argv[1], sys.argv[2]
    port = int(sys.argv[3]) if len(sys.argv) > 3 else 8443
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server = Server(("0.0.0.0", port), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"model stub on https://0.0.0.0:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
