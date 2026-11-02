"""Verify development archive extraction, every-file hashes and isolated relocation."""
from pathlib import Path
import hashlib
import http.client
import json
import os
import select
import subprocess
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parent
TOKEN='relocated-splash-token-0123456789abcdef'


def main():
    results={}
    with tempfile.TemporaryDirectory(prefix='Splash independent path with spaces ',dir=ROOT) as directory:
        base=Path(directory)
        with tarfile.open(ROOT/'velum-engine-splash-1.5.0-velum.2.tar.gz') as archive:
            for member in archive.getmembers():
                assert not member.name.startswith('/') and '..' not in Path(member.name).parts
                assert member.isfile() or member.isdir()
            archive.extractall(base,filter='data')
        payload=base/'velum-engine-splash-1.5.0-velum.2'
        manifest=json.loads((payload/'runtime.json').read_text())
        actual={p.relative_to(payload).as_posix() for p in payload.rglob('*') if p.is_file() and p.name!='runtime.json'}
        assert actual==set(manifest['files'])
        for relative,digest in manifest['files'].items():
            with (payload/relative).open('rb') as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==digest,relative
        for relative in manifest['signing']['mach_o_files']:
            subprocess.run(['codesign','--verify','--strict',str(payload/relative)],check=True,capture_output=True)
        assert not (payload/'python').exists() and not (payload/'site-packages/mlx').exists()
        results['hashed_files']=len(actual)
        results['signed_native']=len(manifest['signing']['mach_o_files'])
        env=dict(os.environ,VELUM_RUNTIME_TOKEN=TOKEN,VELUM_MODELS_DIR=str(base/'Models'),VELUM_RUNTIME_PARENT_PID=str(os.getpid()))
        process=subprocess.Popen([str(ROOT/'test-python/python/bin/python3.12'),'-I','-B',str(payload/'service/server.py'),'--port','0'],
            env=env,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,cwd='/')
        try:
            assert select.select([process.stdout],[],[],30)[0]
            ready=json.loads(process.stdout.readline())
            assert ready['runtime_id']=='splash'
            connection=http.client.HTTPConnection('127.0.0.1',ready['port'],timeout=15)
            connection.request('GET','/health',headers={'Authorization':'Bearer '+TOKEN})
            response=connection.getresponse();health=json.loads(response.read());assert response.status==200 and health['loaded']=={}
            connection.request('POST','/control/shutdown','{}',{'Authorization':'Bearer '+TOKEN,'Content-Type':'application/json'})
            assert connection.getresponse().status==200
            connection.close()
            assert process.wait(15)==0
            results['relocated_authenticated_ready_shutdown']=True
        finally:
            if process.poll() is None:process.kill();process.wait()
        assert not list(payload.rglob('*.pyc'))
        results['payload_stays_immutable']=True
    (ROOT/'relocation-report.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(results,indent=2))


if __name__=='__main__':main()
