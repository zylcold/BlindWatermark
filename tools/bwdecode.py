#!/usr/bin/env python3
"""截图盲水印解码器（Python 版）。

与 `Sources/bwdecode/main.swift` 行为对齐：同样的参数、同样的输出格式、同样的判读规则，
区别只在实现语言。用途是**跨语言备份**：macOS 上编不了 Swift 时也能解截图，
以及拿两套实现对账（`tools/test_bwdecode.py` 就跑这个对账）。

依赖 numpy（特征平面与积分图）与 Pillow（读 PNG/JPEG）。系统的处理逻辑都在
`Sources/BlindWatermarkCore/BlockCodec.swift`，这里是它的镜像 —— 改一处必须改两处，
`tools/test_bwdecode.py` 会在两张图上做交叉验证。

用法见 `--help` 或 README 的「解码」一节。
"""

from __future__ import annotations

import datetime
import hashlib
import hmac
import json
import math
import sys

import numpy as np
from PIL import Image

# MARK: - 与 Swift 端必须一致的前常量

BLOCK = 8  # 块边长（设备像素）
TILE = 256  # 平铺周期（设备像素）
PAIRS_PER_ROW = TILE // BLOCK // 2  # 16
BLOCK_ROWS_PER_TILE = TILE // BLOCK  # 32
PAIRS_PER_TILE = PAIRS_PER_ROW * BLOCK_ROWS_PER_TILE  # 512
MAX_PAYLOAD_BITS = 256
MAX_PHASE_FINALISTS = 16

# 低于此方差的观测按此方差算，避免纯色画面上 z 值除以 0 而爆掉
MIN_VARIANCE = 0.25
# 观测幅度下限：低于此值的 pair 弃权。否则纯色背景上 d == 0 会被当成一个方向的观测
MIN_MAGNITUDE = 0.5
# |z| 小于它就认为该 bit 证据不足
WEAK_Z = 3.0

PAYLOAD_BITS = 256
PAYLOAD_BYTE_COUNT = 32
LAYOUT_VERSION = 3
MAC_BYTE_COUNT = 12
SIGNED_BYTE_COUNT = 20
# 结构自检认定的合理时间戳区间：2015-01-01 ... 2100-01-01
PLAUSIBLE_TIMESTAMP = (1_420_070_400, 4_102_444_800)

SUFFIX_LADDER = [
    "ViewController", "ViewModel", "Presenter", "Interactor",
    "Controller", "View", "Page", "Screen", "Scene", "Cell", "Item", "Model", "VC",
]
KNOWN_PREFIXES = ["BH", "JY", "LL", "HW", "XQ"]
CODE_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789_"
CODE_LENGTH = 10
PAD_CHARACTER = "_"


# MARK: - 特征平面与积分图


def feature_plane(rgba: np.ndarray, plane: str) -> np.ndarray:
    """逐像素标量特征，量纲与像素值一致（对应 `RGBAImage.featureBuffer`）。"""
    px = rgba.astype(np.float64)
    r, g, b = px[:, :, 0], px[:, :, 1], px[:, :, 2]
    if plane == "luma":
        return 0.299 * r + 0.587 * g + 0.114 * b
    # chroma：蓝-黄对色平面。灰阶内容在这里恒为 0，所以内容噪声几乎消失
    return b - (r + g) / 2.0


def integral_image(feature: np.ndarray) -> np.ndarray:
    """尺寸 (h+1, w+1)，首行首列为 0。块均值 O(1) 取值。"""
    h, w = feature.shape
    sat = np.zeros((h + 1, w + 1), dtype=np.float64)
    sat[1:, 1:] = feature.cumsum(axis=0).cumsum(axis=1)
    return sat


def block_mean(sat: np.ndarray, x: int, y: int) -> float:
    x2, y2 = x + BLOCK, y + BLOCK
    total = sat[y2, x2] - sat[y, x2] - sat[y2, x] + sat[y, x]
    return total / (BLOCK * BLOCK)


def block_means(sat: np.ndarray, xs: np.ndarray, ys: np.ndarray) -> np.ndarray:
    """按 (ys, xs) 网格批量取块均值，等价于对每个点调 `block_mean`。"""
    y2 = ys[:, None] + BLOCK
    x2 = xs[None, :] + BLOCK
    total = (
        sat[y2, x2]
        - sat[ys[:, None], x2]
        - sat[y2, xs[None, :]]
        + sat[ys[:, None], xs[None, :]]
    )
    return total / (BLOCK * BLOCK)


