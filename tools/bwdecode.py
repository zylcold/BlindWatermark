#!/usr/bin/env python3
"""截图盲水印解码器（Python 版）。

与 `Sources/bwdecode/main.swift` 行为对齐：同样的参数、同样的输出格式、同样的判读规则，
区别只在实现语言。用途是**跨语言备份**：macOS 上编不了 Swift 时也能解截图，
以及拿两套实现对账（`tools/test_bwdecode.py` 就跑这个对账）。v4 镜像 `BlockCodec`，v5.2 镜像
`V52BCH` / `V52Codec`；修改任一协议时只改一端会破坏跨语言结果。

依赖 numpy（特征平面与积分图）与 Pillow（读 PNG/JPEG）。系统的处理逻辑都在
`Sources/BlindWatermarkCore/BlockCodec.swift` 与 `V52Codec.swift`，这里是它们的镜像 —— 改一处必须改两处，
`tools/test_bwdecode.py` 会在同一批 PNG 上做交叉验证。

用法见 `--help` 或 README 的「解码」一节。
"""

from __future__ import annotations

import datetime
import hashlib
import hmac
import itertools
import json
import math
import sys
from dataclasses import dataclass

import numpy as np
from PIL import Image

# MARK: - 与 Swift 端必须一致的前常量

BLOCK = 8  # 块边长（设备像素）
TILE = 256  # 平铺周期（设备像素）
PAIRS_PER_ROW = TILE // BLOCK // 2  # 16
BLOCK_ROWS_PER_TILE = TILE // BLOCK  # 32
PAIRS_PER_TILE = PAIRS_PER_ROW * BLOCK_ROWS_PER_TILE  # 512
MAX_PAYLOAD_BITS = 512
MAX_PHASE_FINALISTS = 16

# 低于此方差的观测按此方差算，避免纯色画面上 z 值除以 0 而爆掉
MIN_VARIANCE = 0.25
# 观测幅度下限：低于此值的 pair 弃权。否则纯色背景上 d == 0 会被当成一个方向的观测
MIN_MAGNITUDE = 0.5
# |z| 小于它就认为该 bit 证据不足
WEAK_Z = 3.0
# 每个 bit 至少要有几次观测，才允许在**没有校验值**时解读字段。
# 实测（真机像素、chroma、512 bit、整宽 1179）：每 bit 4.4 次观测时弱 bit 16/512、96 bit 自检不过；
# 5.3 次时弱 bit 0/512、自检通过。取 5 作下限，比临界点略保守。载荷带校验值时不受限制。
MIN_OBSERVATIONS_PER_BIT = 5

PAYLOAD_BITS = 512
PAYLOAD_BYTE_COUNT = 64
LAYOUT_VERSION = 4
MAC_BYTE_COUNT = 12
# 校验值覆盖前 52 字节（uid + timestamp + build + pageCode + tag + note）
SIGNED_BYTE_COUNT = 52
PAGE_CODE_BYTE_COUNT = 12
NOTE_BYTE_COUNT = 22
# 结构自检认定的合理时间戳区间：2015-01-01 ... 2100-01-01
PLAUSIBLE_TIMESTAMP = (1_420_070_400, 4_102_444_800)

SUFFIX_LADDER = [
    "ViewController", "ViewModel", "Presenter", "Interactor",
    "Controller", "View", "Page", "Screen", "Scene", "Cell", "Item", "Model", "VC",
]
KNOWN_PREFIXES = ["BH", "JY", "LL", "HW", "XQ"]
CODE_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789_"
CODE_LENGTH = 15
PAD_CHARACTER = "_"

# v5.2 is deliberately kept beside (and independent from) the historical v4
# decoder.  The physical codeword is always 256 bits: a systematic BCH(255,207)
# code followed by one even-parity extension bit.  `V52_*` names avoid silently
# reusing a v4 constant in either the protocol or the image path.
V52_PAYLOAD_BITS = 207
V52_PAYLOAD_BYTE_COUNT = 26
V52_CODEWORD_BITS = 256
V52_CODEWORD_BYTE_COUNT = 32
V52_BCH_BITS = 255
V52_MESSAGE_BITS = 207
V52_PARITY_BITS = 48
V52_BCH_CORRECTION_LIMIT = 6
V52_PROFILE = 1
V52_TIMESTAMP_EPOCH = 1_767_225_600  # 2026-01-01 00:00:00 UTC
V52_PAGE_LENGTH = 8
V52_NOTE_LENGTH = 6
V52_PAGE_BITS = 42
V52_NOTE_BITS = 32
V52_CRC_BITS = 24
V52_CRC_BODY_BITS = 179
V52_BCH_GENERATOR = 0x1C7EB85DF3C97
V52_ALPHABET = CODE_ALPHABET
V52_DEFAULT_SCALES = tuple(0.50 + 0.05 * i for i in range(21))
V52_DEFAULT_CHASE_BITS = 12
V52_DEFAULT_CHASE_FLIPS = 2


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
        "min_observations", "average_observations",
    )

    def __init__(self, payload_bytes, payload_bits, plane, offset_x, offset_y,
                 signal, confidence, weak_bits, median_abs_z, scores,
                 min_observations=0, average_observations=0.0):
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
        self.min_observations = min_observations
        self.average_observations = average_observations

    @property
    def has_sufficient_evidence(self) -> bool:
        """证据够不够支撑"解读字段"。载荷带校验值时不需要它。"""
        return self.min_observations >= MIN_OBSERVATIONS_PER_BIT


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
        min_observations=int(counts.min()) if counts.size else 0,
        average_observations=(stats.observed / payload_bits) if payload_bits else 0.0,
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


# MARK: - 载荷布局与校验（layout v4：512 bit / 64 字节）


def _u32_le(value: int) -> bytes:
    return int(value & 0xFFFFFFFF).to_bytes(4, "little")


def signed_body(uid: int, timestamp: int, build: int, page_code: bytes, tag: int,
                note: bytes) -> bytes:
    """校验值覆盖的前 52 字节：uid(4) + timestamp(4) + build(8) + pageCode(12) + tag(2) + note(22)。

    v4 没有版本位 —— 布局就是这一个，字段边界变了等于换协议（v3 的 256 bit 布局已废弃）。
    """
    body = _u32_le(uid) + _u32_le(timestamp)
    body += int(build & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "little")
    body += _pad(page_code, PAGE_CODE_BYTE_COUNT)
    body += bytes([(tag >> 8) & 0xFF, tag & 0xFF])
    body += _pad(note, NOTE_BYTE_COUNT)
    assert len(body) == SIGNED_BYTE_COUNT
    return body


def _pad(data: bytes, size: int) -> bytes:
    return bytes(data[:size]).ljust(size, b"\x00")


def self_check(uid: int, timestamp: int, build: int, page_code: bytes, tag: int,
               note: bytes) -> bytes:
    """公开自检值：SHA-256(前 52 字节) 截断到 96 bit，与校验值字段同位。

    无密钥部署用它代替 HMAC：任何一位不同都过不了，所以能拦住"对齐错了几个 bit"的近似解。
    但拦不住伪造（谁都能算）—— 自检通过只证明"解对了"，不证明"没被改"。
    """
    return hashlib.sha256(signed_body(uid, timestamp, build, page_code, tag, note)).digest()[:MAC_BYTE_COUNT]


def payload_mac(uid: int, timestamp: int, build: int, page_code: bytes, tag: int,
                note: bytes, key: bytes) -> bytes:
    """HMAC-SHA256(前 52 字节, 服务端密钥) 截断到 96 bit。"""
    return hmac.new(key, signed_body(uid, timestamp, build, page_code, tag, note),
                    hashlib.sha256).digest()[:MAC_BYTE_COUNT]


