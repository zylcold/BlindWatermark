#!/usr/bin/env python3
"""通过 XcodeBuildMCP 启动 Demo，用 sim-use 保留设备像素截图，再逐页解 v6。"""
import argparse
import json
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]


def run(command):
    process=subprocess.run(command,text=True,capture_output=True,timeout=600)
    if process.returncode:
        raise RuntimeError(process.stdout+process.stderr)
    output=process.stdout
    if command[0]=='xcodebuildmcp':
        response=json.loads(output)
        if response.get('isError'):raise RuntimeError(output)
    return output


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('device');parser.add_argument('delta',nargs='?',default='4')
    parser.add_argument('plane',nargs='?',choices=['chroma','luma'],default='chroma')
    parser.add_argument('--output',default='/private/tmp/bw-v6-demo-samples')
    parser.add_argument('--skip-build',action='store_true')
    args=parser.parse_args();out=Path(args.output);out.mkdir(parents=True,exist_ok=True)
    common=['--project-path',str(ROOT/'Demo/Demo.xcodeproj'),'--scheme','Demo','--simulator-id',args.device,'--derived-data-path','/private/tmp/bw-v6-demo']
    if not args.skip_build:
        subprocess.run(['xcodegen','generate'],cwd=ROOT/'Demo',check=True)
        run(['xcodebuildmcp','simulator','build-and-run']+common+['--extra-args','CODE_SIGNING_ALLOWED=NO','--output','json'])
    reports=[]
    for page in ['plain','white','text','photo','dark','mixed']:
        run(['xcodebuildmcp','simulator','stop','--simulator-id',args.device,'--bundle-id','com.zylcold.blindwatermark.demo','--output','json'])
        config={'env':{'BW_PAGE':page,'BW_DELTA':args.delta,'BW_PLANE':args.plane}}
        run(['xcodebuildmcp','simulator','launch-app','--simulator-id',args.device,'--bundle-id','com.zylcold.blindwatermark.demo','--json',json.dumps(config),'--output','json'])
        time.sleep(2)
        shot=out/(page+'.png')
        run(['sim-use','screenshot','--device',args.device,'--output',str(shot)])
        started=time.monotonic()
        decoded=subprocess.run([str(ROOT/'.build/release/bwdecode'),str(shot),'--scale','1','--plane',args.plane,'--layout'],text=True,capture_output=True,timeout=60)
        elapsed=time.monotonic()-started
        report={'page':page,'file':str(shot),'exit':decoded.returncode,'seconds':round(elapsed,3),'stdout':decoded.stdout,'stderr':decoded.stderr}
        reports.append(report)
        print(page,decoded.returncode,round(elapsed,3),decoded.stdout.strip(),flush=True)
    (out/'sweep.json').write_text(json.dumps({'device':args.device,'delta':args.delta,'plane':args.plane,'reports':reports},ensure_ascii=False,indent=2))
    if any(r['exit'] for r in reports):raise SystemExit(1)

if __name__=='__main__':main()
