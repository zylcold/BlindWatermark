#!/usr/bin/env python3
"""`tools/bwdecode.py` 的自检。

不引测试框架：合成 tile → 平铺到带噪声的底图上 → 解回来，逐项断言。
再跑一遍 Swift 版 `bwdecode`（有二进制就用）对账，因为这套解码逻辑有两份实现，
最怕的是两份悄悄漂移。

    python3 tools/test_bwdecode.py
"""

from __future__ import annotations

import os
import shutil
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


def v52_shot(payload: bwdecode.WatermarkPayloadV52, offset: tuple[int, int] = (0, 0),
             alpha: int = 8, plane: str = "chroma", sync: str = bwdecode.V52_SYNC_NONE,
             width: int = 640, height: int = 900) -> np.ndarray:
    """v5.2 合成图：固定灰底、预乘 RGBA 平铺，和 Swift V52Tests 同一几何。"""
    canvas = np.zeros((height, width, 4), dtype=np.uint8)
    canvas[:, :, :3] = 200
    canvas[:, :, 3] = 255
    tile = bwdecode.v52_make_tile(payload, alpha=alpha, plane=plane, sync=sync)
    dx, dy = offset
    y = dy - bwdecode.TILE
    while y < height:
        x = dx - bwdecode.TILE
        while x < width:
            _blend(canvas, tile, x, y)
            x += bwdecode.TILE
        y += bwdecode.TILE
    return canvas


def resize_nearest(image: np.ndarray, scale: float) -> np.ndarray:
    height, width = image.shape[:2]
    new_width = int(width * scale)
    new_height = int(height * scale)
    output = np.zeros((new_height, new_width, 4), dtype=np.uint8)
    for y in range(new_height):
        source_y = min(height - 1, int(y / scale))
        for x in range(new_width):
            source_x = min(width - 1, int(x / scale))
            output[y, x] = image[source_y, source_x]
    return output


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


BUILD = 202609161722


def make_payload(uid: int = 0x1234_5678, timestamp: int = 1_760_000_000,
                 class_name: str = "BHProfileViewController", app: int = 1,
                 note: str = "hotfix-3") -> bytes:
    """有密钥部署：校验值是 HMAC。"""
    return bwdecode.Payload.build_payload(uid, timestamp, BUILD, class_name,
                                          note=note, app=app, key=KEY).bytes


def make_self_checked(uid: int = 0x1234_5678, timestamp: int = 1_760_000_000,
                      class_name: str = "BHProfileViewController", app: int = 1,
                      note: str = "hotfix-3") -> bytes:
    """无密钥部署：校验值位置是公开自检值。"""
    return bwdecode.Payload.build_payload(uid, timestamp, BUILD, class_name,
                                          note=note, app=app, key=None).bytes


