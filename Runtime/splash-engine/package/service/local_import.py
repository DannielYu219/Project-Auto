"""Managed local-file preparation using Splash's stable public API only."""
from __future__ import annotations
import contextlib
import json
import os
from pathlib import Path
import stat
import sys


class ImportErrorDetail(ValueError):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def managed_path(value, root, label):
    if not isinstance(value, str) or not value or '\x00' in value:
        raise ImportErrorDetail(f"{label} must be a nonempty absolute managed path")
    raw = Path(value)
    if not raw.is_absolute() or '..' in raw.parts:
        raise ImportErrorDetail(f"{label} must be absolute and cannot contain ..")
    if not raw.is_relative_to(root):
        raise ImportErrorDetail(f"{label} must be inside VELUM_MODELS_DIR", 403)
    try:
        resolved = raw.resolve(strict=True)
    except FileNotFoundError:
        raise ImportErrorDetail(f"{label} does not exist", 404) from None
    except (OSError, RuntimeError):
        raise ImportErrorDetail(f"{label} cannot be resolved safely", 403) from None
    if not resolved.is_relative_to(root):
        raise ImportErrorDetail(f"{label} symlink escapes VELUM_MODELS_DIR", 403)
    mode = resolved.stat().st_mode
    if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
        raise ImportErrorDetail(f"{label} must be a regular file or directory", 422)
    return raw


def check_tree(directory, root, label):
    # Official directory discovery is recursive. Validate every discovered link
    # before handing it to upstream, including shard paths from JSON indexes.
    pending, count = [directory], 0
    while pending:
        current = pending.pop()
        for item in current.iterdir():
            count += 1
            if count > 20000:
                raise ImportErrorDetail(f"{label} contains too many entries", 422)
            managed_path(str(item), root, label)
            if item.is_dir():
                if item.is_symlink():
                    raise ImportErrorDetail(f"{label} directory symlinks are unsupported", 403)
                pending.append(item)


def validate(data, root):
    if data.get('capability', 'chat') != 'chat':
        raise ImportErrorDetail('Splash supports chat only', 422)
    target = managed_path(data.get('target'), root, 'target')
    draft = managed_path(data.get('draft'), root, 'draft')
    if target.is_file() and target.suffix.lower() != '.gguf':
        raise ImportErrorDetail('target must be a GGUF file or model directory', 422)
    if draft.is_file():
        if draft.name != 'config.json' and draft.suffix != '.safetensors':
            raise ImportErrorDetail('draft file must be config.json or a safetensors shard; its directory must contain the complete DFlash2 checkpoint', 422)
        draft = draft.parent
    check_tree(draft, root, 'draft')
    if not (draft / 'config.json').is_file() or not list(draft.glob('*.safetensors')):
        raise ImportErrorDetail('draft directory requires config.json and DFlash2 safetensors weights', 422)
    if target.is_dir():
        check_tree(target, root, 'target')
    else:
        # Split discovery must remain upstream's responsibility, but validate
        # neighboring GGUF paths it can discover before allowing that discovery.
        for part in target.parent.iterdir():
            if part.suffix.lower() == '.gguf':
                candidate = managed_path(str(part), root, 'target GGUF part')
                if not candidate.is_file():
                    raise ImportErrorDetail('target GGUF part must be a regular file', 422)
    mmproj = None
    if data.get('mmproj') is not None:
        mmproj = managed_path(data['mmproj'], root, 'mmproj')
        if not mmproj.is_file() or mmproj.suffix.lower() != '.gguf':
            raise ImportErrorDetail('mmproj must be a regular GGUF file', 422)
    name = data.get('display_name', target.stem)
    if not isinstance(name, str) or not name.strip() or len(name) > 120 or any(ord(c) < 32 for c in name):
        raise ImportErrorDetail('display_name must be 1-120 printable characters')
    return target, draft, mmproj, name.strip()


def main():
    root = Path(os.environ['VELUM_MODELS_DIR']).resolve(strict=True)
    data = json.load(sys.stdin)
    target, draft, mmproj, _ = validate(data, root)
    # Local preparation promises no networking; enforce that promise for all
    # Python network clients rather than relying on cache/offline settings alone.
    def deny_network(event, args):
        if event in ('socket.connect', 'socket.getaddrinfo', 'socket.gethostbyname'):
            raise RuntimeError('Network access is forbidden during local model import')
    sys.addaudithook(deny_network)
    from install.local import prepare_local_model
    with contextlib.redirect_stdout(sys.stderr):
        prepared = prepare_local_model(target, draft, mmproj=mmproj, models_dir=root)
    if not prepared.resolve().is_relative_to(root):
        raise ImportErrorDetail('Prepared assembly escapes VELUM_MODELS_DIR', 403)
    print(json.dumps({'prepared': str(prepared), 'network_policy': 'denied'}), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'error': str(error), 'status': getattr(error, 'status', 422)}), flush=True)
        raise SystemExit(1)
