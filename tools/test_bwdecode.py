#!/usr/bin/env python3
"""v6 自检：纠错边界、压缩/裁剪/缩放、拒答与 Swift CLI 同图对账。"""
import json
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile
import time
import unittest
from io import BytesIO

import numpy as np
from PIL import Image
import bwdecode as b

ROOT=Path(__file__).resolve().parents[1]
PAYLOAD=b.WatermarkPayload(3735928559,23439179,381210,'secabout',11)
GOLDEN='f35516606e2084c0f65f6715ebd4a06fd1e5b9786cf706584579cacc15a1e9256ecc02d0f56fefbeadde4ba765018de802b5cb6b23c8160064f076cc87817a00'


def screenshot(width=1242,height=2688,photo=False,payload=PAYLOAD):
    canvas=np.full((height,width,4),245,dtype=np.uint8);canvas[:,:,3]=255
    if photo:
        y,x=np.mgrid[:height,:width]
        # 可复现的彩色内容梯度及硬边缘；不用于宣称真机/真实照片成功率。
        canvas[:,:,0]=(80+(x//19+y//23)%150).astype(np.uint8)
        canvas[:,:,1]=(70+(x//13+y//31)%160).astype(np.uint8)
        canvas[:,:,2]=(60+(x//29+y//17)%170).astype(np.uint8)
    return b.blend_tiled(canvas,b.make_tile(payload))


def jpeg(image,quality=76,passes=1):
    im=Image.fromarray(image[:,:,:3])
    for _ in range(passes):
        stream=BytesIO();im.save(stream,format='JPEG',quality=quality,subsampling=2)
        stream.seek(0);im=Image.open(stream);im.load()
    return np.array(im.convert('RGBA'))


class V6Checks(unittest.TestCase):
    def test_bch_boundaries_and_golden(self):
        word=b.V6BCH.encode(PAYLOAD.bytes)
        self.assertEqual(word.hex(),GOLDEN)
        rng=random.Random(6)
        for n in [0,1,6,18,40]:
            for _ in range(5):
                damaged=bytearray(word)
                for i in rng.sample(range(511),n):damaged[i>>3]^=1<<(i&7)
                damaged[63]^=0x80
                decoded=b.V6BCH.decode(damaged)
                self.assertIsNotNone(decoded);self.assertEqual(decoded.message_bytes,PAYLOAD.bytes)
                self.assertEqual(decoded.corrected_bits,n+1)

    def test_payload_limits_and_rejects(self):
        self.assertEqual(len(PAYLOAD.bytes),27)
        self.assertEqual(b.WatermarkPayload.from_bytes(PAYLOAD.bytes),PAYLOAD)
        for bit in [0,50,179,203,207,210,211,215]:
            raw=bytearray(PAYLOAD.bytes);raw[bit>>3]^=1<<(bit&7)
            self.assertIsNone(b.WatermarkPayload.from_bytes(raw))
        self.assertIsNone(b.WatermarkPayload.from_codes(1,0,0,'ok',note_code='abcdefg'))
        self.assertIsNone(b.decode_base37(37**8,8))
        self.assertEqual(b.page_name_code('Module.BHUserProfileViewController'),'userprof')
        # 历史 v5.2 格式必须被明确拒绝，不能解释成 v6。
        self.assertIsNone(b.WatermarkPayload.from_bytes(bytes.fromhex('31ddbdafb15c4516d0882e50bbbc36826c0140066fc7f4224a05')))

    def test_maximum_fields_and_off_grid_resize(self):
        maximum=b.WatermarkPayload(0xffffffff,0x7fffffff,0xffffff,'a_z09xyz',9999,'z9_a0b')
        self.assertEqual(b.WatermarkPayload.from_bytes(maximum.bytes),maximum)
        self.assertEqual(b.V6BCH.decode(b.V6BCH.encode(maximum.bytes)).message_bytes,maximum.bytes)
        self.assertIsNone(b.WatermarkPayload.from_codes(1,0,0,'ok',note_code='abcdef_'))
        source=screenshot()
        for scale in [.837,1.173]:
            image=np.array(Image.fromarray(source).resize(
                (round(source.shape[1]*scale),round(source.shape[0]*scale)),Image.Resampling.LANCZOS))
            result=b.decode_best(jpeg(image,76,2),[scale])
            self.assertIsNotNone(result)
            self.assertEqual(result.payload,PAYLOAD)
            self.assertTrue(result.has_sufficient_evidence)
        pilot_only=source.copy()
        mask=(np.arange(source.shape[1])//b.CELL_WIDTH)%b.COLUMNS<b.DATA_COLUMNS
        pilot_only[:,mask,:3]=245
        self.assertIsNone(b.decode(pilot_only))
        rng=np.random.default_rng(6)
        for _ in range(3):
            noise=rng.integers(0,256,(1542,1206,4),dtype=np.uint8);noise[:,:,3]=255
            self.assertIsNone(b.decode_best(noise,[1]))

    def test_compression_and_cropping(self):
        for photo in [False,True]:
            source=screenshot(photo=photo)
            for quality in [95,90,80,76,70,60]:
                decoded=b.decode(jpeg(source,quality,passes=2))
                self.assertIsNotNone(decoded,(photo,quality))
                self.assertEqual(decoded.payload,PAYLOAD)
                self.assertTrue(decoded.has_sufficient_evidence)
        cropped=jpeg(screenshot()[117:1659,13:1219],76,passes=2)
        decoded=b.decode_best(cropped,[1])
        self.assertIsNotNone(decoded);self.assertEqual(decoded.payload,PAYLOAD)
        self.assertTrue(decoded.has_sufficient_evidence)

    def test_evidence_negative_and_black_border(self):
        small=screenshot(b.TILE_WIDTH,b.TILE_HEIGHT)
        result=b.decode(small)
        self.assertIsNotNone(result);self.assertFalse(result.has_sufficient_evidence)
        self.assertIsNone(b.decode(small,offset_x=-1))
        plain=np.full((640,900,4),255,dtype=np.uint8)
        self.assertIsNone(b.decode_best(plain,[1]))
        padded=np.pad(plain,((9,14),(11,7),(0,0)),constant_values=0);padded[:,:,3]=255
        trimmed,trim=b.trim_uniform_dark_border(padded)
        self.assertEqual(trim,(11,9,7,14));self.assertTrue(np.array_equal(trimmed,plain))
        dark=np.full((900,640,4),4,dtype=np.uint8);dark[:,:,3]=255
        self.assertEqual(b.trim_uniform_dark_border(dark)[1],(0,0,0,0))

    def test_ambiguity(self):
        ctx=b.Context((np.zeros(b.COLUMNS*b.ROWS),)*3,1,0,0,[])
        other=b.WatermarkPayload(1,0,0,'other')
        a=b.Candidate(PAYLOAD,0,False,ctx,0,0,1,10,10,20)
        c=b.Candidate(other,0,False,ctx,0,0,1,10,10,20)
        self.assertTrue(b.adjudicate([a,c]).ambiguous)
        self.assertEqual(b.adjudicate([a,a]).candidate_count,1)

    def test_committed_combined_channel_samples(self):
        folder=ROOT/'docs/samples'
        swift=Path(os.environ.get('BW_SWIFT_CLI',str(ROOT/'.build/release/bwdecode')))
        for sample in json.loads((folder/'samples.json').read_text()):
            path=folder/sample['file']
            image,trim=b.trim_uniform_dark_border(b.load_image(str(path)))
            result=b.decode_best(image,[sample['scale']])
            self.assertIsNotNone(result,sample['file'])
            self.assertTrue(result.is_success and result.has_sufficient_evidence)
            self.assertEqual(result.payload.bytes.hex(),sample['payloadHex'])
            output=subprocess.run([str(swift),str(path),'--scale',str(sample['scale']),'--layout'],
                                  text=True,capture_output=True,timeout=60)
            self.assertEqual(output.returncode,0,output.stderr)
            self.assertIn('payload=0x'+sample['payloadHex'],output.stdout)
        output=subprocess.run([os.sys.executable,str(ROOT/'tools/bwdecode.py'),'/missing-v6-file.jpg','--layout'],
                              text=True,capture_output=True)
        self.assertEqual(output.returncode,1)
        self.assertNotIn('Traceback',output.stderr)

    def test_swift_same_png_and_jpeg_cli_contract(self):
        swift=Path(os.environ.get('BW_SWIFT_CLI',str(ROOT/'.build/release/bwdecode')))
        self.assertTrue(swift.exists(),'先 swift build -c release')
        with tempfile.TemporaryDirectory() as folder:
            for kind in ['png','jpg','small']:
                image=screenshot() if kind!='small' else screenshot(b.TILE_WIDTH,b.TILE_HEIGHT)
                if kind=='jpg':image=jpeg(image,76,passes=2)
                path=Path(folder)/(kind+'.png');Image.fromarray(image).save(path)
                cmd=[str(swift),str(path),'--scale','1','--layout']
                output=subprocess.run(cmd,text=True,capture_output=True,timeout=60)
                python=subprocess.run([os.sys.executable,str(ROOT/'tools/bwdecode.py'),str(path),'--scale','1','--layout'],text=True,capture_output=True,timeout=60)
                self.assertEqual(output.returncode,python.returncode)
                self.assertNotIn('mac=',output.stdout)
                self.assertNotIn('mac=',python.stdout)
                if kind=='small':
                    self.assertEqual(output.returncode,1);self.assertIn('TOO_SMALL',output.stdout);self.assertNotIn('uid=',output.stdout)
                else:
                    self.assertEqual(output.returncode,0,output.stderr)
                    self.assertIn('payload=0x'+PAYLOAD.bytes.hex(),output.stdout)
                    self.assertIn('payload=0x'+PAYLOAD.bytes.hex(),python.stdout)
                    self.assertIn('crcStatus=OK(完整性自检,未验签)',output.stdout)
            for args in [['--protocol','v4'],['--protocol','v5.2'],['--bits','512'],['--key','00'],['--offset','-1,0'],['--scale','nan']]:
                self.assertEqual(subprocess.run([str(swift),str(path)]+args,capture_output=True).returncode,2)
                self.assertEqual(subprocess.run([os.sys.executable,str(ROOT/'tools/bwdecode.py'),str(path)]+args,capture_output=True).returncode,2)

if __name__=='__main__':unittest.main()