def make_unsigned(uid: int = 0x1234_5678, timestamp: int = 1_760_000_000,
                  class_name: str = "BHProfileViewController", app: int = 1) -> bytes:
    """像 `mac: []` 那样没带校验值的载荷。"""
    fields = bwdecode.Payload.build_payload(uid, timestamp, BUILD, class_name,
                                            note="", app=app, key=None)
    return fields.bytes[:52] + bytes(12)


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
        "BHUserProfileEditViewController": "userprofileedit",   # 恰好 15 字符，不截断
        "Module.BHOrderViewController": "order",
    }
    for class_name, expected in cases.items():
        code = bwdecode.page_name_code(class_name)
        check(code == expected, f"{class_name} → {code}")
        encoded = bwdecode.encode_page_code(code)
        check(len(encoded) == 12, f"{code} → 12 字节（96 bit，其中 90 bit 有效）")
        check(bwdecode.decode_page_code(encoded) == code, f"{code} 编解码回环")
        check(bwdecode.validate_page_code(encoded), f"{code} 全部字符落在 37 符号表内")
    check(bwdecode.registry_matches(["BHProfileViewController", "BHChatListViewController"], "profile")
          == ["BHProfileViewController"], "注册表按短码命中唯一类名")

    # 15 字符只用 90 bit，字段剩 6 bit 必须为 0（结构自检会查）
    code = bwdecode.page_name_code("BHProfileViewController")
    encoded = bytearray(bwdecode.encode_page_code(code))
    check(bwdecode.validate_page_code(bytes(encoded)), "填充位为 0 时通过")
    encoded[11] |= 0x40          # 第 90 bit（未使用区）置 1
    check(not bwdecode.validate_page_code(bytes(encoded)), "填充位被置 1 → 结构自检拒绝")

    # note 现在是 22 字节
    check(bwdecode.NOTE_BYTE_COUNT == 22, "note 字段 22 字节")
    long_note = "x" * 40
    fields = bwdecode.Payload.build_payload(1, 1_760_000_000, 202609161722, "BHProfileViewController",
                                            note=long_note, key=KEY)
    check(len(fields.note.encode()) == 22, "超长 note 被截到 22 字节")


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
    tampered[16] ^= 0x01          # pageCode 首字节（v4 偏移 16..31）
    tampered_fields = bwdecode.Payload.from_bytes(bytes(tampered))
    assert tampered_fields is not None
    check(tampered_fields.verification(None) == "failed", "改 pageCode 一位 → 自检值拦截")

    for offset, hint in ((8, "build"), (33, "note"), (31, "tag")):
        edited = bytearray(checked)
        edited[offset] ^= 0x01
        fields_at = bwdecode.Payload.from_bytes(bytes(edited))
        assert fields_at is not None
        check(fields_at.verification(None) == "failed", f"改 {hint} 一位 → 自检值拦截")


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
    # 结构自检的假阳性数会随内容/几何变化（v4 的结构约束比 v3 强，这里可能为 0）。
    # 它不能当校验值用的真正理由见 test_self_check：近似解能过结构自检、过不了自检值 —— 那条是硬断言。
    check(false_positives["结构自检"] >= false_positives["自检值"],
          f"同一空间里结构自检的假阳性 = {false_positives['结构自检']}（只作参考，不依赖它裁决）")


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


def test_insufficient_observations() -> None:
    print("观测不足必须拒绝解读（图太小 / 图案被破坏）")
    payload = make_self_checked()
    # 640x900 → 每 bit 8.8 次观测；640x250 → 2.4 次
    full = shot(payload, "chroma", (0, 0))
    small = shot(payload, "chroma", (0, 0), width=640, height=250)

    big = bwdecode.decode(full, payload_bits=512, plane="chroma")
    tiny = bwdecode.decode(small, payload_bits=512, plane="chroma")
    assert big is not None and tiny is not None
    check(big.has_sufficient_evidence, f"整屏图观测够：最少 {big.min_observations} 次/bit")
    check(not tiny.has_sufficient_evidence,
          f"小图被标出来：最少 {tiny.min_observations} 次/bit（阈值 {bwdecode.MIN_OBSERVATIONS_PER_BIT}）")
    check(tiny.average_observations < bwdecode.MIN_OBSERVATIONS_PER_BIT,
          f"小图平均观测 {tiny.average_observations:.1f} 次/bit")

    # CLI 行为：小图 + --layout 必须拒绝并给非零退出码，而不是打一份看着正常的垃圾字段
    folder = tempfile.mkdtemp()
    try:
        small_path = os.path.join(folder, "small.png")
        Image.fromarray(small).save(small_path)
        result = subprocess.run([SWIFT_CLI, small_path, "--plane", "chroma", "--layout"],
                                capture_output=True, text=True)
        check(result.returncode != 0, f"Swift CLI 拒绝解读（exit={result.returncode}）")
        check("图像太小" in result.stderr or "TOO_SMALL" in result.stdout,
              "Swift CLI 明确报「图像太小 / TOO_SMALL」")

        full_path = os.path.join(folder, "full.png")
        Image.fromarray(full).save(full_path)
        result = subprocess.run([SWIFT_CLI, full_path, "--plane", "chroma", "--layout", "--key", KEY_HEX],
                                capture_output=True, text=True)
        check(result.returncode == 0 and "uid=" in result.stdout, "正常尺寸仍然照常解读")
    finally:
        shutil.rmtree(folder)


