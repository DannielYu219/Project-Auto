"""Velum authenticated Splash adapter; shared CPython, official native Metal engine.

No model downloads occur at startup, load, or chat. Only /control/download prepares
an explicitly chosen, pinned, size-bounded official model and compatible draft.
"""
from __future__ import annotations
import argparse
import contextlib
import hashlib
import hmac
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
from pathlib import Path
import re
import select
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "site-packages"), str(ROOT)]
PROTOCOL, RUNTIME_ID, VERSION = "velum.local-ai.v1", "splash", "1.5.0-velum.2"
TOKEN = os.environ.get("VELUM_RUNTIME_TOKEN", "")
MODELS = Path(os.environ.get("VELUM_MODELS_DIR", ROOT.parent / "Models")).expanduser().resolve()
LOG = logging.getLogger("velum.splash")
MAX_BODY = 8 * 1024 * 1024
# The native engine supports these model families, not arbitrary MLX/HF models.
# Catalog pins both independently released sources; no floating draft branch.
CATALOG = [{"repo": "prism-ml/Ternary-Bonsai-2-27B-gguf", "variant": "PQ2_0",
    "revision": "94dd51cdbbec5309ed8b76a12f3268bc4fdceb93", "capability": "chat",
    "draft_repo": "incoai/Qwen3.8-27B-DFlash2",
    "draft_revision": "015e795645c74b1a0eeef3b570031fb62e769bc5",
    "estimated_download_bytes": 11060000000, "language_only": True}]


class RequestError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def child_environment():
    env = dict(os.environ, VELUM_MODELS_DIR=str(MODELS), PYTHONDONTWRITEBYTECODE="1",
        HF_HOME=str(MODELS / ".hub"), HF_HUB_DISABLE_XET="1", HF_HUB_DISABLE_TELEMETRY="1",
        TOKENIZERS_PARALLELISM="false", TRANSFORMERS_VERBOSITY="error")
    # Never embed a development proxy in a delivered engine. Explicit broker
    # configuration only; internal loopback traffic never uses any proxy.
    proxy = env.get("VELUM_DOWNLOAD_PROXY", "").strip()
    if proxy:
        from urllib.parse import urlsplit
        parsed = urlsplit(proxy)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise RequestError("VELUM_DOWNLOAD_PROXY must be an HTTP(S) proxy URL")
        for key in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
            env[key] = proxy
    for key in ("NO_PROXY", "no_proxy"):
        env[key] = ",".join(dict.fromkeys([*env.get(key, "").split(","), "127.0.0.1", "localhost"]))
    # Keep user data out of the immutable engine package.
    env["SPLASH_THINKING_KEY_FILE"] = str(MODELS / ".runtime/thinking.key")
    return env


def command(module, *args):
    return [sys.executable, "-I", "-B", str(ROOT / "service/upstream.py"), module, *map(str, args)]


def terminate(process):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=4)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=4)
    # The official frontend may exit before its native child has finished.
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)


