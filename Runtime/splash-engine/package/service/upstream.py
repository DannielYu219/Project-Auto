"""Isolated bootstrap for unmodified official Splash Python modules (no interpreter bundled)."""
from pathlib import Path
import os
import runpy
import signal
import sys
import threading

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "site-packages"), str(ROOT)]
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"


def main():
    parent = os.getppid()
    def watch_parent():
        while True:
            threading.Event().wait(0.25)
            if os.getppid() != parent:
                # Each bootstrap is spawned in its own process group; native engine
                # and any download workers must never survive their owning wrapper.
                os.killpg(os.getpgrp(), signal.SIGKILL)
    threading.Thread(target=watch_parent, daemon=True).start()
    from install import paths
    paths.PYTHON = Path(sys.executable)
    paths.BINARY = ROOT / "engine/splash"
    paths.MODELS = Path(os.environ["VELUM_MODELS_DIR"])
    paths.RUNTIME = paths.MODELS / ".runtime"
    paths.RUNTIME.mkdir(parents=True, exist_ok=True)
    # Some explicitly configured proxies strip Content-Length from HEAD. The
    # official Hub client then refuses even small config files. Recover only a
    # size from authenticated immutable repository metadata, never infer bytes
    # from an untrusted partial body or change a requested revision.
    from huggingface_hub import file_download, HfApi
    from urllib.parse import urlsplit, unquote
    original_metadata = file_download.get_hf_file_metadata
    def metadata(url, *args, **kwargs):
        value = original_metadata(url, *args, **kwargs)
        if value.size is None and value.commit_hash:
            parts = unquote(urlsplit(url).path).strip("/").split("/")
            if len(parts) >= 5 and parts[2] == "resolve":
                repo, filename = "/".join(parts[:2]), "/".join(parts[4:])
                info = HfApi().model_info(repo, revision=value.commit_hash, files_metadata=True, timeout=45)
                entry = next((f for f in info.siblings if f.rfilename == filename), None)
                if info.sha == value.commit_hash and entry and entry.size is not None:
                    from dataclasses import replace
                    value = replace(value, size=entry.size)
        return value
    file_download.get_hf_file_metadata = metadata
    module = sys.argv.pop(1)
    if module == "velum.local_import":
        from service.local_import import main
        try:
            main()
        except Exception as error:
            import json
            print(json.dumps({"error": str(error), "status": getattr(error, "status", 422)}), flush=True)
            raise SystemExit(1)
        return
    if module not in ("install.models", "install.local", "server.server", "server.document_worker"):
        raise SystemExit("Unsupported official module")
    if module == "install.models" and os.environ.get("VELUM_SPLASH_DRAFT_REVISION"):
        from install import hub
        hub.HUB_TIMEOUT = 45
        original = hub.Repository.resolve.__func__
        def pinned(cls, name, revision=None, **kwargs):
            if name == os.environ.get("VELUM_SPLASH_DRAFT_REPO"):
                revision = os.environ["VELUM_SPLASH_DRAFT_REVISION"]
            return original(cls, name, revision, **kwargs)
        hub.Repository.resolve = classmethod(pinned)
    if module == "server.server":
        # PDF subprocesses also need the explicit package paths under -I.
        from server import thinking
        original_key = thinking.load_thinking_key
        thinking.load_thinking_key = lambda path=None: original_key(path or paths.RUNTIME / "thinking.key")
        from server import document_worker
        original_render = document_worker.subprocess.Popen
        def spawn(command, **kwargs):
            if command[:3] == [sys.executable, "-m", "server.document_worker"]:
                command = [sys.executable, "-I", "-B", str(Path(__file__).resolve()), "server.document_worker", *command[3:]]
            return original_render(command, **kwargs)
        document_worker.subprocess.Popen = spawn
    if module == "install.models":
        # Import by its canonical name: its own CLI otherwise re-imports this
        # module after runpy, which obscures exception identity and emits noise.
        from install import models
        status = models.main(sys.argv[1:])
        if status == 130:
            os._exit(status)
        raise SystemExit(status)
    runpy.run_module(module, run_name="__main__", alter_sys=True)


if __name__ == "__main__":
    main()
