"""Velum local MLX service. The network adapter uses Python's standard library only."""
from __future__ import annotations

import argparse
import base64
import contextlib
import gc
import hashlib
import hmac
import json
import logging
import os
from pathlib import Path
import re
import select
import signal
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import time
import uuid
import sys

PROTOCOL = "velum.local-ai.v1"
RUNTIME_ID = "mlx"
VERSION = "2026.11.02-split.1"
ROOT = Path(__file__).resolve().parents[1]
# Isolated mode ignores PYTHONPATH: authorize only this engine package path.
sys.path.insert(0, str(ROOT / "site-packages"))
MODELS = Path(os.environ.get("VELUM_MODELS_DIR", ROOT.parent / "Models")).expanduser().resolve()
TOKEN = os.environ.get("VELUM_RUNTIME_TOKEN", "")
download_proxy = os.environ.get("VELUM_DOWNLOAD_PROXY", "").strip()
if download_proxy:
    from urllib.parse import urlsplit
    parsed_proxy = urlsplit(download_proxy)
    if parsed_proxy.scheme not in ("http", "https") or not parsed_proxy.hostname:
        raise SystemExit("VELUM_DOWNLOAD_PROXY must be an HTTP(S) proxy URL")
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
        os.environ[key] = download_proxy
# An unset proxy means direct networking. Broker-supplied HTTP(S)_PROXY is preserved.
for key in ("NO_PROXY", "no_proxy"):
    bypass = [item.strip() for item in os.environ.get(key, "").split(",") if item.strip()]
    os.environ[key] = ",".join(dict.fromkeys([*bypass, "127.0.0.1", "localhost"]))
