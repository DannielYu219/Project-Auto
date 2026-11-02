"""Add complete upstream notices and reseal metadata without changing native code."""
import json
import shutil
from build_split import BASE, archive, save, sha

packages = json.loads((BASE / 'evidence/packages.json').read_text())
base = BASE / 'python-base'
shutil.copytree(BASE / 'upstream-licenses', base / 'licenses/python-build-standalone', dirs_exist_ok=True)
shutil.copy2(BASE / 'evidence/upstream-licenses.json', base / 'licenses/upstream-provenance.json')

def update(root):
    manifest = json.loads((root / 'runtime.json').read_text())
    manifest['files'] = {str(p.relative_to(root)): sha(p) for p in sorted(root.rglob('*')) if p.is_file() and not p.is_symlink() and str(p.relative_to(root)) != 'runtime.json'}
    save(root / 'runtime.json', manifest)
    return manifest

manifest = update(base)
base_digest = sha(base / 'runtime.json')
for key, root, name in [
    ('python_base', base, 'velum-python-3.12.16-split.1'),
    ('mlx', BASE / 'engines/mlx', 'velum-engine-mlx-2026.11.02-split.1'),
    ('custom_echo', BASE / 'engines/custom-echo', 'velum-engine-custom-echo-2026.11.02-split.1')]:
    manifest = json.loads((root / 'runtime.json').read_text())
    if key != 'python_base':
        manifest['tested_python_base_manifest_sha256'] = base_digest
        save(root / 'runtime.json', manifest)
        if key == 'mlx':
            provenance = json.loads((root / 'provenance.json').read_text())
            provenance['python_base_manifest_sha256'] = base_digest
            save(root / 'provenance.json', provenance)
    manifest = update(root)
    packages[key] = archive(root, name)
    packages[key].update(regular_files=len(manifest['files']), symlinks=len(manifest['symlinks']), signed_mach_o_count=len(manifest['signing']['mach_o_files']))
save(BASE / 'evidence/packages.json', packages)
print(json.dumps(packages, indent=2), flush=True)
