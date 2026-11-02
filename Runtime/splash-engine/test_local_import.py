"""Managed local import: real model inference plus rejection and split discovery tests."""
from pathlib import Path
import http.client
import json
import os
import select
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parent
STORE=ROOT/'Models'
TOKEN='local-import-splash-0123456789abcdef'


def main():
    target_source=STORE/'.hub/hub/models--prism-ml--Ternary-Bonsai-2-27B-gguf/snapshots/94dd51cdbbec5309ed8b76a12f3268bc4fdceb93/Ternary-Bonsai-2-27B-PQ2_0.gguf'
    draft_source=STORE/'.hub/hub/models--incoai--Qwen3.8-27B-DFlash2/snapshots/015e795645c74b1a0eeef3b570031fb62e769bc5'
    managed=STORE/'splash-local/local-import-validation'
    (managed/'target').mkdir(parents=True,exist_ok=True)
    (managed/'draft').mkdir(exist_ok=True)
    target=managed/'target/Bonsai-PQ2_0.gguf'
    if not target.exists():os.link(target_source.resolve(),target)
    for name in ('config.json','model.safetensors'):
        dest=managed/'draft'/name
        if not dest.exists():os.link((draft_source/name).resolve(),dest)
    # A non-mmproj with correct extension exercises native projector refusal.
    bad=managed/'bad-mmproj.gguf';bad.write_bytes(b'not a GGUF projector')
    escape=managed/'escape.gguf'
    if not escape.is_symlink():escape.symlink_to('/etc/hosts')
    log=(ROOT/'local-import.stderr.log').open('w')
    p=subprocess.Popen([str(ROOT/'test-python/python/bin/python3.12'),'-I','-B',str(ROOT/'package/service/server.py'),'--port','0'],
        env=dict(os.environ,VELUM_MODELS_DIR=str(STORE),VELUM_RUNTIME_TOKEN=TOKEN,VELUM_RUNTIME_PARENT_PID=str(os.getpid()),
            HTTP_PROXY='http://127.0.0.1:1',HTTPS_PROXY='http://127.0.0.1:1',HF_HUB_OFFLINE='1'),
        stdout=subprocess.PIPE,stderr=log,text=True)
    result={}
    try:
        assert select.select([p.stdout],[],[],30)[0]
        ready=json.loads(p.stdout.readline());assert ready['version']=='1.5.0-velum.2'
        def req(path,data=None,auth=TOKEN):
            c=http.client.HTTPConnection('127.0.0.1',ready['port'],timeout=600)
            headers={'Content-Type':'application/json'}
            if auth:headers['Authorization']='Bearer '+auth
            c.request('GET' if data is None else 'POST',path,None if data is None else json.dumps(data),headers)
            r=c.getresponse();status=r.status;body=json.loads(r.read());c.close();return status,body
        data={'target':str(target),'draft':str(managed/'draft'),'mmproj':None,'capability':'chat','display_name':'Bonsai Local Validation'}
        assert req('/control/import',data,auth='')[0]==401
        before=req('/v1/models')[1]['data']
        errors=[]
        for patch,expected in (({'target':'/etc/hosts'},403),({'target':str(STORE/'../outside.gguf')},400),
            ({'target':str(escape)},403),({'target':str(managed/'missing.gguf')},404),({'draft':str(managed/'missing-draft')},404),
            ({'draft':str(bad)},422),({'mmproj':str(managed/'missing-mmproj.gguf')},404),({'mmproj':str(bad)},422),
            ({'mmproj':str(managed/'draft')},422),({'capability':'embeddings'},422)):
            status,body=req('/control/import',{**data,**patch});assert status==expected,(patch,status,body)
            errors.append({'patch':patch,'status':status,'error':body})
        result['rejections']=errors
        # Recursive draft escape, not merely an escaped top-level input.
        evil=managed/'draft/escape.json';evil.symlink_to('/etc/hosts')
        try:assert req('/control/import',data)[0]==403
        finally:evil.unlink()
        start=time.monotonic()
        status,descriptor=req('/control/import',data)
        assert status==200,(status,descriptor)
        result['import_seconds']=round(time.monotonic()-start,3)
        result['descriptor']=descriptor
        assert descriptor['id'].startswith('local/') and descriptor['source']=='local'
        assert descriptor['vision'] is False
        models=req('/v1/models')[1]['data']
        assert any(m['id']==descriptor['id'] for m in models)
        assert {m['id'] for m in before}.issubset({m['id'] for m in models})
        # draft-file selector is normalized to its complete checkpoint directory.
        status,again=req('/control/import',{**data,'draft':str(managed/'draft/config.json')})
        assert status==200 and again['id']==descriptor['id'],(status,again)
        result['draft_file_and_idempotency']=True
        start=time.monotonic();status,loaded=req('/control/load',{'model':descriptor['id'],'capability':'chat'})
        assert status==200,(status,loaded)
        result['load_seconds']=round(time.monotonic()-start,3)
        status,reply=req('/v1/chat/completions',{'model':descriptor['id'],'messages':[{'role':'user','content':'Reply exactly LOCAL_SPLASH_OK.'}],
            'max_tokens':64,'temperature':0,'reasoning_effort':'none'})
        assert status==200 and reply['choices'][0]['message']['content']=='LOCAL_SPLASH_OK',(status,reply)
        result['nonstream_reply']=reply
        c=http.client.HTTPConnection('127.0.0.1',ready['port'],timeout=120)
        c.request('POST','/v1/chat/completions',json.dumps({'model':descriptor['id'],'messages':[{'role':'user','content':'Say hello in one word.'}],
            'stream':True,'max_tokens':32,'temperature':0,'reasoning_effort':'none'}),{'Content-Type':'application/json','Authorization':'Bearer '+TOKEN})
        r=c.getresponse();raw=r.read().decode();c.close()
        assert r.status==200 and 'Hello' in raw and '[DONE]' in raw,raw
        result['sse']=raw
        assert req('/control/unload',{})[0]==200
        assert req('/health')[1]['loaded']=={}
        assert req('/control/shutdown',{})[0]==200
        assert p.wait(15)==0
        result['unload_shutdown']=True
        result['network']='Local helper audit hook denies socket connect/DNS; test ran with dead proxy+offline enabled, no download endpoint called'
        result['mmproj']='No compatible projector available; optional omitted for actual inference; malformed projector rejected422'
    finally:
        if p.poll() is None:p.terminate();p.wait(15)
        log.close()
        (ROOT/'local-import-report.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