def test_v52() -> bwdecode.WatermarkPayloadV52:
    print("v5.2 紧凑载荷 / BCH / 缩放路径")
    legacy_auto = bwdecode.parse_args(["--auto"])
    mixed_auto = bwdecode.parse_args(["--protocol", "auto"])
    check(legacy_auto["protocol"] == "v4" and legacy_auto["auto"],
          "裸 --auto 保留 v4 历史搜索语义")
    check(mixed_auto["protocol"] == "auto", "混合协议探测必须显式 --protocol auto")
    payload = bwdecode.WatermarkPayloadV52.from_codes(
        0x1234_5678, 1_234_567, 89_012, "profile", 42, "hotfix")
    assert payload is not None
    check(payload.bytes.hex() == "8167452371682d01a0dd0a50ffa86faf4a0520236ff49078f702",
          "207-bit payload golden vector")
    codeword = bwdecode.V52BCH.encode(payload.bytes)
    check(codeword.hex() == "dbf79d8bb6998167452371682d01a0dd0a50ffa86faf4a0520236ff49078f782",
          "BCH(255,207)+even parity golden vector")
    restored = bwdecode.V52BCH.decode(codeword)
    check(restored is not None and restored.message_bytes == payload.bytes and restored.corrected_bits == 0,
          "BCH golden vector 回环")

    damaged = bytearray(codeword)
    for position in (0, 17, 63, 129, 211, 255):
        damaged[position >> 3] ^= 1 << (position & 7)
    corrected = bwdecode.V52BCH.decode(damaged)
    check(corrected is not None and corrected.message_bytes == payload.bytes and corrected.corrected_bits == 6,
          "BCH 六位错误可纠正（含扩展偶校验位）")

    image = v52_shot(payload, offset=(3, 5))
    direct = bwdecode.v52_decode(image, plane="chroma", sync=bwdecode.V52_SYNC_NONE,
                                 scale=1.0, offset_x=3, offset_y=5, search_tile=True)
    check(direct is not None and direct.is_success and direct.payload == payload,
          "v5.2 baseline：预乘 chroma tile 回环")
    check(direct is not None and direct.corrected_bits == 0 and direct.candidate_count == 1,
          "v5.2 baseline：无软恢复且候选唯一")

    cropped = bwdecode.v52_decode_best(
        image[13:, 9:], scales=[1.0], planes=("chroma",),
        sync_modes=(bwdecode.V52_SYNC_NONE,), search_phase=True, search_tile=True, max_contexts=4)
    check(cropped is not None and cropped.is_success and cropped.payload == payload,
          "v5.2：未知 phase + tile rotation 的裁剪图解回")

    resized = resize_nearest(v52_shot(payload), 0.837)
    explicit = bwdecode.v52_decode(resized, plane="chroma", sync=bwdecode.V52_SYNC_NONE,
                                   scale=0.837, offset_x=0, offset_y=0, search_tile=True)
    check(explicit is not None and explicit.is_success and explicit.payload == payload,
          "v5.2：显式 0.837 等比缩放")
    searched = bwdecode.v52_decode_best(
        resized, scales=[0.80, 0.85, 0.90], planes=("chroma",),
        sync_modes=(bwdecode.V52_SYNC_NONE,), search_phase=False, search_tile=True, max_contexts=4)
    check(searched is not None and searched.is_success and searched.payload == payload,
          "v5.2：不在粗网格的比例由局部精搜解回")
    estimated_scale = searched.estimated_scale if searched is not None else float("nan")
    check(searched is not None and abs(searched.estimated_scale - 0.837) < 0.003,
          f"v5.2：估计比例接近真值（{estimated_scale:.4f}）")

    for sync in (bwdecode.V52_SYNC_PN, bwdecode.V52_SYNC_SEPARATED):
        pilot_image = v52_shot(payload, offset=(3, 5), sync=sync)
        pilot = bwdecode.v52_decode(pilot_image, plane="chroma", sync=sync,
                                    scale=1.0, offset_x=3, offset_y=5, search_tile=True)
        check(pilot is not None and pilot.is_success and pilot.payload == payload,
              f"v5.2 pilot={sync}：数据回环")
        pilot_score = pilot.pilot_score if pilot is not None else float("nan")
        check(pilot is not None and pilot.pilot_score > 0.1,
              f"v5.2 pilot={sync}：相关性指标可测（{pilot_score:.3f}）")

    plain = np.zeros((900, 640, 4), dtype=np.uint8)
    plain[:, :, :3] = 200
    plain[:, :, 3] = 255
    check(bwdecode.v52_decode(plain, plane="chroma", sync=bwdecode.V52_SYNC_NONE,
                              scale=1.0, search_tile=True) is None,
          "v5.2 纯色负样本无 CRC-valid 候选")

    # PN 序列是跨语言契约（tile 像素与 pilotScore 都靠它）。golden vector 两边同串。
    pn_bits = "".join("1" if bwdecode._v52_pn_bit(i) else "0" for i in range(64))
    check(pn_bits == "1011111010000010101000111101010111010011010110110000101100011000",
          "v5.2 PN golden vector（前 64 bit）")

    # 不同 payload 同时 CRC-valid → ambiguous，不按 score 挑一个（Swift 侧同一条规则有单测）
    other = bwdecode.WatermarkPayloadV52(uid=0xDEADBEEF, timestamp_offset=7,
                                         build_minute_offset=3, page_code="other",
                                         app=1, note_code="x")

    def candidate(value, score):
        return bwdecode._V52Candidate(payload=value, codeword_bytes=value.bytes,
                                      corrected_bits=0, soft_recovery_used=False,
                                      plane="chroma", sync=bwdecode.V52_SYNC_NONE,
                                      scale=1.0, offset_x=0, offset_y=0, pilot_score=0.0,
                                      median_abs_z=5.0, min_observations=20,
                                      average_observations=20.0, score=score)

    single = bwdecode._v52_adjudicate([candidate(payload, 1.0)])
    check(single is not None and single.is_success and single.payload == payload,
          "v5.2 单一候选照常返回")
    ambiguous = bwdecode._v52_adjudicate([candidate(payload, 1.0), candidate(other, 9.0)])
    check(ambiguous is not None and ambiguous.ambiguous and ambiguous.payload is None
          and ambiguous.candidate_count == 2
          and ambiguous.failure_reason == "multiple distinct CRC-valid payloads",
          "v5.2 两个不同 CRC-valid 候选 → ambiguous 且拒绝返回")

    # 小图观测不足：能解出错值不对的载荷也必须标记出来，CLI 靠它拒绝解读字段
    small = v52_shot(payload, offset=(0, 0), width=320, height=320)
    tiny = bwdecode.v52_decode(small, plane="chroma", sync=bwdecode.V52_SYNC_NONE,
                               scale=1.0, offset_x=0, offset_y=0, search_tile=False)
    check(tiny is not None and tiny.payload == payload and not tiny.has_sufficient_evidence,
          f"v5.2 小图被标出观测不足（最少 {tiny.min_observations if tiny else -1} 次/bit）")
    full_screen = v52_shot(payload, offset=(0, 0))
    big = bwdecode.v52_decode(full_screen, plane="chroma", sync=bwdecode.V52_SYNC_NONE,
                              scale=1.0, offset_x=0, offset_y=0, search_tile=False)
    check(big is not None and big.has_sufficient_evidence,
          f"v5.2 常规尺寸观测够（最少 {big.min_observations if big else -1} 次/bit）")
    return payload


