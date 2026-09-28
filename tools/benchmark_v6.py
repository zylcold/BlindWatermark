#!/usr/bin/env python3
"""v6 实测矩阵；输出 JSON/CSV 与最终样本，不把合成结果当成真机验收。"""
import argparse
import csv
import json
import time
from pathlib import Path
from PIL import Image
import bwdecode as b
from test_bwdecode import screenshot, jpeg


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--input-dir',type=Path)
    parser.add_argument('--output',type=Path,default=Path('/private/tmp/bw-v6-benchmark'))
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    records=[]
    for page in ['plain','white','text','photo','dark','mixed'] if args.input_dir else ['plain','photo']:
        source=b.load_image(str(args.input_dir/(page+'.png'))) if args.input_dir else screenshot(photo=page=='photo')
        reference=b.decode_best(source,[1])
        expected=reference.payload.bytes if reference and reference.is_success else None
        for quality in [95,90,80,76,70,60]:
            image=jpeg(source,quality,passes=2)
            file=args.output/f'{page}-q{quality}-double.png';Image.fromarray(image).save(file)
            started=time.monotonic();result=b.decode_best(image,[1]);seconds=time.monotonic()-started
            c=result.best if result else None
            success=bool(expected is not None and result and result.is_success and result.has_sufficient_evidence and result.payload.bytes==expected)
            records.append({'page':page,'quality':quality,'passes':2,'success':success,
                            'correctedBits':c.corrected_bits if c else None,'minObs':c.min_obs if c else None,'seconds':round(seconds,3)})
            print(records[-1],flush=True)
    report={'kind':'native-simulator' if args.input_dir else 'synthetic','delta':4,'plane':'chroma','records':records}
    (args.output/'benchmark.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    with (args.output/'benchmark.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=records[0].keys());writer.writeheader();writer.writerows(records)
    if not all(r['success'] for r in records):raise SystemExit(1)

if __name__=='__main__':main()
