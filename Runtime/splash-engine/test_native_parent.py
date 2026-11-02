"""Load actual native model then test launcher exit kills wrapper and native children."""
import http.client
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parent
TOKEN='parent-native-splash-0123456789abcdef'
MODEL='prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0@94dd51cdbbec5309ed8b76a12f3268bc4fdceb93'


def main():
    launcher_code="""import json,os,subprocess,sys
p=subprocess.Popen(sys.argv[1:],env=dict(os.environ,VELUM_RUNTIME_PARENT_PID=str(os.getpid())),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
print(p.stdout.readline().strip(),flush=True)
sys.stdin.readline()
"""
    launcher=subprocess.Popen([sys.executable,'-B','-c',launcher_code,str(ROOT/'test-python/python/bin/python3.12'),'-I','-B',str(ROOT/'package/service/server.py'),'--port','0'],
        env=dict(os.environ,VELUM_RUNTIME_TOKEN=TOKEN,VELUM_MODELS_DIR=str(ROOT/'Models'),HF_HUB_OFFLINE='1'),
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    try:
        assert select.select([launcher.stdout],[],[],30)[0]
        ready=json.loads(launcher.stdout.readline())
        c=http.client.HTTPConnection('127.0.0.1',ready['port'],timeout=300)
        c.request('POST','/control/load',json.dumps({'model':MODEL,'capability':'chat'}),{'Authorization':'Bearer '+TOKEN,'Content-Type':'application/json'})
        response=c.getresponse();body=response.read();assert response.status==200,body
        c.close()
        ps=subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,command='],text=True)
        descendants={ready['pid']}
        rows=[line.strip().split(None,3) for line in ps.splitlines()]
        for _ in range(5):
            descendants.update(int(row[0]) for row in rows if int(row[1]) in descendants)
        assert len(descendants)>=3,descendants
        launcher.stdin.write('\n');launcher.stdin.flush();launcher.wait(10)
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            alive=[]
            for pid in descendants:
                try:os.kill(pid,0);alive.append(pid)
                except ProcessLookupError:pass
            if not alive:break
            time.sleep(.1)
        assert not alive,alive
        result={'actual_native_loaded':True,'pids':sorted(descendants),'all_children_terminated_on_parent_exit':True}
        (ROOT/'native-parent-report.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result,indent=2))
    finally:
        if launcher.poll() is None:launcher.terminate();launcher.wait(10)


if __name__=='__main__':main()