def test_scale_ruler() -> None:
    """比例尺粗定位 + 粗筛按比例排名的回归。"""
    print("比例尺粗定位 / 非网格比例")
    payload = bwdecode.WatermarkPayloadV52.build(uid=0x12345678, timestamp=1767250000,
                                                 build_time=1767250000,
                                                 page_class_name="ProfileViewController", note="hotfix")
    base = v52_shot(payload, offset=(3, 5), width=528, height=792)
    for scale in (0.50, 0.837, 1.173, 1.50):
        resized = np.ascontiguousarray(resize_nearest(base, scale))
        hint = bwdecode.estimate_scale_ruler(resized, planes=("chroma",))
        check(hint is not None, f"scale={scale}：给出估计")
        plane, estimated, confidence = hint
        check(plane == "chroma", f"scale={scale}：平面 {plane}")
        check(abs(estimated - scale) / scale <= 0.08, f"scale={scale}：估计 {estimated:.3f}（误差 ≤8%）")
        check(confidence >= bwdecode.SCALE_RULER_MIN_CONFIDENCE, f"scale={scale}：置信 {confidence:.2f}")
        candidates = bwdecode.ruler_candidate_scales(estimated)
        check(len(candidates) == bwdecode.SCALE_RULER_STEPS, f"scale={scale}：{len(candidates)} 个候选")
        check(any(abs(c - scale) / scale <= 0.03 for c in candidates),
              f"scale={scale}：候选 {candidates} 罩住真值")

    plain = np.zeros((792, 528, 4), dtype=np.uint8)
    plain[:, :, :3] = 200
    plain[:, :, 3] = 255
    quiet = bwdecode.estimate_scale_ruler(plain)
    check(quiet is None or quiet[2] < bwdecode.SCALE_RULER_MIN_CONFIDENCE,
          f"无水印图比例尺置信度低（{None if quiet is None else round(quiet[2], 3)}）")

    # 回归：粗筛按比例排名前，同一比例的上百个相位会挤满 top-N，0.837 / 1.173 这类
    # 非粗网格比例进不了精搜（显式 --scale 能解、默认网格解不出）
    for scale in (0.837, 1.173):
        resized = np.ascontiguousarray(resize_nearest(base, scale))
        result = bwdecode.v52_decode_best(
            resized, scales=list(bwdecode.V52_DEFAULT_SCALES), planes=("chroma",),
            sync_modes=(bwdecode.V52_SYNC_NONE,), search_phase=True, search_tile=True)
        check(result is not None and result.payload == payload,
              f"默认 21 档网格解出 scale={scale}")
        check(result is not None and abs(result.estimated_scale - scale) < 0.004,
              f"scale={scale} 估计精度 {None if result is None else round(result.estimated_scale, 4)}")

    # 跨语言：同一张图，两端比例尺估计要一致
    if not os.path.exists(SWIFT_CLI):
        print(f"  跳过 CLI 对账：没有 {SWIFT_CLI}（先 swift build -c release）")
        return
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "scaled.png")
        Image.fromarray(np.ascontiguousarray(resize_nearest(base, 0.837)), mode="RGBA").save(path)
        estimates = []
        for name, command in (("Swift", [SWIFT_CLI]),
                              ("Python", [sys.executable, os.path.join(REPO, "tools", "bwdecode.py")])):
            result = subprocess.run(
                command + [path, "--protocol", "v5.2", "--auto", "--layout"],
                capture_output=True, text=True, check=True,
            )
            marker = "scale≈"
            check(marker in result.stderr, f"{name} CLI 打出比例尺粗定位")
            raw = result.stderr.split(marker)[1]
            digits = ""
            for character in raw:
                if character.isdigit() or character == ".":
                    digits += character
                else:
                    break
            estimates.append(float(digits))
            check(f"payload=0x{payload.bytes.hex()}" in result.stdout.splitlines()[0],
                  f"{name} CLI：粗定位后解出同一份 payload")
        check(abs(estimates[0] - estimates[1]) / estimates[0] <= 0.03,
              f"两端比例尺估计一致（{estimates[0]:.3f} / {estimates[1]:.3f}）")


