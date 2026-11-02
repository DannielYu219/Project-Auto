"""Fetch pinned upstream standalone license notices through the explicit proxy."""
import hashlib
import json
from pathlib import Path
import urllib.request

BASE = Path(__file__).resolve().parent
index = json.loads((BASE / 'evidence/upstream-tree.json').read_text())
root = BASE / 'upstream-licenses'
root.mkdir(exist_ok=True)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({'https': 'http://127.0.0.1:7890', 'http': 'http://127.0.0.1:7890'}))
records = []
for item in index['tree']:
    name = item['path']
    if item['type'] != 'blob' or '/' in name or not (name == 'LICENSE' or name.startswith('LICENSE.')):
        continue
    url = 'https://raw.githubusercontent.com/astral-sh/python-build-standalone/20261026/' + name
    data = opener.open(url, timeout=30).read()
    expected = item['sha']
    assert hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == expected
    (root / name).write_bytes(data)
    records.append({'file': name, 'source': url, 'git_blob_sha1': expected, 'sha256': hashlib.sha256(data).hexdigest()})
(BASE / 'evidence/upstream-licenses.json').write_text(json.dumps({'release': '20261026', 'tree_sha': index['sha'], 'files': records}, indent=2) + '\n')
print(f'Fetched and verified {len(records)} upstream license notices', flush=True)
