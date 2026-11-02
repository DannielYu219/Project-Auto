"""Verify split packages, relocation and actual inference without network access."""
from __future__ import annotations

import base64
import hashlib
import json
import math
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'local-ai'
EVIDENCE = BASE / 'evidence'
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
PACKAGES = json.loads((EVIDENCE / 'packages.json').read_text())
RELOCATED = BASE / 'relocation-check' / ('independent path with spaces ' + PACKAGES['mlx']['archive_sha256'][:12])


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(root):
    manifest = json.loads((root / 'runtime.json').read_text())
    files = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and not p.is_symlink() and str(p.relative_to(root)) != 'runtime.json'}
    links = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_symlink()}
    assert files == set(manifest['files']), (root, files ^ set(manifest['files']))
    assert links == set(manifest['symlinks'])
    for relative, digest in manifest['files'].items():
        assert sha(root / relative) == digest, relative
    for relative, target in manifest['symlinks'].items():
        assert os.readlink(root / relative) == target
        assert (root / relative).resolve().is_relative_to(root.resolve())
    for relative in manifest['signing']['mach_o_files']:
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(root / relative)], check=True, capture_output=True)
    return {'files': len(files), 'symlinks': len(links), 'native_signatures': len(manifest['signing']['mach_o_files']), 'manifest_sha256': sha(root / 'runtime.json')}


def ready_line(process, timeout=30):
    readable, _, _ = select.select([process.stdout], [], [], timeout)
    if not readable:
        raise AssertionError('Runtime did not emit readiness within deadline')
    line = process.stdout.readline()
    assert line, f'Runtime exited early: {process.poll()}'
    return json.loads(line)


def call(ready, token, path, payload=None):
    request = urllib.request.Request('http://127.0.0.1:' + str(ready['port']) + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    return OPENER.open(request, timeout=180)


def env(token):
    result = {k: v for k, v in os.environ.items() if 'proxy' not in k.lower() and not k.startswith('PYTHON')}
    result.update(VELUM_RUNTIME_TOKEN=token, VELUM_MODELS_DIR=str(BASE / 'verification-models'),
                  HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                  PYTHONPATH='/invalid/should-be-ignored', PYTHONHOME='/invalid/should-be-ignored')
    return result


def launch(python, root, token, name):
    log = (EVIDENCE / (name + '-stderr.log')).open('w')
    process = subprocess.Popen([str(python), '-I', '-B', str(root / 'service/server.py'), '--port', '0'],
        cwd='/', env=env(token), stdout=subprocess.PIPE, stderr=log, text=True)
    try:
        ready = ready_line(process)
    except BaseException:
        process.kill()
        process.wait()
        log.close()
        raise
    return process, ready, log


def cleanup(process, log):
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=15)
    log.close()


def helper():
    python, root, name = map(Path, sys.argv[2:5])
    token = os.urandom(32).hex()
    environment = env(token)
    environment['VELUM_RUNTIME_PARENT_PID'] = str(os.getpid())
    with (EVIDENCE / (str(name) + '-parent-stderr.log')).open('w') as log:
        process = subprocess.Popen([str(python), '-I', '-B', str(root / 'service/server.py')], env=environment,
            cwd='/', stdout=subprocess.PIPE, stderr=log, text=True)
        print(json.dumps(ready_line(process)), flush=True)
        process.wait()