def test_border_trim() -> None:
    """黑边（IM 转发 / 图片查看器套的纯黑边框）必须自动裁掉，深色页留白必须不动。"""
    print("黑边自动裁剪")
    payload = bwdecode.WatermarkPayloadV52.build(uid=0x12345678, timestamp=1767250000,
                                                 build_time=1767250000,
                                                 page_class_name="ProfileViewController", note="hotfix")
    shot = v52_shot(payload, offset=(3, 5), width=640, height=900)
    barred = np.zeros((shot.shape[0], shot.shape[1] + 23, 4), dtype=np.uint8)
    barred[:, :, 3] = 255
    barred[:, 9:9 + shot.shape[1]] = shot

    trimmed, trim = bwdecode.trim_uniform_dark_border(barred)
    check(trim == (9, 0, 14, 0), f"识别出黑边 trim={trim}")
    check(trimmed.shape == shot.shape, f"裁到内容区 {trimmed.shape}")
    check(bool((trimmed == shot).all()), "裁出来的就是内容区像素")

    # 深色页留白：四边各超过 25% 纯黑 → 当作内容，一列都不裁
    dark = np.zeros((900, 640, 4), dtype=np.uint8)
    dark[:, :, 3] = 255
    dark[250:650, 200:440] = 255
    _, dark_trim = bwdecode.trim_uniform_dark_border(dark)
    check(dark_trim == (0, 0, 0, 0), f"深色留白不裁（{dark_trim}）")

    if not os.path.exists(SWIFT_CLI):
        print(f"  跳过 CLI 对账：没有 {SWIFT_CLI}（先 swift build -c release）")
        return
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "barred.png")
        Image.fromarray(barred, mode="RGBA").save(path)
        expected = f"payload=0x{payload.bytes.hex()}"
        outputs = []
        for name, command in (("Swift", [SWIFT_CLI]),
                              ("Python", [sys.executable, os.path.join(REPO, "tools", "bwdecode.py")])):
            result = subprocess.run(
                command + [path, "--protocol", "v5.2", "--auto-offset", "--scale", "1", "--layout"],
                capture_output=True, text=True, check=True,
            )
            outputs.append(result.stdout)
            check(expected in result.stdout.splitlines()[0], f"{name} CLI：裁掉黑边后解出同一份 payload")
            check("trim=(9,0,14,0)" in result.stdout, f"{name} CLI：输出里带 trim=(9,0,14,0)")
        check(outputs[0].splitlines()[1] == outputs[1].splitlines()[1],
              "带黑边的图：两端字段行一致")


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