class Runtime:
    def __init__(self):
        MODELS.mkdir(parents=True, exist_ok=True)
        (MODELS / ".runtime").mkdir(exist_ok=True)
        self.guard = threading.RLock()
        self.inference = threading.Lock()
        self.stop = threading.Event()
        self.cancel = threading.Event()
        self.process = None
        self.port = None
        self.loaded = None
        self.active = None
        self.jobs = {}
        self.downloads = {}
        self.import_process = None
        self.registry = MODELS / "splash-models.json"
        self.models = json.loads(self.registry.read_text()).get("models", []) if self.registry.exists() else []
        check = subprocess.run([str(ROOT / "engine/splash"), "device-check"], capture_output=True, text=True, timeout=30)
        if check.returncode:
            raise RuntimeError("Splash requires Apple M3+ and macOS26.4+: " + check.stderr.strip())
        self.device = {"status": "supported", "native_exit_code": check.returncode}

    def health(self):
        with self.guard:
            if self.process and self.process.poll() is not None:
                self.loaded = None
            return {"status": "stopping" if self.stop.is_set() else "ok", "protocol": PROTOCOL,
                "runtime_id": RUNTIME_ID, "version": VERSION, "pid": os.getpid(),
                "loaded": {"chat": self.loaded["id"]} if self.loaded else {},
                "active_request": self.active, "jobs": list(self.jobs.values()), "device": self.device,
                "capabilities": ["chat", "download"], "catalog": CATALOG}

    def descriptor(self, model):
        return {**model, "object": "model", "owned_by": "splash",
            "status": "loaded" if self.loaded and self.loaded["id"] == model["id"] else "installed"}

    def registered(self, identifier):
        from install import assembly
        matches = [m for m in self.models if identifier in (m["id"], m["repo"], m["selection"])]
        if not matches:
            raise RequestError("Splash model is not installed. Choose an official catalog model and explicitly download its target + DFlash2 draft first.", 404)
        model = matches[-1]
        link = MODELS / model["path"]
        if not link.resolve().is_relative_to(MODELS):
            raise RequestError("Prepared model escapes the configured model store", 409)
        try:
            assembly.verify(link)
        except (OSError, RuntimeError) as error:
            raise RequestError("Prepared Splash model failed verification: " + str(error), 409) from error
        return model, link

    def unload(self):
        with self.guard:
            process, self.process = self.process, None
            self.loaded, self.port = None, None
        terminate(process)

    def load(self, identifier, capability="chat", disconnected=lambda: False):
        if capability != "chat":
            raise RequestError("Splash supports chat only; embeddings are unsupported", 422)
        model, link = self.registered(identifier)
        if self.loaded and self.loaded["id"] == model["id"] and self.process.poll() is None:
            return self.descriptor(model)
        self.unload()
        env = child_environment()
        env["HF_HUB_OFFLINE"] = "1"
        # Port zero is chosen by the official server itself, not reserve/rebind.
        args = command("server.server", link, "--model", model["selection"], "--binary", ROOT / "engine/splash",
            "--host", "127.0.0.1", "--port", 0, "--no-webui", "--max-context", 4096,
            "--max-cache-disk", 0)
        env["SPLASH_API_KEY"] = TOKEN
        process = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1, start_new_session=True)
        self.process = process
        ready = threading.Event()
        lines = []
        def read_output():
            for line in process.stdout:
                LOG.info("upstream: %s", line.rstrip())
                lines.append(line.rstrip())
                del lines[:-20]
                match = re.search(r"Ready .*http://127\.0\.0\.1:(\d+)", line)
                if match:
                    self.port = int(match.group(1))
                    ready.set()
        threading.Thread(target=read_output, daemon=True).start()
        deadline = time.monotonic() + 240
        while not ready.wait(0.1):
            if self.stop.is_set() or self.cancel.is_set() or disconnected():
                self.unload()
                raise RequestError("Splash model loading cancelled", 409)
            if process.poll() is not None or time.monotonic() > deadline:
                self.unload()
                raise RequestError("Official Splash server did not become ready: " + " | ".join(lines[-6:]), 503)
        self.loaded = model
        return self.descriptor(model)

    def import_local(self, data, disconnected=lambda: False):
        from service.local_import import validate, ImportErrorDetail
        from install import assembly
        try:
            target, draft, mmproj, display_name = validate(data, MODELS)
        except ImportErrorDetail as error:
            raise RequestError(str(error), error.status) from error
        env = child_environment()
        env.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
        payload = {**data, "target": str(target), "draft": str(draft), "mmproj": str(mmproj) if mmproj else None}
        with contextlib.ExitStack() as stack:
            output = stack.enter_context(__import__("tempfile").TemporaryFile(mode="w+"))
            process = subprocess.Popen(command("velum.local_import"), env=env, stdin=subprocess.PIPE,
                stdout=output, stderr=sys.stderr, text=True, start_new_session=True)
            self.import_process = process
            try:
                process.stdin.write(json.dumps(payload))
                process.stdin.close()
                deadline = time.monotonic() + 600
                while process.poll() is None:
                    if self.stop.is_set() or self.cancel.is_set() or disconnected():
                        raise RequestError("Local model import cancelled", 409)
                    if time.monotonic() > deadline:
                        raise RequestError("Local model import exceeded 600 seconds", 504)
                    self.stop.wait(0.1)
                output.seek(0)
                try:
                    result = json.loads(output.read())
                except ValueError as error:
                    raise RequestError("Official local preparation did not return a valid result", 422) from error
                if process.returncode or "error" in result:
                    raise RequestError(result.get("error", "Official local preparation failed"), result.get("status", 422))
            finally:
                self.import_process = None
                terminate(process)
        prepared = Path(result["prepared"])
        if not prepared.resolve().is_relative_to(MODELS):
            raise RequestError("Prepared local model escapes managed store", 403)
        record = assembly.verify(prepared)
        revision = hashlib.sha256((prepared / "model.json").read_bytes()).hexdigest()[:40]
        slug = re.sub(r"[^A-Za-z0-9-]+", "-", display_name).strip("-")[:60] or "model"
        # --model is an official OWNER/REPO identifier; the prepared assembly
        # path is passed separately as MODEL_DIRECTORY by load().
        selection = f"local/{slug}-{revision[:12]}"
        identifier = f"local/{slug}@{revision[:12]}"
        descriptor = {"id": identifier, "repo": selection, "revision": revision,
            "selection": selection, "path": str(prepared.relative_to(MODELS)), "capability": "chat",
            "created": int(time.time()), "display_name": display_name, "source": "local",
            "target": str(target), "draft": str(draft), "mmproj": str(mmproj) if mmproj else None,
            "family": record["family"], "vision": record["vision_format"] != "none"}
        with self.guard:
            existing = next((m for m in self.models if m["id"] == identifier), None)
            if existing:
                descriptor["created"] = existing["created"]
            self.models = [m for m in self.models if m["id"] != identifier] + [descriptor]
            temporary = self.registry.with_suffix(".json.tmp")
            temporary.write_text(json.dumps({"schema_version": 1, "models": self.models}, indent=2) + "\n")
            temporary.replace(self.registry)
        return self.descriptor(descriptor)

    def download(self, data):
        if data.get("capability", "chat") != "chat":
            raise RequestError("Splash supports chat only; embeddings are unsupported", 422)
        repo, revision = data.get("repo", ""), data.get("revision", "")
        variant = data.get("variant", "PQ2_0")
        if ":" in repo:
            repo, variant = repo.rsplit(":", 1)
        spec = next((s for s in CATALOG if (s["repo"], s["variant"], s["revision"]) == (repo, variant, revision)), None)
        if not spec:
            raise RequestError("Unsupported Splash model/revision. /health catalog lists tested official targets and their pinned compatible drafts.", 422)
        if data.get("max_download_bytes", 15000000000) < spec["estimated_download_bytes"]:
            raise RequestError("Target + required DFlash2 draft exceed the requested download budget", 413)
        identifier = f"{repo}:{variant}@{revision}"
        with self.guard:
            for job in self.jobs.values():
                if job["model"] == identifier and job["status"] in ("queued", "downloading", "verifying"):
                    return dict(job)
            job = {"job_id": str(uuid.uuid4()), "model": identifier, **spec, "status": "queued",
                "started_at": int(time.time()), "downloaded_bytes": 0}
            self.jobs[job["job_id"]] = job
        threading.Thread(target=self._download, args=(job,), daemon=True).start()
        return dict(job)

    def _download(self, job):
        process = None
        try:
            selection = f"{job['repo']}:{job['variant']}"
            env = child_environment()
            env.update(VELUM_SPLASH_DRAFT_REPO=job["draft_repo"], VELUM_SPLASH_DRAFT_REVISION=job["draft_revision"])
            args = command("install.models", "--models", MODELS, "--model", selection, "--revision", job["revision"],
                "--language-only", "prepare", "--json-progress")
            job["status"] = "downloading"
            process = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1, start_new_session=True)
            with self.guard:
                self.downloads[job["job_id"]] = process
            progress, tail = {}, []
            for line in process.stdout:
                if self.stop.is_set() or job["status"] == "cancelled":
                    terminate(process)
                    break
                LOG.info("prepare: %s", line.rstrip())
                tail.append(line.rstrip())
                del tail[:-8]
                try:
                    event = json.loads(line)
                    if event.get("event") == "download":
                        progress[event["repo"]] = event["done"]
                        job["downloaded_bytes"] = sum(progress.values())
                except (ValueError, KeyError):
                    pass
            code = process.wait()
            if self.stop.is_set() or job["status"] == "cancelled":
                job["status"] = "cancelled"
                return
            if code:
                raise RuntimeError("Official model preparation failed: " + " | ".join(tail))
            job["status"] = "verifying"
            from install import models, assembly
            link = models.selection_link(MODELS, selection, revision=job["revision"], language_only=True)
            record = assembly.verify(link, full=True)
            if record["sources"]["draft"]["revision"] != job["draft_revision"]:
                raise RuntimeError("Prepared draft does not match the pinned revision")
            descriptor = {"id": job["model"], "repo": job["repo"], "revision": job["revision"],
                "capability": "chat", "selection": selection, "path": str(link.relative_to(MODELS)),
                "created": int(time.time()), "draft_repo": job["draft_repo"], "draft_revision": job["draft_revision"]}
            with self.guard:
                self.models = [m for m in self.models if m["id"] != descriptor["id"]] + [descriptor]
                temporary = self.registry.with_suffix(".json.tmp")
                temporary.write_text(json.dumps({"schema_version": 1, "models": self.models}, indent=2) + "\n")
                temporary.replace(self.registry)
            job["status"] = "completed"
        except Exception as error:
            LOG.exception("Splash preparation failed")
            job.update(status="cancelled" if self.stop.is_set() else "failed", error=str(error))
        finally:
            terminate(process)
            with self.guard:
                self.downloads.pop(job["job_id"], None)
            job["finished_at"] = int(time.time())

    def close(self):
        self.stop.set()
        self.cancel.set()
        self.unload()
        terminate(self.import_process)
        with self.guard:
            processes = list(self.downloads.values())
            for job in self.jobs.values():
                if job["status"] in ("queued", "downloading", "verifying"):
                    job["status"] = "cancelled"
        for process in processes:
            terminate(process)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "VelumSplash/1"

    def log_message(self, fmt, *args):
        LOG.info(fmt, *args)

    @property
    def runtime(self):
        return self.server.runtime

    def send_json(self, value, status=200):
        raw = json.dumps(value, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def authorized(self):
        values = self.headers.get_all("Authorization", [])
        if len(values) != 1 or not hmac.compare_digest(values[0], f"Bearer {TOKEN}"):
            self.close_connection = True
            self.send_json({"error": {"message": "Unauthorized", "type": "authentication_error"}}, 401)
            return False
        if self.headers.get("Origin"):
            self.send_json({"error": {"message": "Browser origins are not accepted", "type": "authentication_error"}}, 403)
            return False
        return True

    def fail(self, error):
        status = error.status if isinstance(error, RequestError) else 400 if isinstance(error, (ValueError, TypeError)) else 500
        self.send_json({"error": {"message": str(error), "type": "invalid_request_error" if status < 500 else "runtime_error"}}, status)

    def do_GET(self):
        if not self.authorized():
            return
        try:
            if self.path == "/health":
                self.send_json(self.runtime.health())
            elif self.path == "/v1/models":
                self.send_json({"object": "list", "data": [self.runtime.descriptor(m) for m in self.runtime.models]})
            elif self.path.startswith("/control/jobs/"):
                job = self.runtime.jobs.get(self.path.rsplit("/", 1)[-1])
                if job is None:
                    raise RequestError("Unknown job", 404)
                self.send_json(dict(job))
            else:
                raise RequestError("Unknown endpoint", 404)
        except Exception as error:
            self.fail(error)

    def disconnected(self):
        if self.runtime.stop.is_set() or self.runtime.cancel.is_set():
            return True
        ready, _, _ = select.select([self.connection], [], [], 0)
        if ready:
            try:
                return not self.connection.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT)
            except OSError:
                return False
        return False

    def do_POST(self):
        if not self.authorized():
            return
        try:
            if self.headers.get("Transfer-Encoding"):
                raise RequestError("Chunked request bodies are unsupported", 400)
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= MAX_BODY:
                raise RequestError("Request body too large", 413)
            data = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(data, dict):
                raise RequestError("Request must be a JSON object")
            if self.path == "/control/download":
                self.send_json(self.runtime.download(data), 202)
                return
            if self.path == "/control/shutdown":
                self.runtime.stop.set()
                self.runtime.cancel.set()
                self.send_json({"status": "stopping"})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            if self.path == "/control/cancel":
                self.runtime.cancel.set()
                # Stopping upstream guarantees cancellation even before its HTTP
                # listener is ready; next chat loads the selected model again.
                self.runtime.unload()
                terminate(self.runtime.import_process)
                for job_id, process in list(self.runtime.downloads.items()):
                    self.runtime.jobs[job_id]["status"] = "cancelled"
                    terminate(process)
                self.send_json({"status": "cancelling"})
                return
            if self.path == "/v1/embeddings":
                raise RequestError("Splash does not provide embeddings", 422)
            if self.path not in ("/control/import", "/control/load", "/control/unload", "/v1/chat/completions"):
                raise RequestError("Unknown endpoint", 404)
            if not self.runtime.inference.acquire(False):
                raise RequestError("Runtime is busy", 409)
            try:
                self.runtime.cancel.clear()
                self.runtime.active = {"id": str(uuid.uuid4()), "endpoint": self.path, "started_at": int(time.time())}
                if self.path == "/control/unload":
                    if data.get("capability", "chat") not in (None, "chat"):
                        raise RequestError("Splash supports chat only", 422)
                    self.runtime.unload()
                    self.send_json({"status": "unloaded", "loaded": []})
                elif self.path == "/control/import":
                    self.send_json(self.runtime.import_local(data, self.disconnected))
                elif self.path == "/control/load":
                    self.send_json(self.runtime.load(data.get("model"), data.get("capability", "chat"), self.disconnected))
                else:
                    self.chat(data)
            finally:
                self.runtime.active = None
                self.runtime.inference.release()
        except (BrokenPipeError, ConnectionResetError):
            self.runtime.unload()
            self.close_connection = True
        except Exception as error:
            LOG.exception("Splash request failed")
            if getattr(self, "response_started", False):
                self.close_connection = True
            else:
                self.fail(error)

    def chat(self, data):
        identifier = data.get("model") or (self.runtime.loaded or {}).get("id")
        self.runtime.load(identifier, disconnected=self.disconnected)
        body = {**data, "model": self.runtime.loaded["selection"]}
        connection = http.client.HTTPConnection("127.0.0.1", self.runtime.port, timeout=300)
        finished = threading.Event()
        def watch_client():
            while not finished.wait(0.1):
                if self.disconnected():
                    # Interrupt a blocking nonstream read as well as SSE. The
                    # official server then observes its client disconnect and
                    # cancels native generation rather than burning GPU time.
                    if connection.sock:
                        with contextlib.suppress(OSError):
                            connection.sock.shutdown(socket.SHUT_RDWR)
                    connection.close()
                    return
        threading.Thread(target=watch_client, daemon=True).start()
        try:
            connection.request("POST", "/v1/chat/completions", json.dumps(body),
                {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
            response = connection.getresponse()
            self.send_response(response.status)
            self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.response_started = True
            self.close_connection = True
            # Upstream monitors its client disconnect; forward SSE incrementally.
            if data.get("stream"):
                while not self.disconnected():
                    chunk = response.readline()
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            else:
                self.wfile.write(response.read())
                self.wfile.flush()
        finally:
            finished.set()
            connection.close()


def main():
    if len(TOKEN) < 24:
        raise SystemExit("VELUM_RUNTIME_TOKEN must contain at least 24 characters")
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(levelname)s %(message)s")
    parent = int(os.environ.get("VELUM_RUNTIME_PARENT_PID", os.getppid()))
    if parent < 2 or parent != os.getppid():
        raise SystemExit("VELUM_RUNTIME_PARENT_PID must match the launching parent process")
    runtime = Runtime()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.runtime = runtime
    def stop():
        runtime.stop.set()
        runtime.cancel.set()
        server.shutdown()
    def monitor():
        while not runtime.stop.wait(0.25):
            if os.getppid() != parent:
                LOG.info("Launching parent exited; stopping Splash and native children")
                stop()
                return
    threading.Thread(target=monitor, daemon=True).start()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: threading.Thread(target=stop, daemon=True).start())
    print(json.dumps({"event": "ready", "protocol": PROTOCOL, "host": "127.0.0.1", "port": server.server_port,
        "pid": os.getpid(), "runtime_id": RUNTIME_ID, "version": VERSION}), flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        runtime.close()
        server.server_close()


if __name__ == "__main__":
    main()
