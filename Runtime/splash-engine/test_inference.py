"""End-to-end real Metal inference using explicitly predownloaded pinned smoke assets."""
from pathlib import Path
import http.client
import json
import os
import select
import subprocess
import time

ROOT=Path(__file__).resolve().parent
TOKEN='splash-inference-token-0123456789abcdef'
REPO='prism-ml/Ternary-Bonsai-2-27B-gguf'
REVISION='94dd51cdbbec5309ed8b76a12f3268bc4fdceb93'


def main():
    env=dict(os.environ,VELUM_RUNTIME_TOKEN=TOKEN,VELUM_MODELS_DIR=str(ROOT/'Models'),
        VELUM_RUNTIME_PARENT_PID=str(os.getpid()),HF_HUB_OFFLINE='1')
    log=(ROOT/'inference.stderr.log').open('w')
    p=subprocess.Popen([str(ROOT/'test-python/python/bin/python3.12'),'-I','-B',str(ROOT/'package/service/server.py'),'--port','0'],
        env=env,stdout=subprocess.PIPE,stderr=log,text=True)
    result={}
    try:
        assert select.select([p.stdout],[],[],30)[0]
        ready=json.loads(p.stdout.readline())
        def req(path,data=None,timeout=300):
            c=http.client.HTTPConnection('127.0.0.1',ready['port'],timeout=timeout)
            c.request('POST' if data is not None else 'GET',path,None if data is None else json.dumps(data),
                {'Authorization':'Bearer '+TOKEN,'Content-Type':'application/json'})
            r=c.getresponse();status=r.status;raw=r.read();c.close()
            return status,json.loads(raw)
        status,job=req('/control/download',{'repo':REPO,'revision':REVISION,'capability':'chat','variant':'PQ2_0'})
        assert status==202,(status,job)
        deadline=time.monotonic()+180
        while job['status'] in ('queued','downloading','verifying'):
            assert time.monotonic()<deadline,job
            time.sleep(.5)
            _,job=req('/control/jobs/'+job['job_id'])
        assert job['status']=='completed',job
        result['preparation']=job
        models=req('/v1/models')[1]['data'];assert len(models)==1,models
        model=models[0]['id']
        start=time.monotonic()
        status,loaded=req('/control/load',{'model':model,'capability':'chat'})
        assert status==200,(status,loaded)
        result['load_seconds']=round(time.monotonic()-start,3)
        result['loaded_model']=loaded
        start=time.monotonic()
        status,reply=req('/v1/chat/completions',{'model':model,'messages':[{'role':'user','content':'Reply with exactly SPLASH_OK. No explanation.'}],
            'max_tokens':64,'temperature':0,'reasoning_effort':'none'})
        assert status==200,(status,reply)
        assert reply['choices'][0]['message'].get('content'),reply
        result['nonstream_reply']=reply
        result['nonstream_seconds']=round(time.monotonic()-start,3)
        c=http.client.HTTPConnection('127.0.0.1',ready['port'],timeout=120)
        c.request('POST','/v1/chat/completions',json.dumps({'model':model,'stream':True,'messages':[{'role':'user','content':'Say hello in one word.'}],
            'max_tokens':32,'temperature':0,'reasoning_effort':'none'}),{'Authorization':'Bearer '+TOKEN,'Content-Type':'application/json'})
        r=c.getresponse();raw=r.read().decode();c.close()
        assert r.status==200 and 'data: ' in raw and '[DONE]' in raw,raw
        result['stream_sse']=raw
        assert req('/control/unload',{})[0]==200
        assert req('/health')[1]['loaded']=={}
        assert req('/control/shutdown',{})[0]==200
        assert p.wait(15)==0
        result['unload_shutdown']=True
    finally:
        if p.poll() is None:p.terminate();p.wait(15)
        log.close()
        (ROOT/'inference-report.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