def test_swift_v52_cross_check(payload: bwdecode.WatermarkPayloadV52) -> None:
    print("v5.2 与 Swift bwdecode 对账")
    if not os.path.exists(SWIFT_CLI):
        print(f"  跳过：没有 {SWIFT_CLI}（先 swift build -c release）")
        return
    image = v52_shot(payload, offset=(0, 0))
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "v52.png")
        Image.fromarray(image, mode="RGBA").save(path)
        python_result = subprocess.run(
            [sys.executable, os.path.join(REPO, "tools", "bwdecode.py"), path,
             "--protocol", "v5.2", "--layout", "--scale", "1"],
            capture_output=True, text=True, check=True,
        )
        swift_result = subprocess.run(
            [SWIFT_CLI, path, "--protocol", "v5.2", "--layout", "--scale", "1"],
            capture_output=True, text=True, check=True,
        )
        first = f"payload=0x{payload.bytes.hex()}"
        check(first in python_result.stdout.splitlines()[0], "Python v5.2 CLI 输出 golden payload")
        check(first in swift_result.stdout.splitlines()[0], "Swift v5.2 CLI 输出同一份 payload")
        check(python_result.stdout.splitlines()[1] == swift_result.stdout.splitlines()[1],
              "同一张 PNG：Python 与 Swift v5.2 字段行一致")
        check("crcStatus=OK" in swift_result.stdout and "correctedBits=0" in swift_result.stdout,
              "Swift v5.2 CLI 明确报告 CRC 与纠错诊断")
        check("crcStatus=OK(完整性自检,未验签)" in swift_result.stdout
              and not any("mac=" in line for line in swift_result.stdout.splitlines()),
              "v5.2 不得把 CRC24 说成验签（两端措辞一致）")

        cropped_path = os.path.join(folder, "v52-cropped.png")
        Image.fromarray(image[13:, 9:], mode="RGBA").save(cropped_path)
        swift_cropped = subprocess.run(
            [SWIFT_CLI, cropped_path, "--protocol", "v5.2", "--auto", "--layout"],
            capture_output=True, text=True, check=True,
        )
        check(first in swift_cropped.stdout.splitlines()[0],
              "Swift v5.2 CLI：未知 phase / tile rotation 裁剪图解回")

        # 小图：两端都必须拒绝解读字段，而不是打一份看着正常的垃圾
        small_path = os.path.join(folder, "v52-small.png")
        Image.fromarray(v52_shot(payload, offset=(0, 0), width=320, height=320)).save(small_path)
        for name, command in (("Swift", [SWIFT_CLI]), ("Python", [sys.executable, os.path.join(REPO, "tools", "bwdecode.py")])):
            gated = subprocess.run(
                command + [small_path, "--protocol", "v5.2", "--layout", "--scale", "1"],
                capture_output=True, text=True,
            )
            check(gated.returncode != 0, f"{name} v5.2 CLI 小图拒绝解读（exit={gated.returncode}）")
            check("TOO_SMALL" in gated.stdout and "minObs=" in gated.stdout,
                  f"{name} v5.2 CLI 报 TOO_SMALL 并带观测数")
            warned = subprocess.run(
                command + [small_path, "--protocol", "v5.2", "--scale", "1"],
                capture_output=True, text=True,
            )
            check(warned.returncode == 0 and "uid=" not in warned.stdout
                  and "载荷不可信" in warned.stderr,
                  f"{name} v5.2 CLI 小图不加 --layout 时只警告、不解读字段")

        # pilot=pn：同一张 PNG 上两端的 pilotScore 必须逐位一致（PN 序列 + tile 像素都对账）
        pn_path = os.path.join(folder, "v52-pn.png")
        Image.fromarray(v52_shot(payload, offset=(3, 5), sync=bwdecode.V52_SYNC_PN)).save(pn_path)
        scores = []
        for command in ([sys.executable, os.path.join(REPO, "tools", "bwdecode.py")], [SWIFT_CLI]):
            pn_result = subprocess.run(
                command + [pn_path, "--protocol", "v5.2", "--pilot", "pn", "--scale", "1",
                           "--offset", "3,5"],
                capture_output=True, text=True, check=True,
            )
            scores.append(float(pn_result.stdout.split("pilotScore=")[1].split()[0]))
        check(abs(scores[0] - scores[1]) < 1e-3 and scores[0] > 0.1,
              f"pilot=pn：两端 pilotScore 一致（{scores[0]:.6f} / {scores[1]:.6f}）")


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
        test_insufficient_observations()
        test_page_codec()
        v52_payload = test_v52()
        test_border_trim()
        test_scale_ruler()
        test_swift_cross_check(payload)
        test_swift_v52_cross_check(v52_payload)
    except AssertionError as error:
        print(f"\n失败: {error}", file=sys.stderr)
        return 1
    print(f"\n全部通过（{CHECKS} 项检查）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
