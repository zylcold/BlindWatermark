#!/usr/bin/env python3
"""`tools/bwdecode.py` 的自检。

不引测试框架：合成 tile → 平铺到带噪声的底图上 → 解回来，逐项断言。
再跑一遍 Swift 版 `bwdecode`（有二进制就用）对账，因为这套解码逻辑有两份实现，
最怕的是两份悄悄漂移。

    python3 tools/test_bwdecode.py
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bwdecode  # noqa: E402

KEY_HEX = "00112233445566778899aabbccddeeff"
KEY = bytes.fromhex(KEY_HEX)
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT_CLI = os.path.join(REPO, ".build", "release", "bwdecode")

CHECKS = 0


def check(condition: bool, label: str) -> None:
    global CHECKS
    CHECKS += 1
    if not condition:
        raise AssertionError(label)
    print(f"  ok  {label}")


# MARK: - 合成图（镜像 BlockCodec.makeTile / RGBAImage.blend）


def chroma_companion(alpha: int) -> int:
    """p = round(0.114a/0.886)，至少 1 且不超过 a。取 0 就等于拿纯黑配纯蓝，网格会显形。"""
    ideal = round(0.114 * alpha / 0.886)
    return max(1, min(alpha, ideal))


def make_tile(payload: bytes, payload_bits: int, alpha: int, plane: str) -> np.ndarray:
    tile = np.zeros((bwdecode.TILE, bwdecode.TILE, 4), dtype=np.uint8)
    for p in range(bwdecode.PAIRS_PER_TILE):
        row, col = divmod(p, bwdecode.PAIRS_PER_ROW)
        index = p % payload_bits
        bit = (payload[index >> 3] >> (index & 7)) & 1
        left_dark = bool(bit)
        if bwdecode.is_flipped(p, payload_bits):
            left_dark = not left_dark
        for side, dark in ((0, left_dark), (1, not left_dark)):
            x = col * 2 * bwdecode.BLOCK + side * bwdecode.BLOCK
            y = row * bwdecode.BLOCK
            if plane == "luma":
                value = 0 if dark else alpha
                tile[y:y + bwdecode.BLOCK, x:x + bwdecode.BLOCK] = (value, value, value, alpha)
            else:
                companion = chroma_companion(alpha)
                colour = (companion, companion, 0, alpha) if dark else (0, 0, alpha, alpha)
                tile[y:y + bwdecode.BLOCK, x:x + bwdecode.BLOCK] = colour
    return tile


def shot(payload: bytes, plane: str, offset: tuple[int, int], alpha: int = 8,
         width: int = 640, height: int = 900) -> np.ndarray:
    """带噪声的底图 + 平铺水印，等价于 Swift 测试里的 `shot()`。"""
    rng = np.random.default_rng(11)
    canvas = np.zeros((height, width, 4), dtype=np.uint8)
    grey = rng.integers(190, 240, size=(height, width), dtype=np.uint8)
    canvas[:, :, 0] = canvas[:, :, 1] = canvas[:, :, 2] = grey
    canvas[:, :, 3] = 255

    tile = make_tile(payload, bwdecode.PAYLOAD_BITS, alpha, plane)
    dx, dy = offset
    y = dy - bwdecode.TILE
    while y < height:
        x = dx - bwdecode.TILE
        while x < width:
            _blend(canvas, tile, x, y)
            x += bwdecode.TILE
        y += bwdecode.TILE
    return canvas


def _blend(dst: np.ndarray, top: np.ndarray, dx: int, dy: int) -> None:
    """预乘 alpha 合成，整数运算与 Swift 的 `RGBAImage.blend` 一致。"""
    height, width = dst.shape[:2]
    x0, y0 = max(0, dx), max(0, dy)
    x1, y1 = min(width, dx + top.shape[1]), min(height, dy + top.shape[0])
    if x0 >= x1 or y0 >= y1:
        return
    src = top[y0 - dy:y1 - dy, x0 - dx:x1 - dx].astype(np.int32)
    region = dst[y0:y1, x0:x1].astype(np.int32)
    alpha = src[:, :, 3]
    keep = alpha > 0
    inv = 255 - alpha
    for channel in range(3):
        blended = src[:, :, channel] + region[:, :, channel] * inv // 255
        region[:, :, channel] = np.where(keep, np.minimum(255, blended), region[:, :, channel])
    blended_alpha = alpha + region[:, :, 3] * inv // 255
    region[:, :, 3] = np.where(keep, np.minimum(255, blended_alpha), region[:, :, 3])
    dst[y0:y1, x0:x1] = region.astype(np.uint8)


def make_payload(uid: int = 0x1234_5678, timestamp: int = 1_760_000_000,
                 class_name: str = "BHProfileViewController", app: int = 1) -> bytes:
    fields = bwdecode.Payload.build(uid, timestamp, class_name, app=app, key=KEY)
    mac = fields.mac
    return bwdecode.signed_body(fields.uid, fields.timestamp, fields.page_code, fields.tag) + mac


def make_self_checked(uid: int = 0x1234_5678, timestamp: int = 1_760_000_000,
                      class_name: str = "BHProfileViewController", app: int = 1) -> bytes:
    """无密钥部署的载荷：mac 位置是公开自检值。"""
    fields = bwdecode.Payload.self_checked(uid, timestamp, class_name, app=app)
    return bwdecode.signed_body(fields.uid, fields.timestamp, fields.page_code, fields.tag) + fields.mac


def make_unsigned(uid: int = 0x1234_5678, timestamp: int = 1_760_000_000,
                  class_name: str = "BHProfileViewController", app: int = 1) -> bytes:
    """像 `mac: []` 那样没带校验值的载荷。"""
    tag = (bwdecode.LAYOUT_VERSION << 28) | ((app & 0xFF) << 20)
    page_code = bwdecode.encode_page_code(bwdecode.page_name_code(class_name))
    return bwdecode.signed_body(uid, timestamp, page_code, tag) + bytes(12)


def crop(image: np.ndarray, left: int, top: int) -> np.ndarray:
    return image[top:, left:] if top or left else image


def mac_ok(decoded: bwdecode.Decoded | None) -> bool:
    if decoded is None or decoded.payload_bits != bwdecode.PAYLOAD_BITS:
        return False
    fields = bwdecode.Payload.from_bytes(decoded.payload_bytes)
    return fields is not None and fields.is_valid(KEY)


def validator(candidate: bwdecode.Decoded) -> bool:
    return mac_ok(candidate)


def tier_of(raw: bytes, key: bytes | None = None) -> str | None:
    fields = bwdecode.Payload.from_bytes(raw)
    return None if fields is None else fields.verification(key)


# MARK: - 各项检查


def test_round_trip() -> bytes:
    print("整屏解码（两平面）")
    payload = make_payload()
    for plane in ("chroma", "luma"):
        image = shot(payload, plane, (0, 0))
        decoded = bwdecode.decode(image, plane=plane)
        check(decoded is not None and decoded.payload_bytes == payload, f"{plane}: 解出的载荷与真值一致")
        check(mac_ok(decoded), f"{plane}: MAC 校验通过")
        assert decoded is not None
        check(decoded.weak_bits == 0, f"{plane}: 弱 bit = 0（实测 {decoded.weak_bits}）")
    return payload


def test_wrong_parameters(payload: bytes) -> None:
    print("参数给错必须露馅")
    image = shot(payload, "chroma", (0, 0))
    wrong_bits = bwdecode.decode(image, payload_bits=128, plane="chroma")
    check(not mac_ok(wrong_bits), "payloadBits 给错 → MAC 不通过（自洽但错误）")
    wrong_plane = bwdecode.decode(image, plane="luma")
    check(not mac_ok(wrong_plane), "plane 给错 → MAC 不通过")


def test_crop(payload: bytes) -> None:
    print("裁剪（相位 + tile 平移）")
    image = shot(payload, "chroma", (0, 0))
    for left, top, label in ((0, 137, "纵向 137px"), (16, 0, "横向 16px（一个 pair）"),
                             (24, 0, "横向 24px（一个半 pair）"), (40, 0, "横向 40px"),
                             (16, 400, "横纵同时")):
        decoded = bwdecode.decode_best(crop(image, left, top), validate=validator)
        check(mac_ok(decoded) and decoded is not None and decoded.payload_bytes == payload,
              f"{label}: --auto 撤销平移后解对")


def test_no_watermark() -> None:
    print("无水印画面不误报")
    rng = np.random.default_rng(7)
    # 彩色噪声：色度平面上有内容，才谈得上「不误报」；纯色彩的底图 chroma 恒为 0，没有观测
    noisy = np.zeros((900, 640, 4), dtype=np.uint8)
    noisy[:, :, 0] = rng.integers(120, 240, size=(900, 640), dtype=np.uint8)
    noisy[:, :, 1] = rng.integers(120, 240, size=(900, 640), dtype=np.uint8)
    noisy[:, :, 2] = rng.integers(120, 240, size=(900, 640), dtype=np.uint8)
    noisy[:, :, 3] = 255
    decoded = bwdecode.decode(noisy, plane="chroma")
    assert decoded is not None
    check(decoded.weak_bits > decoded.payload_bits // 8,
          f"彩色噪声：弱 bit {decoded.weak_bits}/{decoded.payload_bits} → 判 NO")
    check(not mac_ok(bwdecode.decode_best(noisy, validate=validator)), "--auto 也不会给出通过 MAC 的假结果")

    # 纯色画面一个可用的观测都没有：必须报成全部 bit 证据不足，不能报 OK
    flat = np.zeros((900, 640, 4), dtype=np.uint8)
    flat[:, :, 0] = flat[:, :, 1] = flat[:, :, 2] = 220
    flat[:, :, 3] = 255
    blank = bwdecode.decode(flat, plane="chroma")
    assert blank is not None
    check(blank.weak_bits == blank.payload_bits, f"纯色画面：弱 bit {blank.weak_bits}/{blank.payload_bits}")


def test_tamper(payload: bytes) -> None:
    print("MAC 篡改检测")
    fields = bwdecode.Payload.from_bytes(payload)
    assert fields is not None
    check(fields.is_valid(KEY), "原载荷 MAC 通过")
    tampered = bytearray(payload)
    tampered[0] ^= 0x01
    edited = bwdecode.Payload.from_bytes(bytes(tampered))
    assert edited is not None
    check(not edited.is_valid(KEY), "改一个 bit → MAC 不通过")


def test_page_codec() -> None:
    print("页面短码")
    cases = {
        "BHProfileViewController": "profile",
        "BHChatListViewController": "chatlist",
        "BHLiveRoomViewController": "liveroom",
        "BHUserProfileEditViewController": "userprofil",
        "Module.BHOrderViewController": "order",
    }
    for class_name, expected in cases.items():
        code = bwdecode.page_name_code(class_name)
        check(code == expected, f"{class_name} → {code}")
        check(bwdecode.decode_page_code(bwdecode.encode_page_code(code)) == code, f"{code} 编解码回环")
    check(bwdecode.registry_matches(["BHProfileViewController", "BHChatListViewController"], "profile")
          == ["BHProfileViewController"], "注册表按短码命中唯一类名")


def test_self_check() -> None:
    print("公开自检值（无密钥部署）")
    signed = make_payload()
    checked = make_self_checked()
    unsigned = make_unsigned()

    check(tier_of(checked, None) == "selfCheck", "自检载荷：无密钥也能判定为自检值通过")
    check(tier_of(checked, b"") == "selfCheck", "自检载荷：换任何密钥都是自检值通过（不是验签）")
    check(tier_of(signed, KEY) == "signed", "HMAC 载荷：有密钥时是验签通过")
    check(tier_of(signed, None) == "failed", 'HMAC 载荷：没密钥时报未校验（调用方应说「需要 --key」）')
    check(tier_of(unsigned, KEY) == "unsigned", "mac 全 0：报未签名，不能报 BAD")

    # 近似解——半块相位错位解出的就是这种东西：只改几个 bit，结构字段一点没动。
    # 这正是必须用覆盖全载荷的校验值、而不能只看结构的原因。
    near_copy = bytearray(checked)
    near_copy[0] ^= 0b0000_1111
    fields = bwdecode.Payload.from_bytes(bytes(near_copy))
    assert fields is not None
    check(fields.verification(None) == "failed", "近似解（改 4 bit）→ 自检值拦截")
    check(fields.is_plausible, "同一个近似解→ 结构自检拦不住（这就是结构自检只能当兵底的原因）")

    # 篡改一位也要拦
    tampered = bytearray(checked)
    tampered[8] ^= 0x01
    tampered_fields = bwdecode.Payload.from_bytes(bytes(tampered))
    assert tampered_fields is not None
    check(tampered_fields.verification(None) == "failed", "改 pageCode 一位 → 自检值拦截")


def test_crop_without_key() -> None:
    print("无密钥的裁剪自愈（自检值 vs 结构自检）")
    payload = make_self_checked()
    image = shot(payload, "chroma", (0, 0), width=640, height=900)
    cases = [(0, 137), (0, 400), (8, 0), (16, 0), (24, 0), (40, 0), (16, 400)]

    strict_ok = 0
    for left, top in cases:
        result, tier = bwdecode.decode_with_ladder(
            crop(image, left, top), [bwdecode.PAYLOAD_BITS], ("chroma",), None)
        if result is not None and result.payload_bytes == payload and tier in ("signed", "selfCheck"):
            strict_ok += 1
    check(strict_ok == len(cases), f"自检值裁决：{strict_ok}/{len(cases)} 裁剪用例解对")

    # 结构自检的短板不在"这张图上的命中率"，而在它拦不住近似解：
    # 把 64 相位 × 512 tile 平移全枚举一遍，数"通过校验但不是真解"的假阳性。
    # 自检值必须为 0（实测），结构自检必然有漏网 —— 这就是 A 方案存在的理由。
    false_positives = {}
    for label, check_validator in (("自检值", lambda c: tier_of(c.payload_bytes, None) == "selfCheck"),
                                   ("结构自检", bwdecode.structural_validator)):
        sat = bwdecode.integral_image(bwdecode.feature_plane(image, "chroma"))
        height, width = image.shape[:2]
        count = 0
        for oy in range(bwdecode.BLOCK):
            for ox in range(bwdecode.BLOCK):
                stats = bwdecode.accumulate(sat, width, height, ox, oy)
                for rotation in range(bwdecode.PAIRS_PER_TILE):
                    candidate = bwdecode.fold(stats, bwdecode.PAYLOAD_BITS, rotation)
                    if candidate.payload_bytes != payload and check_validator(candidate):
                        count += 1
        false_positives[label] = count
    check(false_positives["自检值"] == 0,
          f"全搜索空间（64×512）里自检值的假阳性 = {false_positives['自检值']}")
    check(false_positives["结构自检"] > 0,
          f"同一空间里结构自检的假阳性 = {false_positives['结构自检']}（所以它只能当兵底）")


def test_pair_offset() -> None:
    print("block 奇偶档（横向裁剪是奇数个块）")
    payload = make_self_checked()
    image = shot(payload, "chroma", (0, 0), width=640, height=900)
    strict = bwdecode.valid_validator(None)

    aligned = bwdecode.decode_best(crop(image, 16, 0), planes=("chroma",), validate=strict)
    assert aligned is not None

    for left in (8, 24, 40):
        plain = bwdecode.decode_best(crop(image, left, 0), planes=("chroma",), validate=strict)
        parity = bwdecode.decode_best(crop(image, left, 0), planes=("chroma",),
                                      search_pair_offset=True, validate=strict)
        check(plain is not None and plain.payload_bytes == payload, f"left={left} 常规搜索也能解对")
        check(parity is not None and parity.payload_bytes == payload, f"left={left} 奇偶档解出的载荷不对")
        check(parity.median_abs_z > plain.median_abs_z,
              f"left={left} 奇偶档读到真正的 pair（|z| {plain.median_abs_z:.1f} → {parity.median_abs_z:.1f}）")


def test_swift_cross_check(payload: bytes) -> None:
    print("与 Swift bwdecode 对账")
    if not os.path.exists(SWIFT_CLI):
        print(f"  跳过：没有 {SWIFT_CLI}（先 swift build -c release）")
        return
    image = shot(payload, "chroma", (0, 0))
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "shot.png")
        Image.fromarray(image, mode="RGBA").save(path)

        ours = bwdecode.decode(np.array(Image.open(path).convert("RGBA"), dtype=np.uint8))
        assert ours is not None
        result = subprocess.run(
            [SWIFT_CLI, path, "--plane", "chroma", "--layout", "--key", KEY_HEX],
            capture_output=True, text=True, check=True,
        )
        theirs = result.stdout.strip().splitlines()
        check(f"payload=0x{ours.payload_bytes.hex()}" in theirs[0],
              "同一张 PNG：Python 与 Swift 解出同一份 payload")
        check(f"弱bit={ours.weak_bits}/{ours.payload_bits}" in theirs[0], "弱 bit 一致")
        parsed = bwdecode.Payload.from_bytes(ours.payload_bytes)
        assert parsed is not None
        check(f"uid={parsed.uid}(0x{parsed.uid:08X})" in theirs[1], "字段解读一致")
        check("mac=OK(验签)" in theirs[1], "两侧都报验签通过")

        # 无密钥的裁剪自愈：换成自检载荷，两条实现都必须靠自检值解对
        checked = make_self_checked()
        checked_image = shot(checked, "chroma", (0, 0))
        checked_path = os.path.join(folder, "selfcheck.png")
        Image.fromarray(checked_image, mode="RGBA").save(checked_path)
        result = subprocess.run(
            [SWIFT_CLI, checked_path, "--auto", "--layout"],
            capture_output=True, text=True, check=True,
        )
        check(f"payload=0x{checked.hex()}" in result.stdout.splitlines()[0],
              "自检载荷：Swift 无密钥也能解对")
        check("mac=OK(自检,未验签)" in result.stdout, 'Swift 如实报「自检通过（未验签）」')
        ours_checked, tier = bwdecode.decode_with_ladder(
            checked_image, [bwdecode.PAYLOAD_BITS], ("chroma",), None)
        check(ours_checked is not None and ours_checked.payload_bytes == checked
              and tier == "selfCheck", "自检载荷：Python 无密钥也能解对")

        cropped = os.path.join(folder, "cropped.png")
        Image.fromarray(crop(image, 24, 137), mode="RGBA").save(cropped)
        result = subprocess.run(
            [SWIFT_CLI, cropped, "--auto", "--plane", "chroma", "--layout", "--key", KEY_HEX],
            capture_output=True, text=True, check=True,
        )
        auto = bwdecode.decode_best(crop(image, 24, 137), validate=validator)
        assert auto is not None
        check(f"payload=0x{auto.payload_bytes.hex()}" in result.stdout.splitlines()[0],
              "--auto 裁剪图：两条实现给出同一份 payload")


def main() -> int:
    try:
        payload = test_round_trip()
        test_wrong_parameters(payload)
        test_crop(payload)
        test_no_watermark()
        test_tamper(payload)
        test_self_check()
        test_crop_without_key()
        test_pair_offset()
        test_page_codec()
        test_swift_cross_check(payload)
    except AssertionError as error:
        print(f"\n失败: {error}", file=sys.stderr)
        return 1
    print(f"\n全部通过（{CHECKS} 项检查）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