os.environ["HF_HUB_DISABLE_XET"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ["HF_HOME"] = str(MODELS / ".hub")
os.environ["HF_ENDPOINT"] = "https://huggingface.co"
LOG = logging.getLogger("velum.runtime")
MAX_BODY = 8 * 1024 * 1024


class RequestError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


class Runtime:
    def __init__(self):
        MODELS.mkdir(parents=True, exist_ok=True)
        self.guard = threading.RLock()
        self.inference = threading.Lock()
        self.loaded = {}
        self.jobs = {}
        self.active = None
        self.stop = threading.Event()
        self.cancel = threading.Event()
        self.registry = MODELS / "models.json"
        self.models = json.loads(self.registry.read_text()).get("models", []) if self.registry.exists() else []

    def descriptor(self, model):
        return {**model, "object": "model", "owned_by": "local", "status": "loaded" if model["id"] in [x["descriptor"]["id"] for x in self.loaded.values()] else "installed"}

    def health(self):
        with self.guard:
            return {"status": "stopping" if self.stop.is_set() else "ok", "protocol": PROTOCOL,
                    "runtime_id": RUNTIME_ID, "version": VERSION, "pid": os.getpid(),
                    "loaded": {k: v["descriptor"]["id"] for k, v in self.loaded.items()},
                    "active_request": self.active, "jobs": list(self.jobs.values())}

    def registered(self, identifier, capability):
        with self.guard:
            matches = [m for m in self.models if identifier in (m["id"], m["repo"]) and m["capability"] == capability]
        if not matches:
            raise RequestError("Model is not installed for this capability", 404)
        m = matches[-1]
        path = (MODELS / m["path"]).resolve()
        if not path.is_relative_to(MODELS) or not (path / "config.json").is_file():
            raise RequestError("Registered model files are missing or invalid", 409)
        return m, path

    def load(self, identifier, capability):
        if capability not in ("chat", "embeddings"):
            raise RequestError("capability must be chat or embeddings")
        descriptor, path = self.registered(identifier, capability)
        current = self.loaded.get(capability)
        if current and current["descriptor"]["id"] == descriptor["id"]:
            return self.descriptor(descriptor)
        # One loaded model across all capabilities; release old references before allocation.
        self.loaded.clear()
        current = None
        gc.collect()
        import mlx.core as mx
        mx.clear_cache()
        LOG.info("Loading %s at pinned revision %s", descriptor["repo"], descriptor["revision"])
        # All library output is redirected away from the machine-readable stdout channel.
        with contextlib.redirect_stdout(__import__("sys").stderr):
            if capability == "chat":
                from mlx_lm import load
                model, tokenizer = load(str(path), tokenizer_config={"trust_remote_code": False})
            else:
                from mlx_vlm.embedding_loader import load_embedding_model
                from transformers import AutoTokenizer
                model = load_embedding_model(path)
                tokenizer = AutoTokenizer.from_pretrained(path, trust_remote_code=False, local_files_only=True)
        self.loaded[capability] = {"descriptor": descriptor, "model": model, "tokenizer": tokenizer, "path": path}
        return self.descriptor(descriptor)

    def selected(self, data, capability):
        identifier = data.get("model")
        current = self.loaded.get(capability)
        if not identifier and current:
            return current
        if not identifier:
            raise RequestError("model is required when no model is loaded")
        current = None
        self.load(identifier, capability)
        return self.loaded[capability]

    def download(self, data):
        repo, revision, capability = data.get("repo", ""), data.get("revision", ""), data.get("capability", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise RequestError("repo must be an owner/name Hugging Face model repository")
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise RequestError("revision must be a pinned 40-character lowercase commit SHA")
        if capability not in ("chat", "embeddings"):
            raise RequestError("capability must be chat or embeddings")
        identifier = f"{repo}@{revision}"
        with self.guard:
            for job in self.jobs.values():
                if job["model"] == identifier and job["status"] in ("queued", "downloading", "verifying"):
                    return dict(job)
            job_id = str(uuid.uuid4())
            job = {"job_id": job_id, "model": identifier, "repo": repo, "revision": revision,
                   "capability": capability, "status": "queued", "started_at": int(time.time()), "downloaded_bytes": 0}
            self.jobs[job_id] = job
        threading.Thread(target=self._download, args=(job,), daemon=True, name=f"download-{job_id}").start()
        return dict(job)

    def _download(self, job):
        try:
            from huggingface_hub import snapshot_download
            relative = Path(job["repo"].replace("/", "--")) / job["revision"]
            path = MODELS / relative
            job["status"] = "downloading"
            # Data-only artifacts. Model repository Python is never downloaded or executed.
            snapshot_download(repo_id=job["repo"], revision=job["revision"], local_dir=path,
                              allow_patterns=["*.json", "*.safetensors", "*.model", "*.tiktoken", "*.txt", "*.jinja", "*.md", "LICENSE*"],
                              max_workers=4)
            job["status"] = "verifying"
            if not (path / "config.json").is_file() or not list(path.glob("*.safetensors")):
                raise ValueError("Downloaded repository does not contain config.json and safetensors weights")
            files = []
            for f in sorted(path.rglob("*")):
                if not f.is_file() or ".cache" in f.parts or f.name == "velum-model.json":
                    continue
                with f.open("rb") as stream:
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                files.append({"path": str(f.relative_to(path)), "size": f.stat().st_size, "sha256": digest})
                job["downloaded_bytes"] += f.stat().st_size
            descriptor = {"id": job["model"], "repo": job["repo"], "revision": job["revision"],
                          "capability": job["capability"], "path": str(relative), "created": int(time.time()),
                          "manifest": str(relative / "velum-model.json")}
            (path / "velum-model.json").write_text(json.dumps({"schema_version": 1, **descriptor, "files": files}, indent=2) + "\n")
            with self.guard:
                self.models = [m for m in self.models if m["id"] != descriptor["id"]] + [descriptor]
                temp = self.registry.with_suffix(".json.tmp")
                temp.write_text(json.dumps({"schema_version": 1, "models": self.models}, indent=2) + "\n")
                temp.replace(self.registry)
            job["status"] = "completed"
        except Exception as error:
            LOG.exception("Model download failed")
            job.update(status="failed", error=str(error))
        finally:
            job["finished_at"] = int(time.time())


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "VelumMLX/1"

    def log_message(self, message, *args):
        LOG.info(message, *args)

    @property
    def runtime(self):
        return self.server.runtime

    def send_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        supplied = self.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied, f"Bearer {TOKEN}"):
            self.close_connection = True
            self.send_json({"error": {"message": "Unauthorized", "type": "authentication_error"}}, 401)
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        try:
            if self.path == "/health":
                self.send_json(self.runtime.health())
            elif self.path == "/v1/models":
                with self.runtime.guard:
                    self.send_json({"object": "list", "data": [self.runtime.descriptor(m) for m in self.runtime.models]})
            elif self.path.startswith("/control/jobs/"):
                job = self.runtime.jobs.get(self.path.rsplit("/", 1)[-1])
                if job is None:
                    raise RequestError("Unknown job", 404)
                self.send_json(dict(job))
            else:
                raise RequestError("Unknown endpoint", 404)
        except RequestError as error:
            self.send_json({"error": {"message": str(error), "type": "invalid_request_error"}}, error.status)

    def do_POST(self):
        if not self.authorized():
            return
        streaming = False
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > MAX_BODY:
                raise RequestError("Request body too large", 413)
            data = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(data, dict):
                raise RequestError("Request must be a JSON object")
            if self.path == "/control/download":
                self.send_json(self.runtime.download(data), 202)
                return
            if self.path == "/control/cancel":
                self.runtime.cancel.set()
                self.send_json({"status": "cancelling"})
                return
            if self.path == "/control/shutdown":
                self.runtime.stop.set()
                self.runtime.cancel.set()
                self.send_json({"status": "stopping"})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            if self.path not in ("/control/load", "/control/unload", "/v1/chat/completions", "/v1/embeddings"):
                raise RequestError("Unknown endpoint", 404)
            if not self.runtime.inference.acquire(blocking=False):
                raise RequestError("Runtime is busy", 409)
            try:
                self.runtime.cancel.clear()
                self.runtime.active = {"id": str(uuid.uuid4()), "endpoint": self.path, "started_at": int(time.time())}
                if self.path == "/control/load":
                    self.send_json(self.runtime.load(data.get("model"), data.get("capability", "chat")))
                elif self.path == "/control/unload":
                    capability = data.get("capability")
                    if capability is not None and capability not in ("chat", "embeddings"):
                        raise RequestError("capability must be chat or embeddings")
                    if capability:
                        self.runtime.loaded.pop(capability, None)
                    else:
                        self.runtime.loaded.clear()
                    gc.collect()
                    import mlx.core as mx
                    mx.clear_cache()
                    self.send_json({"status": "unloaded", "loaded": list(self.runtime.loaded)})
                elif self.path == "/v1/embeddings":
                    self.embeddings(data)
                else:
                    streaming = bool(data.get("stream", False))
                    self.chat(data)
            finally:
                self.runtime.active = None
                self.runtime.inference.release()
        except (BrokenPipeError, ConnectionResetError):
            LOG.info("Client disconnected; generation cancelled")
            self.close_connection = True
        except Exception as error:
            LOG.exception("Request failed")
            status = error.status if isinstance(error, RequestError) else 400 if isinstance(error, (ValueError, TypeError, KeyError)) else 500
            payload = {"error": {"message": str(error), "type": "invalid_request_error" if status < 500 else "runtime_error"}}
            if streaming and getattr(self, "sse_started", False):
                self.sse(payload)
                self.sse("[DONE]")
            else:
                self.send_json(payload, status)

    def disconnected(self):
        if self.runtime.stop.is_set() or self.runtime.cancel.is_set():
            return True
        ready, _, _ = select.select([self.connection], [], [], 0)
        if ready:
            try:
                return not self.connection.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT)
            except (BlockingIOError, OSError):
                return False
        return False

    def sse(self, payload):
        text = payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False, allow_nan=False)
        self.wfile.write(f"data: {text}\n\n".encode())
        self.wfile.flush()

    def chat(self, data):
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        loaded = self.runtime.selected(data, "chat")
        messages = data.get("messages")
        if not isinstance(messages, list) or not messages:
            raise RequestError("messages must be a nonempty array")
        tokenizer = loaded["tokenizer"]
        template = dict(data.get("chat_template_kwargs") or {})
        template["tokenize"] = False
        template["add_generation_prompt"] = True
        if data.get("tools"):
            template["tools"] = data["tools"]
        prompt = tokenizer.apply_chat_template(messages, **template)
        max_tokens = int(data.get("max_completion_tokens", data.get("max_tokens", 512)))
        if not 1 <= max_tokens <= 32768:
            raise RequestError("max_tokens must be between 1 and 32768")
        sampler = make_sampler(temp=float(data.get("temperature", 0.7)), top_p=float(data.get("top_p", 0.95)))
        identifier = "chatcmpl-" + uuid.uuid4().hex
        created = int(time.time())
        streaming = bool(data.get("stream", False))
        base = {"id": identifier, "object": "chat.completion.chunk", "created": created, "model": loaded["descriptor"]["id"]}
        if streaming:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            self.sse_started = True
            self.sse({**base, "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]})
        content, reasoning, tool_calls = [], [], []
        parser = ReasoningParser(tokenizer)
        def consume(field, text):
            if field == "tool_call":
                parse = getattr(tokenizer, "tool_parser", None)
                try:
                    parsed = parse(text, data.get("tools")) if parse else None
                    entries = parsed if isinstance(parsed, list) else [parsed] if parsed else []
                    delta_calls = []
                    for entry in entries:
                        entry = dict(entry)
                        arguments = entry.get("arguments", {})
                        if not isinstance(arguments, str):
                            arguments = json.dumps(arguments, ensure_ascii=False)
                        call = {"id": entry.pop("id", None) or "call_" + uuid.uuid4().hex,
                                "type": "function", "function": {"name": entry["name"], "arguments": arguments}}
                        delta_calls.append({"index": len(tool_calls), **call})
                        tool_calls.append(call)
                    if delta_calls and streaming:
                        self.sse({**base, "choices": [{"index": 0, "delta": {"tool_calls": delta_calls}, "finish_reason": None}]})
                    if entries:
                        return
                except (ValueError, KeyError, TypeError):
                    LOG.warning("Unable to parse model tool call; preserving raw text")
                field = "content"
                text = (getattr(tokenizer, "tool_call_start", None) or "<tool_call>") + text + (getattr(tokenizer, "tool_call_end", None) or "</tool_call>")
            (reasoning if field == "reasoning_content" else content).append(text)
            if streaming:
                self.sse({**base, "choices": [{"index": 0, "delta": {field: text}, "finish_reason": None}]})
        if prompt.rstrip().endswith(parser.think_start):
            parser.reasoning = True
        last = None
        cancelled = False
        generator = stream_generate(loaded["model"], tokenizer, prompt=prompt, max_tokens=max_tokens, sampler=sampler)
        try:
            for response in generator:
                last = response
                if self.disconnected():
                    cancelled = True
                    break
                for field, text in parser.feed(response.text):
                    consume(field, text)
        finally:
            generator.close()
        for field, text in parser.feed("", final=True):
            if not cancelled:
                consume(field, text)
        finish = "cancelled" if cancelled else "tool_calls" if tool_calls else "length" if last and last.generation_tokens >= max_tokens else "stop"
        usage = {"prompt_tokens": last.prompt_tokens if last else 0, "completion_tokens": last.generation_tokens if last else 0}
        usage["total_tokens"] = sum(usage.values())
        if streaming:
            if not cancelled:
                self.sse({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}], "usage": usage})
                self.sse("[DONE]")
        else:
            message = {"role": "assistant", "content": "".join(content)}
            if reasoning:
                message["reasoning_content"] = "".join(reasoning)
            if tool_calls:
                message["tool_calls"] = tool_calls
            self.send_json({**base, "object": "chat.completion", "choices": [{"index": 0, "message": message, "finish_reason": finish}], "usage": usage})

    def embeddings(self, data):
        import mlx.core as mx
        loaded = self.runtime.selected(data, "embeddings")
        texts = data.get("input")
        if isinstance(texts, str):
            texts = [texts]
        if not isinstance(texts, list) or not texts or len(texts) > 256 or not all(isinstance(t, str) for t in texts):
            raise RequestError("input must be a string or array of 1–256 strings")
        # Explicit task presets from the model's sentence-transformers configuration.
        task = data.get("task")
        if task:
            presets = json.loads((loaded["path"] / "config_sentence_transformers.json").read_text()).get("prompts", {})
            if task not in presets:
                raise RequestError("Unknown embedding task prefix")
            texts = [presets[task] + text for text in texts]
        encoded = loaded["tokenizer"](texts, padding=True, return_tensors="np")
        vectors = loaded["model"](**{k: mx.array(v) for k, v in encoded.items()}).text_embeds
        dimensions = int(data.get("dimensions", vectors.shape[-1]))
        if dimensions not in (128, 256, 512, 768):
            raise RequestError("dimensions must be 128, 256, 512 or 768")
        vectors = vectors[:, :dimensions]
        vectors = vectors / mx.maximum(mx.linalg.norm(vectors, axis=-1, keepdims=True), 1e-12)
        mx.eval(vectors)
        rows = vectors.tolist()
        encoding = data.get("encoding_format", "float")
        if encoding not in ("float", "base64"):
            raise RequestError("encoding_format must be float or base64")
        if encoding == "base64":
            import struct
            rows = [base64.b64encode(struct.pack("<" + "f" * len(row), *row)).decode() for row in rows]
        tokens = int(encoded.get("attention_mask", encoded["input_ids"]).sum())
        self.send_json({"object": "list", "model": loaded["descriptor"]["id"],
                        "data": [{"object": "embedding", "index": i, "embedding": row} for i, row in enumerate(rows)],
                        "usage": {"prompt_tokens": tokens, "total_tokens": tokens}})