class Payload:
    """layout v4：uid + Unix 秒 + build + 20 字符页面短码 + note + 96 bit 校验值。"""

    def __init__(self, uid: int, timestamp: int, build: int, page_code: bytes, tag: int,
                 note: bytes, mac: bytes):
        self.uid = uid
        self.timestamp = timestamp
        self.build = build
        self.page_code = _pad(page_code, PAGE_CODE_BYTE_COUNT)
        self.tag = tag & 0xFFFF
        self.note_bytes = _pad(note, NOTE_BYTE_COUNT)
        self.mac = mac

    @classmethod
    def from_bytes(cls, raw: bytes) -> "Payload | None":
        if len(raw) != PAYLOAD_BYTE_COUNT:
            return None
        return cls(
            uid=int.from_bytes(raw[0:4], "little"),
            timestamp=int.from_bytes(raw[4:8], "little"),
            build=int.from_bytes(raw[8:16], "little"),
            page_code=raw[16:28],
            tag=(raw[28] << 8) | raw[29],
            note=raw[30:52],
            mac=raw[52:64],
        )

    @classmethod
    def build_payload(cls, uid: int, timestamp: int, build: int, page_class_name: str,
                      note: str = "", app: int = 0, environment: int = 0,
                      key: bytes | None = None) -> "Payload":
        """`key` 为 None 时校验值填公开自检值（无密钥部署）。"""
        page_code = encode_page_code(page_name_code(page_class_name))
        tag = ((app & 0xFF) << 8) | (environment & 0xFF)
        note_bytes = note.encode("utf-8")
        if key is None:
            check = self_check(uid, timestamp, build, page_code, tag, note_bytes)
        else:
            check = payload_mac(uid, timestamp, build, page_code, tag, note_bytes, key)
        return cls(uid, timestamp, build, page_code, tag, note_bytes, check)

    @property
    def bytes(self) -> bytes:
        return signed_body(self.uid, self.timestamp, self.build, self.page_code,
                           self.tag, self.note_bytes) + _pad(self.mac, MAC_BYTE_COUNT)

    @property
    def app(self) -> int:
        return (self.tag >> 8) & 0xFF

    @property
    def environment(self) -> int:
        return self.tag & 0xFF

    @property
    def page_name_code(self) -> str:
        return decode_page_code(self.page_code)

    @property
    def note(self) -> str | None:
        try:
            return self.note_bytes.rstrip(b"\x00").decode("utf-8")
        except UnicodeDecodeError:
            return None

    @property
    def build_number(self) -> str:
        return "" if self.build == 0 else f"{self.build:012d}"

    def is_valid(self, key: bytes) -> bool:
        expected = payload_mac(self.uid, self.timestamp, self.build, self.page_code,
                               self.tag, self.note_bytes, key)
        # 定长比较，不做短路
        return len(self.mac) == len(expected) and hmac.compare_digest(bytes(self.mac), expected)

    @property
    def is_unsigned(self) -> bool:
        """校验值全 0：载荷没带任何校验值。"""
        return all(byte == 0 for byte in self.mac)

    def verification(self, key: bytes | None) -> str:
        """判定载荷带的是哪种校验值：signed / selfCheck / unsigned / failed。

        没给密钥时签名载荷落在 failed，调用方应报"未校验(需要 --key)"而不是"被篡改"。
        """
        if self.is_unsigned:
            return "unsigned"
        if key is not None and self.is_valid(key):
            return "signed"
        if bytes(self.mac) == self_check(self.uid, self.timestamp, self.build,
                                         self.page_code, self.tag, self.note_bytes):
            return "selfCheck"
        return "failed"

    @property
    def is_plausible(self) -> bool:
        """结构自检：时间戳合理 + build 日历合法 + note 是 UTF-8 + 20 个字符都在 37 符号表内。

        判别力比"没有校验值"强，但**实测仍会放过近似解**（半块相位错位解出的是真载荷改几个 bit
        的拷贝，结构字段根本没动），所以只能当兵底。
        """
        if not PLAUSIBLE_TIMESTAMP[0] <= self.timestamp <= PLAUSIBLE_TIMESTAMP[1]:
            return False
        if self.note is None:
            return False
        if not plausible_build(self.build):
            return False
        return validate_page_code(self.page_code)


def plausible_build(build: int) -> bool:
    """build = 0（未填）或日历上合法的 12 位 YYYYMMDDHHMM。"""
    if build == 0:
        return True
    digits = str(build)
    if len(digits) != 12 or not digits.isdigit():
        return False
    year, month, day = int(digits[0:4]), int(digits[4:6]), int(digits[6:8])
    hour, minute = int(digits[8:10]), int(digits[10:12])
    return 2000 <= year <= 2099 and 1 <= month <= 12 and 1 <= day <= 31 \
        and 0 <= hour <= 23 and 0 <= minute <= 59


# MARK: - 页面短码（20 字符 = 120 bit）


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


def page_name_code(class_name: str, length: int = CODE_LENGTH) -> str:
    """类名 → 短码，去掉尾部补位符，保证 `decode(encode(code)) == code`。"""
    characters = list(normalized_stem(class_name)[:length])
    while len(characters) < length:
        characters.append(PAD_CHARACTER)
    while characters and characters[-1] == PAD_CHARACTER:
        characters.pop()
    return "".join(characters)