def parent_test(python, root, name):
    parent = subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve()), 'helper', str(python), str(root), name],
                              stdout=subprocess.PIPE, text=True)
    ready = ready_line(parent)
    parent.kill()
    parent.wait(timeout=5)
    started = time.monotonic()
    closed = False
    while time.monotonic() - started < 5:
        try:
            with socket.create_connection(('127.0.0.1', ready['port']), timeout=.1):
                pass
        except OSError:
            closed = True
            break
        time.sleep(.05)
    assert closed, ready
    state = subprocess.run(['/bin/ps', '-p', str(ready['pid']), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
    assert not state or state.startswith('Z'), state
    return {'parent_killed': True, 'port_closed': closed, 'seconds_to_close': time.monotonic() - started, 'remaining_process_state': state or 'reaped'}


def main():
    if RELOCATED.exists():
        raise FileExistsError(RELOCATED)
    RELOCATED.mkdir(parents=True)
    roots, result = {}, {'packages': {}, 'network': 'disabled with offline model loading; all proxy variables removed', 'relocated_root': str(RELOCATED)}
    for name, package in PACKAGES.items():
        archive = Path(package['archive'])
        assert sha(archive) == package['archive_sha256']
        with tarfile.open(archive) as tar:
            top = tar.getnames()[0]
            tar.extractall(RELOCATED, filter='data')
        roots[name] = RELOCATED / top
        result['packages'][name] = verify(roots[name])
    base, mlx, custom = roots['python_base'], roots['mlx'], roots['custom_echo']
    python = base / 'python/bin/python3.12'
    absent = ['python/lib/python3.12/site-packages', 'python/lib/python3.12/ensurepip', 'python/include', 'python/lib/pkgconfig']
    for relative in absent:
        assert not (base / relative).exists(), relative
    assert not list(base.rglob('*.pyc')), 'Unexpected bytecode shipped in clean base'
    probe = subprocess.run([str(python), '-I', '-B', '-c',
        'import sys,importlib.util,json,ssl,sqlite3,ctypes; print(json.dumps({"version":sys.version,"isolated":sys.flags.isolated,"no_bytecode":sys.dont_write_bytecode,"prefix":sys.prefix,"paths":sys.path,"missing":{n:importlib.util.find_spec(n) is None for n in ["pip","ensurepip","setuptools","wheel","mlx","numpy"]}}))'],
        env=env('unused-token-for-base-probe'), cwd='/', capture_output=True, text=True, check=True)
    result['clean_base_probe'] = json.loads(probe.stdout)
    assert all(result['clean_base_probe']['missing'].values())
    assert result['clean_base_probe']['isolated'] == 1 and result['clean_base_probe']['no_bytecode']
    for root in (mlx, custom):
        assert not (root / 'python').exists()
    # Copy registry only; model data stays in its original read-only location.
    models = BASE / 'verification-models'
    models.mkdir(exist_ok=True)
    for item in json.loads((OLD / 'Models/models.json').read_text())['models']:
        source = OLD / 'Models' / item['path'].split('/')[0]
        target = models / source.name
        if not target.exists():
            target.symlink_to(source, target_is_directory=True)
    # Adapter rejects model symlinks escaping model root, so use local cloned snapshots instead.
    import shutil
    for target in models.iterdir():
        if target.is_symlink():
            source = target.resolve()
            assert target.parent.resolve() == models.resolve() and source.is_relative_to((OLD / 'Models').resolve())
            target.unlink()
            shutil.copytree(source, target, copy_function=os.link)
    shutil.copy2(OLD / 'Models/models.json', models / 'models.json')
    token = os.urandom(32).hex()
    process, ready, log = launch(python, mlx, token, 'mlx')
    try:
        assert ready['runtime_id'] == 'mlx' and ready['version'] == '2026.11.02-split.1'
        result['mlx_ready'] = ready
        assert json.load(call(ready, token, '/health'))['status'] == 'ok'
        try:
            call(ready, 'bad-token', '/health')
            raise AssertionError('Unauthenticated request accepted')
        except urllib.error.HTTPError as error:
            assert error.code == 401
        result['unauthorized_status'] = 401
        chat = json.load(call(ready, token, '/v1/chat/completions', {'model': 'mlx-community/Qwen3-0.6B-4bit',
            'messages': [{'role': 'user', 'content': 'Say hello.'}], 'max_tokens': 16, 'temperature': 0,
            'chat_template_kwargs': {'enable_thinking': False}}))
        assert chat['choices'][0]['message']['content']
        result['relocated_chat'] = chat
        response = call(ready, token, '/v1/chat/completions', {'model': 'mlx-community/Qwen3-0.6B-4bit',
            'messages': [{'role': 'user', 'content': 'Say hello again.'}], 'stream': True, 'max_tokens': 16,
            'temperature': 0, 'chat_template_kwargs': {'enable_thinking': False}})
        sse = response.read().decode()
        assert 'data: [DONE]' in sse and 'content' in sse
        result['streaming_chat'] = {'done': True, 'bytes': len(sse)}
        vectors = json.load(call(ready, token, '/v1/embeddings', {'model': 'mlx-community/embeddinggemma-2-4bit',
            'input': ['Mars is the red planet.', 'Venus is a nearby planet.'], 'dimensions': 128}))
        rows = [row['embedding'] for row in vectors['data']]
        norms = [math.sqrt(sum(value * value for value in row)) for row in rows]
        assert all(len(row) == 128 for row in rows)
        assert all(abs(norm - 1) < .01 for norm in norms)
        result['relocated_embeddings'] = {'dimensions': 128, 'rows': len(rows), 'norms': norms}
        health = json.load(call(ready, token, '/health'))
        assert set(health['loaded']) == {'embeddings'}, health
        result['one_loaded_model_after_capability_switch'] = health['loaded']
        encoded = json.load(call(ready, token, '/v1/embeddings', {'input': 'split base embedding', 'dimensions': 128, 'encoding_format': 'base64'}))
        assert len(base64.b64decode(encoded['data'][0]['embedding'])) == 128 * 4
        result['embedding_base64'] = True
        json.load(call(ready, token, '/control/unload', {}))
        json.load(call(ready, token, '/control/shutdown', {}))
        assert process.wait(timeout=15) == 0
        assert not process.stdout.read().strip()
        result['mlx_shutdown_exit'] = process.returncode
    finally:
        cleanup(process, log)
    process, ready, log = launch(python, custom, token, 'custom')
    try:
        assert ready['runtime_id'] == 'custom-echo'
        answer = json.load(call(ready, token, '/v1/chat/completions', {'model': 'custom-echo', 'messages': [{'role': 'user', 'content': 'split test'}]}))
        assert answer['choices'][0]['message']['content'] == 'Echo: split test'
        stream = call(ready, token, '/v1/chat/completions', {'messages': [{'role': 'user', 'content': 'stream test'}], 'stream': True}).read().decode()
        assert 'data: [DONE]' in stream and 'Echo: stream test' in stream
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=15) == 0
        assert not process.stdout.read().strip()
        result['custom_echo'] = {'normal_and_streaming': True, 'sigterm_exit': process.returncode}
    finally:
        cleanup(process, log)
    result['mlx_parent_death'] = parent_test(python, mlx, 'mlx')
    result['custom_parent_death'] = parent_test(python, custom, 'custom')
    # Runtime execution must not alter any sealed package bytes.
    result['post_execution_integrity'] = {name: verify(root) for name, root in roots.items()}
    (EVIDENCE / 'integration.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2), flush=True)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'helper':
        helper()
    else:
        main()