class ReasoningParser:
    """Preserve model-specific reasoning and tool call boundaries across token chunks."""
    def __init__(self, tokenizer=None):
        self.buffer = ""
        self.reasoning = False
        self.tool = False
        self.tool_text = ""
        self.think_start = getattr(tokenizer, "think_start", None) or "<think>"
        self.think_end = getattr(tokenizer, "think_end", None) or "</think>"
        self.tool_start = getattr(tokenizer, "tool_call_start", None) or "<tool_call>"
        self.tool_end = getattr(tokenizer, "tool_call_end", None) or "</tool_call>"

    def feed(self, text, final=False):
        self.buffer += text
        out = []
        while self.buffer:
            tags = [self.tool_end] if self.tool else [self.think_end] if self.reasoning else [self.think_start, self.tool_start]
            found = [(self.buffer.find(tag), tag) for tag in tags if tag in self.buffer]
            if found:
                index, tag = min(found)
                chunk = self.buffer[:index]
                if self.tool:
                    self.tool_text += chunk
                    out.append(("tool_call", self.tool_text))
                    self.tool_text = ""
                    self.tool = False
                else:
                    if chunk:
                        out.append(("reasoning_content" if self.reasoning else "content", chunk))
                    if tag == self.tool_start:
                        self.tool = True
                    else:
                        self.reasoning = not self.reasoning
                self.buffer = self.buffer[index + len(tag):]
                continue
            keep = 0
            if not final:
                for tag in tags:
                    for length in range(1, min(len(tag), len(self.buffer) + 1)):
                        if self.buffer.endswith(tag[:length]):
                            keep = max(keep, length)
            emit = self.buffer[:-keep] if keep else self.buffer
            if self.tool:
                self.tool_text += emit
            elif emit:
                out.append(("reasoning_content" if self.reasoning else "content", emit))
            self.buffer = self.buffer[-keep:] if keep else ""
            break
        if final and self.tool_text:
            out.append(("tool_call", self.tool_text))
            self.tool_text = ""
        return out