def encode_page_code(code: str, length: int = CODE_LENGTH) -> bytes:
    """短码 → 小端字节（每字符 6 bit，低位在前）。20 字符 → 15 字节。"""
    characters = list(code[:length])
    while len(characters) < length:
        characters.append(PAD_CHARACTER)
    out = bytearray((length * 6 + 7) // 8)
    for position, character in enumerate(characters):
        index = CODE_ALPHABET.find(character)
        if index < 0:
            index = len(CODE_ALPHABET) - 1
        for offset in range(6):
            if index & (1 << offset):
                target = 6 * position + offset
                out[target >> 3] |= 1 << (target & 7)
    return bytes(out)


def _decode_page_code_index(data: bytes, position: int) -> int:
    index = 0
    for offset in range(6):
        source = 6 * position + offset
        if source >> 3 < len(data) and data[source >> 3] & (1 << (source & 7)):
            index |= 1 << offset
    return index


def decode_page_code(data: bytes, length: int = CODE_LENGTH) -> str:
    characters = []
    for position in range(length):
        index = _decode_page_code_index(data, position)
        characters.append(CODE_ALPHABET[index] if index < len(CODE_ALPHABET) else PAD_CHARACTER)
    while characters and characters[-1] == PAD_CHARACTER:
        characters.pop()
    return "".join(characters)


def validate_page_code(data: bytes, length: int = CODE_LENGTH) -> bool:
    """每个 6-bit 字符是否都落在 37 符号表内，且未被字符用到的比特必须为 0。

    15 字符只用 90 bit，字段有 96 bit —— 多出来的 6 bit 留 0，结构自检顺手查掉，
    等于白拿 6 bit 判别力。
    """
    if not all(_decode_page_code_index(data, position) < len(CODE_ALPHABET)
               for position in range(length)):
        return False
    used_bits = length * 6
    for bit in range(used_bits, len(_pad(data, PAGE_CODE_BYTE_COUNT)) * 8):
        if data[bit >> 3] & (1 << (bit & 7)):
            return False
    return True


def grep_hint(code: str) -> str:
    if not code:
        return "短码为空，页面类名可能不含字母数字"
    return f'grep -rin "class.*{code}" --include=\'*.swift\''


def registry_matches(names: list[str], code: str) -> list[str]:
    if not code:
        return []
    return [name for name in names if page_name_code(name) == code]


# MARK: - v5.2 compact payload and BCH


def _v52_bits(value: int, width: int) -> list[bool]:
    """Return a fixed-width integer as a low-bit-first stream."""
    return [bool((int(value) >> bit) & 1) for bit in range(width)]


def _v52_read(bits: list[bool], offset: int, width: int) -> int:
    value = 0
    for bit in range(width):
        if bits[offset + bit]:
            value |= 1 << bit
    return value


def _v52_pack(bits: list[bool]) -> bytes:
    output = bytearray((len(bits) + 7) // 8)
    for index, value in enumerate(bits):
        if value:
            output[index >> 3] |= 1 << (index & 7)
    return bytes(output)


def _v52_unpack(data: bytes, count: int) -> list[bool]:
    return [bool(data[index >> 3] & (1 << (index & 7))) for index in range(count)]


def _v52_compact_code(value: str, max_length: int) -> str | None:
    if max_length <= 0:
        return None
    chars = list(str(value).lower())
    while chars and chars[-1] == PAD_CHARACTER:
        chars.pop()
    if len(chars) > max_length or any(char not in V52_ALPHABET for char in chars):
        return None
    return "".join(chars)


def encode_base37(value: str, length: int) -> int | None:
    """Encode a compact field as a fixed-width, most-significant digit first radix value."""
    if not 1 <= length <= 8:
        return None
    compact = _v52_compact_code(value, length)
    if compact is None:
        return None
    digits = compact + PAD_CHARACTER * (length - len(compact))
    result = 0
    for char in digits:
        result = result * 37 + V52_ALPHABET.index(char)
    return result


def decode_base37(value: int, length: int) -> str | None:
    """Decode a radix value and remove only the fixed-field right padding."""
    if not 1 <= length <= 8:
        return None
    limit = 37 ** length
    if not 0 <= int(value) < limit:
        return None
    remaining = int(value)
    chars = [PAD_CHARACTER] * length
    for index in range(length - 1, -1, -1):
        chars[index] = V52_ALPHABET[remaining % 37]
        remaining //= 37
    while chars and chars[-1] == PAD_CHARACTER:
        chars.pop()
    return "".join(chars)


def crc24_bits(bits: list[bool]) -> int:
    """CRC-24/OPENPGP over the exact 179 protocol bits, without byte padding."""
    crc = 0xB704CE
    for bit in bits:
        top = ((crc >> 23) & 1) ^ int(bool(bit))
        crc = (crc << 1) & 0xFFFFFF
        if top:
            crc ^= 0x864CFB
    return crc


class WatermarkPayloadV52:
    """The compact 207-bit v5.2 payload before BCH encoding."""

    payload_bits = V52_PAYLOAD_BITS
    byte_count = V52_PAYLOAD_BYTE_COUNT
    profile = V52_PROFILE
    timestamp_epoch = V52_TIMESTAMP_EPOCH
    page_length = V52_PAGE_LENGTH
    note_length = V52_NOTE_LENGTH
    page_bits = V52_PAGE_BITS
    note_bits = V52_NOTE_BITS

    def __init__(self, uid: int, timestamp_offset: int, build_minute_offset: int,
                 page_code: str, app: int = 0, note_code: str = "",
                 crc24: int | None = None):
        if not 0 <= int(uid) <= 0xFFFFFFFF:
            raise ValueError("uid must fit UInt32")
        if not 0 <= int(timestamp_offset) <= (1 << 31) - 1:
            raise ValueError("timestamp offset must fit 31 bits")
        if not 0 <= int(build_minute_offset) < (1 << 24):
            raise ValueError("build minute offset must fit 24 bits")
        if not 0 <= int(app) <= 9_999:
            raise ValueError("app must be in 0...9999")
        page = _v52_compact_code(page_code, V52_PAGE_LENGTH)
        note = _v52_compact_code(note_code, V52_NOTE_LENGTH)
        if page is None or note is None:
            raise ValueError("page/note contains an invalid or oversized base-37 code")
        self.uid = int(uid)
        self.timestamp_offset = int(timestamp_offset)
        self.build_minute_offset = int(build_minute_offset)
        self.page_code = page
        self.app = int(app)
        self.note_code = note
        body = self._body_bits()
        self.crc24 = crc24_bits(body) if crc24 is None else int(crc24) & 0xFFFFFF

    @classmethod
    def build(cls, uid: int, timestamp: int, build_time: int,
              page_class_name: str, app: int = 0, note: str = "") -> "WatermarkPayloadV52 | None":
        """Build from Unix seconds, with build time rounded down to a UTC minute."""
        if timestamp < V52_TIMESTAMP_EPOCH or build_time < V52_TIMESTAMP_EPOCH:
            return None
        timestamp_offset = int(timestamp) - V52_TIMESTAMP_EPOCH
        build_minute_offset = (int(build_time) - V52_TIMESTAMP_EPOCH) // 60
        if timestamp_offset > (1 << 31) - 1 or build_minute_offset >= (1 << 24):
            return None
        page = page_name_code(page_class_name)[:V52_PAGE_LENGTH]
        compact_note = str(note).lower()
        try:
            return cls(uid, timestamp_offset, build_minute_offset, page, app, compact_note)
        except ValueError:
            return None

    @classmethod
    def from_relative(cls, uid: int, timestamp_offset: int, build_minute_offset: int,
                      page_class_name: str, app: int = 0,
                      note: str = "") -> "WatermarkPayloadV52 | None":
        page = page_name_code(page_class_name)[:V52_PAGE_LENGTH]
        try:
            return cls(uid, timestamp_offset, build_minute_offset, page, app, str(note).lower())
        except ValueError:
            return None

    @classmethod
    def from_codes(cls, uid: int, timestamp_offset: int, build_minute_offset: int,
                   page_code: str, app: int = 0,
                   note_code: str = "") -> "WatermarkPayloadV52 | None":
        try:
            return cls(uid, timestamp_offset, build_minute_offset, page_code, app, note_code)
        except ValueError:
            return None

    @classmethod
    def from_bytes(cls, raw: bytes | bytearray) -> "WatermarkPayloadV52 | None":
        data = bytes(raw)
        if len(data) != V52_PAYLOAD_BYTE_COUNT or data[-1] & 0x80:
            return None
        bits = _v52_unpack(data, V52_PAYLOAD_BITS)
        cursor = 0
        profile = _v52_read(bits, cursor, 4); cursor += 4
        if profile != V52_PROFILE:
            return None
        uid = _v52_read(bits, cursor, 32); cursor += 32
        timestamp_offset = _v52_read(bits, cursor, 31); cursor += 31
        build_minute_offset = _v52_read(bits, cursor, 24); cursor += 24
        page_value = _v52_read(bits, cursor, V52_PAGE_BITS); cursor += V52_PAGE_BITS
        app = _v52_read(bits, cursor, 14); cursor += 14
        note_value = _v52_read(bits, cursor, V52_NOTE_BITS); cursor += V52_NOTE_BITS
        crc = _v52_read(bits, cursor, V52_CRC_BITS); cursor += V52_CRC_BITS
        if _v52_read(bits, cursor, 4) != 0:
            return None
        page = decode_base37(page_value, V52_PAGE_LENGTH)
        note = decode_base37(note_value, V52_NOTE_LENGTH)
        if page is None or note is None or app > 9_999:
            return None
        if crc24_bits(bits[:V52_CRC_BODY_BITS]) != crc:
            return None
        try:
            return cls(uid, timestamp_offset, build_minute_offset, page, app, note, crc)
        except ValueError:
            return None

    @classmethod
    def encode_base37(cls, value: str, length: int) -> int | None:
        return encode_base37(value, length)

    @classmethod
    def decode_base37(cls, value: int, length: int) -> str | None:
        return decode_base37(value, length)

    @classmethod
    def crc24(cls, bits: list[bool]) -> int:
        return crc24_bits(bits)

    def _body_bits(self) -> list[bool]:
        page = encode_base37(self.page_code, V52_PAGE_LENGTH)
        note = encode_base37(self.note_code, V52_NOTE_LENGTH)
        assert page is not None and note is not None
        bits: list[bool] = []
        bits.extend(_v52_bits(V52_PROFILE, 4))
        bits.extend(_v52_bits(self.uid, 32))
        bits.extend(_v52_bits(self.timestamp_offset, 31))
        bits.extend(_v52_bits(self.build_minute_offset, 24))
        bits.extend(_v52_bits(page, V52_PAGE_BITS))
        bits.extend(_v52_bits(self.app, 14))
        bits.extend(_v52_bits(note, V52_NOTE_BITS))
        assert len(bits) == V52_CRC_BODY_BITS
        return bits

    @property
    def bytes(self) -> bytes:
        bits = self._body_bits()
        bits.extend(_v52_bits(self.crc24, V52_CRC_BITS))
        bits.extend([False] * 4)  # reserved
        assert len(bits) == V52_PAYLOAD_BITS
        return _v52_pack(bits)

    @property
    def timestamp(self) -> int:
        return V52_TIMESTAMP_EPOCH + self.timestamp_offset

    @property
    def build_time(self) -> int:
        return V52_TIMESTAMP_EPOCH + self.build_minute_offset * 60

    @property
    def page_name_code(self) -> str:
        return self.page_code

    @property
    def note(self) -> str:
        return self.note_code

    @property
    def is_valid(self) -> bool:
        return crc24_bits(self._body_bits()) == self.crc24

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, WatermarkPayloadV52):
            return NotImplemented
        return self.__dict__ == other.__dict__

    def __repr__(self) -> str:
        return (f"WatermarkPayloadV52(uid={self.uid}, timestamp_offset={self.timestamp_offset}, "
                f"build_minute_offset={self.build_minute_offset}, page_code={self.page_code!r}, "
                f"app={self.app}, note_code={self.note_code!r}, crc24=0x{self.crc24:06x})")


@dataclass(frozen=True)
class V52BCHDecoded:
    message_bytes: bytes
    codeword_bytes: bytes
    corrected_bits: int


_V52_GF_EXP = [0] * 510
_V52_GF_LOG = [-1] * 256
_v52_gf_value = 1
for _v52_index in range(255):
    _V52_GF_EXP[_v52_index] = _v52_gf_value
    _V52_GF_LOG[_v52_gf_value] = _v52_index
    _v52_gf_value <<= 1
    if _v52_gf_value & 0x100:
        _v52_gf_value ^= 0x11D
for _v52_index in range(255, 510):
    _V52_GF_EXP[_v52_index] = _V52_GF_EXP[_v52_index - 255]


def _v52_gf_exp(exponent: int) -> int:
    return _V52_GF_EXP[exponent % 255]


def _v52_gf_multiply(lhs: int, rhs: int) -> int:
    if lhs == 0 or rhs == 0:
        return 0
    return _v52_gf_exp(_V52_GF_LOG[lhs] + _V52_GF_LOG[rhs])


def _v52_gf_inverse(value: int) -> int:
    if value == 0:
        raise ZeroDivisionError("GF(256) inverse of zero")
    return _v52_gf_exp(255 - _V52_GF_LOG[value])


class V52BCH:
    """Binary narrow-sense BCH(255,207), t=6, with an even parity extension."""

    codeword_bits = V52_CODEWORD_BITS
    bch_bits = V52_BCH_BITS
    message_bits = V52_MESSAGE_BITS
    parity_bits = V52_PARITY_BITS
    correction_limit = V52_BCH_CORRECTION_LIMIT
    message_byte_count = V52_PAYLOAD_BYTE_COUNT
    codeword_byte_count = V52_CODEWORD_BYTE_COUNT

    @staticmethod
    def encode(message_bytes: bytes | bytearray) -> bytes:
        message = bytes(message_bytes)
        if len(message) != V52_PAYLOAD_BYTE_COUNT:
            raise ValueError("v5.2 BCH message must be 26 bytes")
        if message[-1] & 0x80:
            raise ValueError("v5.2 message bit 207 must be zero padding")
        work = [False] * V52_BCH_BITS
        for index in range(V52_MESSAGE_BITS):
            work[V52_PARITY_BITS + index] = bool(message[index >> 3] & (1 << (index & 7)))
        for pivot in range(V52_BCH_BITS - 1, V52_PARITY_BITS - 1, -1):
            if not work[pivot]:
                continue
            shift = pivot - V52_PARITY_BITS
            for offset in range(V52_PARITY_BITS + 1):
                if (V52_BCH_GENERATOR >> offset) & 1:
                    work[shift + offset] = not work[shift + offset]
        codeword = [False] * V52_CODEWORD_BITS
        codeword[:V52_PARITY_BITS] = work[:V52_PARITY_BITS]
        for index in range(V52_MESSAGE_BITS):
            codeword[V52_PARITY_BITS + index] = bool(message[index >> 3] & (1 << (index & 7)))
        codeword[255] = sum(codeword[:255]) % 2 == 1
        return _v52_pack(codeword)

    @classmethod
    def _syndromes(cls, bits: list[bool]) -> list[int]:
        values = []
        for order in range(1, 2 * cls.correction_limit + 1):
            value = 0
            for degree, bit in enumerate(bits):
                if bit:
                    value ^= _v52_gf_exp(order * degree)
            values.append(value)
        return values

    @classmethod
    def _berlekamp_massey(cls, syndromes: list[int]) -> list[int] | None:
        size = 2 * cls.correction_limit + 1
        connection = [0] * size
        backup = [0] * size
        connection[0] = 1
        backup[0] = 1
        length = 0
        shift = 1
        scale = 1
        for index in range(len(syndromes)):
            discrepancy = syndromes[index]
            if length > 0:
                for coefficient in range(1, length + 1):
                    discrepancy ^= _v52_gf_multiply(connection[coefficient], syndromes[index - coefficient])
            if discrepancy == 0:
                shift += 1
                continue
            previous = connection.copy()
            factor = _v52_gf_multiply(discrepancy, _v52_gf_inverse(scale))
            for coefficient in range(size - shift):
                if backup[coefficient] != 0:
                    connection[coefficient + shift] ^= _v52_gf_multiply(factor, backup[coefficient])
            if 2 * length <= index:
                length = index + 1 - length
                backup = previous
                scale = discrepancy
                shift = 1
            else:
                shift += 1
            if length > cls.correction_limit:
                return None
        return connection[:length + 1]

    @classmethod
    def decode(cls, codeword_bytes: bytes | bytearray) -> V52BCHDecoded | None:
        data = bytes(codeword_bytes)
        if len(data) != V52_CODEWORD_BYTE_COUNT:
            return None
        received = _v52_unpack(data, V52_CODEWORD_BITS)
        bch_received = received[:V52_BCH_BITS]
        syndrome_values = cls._syndromes(bch_received)
        if all(value == 0 for value in syndrome_values):
            corrected = bch_received
            corrected_count = 0
        else:
            locator = cls._berlekamp_massey(syndrome_values)
            if locator is None or len(locator) <= 1:
                return None
            degree = len(locator) - 1
            if degree > cls.correction_limit:
                return None
            positions = []
            for error_degree in range(V52_BCH_BITS):
                x = 1 if error_degree == 0 else _v52_gf_exp(255 - error_degree)
                value = 0
                power = 1
                for coefficient in locator:
                    value ^= _v52_gf_multiply(coefficient, power)
                    power = _v52_gf_multiply(power, x)
                if value == 0:
                    positions.append(error_degree)
            if len(positions) != degree:
                return None
            corrected = bch_received.copy()
            for position in positions:
                corrected[position] = not corrected[position]
            if any(cls._syndromes(corrected)):
                return None
            corrected_count = len(positions)
        expected_parity = sum(corrected) % 2 == 1
        if received[255] != expected_parity:
            corrected_count += 1
        full = corrected + [expected_parity]
        message = _v52_pack(corrected[V52_PARITY_BITS:V52_BCH_BITS])
        canonical = cls.encode(message)
        corrected_bytes = _v52_pack(full)
        if canonical != corrected_bytes:
            return None
        return V52BCHDecoded(message, corrected_bytes, corrected_count)


# Short aliases are useful to callers that mirror the Swift type names without
# making v4's `Payload` ambiguous.
PayloadV52 = WatermarkPayloadV52


# MARK: - v5.2 image layer (mirror of Sources/BlindWatermarkCore/V52Codec.swift)


V52_SYNC_NONE = "none"
V52_SYNC_PN = "pn"
V52_SYNC_SEPARATED = "separated"
V52_MIN_MAGNITUDE = 0.25
_V52_PAIR_ROWS = np.arange(PAIRS_PER_TILE, dtype=np.int64) // PAIRS_PER_ROW
_V52_PAIR_COLS = np.arange(PAIRS_PER_TILE, dtype=np.int64) % PAIRS_PER_ROW


@dataclass
class V52PairStats:
    sums: np.ndarray
    squares: np.ndarray
    counts: np.ndarray
    pilot_sums: np.ndarray
    pilot_squares: np.ndarray
    pilot_counts: np.ndarray
    abs_sum: float
    observed: int

    @classmethod
    def empty(cls) -> "V52PairStats":
        zeros = np.zeros(PAIRS_PER_TILE, dtype=np.float64)
        return cls(
            sums=zeros.copy(),
            squares=zeros.copy(),
            counts=np.zeros(PAIRS_PER_TILE, dtype=np.int64),
            pilot_sums=zeros.copy(),
            pilot_squares=zeros.copy(),
            pilot_counts=np.zeros(PAIRS_PER_TILE, dtype=np.int64),
            abs_sum=0.0,
            observed=0,
        )


@dataclass
class V52Folded:
    scores: np.ndarray
    counts: np.ndarray
    signal: float
    pilot_score: float
    median_abs_z: float
    min_observations: int
    average_observations: float


@dataclass
class V52Decoded:
    payload: WatermarkPayloadV52 | None
    codeword_bytes: bytes | None
    plane: str
    sync: str
    offset_x: int
    offset_y: int
    estimated_scale: float
    corrected_bits: int
    soft_recovery_used: bool
    pilot_score: float
    candidate_count: int
    ambiguous: bool
    failure_reason: str | None
    median_abs_z: float
    min_observations: int
    average_observations: float

    @property
    def is_success(self) -> bool:
        return self.payload is not None and not self.ambiguous

    @property
    def has_sufficient_evidence(self) -> bool:
        """v5.2 只有 CRC24（不是验签），所以没有「带校验值就放行」的例外：
        观测低于 MIN_OBSERVATIONS_PER_BIT 的图会解出「看着正常的垃圾」。"""
        return self.min_observations >= MIN_OBSERVATIONS_PER_BIT


def _v52_pn_bit(index: int) -> bool:
    value = (int(index) * 0x9E3779B9 + 0x7F4A7C15) & 0xFFFFFFFF
    value ^= value >> 16
    value = (value * 0x85EBCA6B) & 0xFFFFFFFF
    value ^= value >> 13
    return bool(value & 1)


def _v52_chroma_companion(amplitude: int) -> int:
    # Swift's Double.rounded() uses nearest with ties away from zero. None of
    # the supported amplitudes is a half-way value, but spelling this out keeps
    # the Python and Swift integer paths independent of Python's bankers round.
    ideal = math.floor(0.114 * amplitude / 0.886 + 0.5)
    return max(1, min(amplitude, ideal))


def v52_make_tile(payload: WatermarkPayloadV52 | bytes, alpha: int = 8,
                  plane: str = "chroma", sync: str = V52_SYNC_NONE) -> np.ndarray:
    """Create one v5.2 tile using the same premultiplied RGBA values as Swift."""
    if isinstance(payload, WatermarkPayloadV52):
        message = payload.bytes
    else:
        message = bytes(payload)
        if WatermarkPayloadV52.from_bytes(message) is None:
            raise ValueError("v5.2 payload must pass profile, field, reserved, and CRC checks")
    if len(message) != V52_PAYLOAD_BYTE_COUNT:
        raise ValueError("v5.2 payload must be 26 bytes")
    if not 2 <= int(alpha) <= 255:
        raise ValueError("v5.2 alpha must be in 2...255")
    if plane not in ("luma", "chroma") or sync not in (V52_SYNC_NONE, V52_SYNC_PN, V52_SYNC_SEPARATED):
        raise ValueError("invalid v5.2 plane or sync mode")

    codeword = V52BCH.encode(message)
    tile = np.zeros((TILE, TILE, 4), dtype=np.uint8)
    pilot_amplitude = 0 if sync == V52_SYNC_NONE or plane == "luma" else max(1, min(2, int(alpha) // 4))
    data_amplitude = max(1, int(alpha) - pilot_amplitude)
    companion = _v52_chroma_companion(data_amplitude)

    for pair in range(PAIRS_PER_TILE):
        row, col = divmod(pair, PAIRS_PER_ROW)
        code_index = pair % V52_CODEWORD_BITS
        data_bit = bool(codeword[code_index >> 3] & (1 << (code_index & 7)))
        if pair >= V52_CODEWORD_BITS:
            data_bit = not data_bit
        if sync == V52_SYNC_NONE:
            pilot_bit = False
        else:
            pilot_index = pair if sync == V52_SYNC_PN else pair % V52_CODEWORD_BITS
            pilot_bit = _v52_pn_bit(pilot_index)
        x = col * BLOCK * 2
        y = row * BLOCK

        def paint(x0: int, dark: bool, pilot_on: bool) -> None:
            if plane == "luma":
                value = 0 if dark else data_amplitude
                colour = (value, value, value, alpha)
            else:
                r = companion if dark else 0
                g = r
                b = 0 if dark else data_amplitude
                if pilot_on:
                    r += pilot_amplitude
                    g += pilot_amplitude
                    b += pilot_amplitude
                colour = (min(alpha, r), min(alpha, g), min(alpha, b), alpha)
            tile[y:y + BLOCK, x0:x0 + BLOCK] = colour

        paint(x, data_bit, pilot_bit)
        paint(x + BLOCK, not data_bit, False if sync == V52_SYNC_NONE else not pilot_bit)
    return tile


def _v52_integral_at(sat: np.ndarray, x, y) -> np.ndarray:
    """Bilinear interpolation of an integral image, mirroring Swift Integral.at."""
    height, width = sat.shape[0] - 1, sat.shape[1] - 1
    xx = np.clip(np.asarray(x, dtype=np.float64), 0.0, float(width))
    yy = np.clip(np.asarray(y, dtype=np.float64), 0.0, float(height))
    x0 = np.floor(xx).astype(np.int64)
    y0 = np.floor(yy).astype(np.int64)
    x1 = np.minimum(width, x0 + 1)
    y1 = np.minimum(height, y0 + 1)
    fx = xx - x0
    fy = yy - y0
    top = sat[y0, x0] * (1.0 - fx) + sat[y0, x1] * fx
    bottom = sat[y1, x0] * (1.0 - fx) + sat[y1, x1] * fx
    return top * (1.0 - fy) + bottom * fy


def _v52_rect_means(sat: np.ndarray, xs: np.ndarray, ys: np.ndarray, size: float) -> np.ndarray:
    x = np.asarray(xs, dtype=np.float64)[None, :]
    y = np.asarray(ys, dtype=np.float64)[:, None]
    x1 = np.minimum(float(sat.shape[1] - 1), x + size)
    y1 = np.minimum(float(sat.shape[0] - 1), y + size)
    total = (_v52_integral_at(sat, x1, y1) - _v52_integral_at(sat, x, y1)
             - _v52_integral_at(sat, x1, y) + _v52_integral_at(sat, x, y))
    area = (x1 - x) * (y1 - y)
    return np.divide(total, area, out=np.zeros_like(total), where=area > 0)


def _v52_accumulate(sat: np.ndarray, image: np.ndarray, scale: float,
                    offset_x: int, offset_y: int, sync: str,
                    luma_sat: np.ndarray | None) -> V52PairStats | None:
    if not math.isfinite(float(scale)) or scale <= 0 or offset_x < 0 or offset_y < 0:
        return None
    block = BLOCK * float(scale)
    height, width = image.shape[:2]
    if width - offset_x < block * 2 or height - offset_y < block:
        return None
    rows = int(math.floor((height - offset_y) / block))
    cols = int(math.floor((width - offset_x) / (block * 2)))
    if rows <= 0 or cols <= 0:
        return None
    xs = float(offset_x) + np.arange(cols, dtype=np.float64) * block * 2.0
    ys = float(offset_y) + np.arange(rows, dtype=np.float64) * block
    left = _v52_rect_means(sat, xs, ys, block)
    right = _v52_rect_means(sat, xs + block, ys, block)
    difference = left - right
    local_index = ((np.arange(rows, dtype=np.int64)[:, None] % BLOCK_ROWS_PER_TILE) * PAIRS_PER_ROW
                   + (np.arange(cols, dtype=np.int64)[None, :] % PAIRS_PER_ROW))

    stats = V52PairStats.empty()
    keep = np.abs(difference) >= V52_MIN_MAGNITUDE
    flat_index = local_index[keep]
    flat_difference = difference[keep]
    np.add.at(stats.sums, flat_index, flat_difference)
    np.add.at(stats.squares, flat_index, flat_difference * flat_difference)
    np.add.at(stats.counts, flat_index, 1)
    stats.abs_sum = float(np.abs(flat_difference).sum())
    stats.observed = int(flat_difference.size)

    if luma_sat is not None and sync != V52_SYNC_NONE:
        pilot_difference = (_v52_rect_means(luma_sat, xs, ys, block)
                             - _v52_rect_means(luma_sat, xs + block, ys, block))
        np.add.at(stats.pilot_sums, local_index.ravel(), pilot_difference.ravel())
        np.add.at(stats.pilot_squares, local_index.ravel(), (pilot_difference * pilot_difference).ravel())
        np.add.at(stats.pilot_counts, local_index.ravel(), 1)
    return stats


def _v52_fold(stats: V52PairStats, rotation: int, sync: str) -> V52Folded:
    row_shift, col_shift = divmod(int(rotation), PAIRS_PER_ROW)
    shifted = (((_V52_PAIR_ROWS + row_shift) % BLOCK_ROWS_PER_TILE) * PAIRS_PER_ROW
               + (_V52_PAIR_COLS + col_shift) % PAIRS_PER_ROW)
    code_index = shifted % V52_CODEWORD_BITS
    copy_sign = np.where(shifted >= V52_CODEWORD_BITS, -1.0, 1.0)
    sums = np.bincount(code_index, weights=copy_sign * stats.sums, minlength=V52_CODEWORD_BITS)
    squares = np.bincount(code_index, weights=stats.squares, minlength=V52_CODEWORD_BITS)
    counts = np.bincount(code_index, weights=stats.counts, minlength=V52_CODEWORD_BITS)
    scores = np.zeros(V52_CODEWORD_BITS, dtype=np.float64)
    usable = counts >= 2
    n = counts[usable].astype(np.float64)
    mean = sums[usable] / n
    variance = np.maximum(squares[usable] / n - mean * mean, MIN_VARIANCE)
    scores[usable] = mean / np.sqrt(variance / n)

    pilot_score = 0.0
    if sync != V52_SYNC_NONE and stats.pilot_counts.sum() > 0:
        if sync == V52_SYNC_PN:
            pilot_indices = shifted
        else:
            pilot_indices = shifted % V52_CODEWORD_BITS
        expected = np.where(np.fromiter((_v52_pn_bit(int(i)) for i in pilot_indices), dtype=bool), 1.0, -1.0)
        numerator = float(np.sum(expected * stats.pilot_sums))
        denominator = float(np.sum(stats.pilot_squares))
        pilot_score = numerator / math.sqrt(denominator * max(1, int(stats.pilot_counts.sum()))) if denominator > 0 else 0.0
    absolute = np.sort(np.abs(scores[scores != 0]))
    return V52Folded(
        scores=scores,
        counts=counts,
        signal=stats.abs_sum / stats.observed if stats.observed else 0.0,
        pilot_score=pilot_score,
        median_abs_z=float(absolute[absolute.size // 2]) if absolute.size else 0.0,
        min_observations=int(counts.min()) if counts.size else 0,
        average_observations=stats.observed / V52_CODEWORD_BITS,
    )


@dataclass
class _V52Candidate:
    payload: WatermarkPayloadV52
    codeword_bytes: bytes
    corrected_bits: int
    soft_recovery_used: bool
    plane: str
    sync: str
    scale: float
    offset_x: int
    offset_y: int
    pilot_score: float
    median_abs_z: float
    min_observations: int
    average_observations: float
    score: float


def _v52_try_candidate(raw: bytes, folded: V52Folded, hard: bytes,
                       plane: str, sync: str, scale: float, offset_x: int,
                       offset_y: int, soft: bool) -> _V52Candidate | None:
    corrected = V52BCH.decode(raw)
    if corrected is None:
        return None
    payload = WatermarkPayloadV52.from_bytes(corrected.message_bytes)
    if payload is None:
        return None
    # bin(...).count("1") 而不是 int.bit_count()：后者要 Python ≥3.10，本仓库的 python3 下限没有写进 README。
    corrected_bits = sum(bin(a ^ b).count("1") for a, b in zip(hard, corrected.codeword_bytes))
    return _V52Candidate(
        payload=payload,
        codeword_bytes=corrected.codeword_bytes,
        corrected_bits=corrected_bits,
        soft_recovery_used=soft,
        plane=plane,
        sync=sync,
        scale=scale,
        offset_x=offset_x,
        offset_y=offset_y,
        pilot_score=folded.pilot_score,
        median_abs_z=folded.median_abs_z,
        min_observations=folded.min_observations,
        average_observations=folded.average_observations,
        score=folded.median_abs_z - corrected_bits * 0.25 + folded.pilot_score * 0.05,
    )


def _v52_collect_candidates(stats: V52PairStats, rotations, plane: str, sync: str,
                            scale: float, offset_x: int, offset_y: int,
                            max_chase_bits: int, max_chase_flips: int) -> list[_V52Candidate]:
    candidates: list[_V52Candidate] = []
    # Scan all rotations for a hard hit before spending the bounded Chase
    # budget. Otherwise early wrong rotations can consume the budget and hide
    # a later exact copy.
    pending_soft: list[tuple[V52Folded, bytes]] = []
    for rotation in rotations:
        folded = _v52_fold(stats, rotation, sync)
        hard = _v52_pack(folded.scores < 0)
        hard_candidate = _v52_try_candidate(hard, folded, hard, plane, sync, scale, offset_x, offset_y, False)
        if hard_candidate is not None:
            candidates.append(hard_candidate)
            continue
        pending_soft.append((folded, hard))
    # Exact candidates are stronger evidence than bounded soft recovery.
    if candidates:
        return candidates
    soft_attempts = 0
    max_soft_attempts = 256
    for folded, hard in pending_soft:
        if max_chase_flips <= 0 or soft_attempts >= max_soft_attempts:
            break
        ranked = np.argsort(np.abs(folded.scores))[:max(0, min(max_chase_bits, V52_CODEWORD_BITS))]
        if not len(ranked):
            continue
        for flip_count in range(1, min(max_chase_flips, len(ranked)) + 1):
            for combination in itertools.combinations((int(i) for i in ranked), flip_count):
                if soft_attempts >= max_soft_attempts:
                    break
                soft_attempts += 1
                bits = folded.scores < 0
                bits = bits.copy()
                bits[list(combination)] = ~bits[list(combination)]
                candidate = _v52_try_candidate(_v52_pack(bits), folded, hard, plane, sync,
                                                scale, offset_x, offset_y, True)
                if candidate is not None:
                    candidates.append(candidate)
            if soft_attempts >= max_soft_attempts:
                break
    return candidates


def _v52_adjudicate(candidates: list[_V52Candidate]) -> V52Decoded | None:
    if not candidates:
        return None
    by_payload: dict[bytes, _V52Candidate] = {}
    for candidate in candidates:
        key = candidate.payload.bytes
        if key not in by_payload or by_payload[key].score < candidate.score:
            by_payload[key] = candidate
    distinct = sorted(by_payload.values(), key=lambda candidate: candidate.score, reverse=True)
    best = distinct[0]
    ambiguous = len(distinct) > 1
    return V52Decoded(
        payload=None if ambiguous else best.payload,
        codeword_bytes=None if ambiguous else best.codeword_bytes,
        plane=best.plane,
        sync=best.sync,
        offset_x=best.offset_x,
        offset_y=best.offset_y,
        estimated_scale=best.scale,
        corrected_bits=best.corrected_bits,
        soft_recovery_used=best.soft_recovery_used,
        pilot_score=best.pilot_score,
        candidate_count=len(candidates),
        ambiguous=ambiguous,
        failure_reason="multiple distinct CRC-valid payloads" if ambiguous else None,
        median_abs_z=best.median_abs_z,
        min_observations=best.min_observations,
        average_observations=best.average_observations,
    )


def v52_decode(image: np.ndarray, plane: str = "chroma", sync: str = V52_SYNC_NONE,
               scale: float = 1.0, offset_x: int = 0, offset_y: int = 0,
               search_tile: bool = False, max_chase_bits: int = V52_DEFAULT_CHASE_BITS,
               max_chase_flips: int = V52_DEFAULT_CHASE_FLIPS) -> V52Decoded | None:
    if plane not in ("luma", "chroma") or sync not in (V52_SYNC_NONE, V52_SYNC_PN, V52_SYNC_SEPARATED):
        return None
    sat = integral_image(feature_plane(image, plane))
    luma_sat = integral_image(feature_plane(image, "luma")) if sync != V52_SYNC_NONE else None
    stats = _v52_accumulate(sat, image, scale, offset_x, offset_y, sync, luma_sat)
    if stats is None:
        return None
    rotations = range(PAIRS_PER_TILE) if search_tile else (0,)
    candidates = _v52_collect_candidates(stats, rotations, plane, sync, float(scale), offset_x, offset_y,
                                          max_chase_bits, max_chase_flips)
    return _v52_adjudicate(candidates)


@dataclass
class _V52Context:
    stats: V52PairStats
    plane: str
    sync: str
    scale: float
    offset_x: int
    offset_y: int
    score: float


def v52_decode_best(image: np.ndarray, scales=None, planes=("chroma", "luma"),
                    sync_modes=(V52_SYNC_NONE,), search_phase: bool = True,
                    search_tile: bool = True, max_contexts: int = 16,
                    max_chase_bits: int = V52_DEFAULT_CHASE_BITS,
                    max_chase_flips: int = V52_DEFAULT_CHASE_FLIPS) -> V52Decoded | None:
    if scales is None:
        scales = V52_DEFAULT_SCALES
    scales = [float(value) for value in scales if math.isfinite(float(value)) and float(value) > 0]
    planes = [plane for plane in planes if plane in ("luma", "chroma")]
    sync_modes = [mode for mode in sync_modes if mode in (V52_SYNC_NONE, V52_SYNC_PN, V52_SYNC_SEPARATED)]
    if not scales or not planes or not sync_modes:
        return None
    height, width = image.shape[:2]
    chroma_sat = integral_image(feature_plane(image, "chroma"))
    luma_sat = integral_image(feature_plane(image, "luma"))
    pilot_sat = luma_sat if any(mode != V52_SYNC_NONE for mode in sync_modes) else None
    contexts: list[_V52Context] = []
    for scale in scales:
        block = BLOCK * scale
        phase_x_count = max(1, math.ceil(block * 2)) if search_phase else 1
        phase_y_count = max(1, math.ceil(block)) if search_phase else 1
        for plane in planes:
            sat = chroma_sat if plane == "chroma" else luma_sat
            for sync in sync_modes:
                for offset_y in range(phase_y_count):
                    for offset_x in range(phase_x_count):
                        stats = _v52_accumulate(sat, image, scale, offset_x, offset_y, sync, pilot_sat)
                        if stats is None:
                            continue
                        folded = _v52_fold(stats, 0, sync)
                        if folded.counts.min() <= 0:
                            continue
                        contexts.append(_V52Context(stats, plane, sync, scale, offset_x, offset_y,
                                                   folded.median_abs_z + abs(folded.pilot_score) * 0.05))
    if not contexts:
        return None
    # 粗筛按「比例」排名，不按单个上下文排名：一个比例有上百个相位，直接对上下文排序会让
    # 同一比例的一堆相位挤满 top-N，真正的好比例（实测 1.173 这类非网格值）根本没机会进精搜
    # —— 症状是"显式 --scale 能解，默认网格解不出"。
    best_per_scale: dict[str, _V52Context] = {}
    for context in contexts:
        key = f"{context.plane}:{context.sync}:{round(context.scale * 200)}"
        current = best_per_scale.get(key)
        if current is None or context.score > current.score:
            best_per_scale[key] = context
    ranked = sorted(best_per_scale.values(), key=lambda context: context.score, reverse=True)
    seeds = ranked[:min(4, max(1, max_contexts))]

    def evaluate(seed: _V52Context, value: float, offset_x: int, offset_y: int) -> _V52Context | None:
        if not 0.5 <= value <= 1.5 or not math.isfinite(value):
            return None
        sat = chroma_sat if seed.plane == "chroma" else luma_sat
        stats = _v52_accumulate(sat, image, value, offset_x, offset_y, seed.sync,
                                luma_sat if seed.sync != V52_SYNC_NONE else None)
        if stats is None:
            return None
        folded = _v52_fold(stats, 0, seed.sync)
        if folded.counts.min() <= 0:
            return None
        return _V52Context(stats, seed.plane, seed.sync, value, offset_x, offset_y,
                           folded.median_abs_z + abs(folded.pilot_score) * 0.05)

    finalists: list[_V52Context] = []
    for seed in seeds:
        best = seed
        fine = max(0.5, seed.scale - 0.05)
        while fine <= min(1.5, seed.scale + 0.05) + 1e-9:
            probe = evaluate(seed, fine, seed.offset_x, seed.offset_y)
            if probe is not None and probe.score > best.score:
                best = probe
            fine += 0.005
        step = 0.025
        tolerance = 0.5 / max(width, height)
        while step > tolerance:
            best_probe = best
            for value in (best.scale - step, best.scale, best.scale + step):
                for offset_y in range(max(0, best.offset_y - 1), best.offset_y + 2):
                    for offset_x in range(max(0, best.offset_x - 1), best.offset_x + 2):
                        probe = evaluate(best, value, offset_x, offset_y)
                        if probe is not None and probe.score > best_probe.score:
                            best_probe = probe
            best = best_probe
            step *= 0.5
        finalists.append(best)

    rotations = range(PAIRS_PER_TILE) if search_tile else (0,)
    candidates: list[_V52Candidate] = []
    for context in finalists:
        candidates.extend(_v52_collect_candidates(context.stats, rotations, context.plane, context.sync,
                                                   context.scale, context.offset_x, context.offset_y,
                                                   max_chase_bits, max_chase_flips))
    return _v52_adjudicate(candidates)
# MARK: - CLI


def fail(message: str, code: int) -> "None":
    print(message, file=sys.stderr)
    raise SystemExit(code)


def warn(message: str) -> None:
    print("警告: " + message, file=sys.stderr)


def usage() -> str:
    return (
        "用法: bwdecode.py <截图路径> [--protocol v4|v5.2|auto] [--bits N] [--offset X,Y] "
        "[--auto-offset] [--plane luma|chroma] [--pilot none|pn|separated] [--scale N] "
        "[--layout] [--key <hex>] [--pages <json>] [--auto] [--dump-codes]"
    )


def parse_args(argv: list[str]) -> dict:
    options = {
        "path": None, "payload_bits": PAYLOAD_BITS, "offset": (0, 0), "auto_offset": False,
        "explicit_offset": False, "plane": "chroma", "layout": False, "key": None,
        "pages": None, "auto": False, "dump_codes": False, "protocol": "v4",
        "pilot": V52_SYNC_NONE, "scale": None,
        "bits_explicit": False,
    }
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "--protocol":
            index += 1
            if index >= len(argv):
                fail("--protocol 需要 v4、v5.2 或 auto", 2)
            value = argv[index].lower()
            if value in ("v4", "4"):
                options["protocol"] = "v4"
            elif value in ("v5.2", "v52", "5.2"):
                options["protocol"] = "v5.2"
            elif value == "auto":
                options["protocol"] = "auto"
            else:
                fail("--protocol 需要 v4、v5.2 或 auto", 2)
        elif argument == "--v52":
            options["protocol"] = "v5.2"
        elif argument == "--pilot":
            index += 1
            if index >= len(argv) or argv[index] not in (V52_SYNC_NONE, V52_SYNC_PN, V52_SYNC_SEPARATED):
                fail("--pilot 需要 none、pn 或 separated", 2)
            options["pilot"] = argv[index]
        elif argument == "--scale":
            index += 1
            if index >= len(argv):
                fail("--scale 需要一个大于 0 的数，例如 0.837", 2)
            try:
                value = float(argv[index])
            except ValueError:
                value = float("nan")
            if not math.isfinite(value) or value <= 0 or value > 4:
                fail("--scale 需要一个大于 0 的数，例如 0.837", 2)
            options["scale"] = value
        elif argument == "--bits":
            index += 1
            if index >= len(argv) or not argv[index].lstrip("-").isdigit():
                fail(f"--bits 需要 1...{MAX_PAYLOAD_BITS} 的整数", 2)
            value = int(argv[index])
            if not 1 <= value <= MAX_PAYLOAD_BITS:
                fail(f"--bits 需要 1...{MAX_PAYLOAD_BITS} 的整数", 2)
            options["payload_bits"] = value
            options["bits_explicit"] = True
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


# 黑边检测阈值：与 Swift `RGBAImage.BorderTrimHeuristic` 一一对应。
# 实测企业微信/CleanShot 转发图会在截图外套一层纯黑，圆角让边缘列的近黑占比只有 0.93~0.95。
BORDER_DARK_LUMA = 32.0
BORDER_MIN_DARK_COVERAGE = 0.90
BORDER_MAX_TRIM_FRACTION = 0.25
BORDER_PROBE_LUMA = 96.0
BORDER_MIN_PROBE_COVERAGE = 0.30
BORDER_PROBE_DEPTH = 8


# 比例尺（粗定位）：水印在 x 方向是 [block, !block] 交替，所以水平自相关在 lag=block 处最负、
# lag=2*block 处最正。用这个"谷 + 2 倍峰"的联合目标直接读出 block 边长 → scale，省掉 21 档粗网格。
# 实测（合成 v5.2 图）：0.50/0.75/1.00/1.50 精确，1.173/1.30 误差 ≤1.3%，0.837 误差 4.5%；
# 企业微信转发的真实缩放图误差 7.6%，所以只当**粗定位**，候选要留 ±10% 余量，失败再退回完整网格。
SCALE_RULER_MIN_CONFIDENCE = 0.05
SCALE_RULER_SPAN = 0.10
SCALE_RULER_STEPS = 5
SCALE_RULER_MIN_BLOCK = 3.5
SCALE_RULER_MAX_BLOCK = 13.0


def estimate_scale_ruler(image: np.ndarray, planes=("chroma", "luma")):
    """用水平自相关的谷/峰联合目标估 block 边长，返回置信度最高的 (plane, scale, confidence)。

    置信度 = 谷深（|ACF(block)|）。水印图实测 0.30~0.74，无水印纯色/彩色噪声 ≈ 0.00。
    """
    best = None
    for plane in planes:
        feature = feature_plane(image, plane).reshape(image.shape[:2]).astype(np.float64)
        feature -= feature.mean()
        width = feature.shape[1]
        if width < int(SCALE_RULER_MAX_BLOCK * 2) + 2:
            continue
        nfft = 1 << int(np.ceil(np.log2(width + int(SCALE_RULER_MAX_BLOCK) + 1)))
        spectrum = np.fft.rfft(feature, n=nfft, axis=1)
        acf = np.fft.irfft(spectrum * np.conj(spectrum), n=nfft, axis=1)[:, :width].mean(axis=0)
        if acf[0] <= 0:
            continue
        acf = acf / acf[0]
        lags = np.arange(width, dtype=np.float64)
        grid = np.arange(SCALE_RULER_MIN_BLOCK, SCALE_RULER_MAX_BLOCK, 0.01)
        around = np.interp(grid, lags, acf)
        doubled = np.interp(np.clip(2.0 * grid, 0.0, lags[-1]), lags, acf)
        index = int(np.argmax(doubled - around))
        confidence = float(-around[index])
        candidate = (plane, float(grid[index]) / 8.0, confidence)
        if best is None or candidate[2] > best[2]:
            best = candidate
    return best


def ruler_candidate_scales(scale: float, span: float = SCALE_RULER_SPAN,
                           steps: int = SCALE_RULER_STEPS) -> list[float]:
    """按粗定位给的候选比例：span=0.10、steps=5 → 0.90/0.95/1.00/1.05/1.10 × scale。"""
    ratios = [1.0 + span * (2.0 * i / (steps - 1) - 1.0) for i in range(steps)]
    return sorted({round(scale * ratio, 4) for ratio in ratios if scale * ratio > 0})


def trim_uniform_dark_border(image: np.ndarray) -> tuple[np.ndarray, tuple[int, int, int, int]]:
    """裁掉四边纯黑边框，返回 (裁剪后的图, (left, top, right, bottom))。

    黑边本身不产生观测，但**黑边与内容交界的那几列 pair** 会拿到量级很大、方向固定的假差分，
    按 tile 周期性反复砸在同样的 bit 上，折起来就是十几个固定的错 bit，超过 BCH(255,207,t=6)
    的纠错能力。实测一张企业微信转发图：不裁失败，裁完 correctedBits=0。

    保守起见只在"这条边纯黑 + 紧挨着它就有明显更亮的内容"时才裁；深色 UI 的黑背景、或者
    跑满上限的长条，都当作内容不动（与 Swift 端 `trimmingUniformDarkBorder` 逐条同义）。
    """
    height, width = image.shape[:2]
    if height == 0 or width == 0:
        return image, (0, 0, 0, 0)
    luma = feature_plane(image, "luma").reshape(height, width)
    dark = luma <= BORDER_DARK_LUMA
    bright = luma >= BORDER_PROBE_LUMA
    column_dark, column_bright = dark.sum(axis=0), bright.sum(axis=0)
    row_dark, row_bright = dark.sum(axis=1), bright.sum(axis=1)

    def run(counts: np.ndarray, bright_counts: np.ndarray, span: int, from_start: bool) -> int:
        extent = int(counts.size)
        cap = min(extent, max(1, int(extent * BORDER_MAX_TRIM_FRACTION)))
        minimum = span * BORDER_MIN_DARK_COVERAGE
        count = 0
        while count < cap:
            index = count if from_start else extent - 1 - count
            if counts[index] < minimum:
                break
            count += 1
        # 全黑一直顶到上限 → 深色内容，不是黑边
        if count == 0 or count >= cap:
            return 0
        probe = 0
        pixels = 0
        for step in range(BORDER_PROBE_DEPTH):
            index = count + step if from_start else extent - 1 - count - step
            if index < count or index >= extent - count:
                continue
            probe += int(bright_counts[index])
            pixels += span
        if pixels == 0 or probe / pixels < BORDER_MIN_PROBE_COVERAGE:
            return 0
        return count

    left = run(column_dark, column_bright, height, True)
    top = run(row_dark, row_bright, width, True)
    right = run(column_dark, column_bright, height, False)
    bottom = run(row_dark, row_bright, width, False)
    if left == top == right == bottom == 0:
        return image, (0, 0, 0, 0)
    return image[top:height - bottom, left:width - right], (left, top, right, bottom)


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


def build_clock_line(build: int) -> str:
    """build 号是外部传入的 12 位十进制（YYYYMMDDHHMM），这里渲染成可读时间。

    语义上它就是构建方当地的墙上时间，不做时区换算，直接按数字拆。
    """
    digits = f"{build:012d}"
    return (f"build 时间: {digits[0:4]}-{digits[4:6]}-{digits[6:8]} "
            f"{digits[8:10]}:{digits[10:12]}（构建方当地墙上时间）")


def print_layout(result: Decoded, key: bytes | None, pages: list[str] | None) -> None:
    if result.payload_bits != PAYLOAD_BITS:
        fail(f"--layout 需要 --bits {PAYLOAD_BITS} 且载荷为 {PAYLOAD_BYTE_COUNT} 字节", 2)
    fields = Payload.from_bytes(result.payload_bytes)
    if fields is None:
        fail(f"--layout 需要 --bits {PAYLOAD_BITS} 且载荷为 {PAYLOAD_BYTE_COUNT} 字节", 2)

    stamp = datetime.datetime.fromtimestamp(fields.timestamp, datetime.timezone.utc)
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
        check_line = "mac=OK(验签)"
    elif verification == "selfCheck":
        check_line = "mac=OK(自检,未验签)"
    elif verification == "unsigned":
        check_line = ("mac=未签名(字段自洽,退结构自检)" if fields.is_plausible
                      else "mac=未签名(字段不自洽,谨慎)")
    else:
        check_line = "mac=未校验(需要 --key)" if key is None else "mac=BAD(密钥不符或载荷被改)"

    build_line = "build=未填" if fields.build == 0 else f"build={fields.build_number}"
    note = fields.note
    note_line = "note=（非法 UTF-8）" if note is None else ("note=（空）" if not note else f"note={note}")
    print(
        f"uid={fields.uid}(0x{fields.uid:08X})  time={stamp.strftime('%Y-%m-%d %H:%M:%S')} UTC  "
        f"{page_line}  {build_line}  {note_line}  "
        f"layout=v{LAYOUT_VERSION} app={fields.app} env={fields.environment}  {check_line}"
    )
    if fields.build != 0:
        print(build_clock_line(fields.build))


def print_v52_result(result: V52Decoded, layout: bool, trim_field: str = "") -> bool:
    """Print a successful v5.2 result; return false for ambiguity/failure."""
    if result.ambiguous:
        warn("v5.2 找到多个不同的 CRC-valid payload，拒绝按首个结果裁决 "
             f"（候选 {result.candidate_count} 个）")
        return False
    if result.payload is None:
        warn("v5.2 未找到 BCH + CRC-valid payload "
             f"（{result.failure_reason or '图像太小、相位或缩放不匹配'}）")
        return False
    payload = result.payload
    # 证据分档与 v4 同一把尺：v5.2 只有 CRC24（不是验签），观测不够就必须自己当守门人。
    minimum = MIN_OBSERVATIONS_PER_BIT
    verdict = (f"OK(每 bit 最少 {result.min_observations} 次观测)" if result.has_sufficient_evidence
               else f"TOO_SMALL(每 bit 仅 {result.average_observations:.1f} 次观测、"
                    f"最少 {result.min_observations} 次，需要 ≥ {minimum}：图太小或图案已被破坏)")
    print(
        f"protocol=v5.2 payload=0x{payload.bytes.hex()}  plane={result.plane}  "
        f"pilot={result.sync}  phase=({result.offset_x},{result.offset_y})  "
        f"scale={result.estimated_scale:.4f}  correctedBits={result.corrected_bits}  "
        f"softRecovery={'true' if result.soft_recovery_used else 'false'}  "
        f"pilotScore={result.pilot_score:.3f}  candidateCount={result.candidate_count}  "
        f"minObs={result.min_observations}  avgObs={result.average_observations:.1f}  "
        f"|z|中位={result.median_abs_z:.1f}  {verdict}{trim_field}"
    )
    if not result.has_sufficient_evidence:
        message = (f"每 bit 仅 {result.average_observations:.1f} 次观测（最少 {result.min_observations} 次，"
                   f"需要 ≥ {minimum}）：图太小或图案已被破坏，载荷不可信")
        if not layout:
            warn(message + "，不要用 --layout 解读字段")
            return True
        fail("图像太小 / 图案已被破坏，不解读字段：可用观测"
             f"每 bit 仅 {result.average_observations:.1f} 次（最少 {result.min_observations} 次，"
             f"需要 ≥ {minimum}）。请让用户发原图并保证范围足够大"
             "（256 bit 码字实测需要约 1280 个 pair，整宽 1179 时约 150px 高）", 1)
    if not layout:
        return True
    stamp = datetime.datetime.fromtimestamp(payload.timestamp, datetime.timezone.utc)
    build = datetime.datetime.fromtimestamp(payload.build_time, datetime.timezone.utc)
    note = payload.note or "（空）"
    print(
        f"uid={payload.uid}(0x{payload.uid:08X})  time={stamp.strftime('%Y-%m-%d %H:%M:%S')} UTC  "
        f"page={payload.page_name_code}  buildTime={build.strftime('%Y-%m-%d %H:%M:%S')} UTC  "
        f"app={payload.app}  note={note}  profile={V52_PROFILE}  crcStatus=OK(完整性自检,未验签)"
    )
    return True


def main(argv: list[str]) -> int:
    options = parse_args(argv)

    # Bare --auto keeps the historical v4 phase/plane search. Mixed protocol
    # detection is opt-in through the explicit --protocol auto spelling.
    if options["protocol"] == "auto":
        options["auto"] = True

    if options["auto_offset"] and options["explicit_offset"]:
        fail("--auto-offset 与 --offset 互斥：前者就是自动求后者，同时给无法判断以哪个为准", 2)
    if options["auto_offset"] and options["auto"]:
        fail("--auto-offset 与 --auto 语义重叠：--auto 已经穷举相位 / 平面 / 位数，单独用 --auto 即可", 2)

    if options["protocol"] == "v5.2":
        if options["bits_explicit"]:
            fail("v5.2 的物理码字固定为 256 bit（信息字段 207 bit），不要传 v4 的 --bits", 2)
        if options["key"] is not None:
            fail("v5.2 只有 CRC24，没有 v4 的 HMAC；请去掉 --key", 2)
        if options["pages"] is not None:
            fail("--pages 是 v4 的 15 字符注册表；v5.2 只输出 8 字符 compact page code，请去掉 --pages", 2)
        # pilot 要从亮度通道叠调制，luma 平面已经把亮度通道拿去放数据了。
        if options["pilot"] != V52_SYNC_NONE and options["plane"] == "luma":
            warn(f"--pilot {options['pilot']} 在 --plane luma 下不会写入导频"
                 "（luma 平面把亮度通道全部用于数据），输出的 pilotScore 无意义；要测导频请用 --plane chroma")
    elif options["protocol"] == "auto":
        if options["key"] is not None:
            warn("--protocol auto 带 --key 时，v5.2 分支仍只验证 CRC24（不使用 HMAC）；若需强制验签请显式 --protocol v4")
        if options["bits_explicit"]:
            warn("--protocol auto 的 v5.2 探测固定 256-bit 码字，忽略 --bits；v4 回退仍使用该参数")
        if options["pages"] is not None:
            warn("--pages 仅用于 v4 回退；v5.2 输出 compact page code，不使用旧 15 字符注册表")

    if options["dump_codes"]:
        if options["protocol"] == "v5.2":
            fail("--dump-codes 当前只支持 v4 页面注册表；v5.2 请使用 compact page code 定位", 2)
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

    # 黑边（IM 转发 / 图片查看器套的纯黑边框）先在自动路径上裁掉；显式 --offset 的调用方
    # 自己掌握几何，不动他们的图。裁剪后 phase 相对裁剪后的图像。
    trim = (0, 0, 0, 0)
    if not options["explicit_offset"]:
        image, trim = trim_uniform_dark_border(image)
        if any(trim):
            warn("检测到黑边，已按内容区解码"
                 f"（trim=({trim[0]},{trim[1]},{trim[2]},{trim[3]})，"
                 "phase 相对裁剪后的图像 / black border trimmed")
    trim_field = f"  trim=({trim[0]},{trim[1]},{trim[2]},{trim[3]})" if any(trim) else ""

    if options["protocol"] in ("v5.2", "auto"):
        explicit_v52 = options["protocol"] == "v5.2"
        scales = ([options["scale"]] if options["scale"] is not None
                  else (list(V52_DEFAULT_SCALES) if options["auto"] else [1.0]))
        if explicit_v52 and not options["auto"] and not options["auto_offset"]:
            v52_result = v52_decode(
                image, plane=options["plane"], sync=options["pilot"],
                scale=options["scale"] or 1.0, offset_x=options["offset"][0],
                offset_y=options["offset"][1], search_tile=False,
            )
        else:
            search_tile = (options["auto"] or options["auto_offset"]) if explicit_v52 else True
            planes = (options["plane"],) if explicit_v52 else ("chroma", "luma")
            v52_result = None
            if options["auto"] and options["scale"] is None:
                # 粗定位：比例尺先给 1 个平面 + ±10% 的 5 档候选，省掉 21 档粗网格 × 2 平面。
                hint = estimate_scale_ruler(image, planes=planes)
                if hint is not None and hint[2] >= SCALE_RULER_MIN_CONFIDENCE:
                    warn(f"比例尺粗定位：{hint[0]} scale≈{hint[1]:.3f}（置信 {hint[2]:.2f}）"
                         " → 只在候选附近精搜 / scale ruler hint")
                    v52_result = v52_decode_best(
                        image, scales=ruler_candidate_scales(hint[1]), planes=(hint[0],),
                        sync_modes=(options["pilot"],), search_phase=True, search_tile=search_tile,
                    )
                    if v52_result is not None and not v52_result.is_success:
                        v52_result = None   # ambiguous 不值得信，交给完整网格重搜
            if v52_result is None:
                v52_result = v52_decode_best(
                    image, scales=scales, planes=planes,
                    sync_modes=(options["pilot"],), search_phase=True, search_tile=search_tile,
                )
        if v52_result is not None:
            if print_v52_result(v52_result, options["layout"], trim_field):
                return 0
            fail("v5.2 解码未形成唯一的 BCH + CRC-valid 结果", 1)
        if explicit_v52:
            fail("v5.2 解码失败：未找到 BCH + CRC-valid 结果，请检查 --plane/--pilot/--scale/--offset", 1)

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
    validated = tier in ("signed", "selfCheck")
    # 没有校验值时，观测太少的图会解出一份「看着正常的垃圾」——必须自己当守门人
    insufficient = not validated and not result.has_sufficient_evidence
    if insufficient:
        verdict = (f"TOO_SMALL(每 bit 仅 {result.average_observations:.1f} 次观测、"
                   f"最少 {result.min_observations} 次，需要 ≥ {MIN_OBSERVATIONS_PER_BIT}："
                   "图太小或图案已被破坏)")
    elif weak == 0:
        verdict = f"OK(全部 {total} bit 显著)"
    elif weak <= total // 8:
        verdict = f"WEAK({weak}/{total} bit 证据不足，结论谨慎)"
    else:
        verdict = "NO(画面中可能没有水印)"

    print(
        f"payload=0x{result.payload_bytes.hex()}  payloadBits={result.payload_bits}  "
        f"平面={result.plane}  相位=({result.offset_x},{result.offset_y})  "
        f"signal={result.signal:.2f}  |z|中位={result.median_abs_z:.1f}  "
        f"最弱={result.confidence:.1f}  弱bit={weak}/{total}  {verdict}{trim_field}"
    )
    if options["layout"]:
        if insufficient:
            fail(f"图像太小 / 图案已被破坏，不解读字段：可用观测每 bit 仅 "
                 f"{result.average_observations:.1f} 次（最少 {result.min_observations} 次，"
                 f"需要 ≥ {MIN_OBSERVATIONS_PER_BIT}）。请让用户发原图，并保证范围足够大"
                 f"（512 bit 载荷实测需要约 2700 个 pair，整宽 1179 时约 300px 高，整屏最稳）", 1)
        print_layout(result, key, options["pages"])
    elif insufficient:
        warn(f"每 bit 仅 {result.average_observations:.1f} 次观测（最少 {result.min_observations} 次，"
             f"需要 ≥ {MIN_OBSERVATIONS_PER_BIT}）：图太小或图案已被破坏，载荷不可信，"
             f"不要用 --layout 解读字段")
    elif tier == "unsigned":
        # 没开 --layout 也要提醒：无校验值的载荷在裁剪场景下不可信
        warn(NO_VALIDATOR_WARNING)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
