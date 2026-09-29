#!/usr/bin/env python3
"""对比真实转发前后文件；只输出统计，不保存用户图片或载荷字段。"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time
import tempfile

import numpy as np
from PIL import Image, JpegImagePlugin
import bwdecode as b
from test_bwdecode import jpeg

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--original', type=Path, required=True)
    parser.add_argument('--compressed', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    original = b.load_image(str(args.original))
    compressed = b.load_image(str(args.compressed))
    reference = b.decode_best(original)
    if not reference or not reference.is_success or not reference.has_sufficient_evidence:
        parser.error('较大图片必须先能完整解码，才能比较字段一致性')
    scale = compressed.shape[1] / original.shape[1] * reference.best.context.scale
    records = []

    def check(name, image, scales, path=None):
        working, _ = b.trim_uniform_dark_border(image)
        bounds = b.evidence_bounds(working)
        primary = b._search(b.integral_image(b.feature_plane(working, 'chroma')), bounds, scales, False)
        started = time.monotonic()
        result = b.decode_best(working, scales)
        elapsed = time.monotonic() - started
        accepted = bool(result and result.is_success and result.has_sufficient_evidence)
        record = dict(case=name, size=list(image.shape[:2][::-1]),
                      primaryAccepted=bool(primary and primary.is_success and primary.has_sufficient_evidence),
                      accepted=accepted, fieldsEqual=bool(result and result.payload == reference.payload),
                      companionRecovery=result.best.context.companion if result else None,
                      correctedBits=result.best.corrected_bits if result else None,
                      minObs=result.best.min_obs if result else None,
                      pythonSeconds=round(elapsed, 3))
        # 真实输入直接调用 CLI；衍生像素只在临时目录中存放。
        with tempfile.TemporaryDirectory() as directory:
            if path is None:
                path = Path(directory) / 'channel.png'
                Image.fromarray(image).save(path)
            command = [str(ROOT / '.build/release/bwdecode'), str(path), '--layout']
            if scales is not None:
                command.extend(['--scale', str(scales[0])])
            started = time.monotonic()
            swift = subprocess.run(command, text=True, capture_output=True, timeout=120)
            record['swiftSeconds'] = round(time.monotonic() - started, 3)
            record['swiftExit'] = swift.returncode
            record['swiftFieldsEqual'] = 'payload=0x' + reference.payload.bytes.hex() in swift.stdout
            record['agreement'] = (swift.returncode == 0) == accepted
            if accepted:
                record['agreement'] &= record['fieldsEqual'] and record['swiftFieldsEqual']
                diagnostic = re.search(r'companionRecovery=(true|false)', swift.stdout)
                record['agreement'] &= bool(diagnostic and (diagnostic[1] == 'true') == record['companionRecovery'])
        records.append(record)
        print(record, flush=True)

    check('original-auto', original, None, args.original)
    check('wechat-auto', compressed, None, args.compressed)
    check('wechat-known-scale', compressed, [scale], args.compressed)
    for quality in [92, 85, 76]:
        check(f'wechat-then-jpeg-{quality}', jpeg(compressed, quality), [scale])
    check('wechat-then-crop', compressed[29:-29, 13:-13], [scale])
    for color in [0, 255]:
        framed = np.pad(compressed, ((31, 23), (17, 19), (0, 0)), constant_values=color)
        framed[:, :, 3] = 255
        check(f'wechat-then-frame-{color}', framed, [scale])
    metadata = []
    for path in [args.original, args.compressed]:
        with Image.open(path) as image:
            metadata.append(dict(size=list(image.size), bytes=path.stat().st_size,
                                 subsampling=JpegImagePlugin.get_sampling(image) if image.format == 'JPEG' else None,
                                 quantization=getattr(image, 'quantization', None)))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(inputs=metadata, records=records), indent=2) + '\n')
    return 0 if all(record['agreement'] for record in records) else 1


if __name__ == '__main__':
    raise SystemExit(main())
