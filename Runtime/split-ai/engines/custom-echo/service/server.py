"""Standard-library-only sample engine; replace echo behavior with your adapter."""
from __future__ import annotations

import argparse
import hmac
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# -I ignores PYTHONPATH and excludes the script directory. Add only this package.
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "site-packages"))
PROTOCOL = "velum.local-ai.v1"
RUNTIME_ID = "custom-echo"
VERSION = "2026.11.02-split.1"
TOKEN = os.environ.get("VELUM_RUNTIME_TOKEN", "")
MODEL = "custom-echo"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, message, *args):
        print(message % args, file=sys.stderr)

    def send_json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        if hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + TOKEN):
            return True
        self.close_connection = True
        self.send_json({"error": {"message": "Unauthorized", "type": "authentication_error"}}, 401)
        return False

    def do_GET(self):
        if not self.authorized():
            return
        if self.path == "/health":
            self.send_json({"status": "ok", "protocol": PROTOCOL, "runtime_id": RUNTIME_ID,
                            "version": VERSION, "pid": os.getpid(), "loaded": {"chat": MODEL},
                            "active_request": None, "jobs": []})
        elif self.path == "/v1/models":
            self.send_json({"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "local", "capability": "chat", "status": "loaded"}]})
        else:
            self.send_json({"error": {"message": "Unknown endpoint"}}, 404)

    def do_POST(self):
        if not self.authorized():
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 8 * 1024 * 1024:
                raise ValueError("Invalid request size")
            data = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(data, dict):
                raise ValueError("Request must be an object")
            if self.path == "/control/shutdown":
                self.send_json({"status": "stopping"})
                self.server.stop.set()
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            elif self.path in ("/control/load", "/control/unload", "/control/cancel"):
                self.send_json({"status": "ok", "model": MODEL})
            elif self.path == "/v1/chat/completions":
                messages = data.get("messages")
                if not isinstance(messages, list) or not messages:
                    raise ValueError("messages must be a nonempty array")
                if data.get("model", MODEL) != MODEL:
                    self.send_json({"error": {"message": "Unknown model"}}, 404)
                    return
                text = "Echo: " + str(messages[-1].get("content", ""))
                base = {"id": "chatcmpl-" + uuid.uuid4().hex, "created": int(time.time()), "model": MODEL}
                if data.get("stream"):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.close_connection = True
                    for delta, finish in [({"role": "assistant"}, None), ({"content": text}, None), ({}, "stop")]:
                        chunk = {**base, "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                        self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                else:
                    self.send_json({**base, "object": "chat.completion", "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}]})
            else:
                self.send_json({"error": {"message": "Unsupported endpoint"}}, 404)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except (ValueError, TypeError, KeyError) as error:
            self.send_json({"error": {"message": str(error), "type": "invalid_request_error"}}, 400)


def main():
    if len(TOKEN) < 24:
        raise SystemExit("VELUM_RUNTIME_TOKEN must contain at least 24 characters")
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    parent = int(os.environ.get("VELUM_RUNTIME_PARENT_PID", os.getppid()))
    if parent < 2 or parent != os.getppid():
        raise SystemExit("VELUM_RUNTIME_PARENT_PID must match the launching parent process")
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.stop = threading.Event()

    def stop(*_):
        server.stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    def monitor():
        while not server.stop.wait(0.25):
            if os.getppid() != parent:
                stop()
                return

    threading.Thread(target=monitor, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(json.dumps({"event": "ready", "protocol": PROTOCOL, "host": "127.0.0.1", "port": server.server_port,
                      "pid": os.getpid(), "runtime_id": RUNTIME_ID, "version": VERSION}), flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.stop.set()
        server.server_close()


if __name__ == "__main__":
    main()
