#!/usr/bin/env python3
"""在原始 Demo 截图上验证组合转发链路，同时与 Swift CLI 对账。"""
import argparse
import json
from pathlib import Path
import subprocess
import time

import numpy as np
from PIL import Image
import bwdecode as b
from test_bwdecode import jpeg

ROOT = Path(__file__).resolve().parents[1]


def transform(source, kind):
    # 先损失屏幕范围，保留的位观测数必须由解码器重新计算。
    image = source[117:1659, 13:1219] if kind != 'small' else source[117:629, 13:557]
    scale = 0.837 if kind == 'down' else 1.173 if kind == 'up' else 1.0
    if scale != 1:
        image = np.array(Image.fromarray(image).resize(
            (round(image.shape[1] * scale), round(image.shape[0] * scale)), Image.Resampling.LANCZOS))
    if kind == 'frame-first':
        image = np.pad(image, ((31, 23), (17, 19), (0, 0)), constant_values=0)
        image[:, :, 3] = 255
    image = jpeg(image, 76, passes=2)
    if kind == 'gray':
        framed = np.empty((image.shape[0] + 54, image.shape[1] + 36, 4), dtype=np.uint8)
        framed[:] = (40, 43, 46, 255)
        framed[31:-23, 17:-19] = image
        image = framed
    if kind in ('black', 'white', 'down', 'up'):
        color = 255 if kind == 'white' else 0
        image = np.pad(image, ((31, 23), (17, 19), (0, 0)), constant_values=color)
        image[:, :, 3] = 255
    return image, scale


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('/private/tmp/bw-v6-channels'))
    parser.add_argument('--background', type=Path, help='将真实内容作为背景重新嵌入测试 v6；不恢复旧水印')
    parser.add_argument('--automatic', action='store_true', help='额外测未知比例自动搜索；耗时较长')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    records = []
    pages = ['plain', 'white', 'text', 'photo', 'dark', 'mixed']
    if args.background:
        pages.append('background')
    for page in pages:
        if page == 'background':
            payload = b.WatermarkPayload(0xDEADBEEF, 23439179, 381210, 'photobg', 11, 'test01')
            source = b.blend_tiled(b.load_image(str(args.background)), b.make_tile(payload))
        else:
            source = b.load_image(str(args.input_dir / (page + '.png')))
        reference = b.decode_best(source, [1])
        assert reference and reference.is_success and reference.has_sufficient_evidence
        for kind in ('crop', 'black', 'white', 'gray', 'frame-first', 'down', 'up', 'small'):
            image, scale = transform(source, kind)
            path = args.output / f'{page}-{kind}.png'
            Image.fromarray(image).save(path)
            working, trim = b.trim_uniform_dark_border(image)
            started = time.monotonic()
            result = b.decode_best(working, [scale])
            elapsed = time.monotonic() - started
            accepted = bool(result and result.is_success and result.has_sufficient_evidence)
            expected = kind != 'small'
            same = bool(result and result.payload == reference.payload)
            command = [str(ROOT / '.build/release/bwdecode'), str(path), '--layout', '--scale', str(scale)]
            swift = subprocess.run(command, text=True, capture_output=True, timeout=60)
            swift_same = 'payload=0x' + reference.payload.bytes.hex() in swift.stdout
            passed = (accepted and same and swift.returncode == 0 and swift_same) if expected else (
                not accepted and swift.returncode == 1 and 'uid=' not in swift.stdout)
            record = dict(page=page, channel=kind, scale=scale, size=list(image.shape[:2][::-1]),
                          trim=list(trim), accepted=accepted, fieldsEqual=same, passed=passed,
                          minObs=result.best.min_obs if result else None,
                          correctedBits=result.best.corrected_bits if result else None,
                          pythonSeconds=round(elapsed, 3), swiftExit=swift.returncode)
            records.append(record)
            print(record, flush=True)
    if args.automatic:
        for kind in ('down', 'up'):
            path = args.output / f'mixed-{kind}.png'
            source = b.load_image(str(args.input_dir / 'mixed.png'))
            reference = b.decode_best(source, [1])
            image, _ = b.trim_uniform_dark_border(b.load_image(str(path)))
            started = time.monotonic()
            result = b.decode_best(image)
            elapsed = time.monotonic() - started
            swift = subprocess.run([str(ROOT / '.build/release/bwdecode'), str(path), '--layout'],
                                   text=True, capture_output=True, timeout=180)
            passed = bool(result and result.is_success and result.has_sufficient_evidence and
                          result.payload == reference.payload and swift.returncode == 0 and
                          'payload=0x' + reference.payload.bytes.hex() in swift.stdout)
            record = dict(page='mixed', channel='auto-' + kind, passed=passed,
                          estimatedScale=result.best.context.scale if result else None,
                          pythonSeconds=round(elapsed, 3), swiftExit=swift.returncode)
            records.append(record)
            print(record, flush=True)
    (args.output / 'channels.json').write_text(json.dumps(records, ensure_ascii=False, indent=2))
    if not all(r['passed'] for r in records):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