# MARK: - 按 tile 本地 pair 累积


class PairStats:
    """按 tile 本地 pair 索引（0..<512）累积的统计。

    不做 `% payloadBits` 分组、不翻极性 —— 那两步推迟到折叠阶段，
    因此同一份统计可以廉价地按任意位数重读（自动探测位数的基础）。
    """

    __slots__ = ("sums", "sum_squares", "counts", "abs_sum", "observed")

    def __init__(self) -> None:
        self.sums = np.zeros(PAIRS_PER_TILE, dtype=np.float64)
        self.sum_squares = np.zeros(PAIRS_PER_TILE, dtype=np.float64)
        self.counts = np.zeros(PAIRS_PER_TILE, dtype=np.int64)
        self.abs_sum = 0.0
        self.observed = 0

    @property
    def signal(self) -> float:
        return self.abs_sum / self.observed if self.observed else 0.0


def accumulate(sat: np.ndarray, width: int, height: int, ox: int, oy: int) -> PairStats:
    """相位 (ox, oy) 下的 pair 统计。整除留下的边角一律丢弃，与 Swift 端一致。"""
    stats = PairStats()
    pair_rows = (height - oy) // BLOCK
    pair_cols = ((width - ox) // BLOCK) // 2
    if pair_rows <= 0 or pair_cols <= 0:
        return stats

    rows = np.arange(pair_rows)
    cols = np.arange(pair_cols)
    xs = ox + cols * 2 * BLOCK
    ys = oy + rows * BLOCK
    # 每个 pair 取左块均值减右块均值（x 每次跨两个块）
    d = block_means(sat, xs, ys) - block_means(sat, xs + BLOCK, ys)

    # 本地索引取模，让跨 tile 的观测叠到同一个 pair 上
    index = (rows[:, None] % BLOCK_ROWS_PER_TILE) * PAIRS_PER_ROW + (cols[None, :] % PAIRS_PER_ROW)

    keep = np.abs(d) >= MIN_MAGNITUDE
    flat_index = index[keep].ravel()
    flat_d = d[keep].ravel()
    np.add.at(stats.sums, flat_index, flat_d)
    np.add.at(stats.sum_squares, flat_index, flat_d * flat_d)
    np.add.at(stats.counts, flat_index, 1)
    stats.abs_sum = float(np.abs(flat_d).sum())
    stats.observed = int(flat_d.size)
    return stats


# MARK: - 折叠成 per-bit 统计


class Decoded:
    __slots__ = (
        "payload_bytes", "payload_bits", "plane", "offset_x", "offset_y",
        "signal", "confidence", "weak_bits", "median_abs_z", "scores",
    )

    def __init__(self, payload_bytes, payload_bits, plane, offset_x, offset_y,
                 signal, confidence, weak_bits, median_abs_z, scores):
        self.payload_bytes = payload_bytes
        self.payload_bits = payload_bits
        self.plane = plane
        self.offset_x = offset_x
        self.offset_y = offset_y
        self.signal = signal
        self.confidence = confidence
        self.weak_bits = weak_bits
        self.median_abs_z = median_abs_z
        self.scores = scores


def is_flipped(local_pair_index: int, payload_bits: int) -> bool:
    """同一个 bit 的重复观测隔一份翻转极性，让梯度偏置成对相消。
    重复份数为奇数时不翻，宁可不抵消也不能翻错。"""
    repetitions = PAIRS_PER_TILE // payload_bits
    if repetitions < 2 or repetitions % 2 != 0:
        return False
    return (local_pair_index // payload_bits) % 2 == 1


_PAIR_ROWS = np.arange(PAIRS_PER_TILE) // PAIRS_PER_ROW
_PAIR_COLS = np.arange(PAIRS_PER_TILE) % PAIRS_PER_ROW


def fold(stats: PairStats, payload_bits: int, rotation: int = 0) -> Decoded:
    """把按 pair 累积的统计折叠成 per-bit 统计。

    `rotation` 补偿裁剪：`(行偏移) × PAIRS_PER_ROW + 列偏移`，覆盖 32×16 种 tile 平移。
    横向平移必须在 tile 右边界回卷到**本行第 0 列**，按线性索引加偏移会跨到下一行 ——
    那样只有 1/16 的观测错位，z 值照样漂亮、weak_bits 显得正常，只有 MAC 看得出来。
    """
    row_shift, col_shift = divmod(rotation, PAIRS_PER_ROW)
    shifted = ((_PAIR_ROWS + row_shift) % BLOCK_ROWS_PER_TILE) * PAIRS_PER_ROW
    shifted = shifted + (_PAIR_COLS + col_shift) % PAIRS_PER_ROW

    repetitions = PAIRS_PER_TILE // payload_bits
    flipped = np.zeros(PAIRS_PER_TILE, dtype=bool)
    if repetitions >= 2 and repetitions % 2 == 0:
        flipped = (shifted // payload_bits) % 2 == 1
    sign = np.where(flipped, -1.0, 1.0)
    bits = shifted % payload_bits

    sums = np.bincount(bits, weights=sign * stats.sums, minlength=payload_bits)[:payload_bits]
    sum_squares = np.bincount(bits, weights=stats.sum_squares, minlength=payload_bits)[:payload_bits]
    counts = np.bincount(bits, weights=stats.counts, minlength=payload_bits)[:payload_bits]

    scores = np.zeros(payload_bits, dtype=np.float64)
    usable = counts >= 2
    n = counts[usable]
    mean = sums[usable] / n
    variance = np.maximum(sum_squares[usable] / n - mean * mean, MIN_VARIANCE)
    scores[usable] = mean / np.sqrt(variance / n)

    # 水印压在低于均值的块上：z < 0 记 1
    payload_bytes = np.packbits(scores < 0, bitorder="little").tobytes()
    payload_bytes = payload_bytes[: (payload_bits + 7) // 8]

    absolute = np.sort(np.abs(scores[scores != 0]))
    return Decoded(
        payload_bytes=payload_bytes,
        payload_bits=payload_bits,
        plane="",
        offset_x=0,
        offset_y=0,
        signal=stats.signal,
        confidence=float(absolute[0]) if absolute.size else 0.0,
        # 「证据不足」要数**全部** bit：完全没观测到的 bit（z == 0）也算，
        # 否则纯色画面（所有 d 都低于 MIN_MAGNITUDE）会一个弱 bit 都没有，被报成「全部显著」
        weak_bits=int((np.abs(scores) < WEAK_Z).sum()),
        median_abs_z=float(absolute[absolute.size // 2]) if absolute.size else 0.0,
        scores=scores,
    )


def _with_context(decoded: Decoded, plane: str, ox: int, oy: int) -> Decoded:
    decoded.plane = plane
    decoded.offset_x = ox
    decoded.offset_y = oy
    return decoded


# MARK: - 解码入口


def decode(image: np.ndarray, payload_bits: int = PAYLOAD_BITS, offset_x: int = 0,
           offset_y: int = 0, plane: str = "chroma") -> Decoded | None:
    """整屏截图解码，参数全部显式给定。

    **payload_bits / plane 必须与编码端一致**，给错会得到一份自洽但错误的载荷。
    """
    if not 1 <= payload_bits <= MAX_PAYLOAD_BITS:
        raise ValueError(f"payloadBits 必须在 1...{MAX_PAYLOAD_BITS}")
    height, width = image.shape[:2]
    if width < BLOCK * 2 or height < BLOCK:
        return None
    sat = integral_image(feature_plane(image, plane))
    stats = accumulate(sat, width, height, offset_x, offset_y)
    return _with_context(fold(stats, payload_bits), plane, offset_x, offset_y)


def find_best_offset(image: np.ndarray, payload_bits: int = PAYLOAD_BITS, plane: str = "chroma",
                     search_pair_offset: bool = False, validate=None) -> tuple[int, int]:
    """只搜索块网格相位（0..<8）。给「已知被裁过、平面与位数确定」的调用方用。

    给了 `validate`（通常是 MAC 校验）就在**通过校验**的候选里取 medianAbsZ 最高的；
    一个都没通过、或没给校验器，退回 medianAbsZ 最高的 —— 那只代表「块对齐得最好」，
    **不保证解出正确载荷**。
    """
    if not 1 <= payload_bits <= MAX_PAYLOAD_BITS:
        raise ValueError(f"payloadBits 必须在 1...{MAX_PAYLOAD_BITS}")
    height, width = image.shape[:2]
    if width < BLOCK * 2 or height < BLOCK:
        return (0, 0)
    sat = integral_image(feature_plane(image, plane))

    best = (0, 0)
    best_score = -math.inf
    validated: tuple[tuple[int, int], float] | None = None
    column_count = BLOCK * 2 if search_pair_offset else BLOCK
    for oy in range(BLOCK):
        for ox in range(column_count):
            candidate = _with_context(fold(accumulate(sat, width, height, ox, oy), payload_bits), plane, ox, oy)
            if candidate.median_abs_z > best_score:
                best_score = candidate.median_abs_z
                best = (ox, oy)
            if validate is None or not validate(candidate):
                continue
            if validated is None or candidate.median_abs_z > validated[1]:
                validated = ((ox, oy), candidate.median_abs_z)
    return validated[0] if validated else best


def decode_best(image: np.ndarray, payload_bits_candidates=None, planes=("chroma", "luma"),
                search_phase: bool = True, search_tile: bool = True,
                search_pair_offset: bool = False, validate=None) -> Decoded | None:
    """自动探测解码：穷举相位 / 双平面 / 多种位数，选一个最可信的结果。

    裁决规则：**先看 `validate`**（HMAC 或公开自检值校验）；一个都没通过才退回按 medianAbsZ。
    裸穷举不可信 —— 错位相位在低变化画面上也能让所有 bit 自洽。

    `search_pair_offset` 多搜一档 block 偏移（ox 取 0..<16）：pair 是两个相邻块，
    块网格错开一个块时解码端配的是跨两个 pattern pair 的块对，读出来是相邻两个 bit 的和
    （只有两位相同时才留下观测），部分 bit 会稀疏到一个证据都没有。多搜一档后这些位重新变完整。
    """
    if payload_bits_candidates is None:
        payload_bits_candidates = [PAYLOAD_BITS, 32]
    bits_list = [b for b in payload_bits_candidates if 1 <= b <= MAX_PAYLOAD_BITS]
    if not bits_list:
        return None
    height, width = image.shape[:2]
    if width < BLOCK * 2 or height < BLOCK:
        return None

    # 阶段一：全平面全相位累加一次，排出「块对齐 + 图案自洽」最好的几组。
    # 排序不能用 signal（被内容撑大，没水印的 luma 平面能拿 19），用 z 值。
    scored = []
    column_count = BLOCK * 2 if search_pair_offset else BLOCK
    for plane in planes:
        sat = integral_image(feature_plane(image, plane))
        phases = ([(i % column_count, i // column_count) for i in range(column_count * BLOCK)]
                  if search_phase else [(0, 0)])
        for ox, oy in phases:
            stats = accumulate(sat, width, height, ox, oy)
            score = max(fold(stats, bits).median_abs_z for bits in bits_list)
            scored.append((plane, ox, oy, stats, score))
    if not scored:
        return None
    scored.sort(key=lambda item: -item[4])
    finalists = scored[: min(len(scored), MAX_PHASE_FINALISTS)]

    rotations = range(PAIRS_PER_TILE) if search_tile else [0]

    def build(context, bits: int, rotation: int) -> Decoded:
        plane, ox, oy, stats, _ = context
        return _with_context(fold(stats, bits, rotation), plane, ox, oy)

    if validate is None:
        # 没有校验器就不敢乱猜相位：只信块对齐最好那一组的原始相位、原始平移
        return build(finalists[0], bits_list[0], 0)

    # 阶段二：在入围相位上穷举 tile 平移（补偿裁剪）。错误平移同样能给出很干净的自洽载荷，
    # 唯一可靠的裁决是 MAC —— 所以校验器通过即返回，不按分数排。
    for context in finalists:
        for bits in bits_list:
            for rotation in rotations:
                candidate = build(context, bits, rotation)
                if validate(candidate):
                    return candidate
    return build(finalists[0], bits_list[0], 0)


# MARK: - 载荷布局与校验


def _u32_le(value: int) -> bytes:
    return int(value & 0xFFFFFFFF).to_bytes(4, "little")


def signed_body(uid: int, timestamp: int, page_code: int, tag: int) -> bytes:
    """前 20 字节的规范编码（小端，pageCode 高 4 位归零）。"""
    body = _u32_le(uid) + _u32_le(timestamp)
    body += int(page_code & 0x0FFFFFFFFFFFFFFF).to_bytes(8, "little")
    body += _u32_le(tag)
    assert len(body) == SIGNED_BYTE_COUNT
    return body


def payload_mac(uid: int, timestamp: int, page_code: int, tag: int, key: bytes) -> bytes:
    """前 20 字节的 HMAC-SHA256 截断到 96 bit。"""
    return hmac.new(key, signed_body(uid, timestamp, page_code, tag), hashlib.sha256).digest()[:MAC_BYTE_COUNT]


def self_check(uid: int, timestamp: int, page_code: int, tag: int) -> bytes:
    """公开自检值：SHA-256(前 20 字节) 截断到 96 bit，与 mac 同位。

    无密钥部署用它代替 HMAC：任何一位不同都过不了，所以能拦住"对齐错了几个 bit"的近似解。
    但拦不住伪造（谁都能算）—— 自检通过只证明"解对了"，不证明"没被改"。
    """
    return hashlib.sha256(signed_body(uid, timestamp, page_code, tag)).digest()[:MAC_BYTE_COUNT]


class Payload:
    """256 bit 推荐布局：uid + Unix 秒 + 页面短码 + tag + 96 bit mac，字段全小端。"""

    def __init__(self, uid: int, timestamp: int, page_code: int, tag: int, mac: bytes):
        self.uid = uid
        self.timestamp = timestamp
        self.page_code = page_code & 0x0FFFFFFFFFFFFFFF
        self.tag = tag
        self.mac = mac

    @classmethod
    def from_bytes(cls, raw: bytes) -> "Payload | None":
        if len(raw) != PAYLOAD_BYTE_COUNT:
            return None
        return cls(
            uid=int.from_bytes(raw[0:4], "little"),
            timestamp=int.from_bytes(raw[4:8], "little"),
            page_code=int.from_bytes(raw[8:16], "little"),
            tag=int.from_bytes(raw[16:20], "little"),
            mac=raw[20:32],
        )

    @classmethod
    def build(cls, uid: int, timestamp: int, page_class_name: str,
              app: int = 0, environment: int = 0, key: bytes = b"") -> "Payload":
        tag = (LAYOUT_VERSION << 28) | ((app & 0xFF) << 20) | ((environment & 0xFF) << 12)
        page_code = encode_page_code(page_name_code(page_class_name))
        return cls(uid, timestamp, page_code, tag,
                   payload_mac(uid, timestamp, page_code, tag, key))

    @classmethod
    def self_checked(cls, uid: int, timestamp: int, page_class_name: str,
                     app: int = 0, environment: int = 0) -> "Payload":
        """无密钥场景：mac 位置放公开自检值。"""
        tag = (LAYOUT_VERSION << 28) | ((app & 0xFF) << 20) | ((environment & 0xFF) << 12)
        page_code = encode_page_code(page_name_code(page_class_name))
        return cls(uid, timestamp, page_code, tag, self_check(uid, timestamp, page_code, tag))

    @property
    def layout_version(self) -> int:
        return self.tag >> 28

    @property
    def app(self) -> int:
        return (self.tag >> 20) & 0xFF

    @property
    def environment(self) -> int:
        return (self.tag >> 12) & 0xFF

    @property
    def page_name_code(self) -> str:
        return decode_page_code(self.page_code)

    def is_valid(self, key: bytes) -> bool:
        expected = payload_mac(self.uid, self.timestamp, self.page_code, self.tag, key)
        # 定长比较，不做短路
        return len(self.mac) == len(expected) and hmac.compare_digest(bytes(self.mac), expected)

    @property
    def is_unsigned(self) -> bool:
        """mac 全 0：载荷没带任何校验值。"""
        return all(byte == 0 for byte in self.mac)

    def verification(self, key: bytes | None) -> str:
        """判定载荷带的是哪种校验值：signed / selfCheck / unsigned / failed。

        没给密钥时签名载荷落在 failed，调用方应报"未校验(需要 --key)"而不是"被篡改"。
        """
        if self.is_unsigned:
            return "unsigned"
        if key is not None and self.is_valid(key):
            return "signed"
        if bytes(self.mac) == self_check(self.uid, self.timestamp, self.page_code, self.tag):
            return "selfCheck"
        return "failed"

    @property
    def is_plausible(self) -> bool:
        """结构自检：只看布局本身的结构约束，不需密钥也不靠额外字段。

        名义判别力 ≈ 28 bit，但**实测仍会放过近似解**（半块相位错位解出的是真载荷改几个 bit
        的拷贝，结构字段根本没动），所以只能当"没有任何校验值时的兵底"。
        """
        if self.layout_version != LAYOUT_VERSION:
            return False
        if self.tag & 0x0FFF:
            return False
        if self.page_code >> 60:
            return False
        if not PLAUSIBLE_TIMESTAMP[0] <= self.timestamp <= PLAUSIBLE_TIMESTAMP[1]:
            return False
        return all(((self.page_code >> (6 * i)) & 0x3F) < len(CODE_ALPHABET) for i in range(CODE_LENGTH))


# MARK: - 页面短码


def normalized_stem(class_name: str) -> str:
    """取最后一段类名 → 剥后缀（最多两层）→ 剥前缀 → 小写 → 只留字母数字。"""
    name = class_name.split(".")[-1] if "." in class_name else class_name
    stripped = 0
    changed = True
    while changed and stripped < 2:
        changed = False
        for suffix in SUFFIX_LADDER:  # 按长度降序，先剥长的
            if len(name) > len(suffix) and name.endswith(suffix):
                name = name[: -len(suffix)]
                stripped += 1
                changed = True
                break
    for prefix in KNOWN_PREFIXES:
        if len(name) > len(prefix) and name.startswith(prefix):
            name = name[len(prefix):]
            break
    return "".join(ch for ch in name.lower() if ch.isascii() and ch.isalnum())


def page_name_code(class_name: str) -> str:
    """类名 → 短码，去掉尾部补位符，保证 `decode(encode(code)) == code`。"""
    characters = list(normalized_stem(class_name)[:CODE_LENGTH])
    while len(characters) < CODE_LENGTH:
        characters.append(PAD_CHARACTER)
    while characters and characters[-1] == PAD_CHARACTER:
        characters.pop()
    return "".join(characters)


def encode_page_code(code: str) -> int:
    characters = list(code[:CODE_LENGTH])
    while len(characters) < CODE_LENGTH:
        characters.append(PAD_CHARACTER)
    value = 0
    for position, character in enumerate(characters):
        index = CODE_ALPHABET.find(character)
        value |= (index if index >= 0 else len(CODE_ALPHABET) - 1) << (6 * position)
    return value


def decode_page_code(value: int) -> str:
    characters = []
    for position in range(CODE_LENGTH):
        index = (value >> (6 * position)) & 0x3F
        characters.append(CODE_ALPHABET[index] if index < len(CODE_ALPHABET) else PAD_CHARACTER)
    while characters and characters[-1] == PAD_CHARACTER:
        characters.pop()
    return "".join(characters)


def grep_hint(code: str) -> str:
    if not code:
        return "短码为空，页面类名可能不含字母数字"
    return f'grep -rin "class.*{code}" --include=\'*.swift\''


def registry_matches(names: list[str], code: str) -> list[str]:
    if not code:
        return []
    return [name for name in names if page_name_code(name) == code]


# MARK: - CLI


def fail(message: str, code: int) -> "None":
    print(message, file=sys.stderr)
    raise SystemExit(code)


def warn(message: str) -> None:
    print("警告: " + message, file=sys.stderr)


def usage() -> str:
    return (
        "用法: bwdecode.py <截图路径> [--bits N] [--offset X,Y] [--auto-offset] "
        "[--plane luma|chroma] [--layout] [--key <hex>] [--pages <json>] [--auto] [--dump-codes]"
    )


def parse_args(argv: list[str]) -> dict:
    options = {
        "path": None, "payload_bits": PAYLOAD_BITS, "offset": (0, 0), "auto_offset": False,
        "explicit_offset": False, "plane": "chroma", "layout": False, "key": None,
        "pages": None, "auto": False, "dump_codes": False,
    }
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "--bits":
            index += 1
            if index >= len(argv) or not argv[index].lstrip("-").isdigit():
                fail(f"--bits 需要 1...{MAX_PAYLOAD_BITS} 的整数", 2)
            value = int(argv[index])
            if not 1 <= value <= MAX_PAYLOAD_BITS:
                fail(f"--bits 需要 1...{MAX_PAYLOAD_BITS} 的整数", 2)
            options["payload_bits"] = value
        elif argument == "--offset":
            index += 1
            parts = argv[index].split(",") if index < len(argv) else []
            if len(parts) != 2:
                fail("--offset 需要 X,Y 形式，例如 --offset 0,-130", 2)
            try:
                options["offset"] = (int(parts[0]), int(parts[1]))
            except ValueError:
                fail("--offset 需要 X,Y 形式，例如 --offset 0,-130", 2)
            options["explicit_offset"] = True
        elif argument == "--auto-offset":
            options["auto_offset"] = True
        elif argument == "--plane":
            index += 1
            if index >= len(argv) or argv[index] not in ("luma", "chroma"):
                fail("--plane 需要 luma 或 chroma", 2)
            options["plane"] = argv[index]
        elif argument == "--layout":
            options["layout"] = True
        elif argument == "--pages":
            index += 1
            if index >= len(argv):
                fail("--pages 需要一个可读的 JSON 文件（顶层字符串数组）", 2)
            try:
                with open(argv[index], "r", encoding="utf-8") as handle:
                    names = json.load(handle)
                if not isinstance(names, list) or not names or not all(isinstance(n, str) for n in names):
                    raise ValueError
            except (OSError, ValueError):
                fail("--pages 需要一个可读的 JSON 文件（顶层字符串数组）", 2)
            options["pages"] = names
        elif argument == "--auto":
            options["auto"] = True
        elif argument == "--dump-codes":
            options["dump_codes"] = True
        elif argument == "--key":
            index += 1
            value = argv[index] if index < len(argv) else ""
            try:
                key = bytes.fromhex(value)
            except ValueError:
                key = b""
            if not key:
                fail("--key 需要 hex 字符串，例如 00112233445566778899aabbccddeeff", 2)
            options["key"] = key
        elif argument in ("-h", "--help"):
            print(usage())
            raise SystemExit(0)
        elif options["path"] is None and not argument.startswith("--"):
            options["path"] = argument
        else:
            fail(f"无法识别的参数: {argument}", 2)
        index += 1
    return options


def load_image(path: str) -> np.ndarray:
    try:
        with Image.open(path) as handle:
            return np.array(handle.convert("RGBA"), dtype=np.uint8)
    except Exception as error:  # noqa: BLE001 - 报错信息原样带给用户
        fail(f"读不到图片: {path}（{error}）", 1)


def valid_validator(key: bytes | None):
    """严格校验器：验签通过或公开自检值通过。位数不符一律 false。"""
    def validate(candidate: Decoded) -> bool:
        if candidate.payload_bits != PAYLOAD_BITS:
            return False
        fields = Payload.from_bytes(candidate.payload_bytes)
        return fields is not None and fields.verification(key) in ("signed", "selfCheck")

    return validate


def structural_validator(candidate: Decoded) -> bool:
    """兜底校验器：结构自检。只减少错误，不消除错误。"""
    if candidate.payload_bits != PAYLOAD_BITS:
        return False
    fields = Payload.from_bytes(candidate.payload_bytes)
    return fields is not None and fields.is_plausible


NO_VALIDATOR_WARNING = (
    "载荷没带可校验的校验值（mac 全 0 或仅有 HMAC 而没给 --key）："
    "裁剪 / 相位搜索已退化为结构自检，近似解会漏网 —— 结论不保证正确，必须看 弱bit 与 校验 字段；"
    "接入端填公开自检值（WatermarkPayload.selfChecked）或服务端 HMAC 才能真正保证"
)


def tier_of(result: "Decoded | None", key: bytes | None) -> str | None:
    if result is None or result.payload_bits != PAYLOAD_BITS:
        return None
    fields = Payload.from_bytes(result.payload_bytes)
    return None if fields is None else fields.verification(key)


def decode_with_ladder(image, bits_candidates, planes, key, search_tile: bool = True):
    """三档阶梯：严格校验器（常规相位）→ 严格校验器（加 block 奇偶）→ 结构自检兜底。

    返回最终结果与它落在哪一档校验上。
    """
    strict = valid_validator(key)
    for search_pair_offset in (False, True):
        best = decode_best(image, payload_bits_candidates=bits_candidates, planes=planes,
                           search_phase=True, search_tile=search_tile,
                           search_pair_offset=search_pair_offset, validate=strict)
        tier = tier_of(best, key)
        if tier in ("signed", "selfCheck"):
            return best, tier
    warn(NO_VALIDATOR_WARNING)
    best = decode_best(image, payload_bits_candidates=bits_candidates, planes=planes,
                       search_phase=True, search_tile=search_tile, validate=structural_validator)
    return best, tier_of(best, key)


def print_layout(result: Decoded, key: bytes | None, pages: list[str] | None) -> None:
    if result.payload_bits != PAYLOAD_BITS:
        fail(f"--layout 需要 --bits {PAYLOAD_BITS} 且载荷为 {PAYLOAD_BYTE_COUNT} 字节", 2)
    fields = Payload.from_bytes(result.payload_bytes)
    if fields is None:
        fail(f"--layout 需要 --bits {PAYLOAD_BITS} 且载荷为 {PAYLOAD_BYTE_COUNT} 字节", 2)

    stamp = datetime.datetime.fromtimestamp(fields.timestamp, datetime.timezone.utc)
    if fields.layout_version != LAYOUT_VERSION:
        print(f"注意: 这张截图是 layout=v{fields.layout_version}，当前布局是 v{LAYOUT_VERSION}，"
              "page/tag 字段边界不同，下面的解读可能是错的")

    code = fields.page_name_code
    if pages is not None:
        hits = registry_matches(pages, code)
        if len(hits) == 1:
            page_line = f"page={code} → {hits[0]}"
        elif not hits:
            page_line = f"page={code}（注册表无命中，换版本或没登记；{grep_hint(code)}）"
        else:
            page_line = f"page={code} → {len(hits)} 个候选: " + ", ".join(hits)
    else:
        page_line = f"page={code}（无注册表，直接 {grep_hint(code)}）"

    # 校验分档必须如实写：自检值通过只证明"解对了"，不证明"没被伪造"
    verification = fields.verification(key)
    if verification == "signed":
        mac_line = "mac=OK(验签)"
    elif verification == "selfCheck":
        mac_line = "mac=OK(自检,未验签)"
    elif verification == "unsigned":
        mac_line = ("mac=未签名(字段自洽,退结构自检)" if fields.is_plausible
                    else "mac=未签名(字段不自洽,谨慎)")
    else:
        mac_line = "mac=未校验(需要 --key)" if key is None else "mac=BAD(密钥不符或载荷被改)"

    print(
        f"uid={fields.uid}(0x{fields.uid:08X})  time={stamp.strftime('%Y-%m-%d %H:%M:%S')} UTC  "
        f"{page_line}  layout=v{fields.layout_version} app={fields.app} env={fields.environment}  {mac_line}"
    )


def main(argv: list[str]) -> int:
    options = parse_args(argv)

    if options["auto_offset"] and options["explicit_offset"]:
        fail("--auto-offset 与 --offset 互斥：前者就是自动求后者，同时给无法判断以哪个为准", 2)
    if options["auto_offset"] and options["auto"]:
        fail("--auto-offset 与 --auto 语义重叠：--auto 已经穷举相位 / 平面 / 位数，单独用 --auto 即可", 2)

    if options["dump_codes"]:
        if options["pages"] is None:
            fail("--dump-codes 需要配合 --pages 使用", 2)
        # 列宽 = codeLength + 1：短码最长 10 字符，截断会把 darkmode 显示成 darkmo
        print("code       类名")
        for name in sorted(options["pages"], key=lambda n: page_name_code(n)):
            print(f"{page_name_code(name):<{CODE_LENGTH + 1}}{name}")
        return 0

    if options["path"] is None:
        fail(usage(), 2)
    image = load_image(options["path"])
    key = options["key"]

    if options["auto"]:
        candidates = [PAYLOAD_BITS]
        if options["payload_bits"] != PAYLOAD_BITS:
            candidates.append(options["payload_bits"])
        result, tier = decode_with_ladder(image, candidates, ("chroma", "luma"), key)
    elif options["auto_offset"]:
        if options["payload_bits"] != PAYLOAD_BITS:
            warn(f"HMAC 与公开自检值都只覆盖 {PAYLOAD_BITS} bit 推荐布局，"
                 f"--bits {options['payload_bits']} 下相位与平移无法校验")
        result, tier = decode_with_ladder(image, [options["payload_bits"]],
                                          (options["plane"],), key)
    else:
        result = decode(image, payload_bits=options["payload_bits"],
                        offset_x=options["offset"][0], offset_y=options["offset"][1],
                        plane=options["plane"])
        tier = tier_of(result, key)

    if result is None:
        fail("解码失败: 图像太小，或 --auto 没找到可信的候选", 1)

    total, weak = result.payload_bits, result.weak_bits
    if weak == 0:
        verdict = f"OK(全部 {total} bit 显著)"
    elif weak <= total // 8:
        verdict = f"WEAK({weak}/{total} bit 证据不足，结论谨慎)"
    else:
        verdict = "NO(画面中可能没有水印)"

    print(
        f"payload=0x{result.payload_bytes.hex()}  payloadBits={result.payload_bits}  "
        f"平面={result.plane}  相位=({result.offset_x},{result.offset_y})  "
        f"signal={result.signal:.2f}  |z|中位={result.median_abs_z:.1f}  "
        f"最弱={result.confidence:.1f}  弱bit={weak}/{total}  {verdict}"
    )
    if options["layout"]:
        print_layout(result, key, options["pages"])
    elif tier == "unsigned":
        # 没开 --layout 也要提醒：无校验值的载荷在裁剪场景下不可信
        warn(NO_VALIDATOR_WARNING)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