def main():
    if len(TOKEN) < 24:
        raise SystemExit("VELUM_RUNTIME_TOKEN must contain at least 24 characters")
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, stream=__import__("sys").stderr, format="%(asctime)s %(levelname)s %(message)s")
    runtime = Runtime()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.runtime = runtime
    parent_pid = int(os.environ.get("VELUM_RUNTIME_PARENT_PID", os.getppid()))
    if parent_pid < 2 or parent_pid != os.getppid():
        server.server_close()
        raise SystemExit("VELUM_RUNTIME_PARENT_PID must match the launching parent process")
    def monitor_parent():
        while not runtime.stop.wait(0.25):
            if os.getppid() != parent_pid:
                LOG.info("Launching parent exited; stopping runtime")
                runtime.stop.set()
                runtime.cancel.set()
                server.shutdown()
                return
    threading.Thread(target=monitor_parent, daemon=True, name="parent-monitor").start()
    def stop(signum, frame):
        runtime.stop.set()
        runtime.cancel.set()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(json.dumps({"event": "ready", "protocol": PROTOCOL, "host": "127.0.0.1", "port": server.server_port,
                      "pid": os.getpid(), "runtime_id": RUNTIME_ID, "version": VERSION}), flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        runtime.stop.set()
        runtime.cancel.set()
        server.server_close()
        LOG.info("Runtime stopped")


if __name__ == "__main__":
    main()
