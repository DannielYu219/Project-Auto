"""Seal the external Splash payload and produce a development-only import archive."""
from pathlib import Path
import hashlib
import importlib.metadata
import json
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent
PACKAGE = ROOT/'package'
MACH_MAGICS = {bytes.fromhex(x) for x in ('feedface','feedfacf','cefaedfe','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca')}


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    for path in list(PACKAGE.rglob('__pycache__')) + [PACKAGE/'site-packages/bin']:
        absolute = path.resolve()
        assert absolute.is_relative_to(PACKAGE.resolve()) and absolute != PACKAGE.resolve()
        if path.exists():shutil.rmtree(path)
    shutil.copy2(ROOT/'requirements.cp312.txt',PACKAGE/'requirements.lock')
    native=[]
    for path in sorted(PACKAGE.rglob('*')):
        if not path.is_file() or path.is_symlink():continue
        with path.open('rb') as f:magic=f.read(4)
        if magic not in MACH_MAGICS:continue
        subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(path)],check=True,capture_output=True)
        subprocess.run(['codesign','--verify','--strict',str(path)],check=True,capture_output=True)
        native.append(path.relative_to(PACKAGE).as_posix())
    provenance={
        'upstream':'https://github.com/incoai/splash/releases/tag/1.5.0',
        'asset':'splash-1.5.0-arm64-macos26.tar.gz',
        'upstream_sha256':sha(ROOT/'splash-1.5.0-arm64-macos26.tar.gz'),
        'official_modules':['engine','install','server','LICENSE','THIRD_PARTY_NOTICES','release.json'],
        'python':'Shared CPython3.12 (not included)',
        'dependencies':'Official install/requirements.txt exact pins, cp312/abi3 wheels; pip omitted build-time only',
        'mlx_dependency':False,
        'modifications':'Official files unmodified; service/upstream.py isolated bootstrap adapts paths, pins draft, redirects thinking key and isolates PDF workers',
        'release_trust':'development-adhoc, not Developer ID signed or notarized',
    }
    (PACKAGE/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    files,symlinks={},{}
    for path in sorted(PACKAGE.rglob('*')):
        rel=path.relative_to(PACKAGE).as_posix()
        if path.is_symlink():
            assert path.resolve().is_relative_to(PACKAGE.resolve())
            symlinks[rel]=str(path.readlink())
        elif path.is_file() and rel!='runtime.json':files[rel]=sha(path)
    manifest={'schema_version':2,'platform':'macos','architecture':'arm64','minimum_macos':'26.4',
        'minimum_apple_chip':'M3','id':'splash','kind':'python','version':'1.5.0-velum.2','python_abi':'cp312',
        'entrypoint':'service/server.py','capabilities':['chat','download'],
        'adapter':{'protocol':'velum.local-ai.v1','host':'127.0.0.1','port':0,'auth_env':'VELUM_RUNTIME_TOKEN',
            'models_env':'VELUM_MODELS_DIR','parent_pid_env':'VELUM_RUNTIME_PARENT_PID'},
        'tested_python_base_manifest_sha256':'4e324837965ee84bee24ca6a29479476c6f0dfb1aa9833630a1a6fee0ffbd766',
        'files':files,'symlinks':symlinks,'signing':{'policy':'development-adhoc','notarized':False,'mach_o_files':native}}
    (PACKAGE/'runtime.json').write_text(json.dumps(manifest,indent=2)+'\n')
    archive=ROOT/'velum-engine-splash-1.5.0-velum.2.tar.gz'
    with tarfile.open(archive,'w:gz') as t:t.add(PACKAGE,arcname='velum-engine-splash-1.5.0-velum.2')
    report={'archive':archive.name,'archive_sha256':sha(archive),'manifest_sha256':sha(PACKAGE/'runtime.json'),
        'regular_files':len(files),'symlinks':len(symlinks),'signed_mach_o_files':len(native),'size_bytes':archive.stat().st_size}
    (ROOT/'package-report.json').write_text(json.dumps(report,indent=2)+'\n')
    (ROOT/(archive.name+'.sha256')).write_text(report['archive_sha256']+'  '+archive.name+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()
