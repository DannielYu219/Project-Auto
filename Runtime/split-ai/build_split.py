"""Build split artifacts using existing assets; write ONLY beneath this directory."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

BASE = Path(__file__).resolve().parent
assert BASE == Path('/Users/dannielyu/Project-Auto/Runtime/split-ai')
OLD = BASE.parent / 'local-ai'
VERSION = '2026.11.02-split.1'
PY_VERSION = '3.12.16-split.1'
SOURCE_SHA = '353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e'
MACHO = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, payload):
    assert path.resolve().is_relative_to(BASE)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + '\n')


def sign_and_inventory(root):
    signed, files, symlinks = [], {}, {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic in MACHO:
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(path)], check=True, capture_output=True)
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)], check=True, capture_output=True)
            signed.append(str(path.relative_to(root)))
    for path in sorted(root.rglob('*')):
        name = str(path.relative_to(root))
        if name == 'runtime.json':
            continue
        if path.is_symlink():
            if os.path.isabs(os.readlink(path)) or not path.resolve().is_relative_to(root.resolve()):
                raise ValueError(f'Unsafe symlink {path}')
            symlinks[name] = os.readlink(path)
        elif path.is_file():
            files[name] = sha(path)
    return {'files': files, 'symlinks': symlinks, 'signing': {'policy': 'development-adhoc', 'notarized': False, 'mach_o_files': signed}}


def archive(root, name):
    target = BASE / (name + '-macos-arm64.tar.gz')
    with tarfile.open(target, 'w:gz', compresslevel=6, dereference=False) as tar:
        tar.add(root, arcname=name, recursive=False)
        for path in sorted(root.rglob('*')):
            tar.add(path, arcname=name + '/' + str(path.relative_to(root)), recursive=False)
    return {'directory': str(root), 'archive': str(target), 'archive_size': target.stat().st_size,
            'archive_sha256': sha(target), 'manifest_sha256': sha(root / 'runtime.json')}


def common():
    return {'schema_version': 2, 'platform': 'macos', 'architecture': 'arm64', 'minimum_macos': '26.0'}


def engine_manifest(identifier, capabilities, base_digest):
    return {**common(), 'id': identifier, 'kind': 'python', 'version': VERSION, 'python_abi': 'cp312',
            'entrypoint': 'service/server.py', 'capabilities': capabilities,
            'adapter': {'protocol': 'velum.local-ai.v1', 'host': '127.0.0.1', 'port': 0,
                        'auth_env': 'VELUM_RUNTIME_TOKEN', 'models_env': 'VELUM_MODELS_DIR',
                        'parent_pid_env': 'VELUM_RUNTIME_PARENT_PID'},
            'tested_python_base_manifest_sha256': base_digest}


def main():
    source = OLD / 'downloads/cpython-3.12.16-aarch64.tar.gz'
    assert sha(source) == SOURCE_SHA
    base = BASE / 'python-base'
    mlx = BASE / 'engines/mlx'
    custom = BASE / 'engines/custom-echo'
    for root in (base, mlx, custom):
        if root.exists():
            raise FileExistsError(f'Refusing to overwrite existing artifact: {root}')
        root.mkdir(parents=True)
    # Extract only runtime files: never install pip, headers, console tools or packages.
    excluded = ('python/lib/python3.12/site-packages', 'python/lib/python3.12/ensurepip',
                'python/include', 'python/lib/pkgconfig', 'python/share', 'python/lib/python3.12/config-')
    with tarfile.open(source) as tar:
        members = []
        for member in tar.getmembers():
            name = member.name
            if any(name == x or name.startswith(x + '/') or (x.endswith('-') and name.startswith(x)) for x in excluded):
                continue
            if name.startswith('python/bin/') and name.rsplit('/', 1)[-1] not in ('python', 'python3', 'python3.12'):
                continue
            if '/__pycache__/' in name or name.endswith(('.pyc', '.pyo', '.a')):
                continue
            members.append(member)
        tar.extractall(base, members=members, filter='data')
    licenses = base / 'licenses'
    licenses.mkdir()
    shutil.copy2(base / 'python/lib/python3.12/LICENSE.txt', licenses / 'CPython-LICENSE.txt')
    shutil.copytree(BASE / 'upstream-licenses', licenses / 'python-build-standalone')
    shutil.copy2(BASE / 'evidence/upstream-licenses.json', licenses / 'upstream-provenance.json')
    for path in sorted((base / 'python/lib').rglob('*')):
        if path.is_file() and not path.is_symlink() and path.name.lower().startswith(('license', 'copying', 'notice')):
            relative = path.relative_to(base / 'python/lib')
            dest = licenses / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
    save(base / 'provenance.json', {'source': 'python-build-standalone', 'version': '3.12.16', 'release': '20261026',
         'archive': 'cpython-3.12.16+20261026-aarch64-apple-darwin-install_only_stripped.tar.gz', 'sha256': SOURCE_SHA,
         'removed': list(excluded) + ['pip executables', 'non-Python bin console scripts', 'bytecode', 'static archives'],
         'bundled_third_party_packages': []})
    save(base / 'runtime.json', {**common(), 'id': 'velum-python', 'kind': 'python-base', 'version': PY_VERSION,
         'python': {'version': '3.12.16', 'abi': 'cp312', 'executable': 'python/bin/python3.12'}, **sign_and_inventory(base)})
    base_digest = sha(base / 'runtime.json')
    print('Clean Python base sealed', base_digest, flush=True)

    shutil.copytree(OLD / 'bundle/python/lib/python3.12/site-packages', mlx / 'site-packages', symlinks=True,
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '*.pyo'))
    (mlx / 'service').mkdir()
    adapter = (OLD / 'bundle/service/server.py').read_text()
    adapter = adapter.replace('import uuid\n', 'import uuid\nimport sys\n')
    adapter = adapter.replace('RUNTIME_ID = "velum-mlx-python"', 'RUNTIME_ID = "mlx"')
    adapter = adapter.replace('VERSION = "2026.11.02-dev.2"', f'VERSION = "{VERSION}"')
    adapter = adapter.replace('ROOT = Path(__file__).resolve().parents[1]\n',
        'ROOT = Path(__file__).resolve().parents[1]\n# Isolated mode ignores PYTHONPATH: authorize only this engine package path.\nsys.path.insert(0, str(ROOT / "site-packages"))\n')
    adapter = adapter.replace('        self.loaded.pop(capability, None)\n        gc.collect()\n        LOG.info',
        '        # One loaded model across all capabilities; release old references before allocation.\n        self.loaded.clear()\n        current = None\n        gc.collect()\n        import mlx.core as mx\n        mx.clear_cache()\n        LOG.info')
    adapter = adapter.replace('        self.load(identifier, capability)\n', '        current = None\n        self.load(identifier, capability)\n')
    (mlx / 'service/server.py').write_text(adapter)
    shutil.copy2(OLD / 'bundle/requirements.lock', mlx / 'requirements.lock')
    provenance = json.loads((OLD / 'bundle/provenance.json').read_text())
    provenance.update(schema_version=2, packaging='external-engine-no-python', python_base_manifest_sha256=base_digest)
    save(mlx / 'provenance.json', provenance)
    save(mlx / 'runtime.json', {**engine_manifest('mlx', ['chat', 'embeddings', 'download'], base_digest), **sign_and_inventory(mlx)})
    print('MLX engine sealed', flush=True)

    shutil.copytree(BASE / 'template/service', custom / 'service')
    (custom / 'site-packages').mkdir()
    (custom / 'LICENSE.txt').write_text('SPDX-License-Identifier: MIT\n\nCopyright (c) 2026 Velum contributors\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.\n')
    save(custom / 'provenance.json', {'schema_version': 2, 'dependencies': 'Python standard library only', 'purpose': 'Custom engine contract smoke test, deterministic echo; no ML inference'})
    save(custom / 'runtime.json', {**engine_manifest('custom-echo', ['chat', 'models'], base_digest), **sign_and_inventory(custom)})
    packages = {'python_base': archive(base, 'velum-python-' + PY_VERSION),
                'mlx': archive(mlx, 'velum-engine-mlx-' + VERSION),
                'custom_echo': archive(custom, 'velum-engine-custom-echo-' + VERSION)}
    for key, root in [('python_base', base), ('mlx', mlx), ('custom_echo', custom)]:
        manifest = json.loads((root / 'runtime.json').read_text())
        packages[key].update(regular_files=len(manifest['files']), symlinks=len(manifest['symlinks']), signed_mach_o_count=len(manifest['signing']['mach_o_files']))
    save(BASE / 'evidence/packages.json', packages)
    print(json.dumps(packages, indent=2), flush=True)


if __name__ == '__main__':
    main()
