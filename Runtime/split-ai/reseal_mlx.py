"""Recompute the split MLX manifest/archive after adapter-only maintenance."""
import json
from pathlib import Path
from build_split import BASE, archive, save, sha, sign_and_inventory

root = BASE / 'engines/mlx'
manifest = json.loads((root / 'runtime.json').read_text())
manifest.update(sign_and_inventory(root))
save(root / 'runtime.json', manifest)
packages = json.loads((BASE / 'evidence/packages.json').read_text())
packages['mlx'] = archive(root, 'velum-engine-mlx-' + manifest['version'])
packages['mlx'].update(regular_files=len(manifest['files']), symlinks=len(manifest['symlinks']), signed_mach_o_count=len(manifest['signing']['mach_o_files']))
save(BASE / 'evidence/packages.json', packages)
print(json.dumps(packages['mlx'], indent=2), flush=True)
