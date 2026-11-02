"""Control-plane/native smoke tests; no model download or synthetic inference."""
import hashlib
import http.client
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
PYTHON = ROOT / 'test-python/python/bin/python3.12'
SERVER = ROOT / 'package/service/server.py'
TOKEN = 'test-splash-token-0123456789abcdef'


def main():
    results = {}
    with tempfile.TemporaryDirectory(prefix='splash-control-') as temporary:
        env = dict(os.environ, VELUM_RUNTIME_TOKEN=TOKEN, VELUM_MODELS_DIR=temporary,
                   VELUM_RUNTIME_PARENT_PID=str(os.getpid()))
        log = (ROOT / 'adapter-smoke.stderr.log').open('w')
        process = subprocess.Popen([str(PYTHON), '-I', '-B', str(SERVER), '--port', '0'],
                                   env=env, stdout=subprocess.PIPE, stderr=log, text=True)
        try:
            assert select.select([process.stdout], [], [], 30)[0], 'No readiness'
            ready = json.loads(process.stdout.readline())
            assert ready['event'] == 'ready' and ready['runtime_id'] == 'splash' and ready['port'] > 0, ready
            results['readiness'] = ready
            def request(path, data=None, auth=TOKEN):
                conn = http.client.HTTPConnection('127.0.0.1', ready['port'], timeout=30)
                headers = {'Content-Type': 'application/json'}
                if auth:
                    headers['Authorization'] = 'Bearer ' + auth
                conn.request('POST' if data is not None else 'GET', path, None if data is None else json.dumps(data), headers)
                response = conn.getresponse()
                status, body = response.status, json.loads(response.read())
                conn.close()
                return status, body
            for path in ('/health', '/v1/models'):
                assert request(path, auth='')[0] == 401
            assert request('/control/unload', {}, auth='')[0] == 401
            results['auth401'] = True
            status, health = request('/health')
            assert status == 200 and health['loaded'] == {} and health['jobs'] == []
            assert health['device']['native_exit_code'] == 0
            assert request('/v1/models')[1]['data'] == []
            results['native_device_check'] = health['device']
            for path, data, expected in (
                ('/control/download', {'repo': 'mlx-community/Qwen2.5-0.5B', 'revision': 'a'*40, 'capability': 'chat'}, 422),
                ('/control/download', {**health['catalog'][0], 'max_download_bytes': 1}, 413),
                ('/control/load', {'model': 'nonexistent', 'capability': 'chat'}, 404),
                ('/control/load', {'model': 'nonexistent', 'capability': 'embeddings'}, 422),
                ('/v1/embeddings', {}, 422),
                ('/v1/chat/completions', {'model': 'nonexistent', 'messages': [{'role': 'user', 'content': 'Hi'}]}, 404),
                ('/control/unload', {}, 200),
                ('/control/cancel', {}, 200),
            ):
                status, body = request(path, data)
                assert status == expected, (path, status, body)
            results['unsupported_model_errors_and_no_automatic_download'] = True
            assert request('/control/shutdown', {})[0] == 200
            assert process.wait(10) == 0
            results['shutdown'] = True
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            log.close()
    # An intermediate launcher exits, leaving the wrapper to detect reparenting.
    code = """import os,subprocess,sys,time
p=subprocess.Popen(sys.argv[1:],env=dict(os.environ,VELUM_RUNTIME_PARENT_PID=str(os.getpid())),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
print(p.stdout.readline().strip(),flush=True)
"""
    with tempfile.TemporaryDirectory(prefix='splash-parent-') as temporary:
        launcher = subprocess.Popen([sys.executable, '-B', '-c', code, str(PYTHON), '-I', '-B', str(SERVER), '--port', '0'],
            env=dict(os.environ, VELUM_RUNTIME_TOKEN=TOKEN, VELUM_MODELS_DIR=temporary), stdout=subprocess.PIPE, text=True)
        ready = json.loads(launcher.stdout.readline())
        launcher.wait(10)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                os.kill(ready['pid'], 0)
            except ProcessLookupError:
                break
            time.sleep(.1)
        else:
            raise AssertionError('Wrapper survived launcher exit')
        results['parent_exit_cancellation'] = True
    results['native_serve_smoke'] = subprocess.run([str(ROOT/'package/engine/splash'), 'serve-native', '/nonexistent', 'auto', 'auto'], capture_output=True, text=True).returncode != 0
    (ROOT / 'adapter-smoke.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
