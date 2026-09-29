#!/usr/bin/env python3
"""v6-only 水印编解码镜像。依赖 numpy/Pillow；不包含历史协议回退。"""
from __future__ import annotations
import argparse
import datetime
import math
import sys
from dataclasses import dataclass
import numpy as np
from PIL import Image

V6_PAYLOAD_BITS = V6_MESSAGE_BITS = 211
V6_PAYLOAD_BYTE_COUNT = 27
V6_PROFILE = 6
V6_TIMESTAMP_EPOCH = 1767225600
V6_PAGE_LENGTH = 8
V6_NOTE_LENGTH = 6
V6_PAGE_BITS = 42
V6_NOTE_BITS = 32
V6_CRC_BITS = 24
V6_CRC_BODY_BITS = 179
V6_CODEWORD_BITS = 512
V6_BCH_BITS = 511
V6_PARITY_BITS = 300
V6_BCH_CORRECTION_LIMIT = 40
V6_CODEWORD_BYTE_COUNT = 64
V6_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789_'
PAD_CHARACTER = '_'
MIN_OBSERVATIONS_PER_BIT = 5
CELL_WIDTH, CELL_HEIGHT = 32, 8
DATA_COLUMNS, COLUMNS, ROWS = 16, 17, 64
TILE_WIDTH, TILE_HEIGHT = 544, 512
OBSERVATION_CLIP = 12.0
OBSERVATION_VARIANCE_FLOOR = 0.25
MAX_CONTEXTS, SHIFTS_PER_CONTEXT, SOFT_BITS = 12, 2, 6
MIN_PILOT_SCORE = 0.35
# 0.75 缩放加非整 cell 边框时需要覆盖跨周期的半像素相位。
COMPANION_X_REFINEMENTS = (-2,-1,0,1,2)
COMPANION_Y_REFINEMENTS = (-1,-0.5,0,0.5,1)
DEFAULT_SCALES = [0.5 + i * 0.05 for i in range(21)]

def feature_plane(rgba: np.ndarray, plane: str, companion: bool = False) -> np.ndarray:
    """逐像素标量特征，量纲与像素值一致（对应 `RGBAImage.featureBuffer`）。"""
    px = rgba.astype(np.float64)
    r, g, b = px[:, :, 0], px[:, :, 1], px[:, :, 2]
    # 只读取 chroma 渲染已有的反极性 R/G 伴色，不增加渲染幅度。
    if companion and plane == "chroma":
        return -(r + g) / 2
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


def page_name_code(name: str) -> str:
    name = name.split('.')[-1]
    suffixes = ('ViewController','ViewModel','Presenter','Interactor','Controller','View','Page','Screen','Scene','Cell','Item','Model','VC')
    for _ in range(2):
        for suffix in suffixes:
            if len(name) > len(suffix) and name.endswith(suffix):
                name = name[:-len(suffix)]
                break
        else:
            break
    for prefix in ('BH','JY','LL','HW','XQ'):
        if len(name) > len(prefix) and name.startswith(prefix):
            name = name[len(prefix):]
            break
    return ''.join(c for c in name.lower() if c in 'abcdefghijklmnopqrstuvwxyz0123456789')[:8]

def _v6_bits(value: int, width: int) -> list[bool]:
    """Return a fixed-width integer as a low-bit-first stream."""
    return [bool((int(value) >> bit) & 1) for bit in range(width)]


def _v6_read(bits: list[bool], offset: int, width: int) -> int:
    value = 0
    for bit in range(width):
        if bits[offset + bit]:
            value |= 1 << bit
    return value


def _v6_pack(bits: list[bool]) -> bytes:
    output = bytearray((len(bits) + 7) // 8)
    for index, value in enumerate(bits):
        if value:
            output[index >> 3] |= 1 << (index & 7)
    return bytes(output)


def _v6_unpack(data: bytes, count: int) -> list[bool]:
    return [bool(data[index >> 3] & (1 << (index & 7))) for index in range(count)]


def _v6_compact_code(value: str, max_length: int) -> str | None:
    if max_length <= 0:
        return None
    chars = list(str(value).lower())
    if len(chars) > max_length:
        return None
    while chars and chars[-1] == PAD_CHARACTER:
        chars.pop()
    if len(chars) > max_length or any(char not in V6_ALPHABET for char in chars):
        return None
    return "".join(chars)


def encode_base37(value: str, length: int) -> int | None:
    """Encode a compact field as a fixed-width, most-significant digit first radix value."""
    if not 1 <= length <= 8:
        return None
    compact = _v6_compact_code(value, length)
    if compact is None:
        return None
    digits = compact + PAD_CHARACTER * (length - len(compact))
    result = 0
    for char in digits:
        result = result * 37 + V6_ALPHABET.index(char)
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
        chars[index] = V6_ALPHABET[remaining % 37]
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


class WatermarkPayload:
    """The compact 211-bit v6 payload before BCH encoding."""

    payload_bits = V6_PAYLOAD_BITS
    byte_count = V6_PAYLOAD_BYTE_COUNT
    profile = V6_PROFILE
    timestamp_epoch = V6_TIMESTAMP_EPOCH
    page_length = V6_PAGE_LENGTH
    note_length = V6_NOTE_LENGTH
    page_bits = V6_PAGE_BITS
    note_bits = V6_NOTE_BITS

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
        page = _v6_compact_code(page_code, V6_PAGE_LENGTH)
        note = _v6_compact_code(note_code, V6_NOTE_LENGTH)
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
              page_class_name: str, app: int = 0, note: str = "") -> "WatermarkPayload | None":
        """Build from Unix seconds, with build time rounded down to a UTC minute."""
        if timestamp < V6_TIMESTAMP_EPOCH or build_time < V6_TIMESTAMP_EPOCH:
            return None
        timestamp_offset = int(timestamp) - V6_TIMESTAMP_EPOCH
        build_minute_offset = (int(build_time) - V6_TIMESTAMP_EPOCH) // 60
        if timestamp_offset > (1 << 31) - 1 or build_minute_offset >= (1 << 24):
            return None
        page = page_name_code(page_class_name)[:V6_PAGE_LENGTH]
        compact_note = str(note).lower()
        try:
            return cls(uid, timestamp_offset, build_minute_offset, page, app, compact_note)
        except ValueError:
            return None

    @classmethod
    def from_relative(cls, uid: int, timestamp_offset: int, build_minute_offset: int,
                      page_class_name: str, app: int = 0,
                      note: str = "") -> "WatermarkPayload | None":
        page = page_name_code(page_class_name)[:V6_PAGE_LENGTH]
        try:
            return cls(uid, timestamp_offset, build_minute_offset, page, app, str(note).lower())
        except ValueError:
            return None

    @classmethod
    def from_codes(cls, uid: int, timestamp_offset: int, build_minute_offset: int,
                   page_code: str, app: int = 0,
                   note_code: str = "") -> "WatermarkPayload | None":
        try:
            return cls(uid, timestamp_offset, build_minute_offset, page_code, app, note_code)
        except ValueError:
            return None

    @classmethod
    def from_bytes(cls, raw: bytes | bytearray) -> "WatermarkPayload | None":
        data = bytes(raw)
        if len(data) != V6_PAYLOAD_BYTE_COUNT or data[-1] & 0xF8:
            return None
        bits = _v6_unpack(data, V6_PAYLOAD_BITS)
        cursor = 0
        profile = _v6_read(bits, cursor, 4)
        cursor += 4
        if profile != V6_PROFILE:
            return None
        uid = _v6_read(bits, cursor, 32)
        cursor += 32
        timestamp_offset = _v6_read(bits, cursor, 31)
        cursor += 31
        build_minute_offset = _v6_read(bits, cursor, 24)
        cursor += 24
        page_value = _v6_read(bits, cursor, V6_PAGE_BITS)
        cursor += V6_PAGE_BITS
        app = _v6_read(bits, cursor, 14)
        cursor += 14
        note_value = _v6_read(bits, cursor, V6_NOTE_BITS)
        cursor += V6_NOTE_BITS
        crc = _v6_read(bits, cursor, V6_CRC_BITS)
        cursor += V6_CRC_BITS
        if _v6_read(bits, cursor, 8) != 0:
            return None
        page = decode_base37(page_value, V6_PAGE_LENGTH)
        note = decode_base37(note_value, V6_NOTE_LENGTH)
        if page is None or note is None or app > 9_999:
            return None
        if crc24_bits(bits[:V6_CRC_BODY_BITS]) != crc:
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
        page = encode_base37(self.page_code, V6_PAGE_LENGTH)
        note = encode_base37(self.note_code, V6_NOTE_LENGTH)
        assert page is not None and note is not None
        bits: list[bool] = []
        bits.extend(_v6_bits(V6_PROFILE, 4))
        bits.extend(_v6_bits(self.uid, 32))
        bits.extend(_v6_bits(self.timestamp_offset, 31))
        bits.extend(_v6_bits(self.build_minute_offset, 24))
        bits.extend(_v6_bits(page, V6_PAGE_BITS))
        bits.extend(_v6_bits(self.app, 14))
        bits.extend(_v6_bits(note, V6_NOTE_BITS))
        assert len(bits) == V6_CRC_BODY_BITS
        return bits

    @property
    def bytes(self) -> bytes:
        bits = self._body_bits()
        bits.extend(_v6_bits(self.crc24, V6_CRC_BITS))
        bits.extend([False] * 8)  # reserved
        assert len(bits) == V6_PAYLOAD_BITS
        return _v6_pack(bits)

    @property
    def timestamp(self) -> int:
        return V6_TIMESTAMP_EPOCH + self.timestamp_offset

    @property
    def build_time(self) -> int:
        return V6_TIMESTAMP_EPOCH + self.build_minute_offset * 60

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
        if not isinstance(other, WatermarkPayload):
            return NotImplemented
        return self.__dict__ == other.__dict__

    def __repr__(self) -> str:
        return (f"WatermarkPayload(uid={self.uid}, timestamp_offset={self.timestamp_offset}, "
                f"build_minute_offset={self.build_minute_offset}, page_code={self.page_code!r}, "
                f"app={self.app}, note_code={self.note_code!r}, crc24=0x{self.crc24:06x})")


@dataclass(frozen=True)
class V6BCHDecoded:
    message_bytes: bytes
    codeword_bytes: bytes
    corrected_bits: int


_V6_GF_EXP = [0] * 1022
_V6_GF_LOG = [-1] * 512
_v6_gf_value = 1
for _v6_index in range(511):
    _V6_GF_EXP[_v6_index] = _v6_gf_value
    _V6_GF_LOG[_v6_gf_value] = _v6_index
    _v6_gf_value <<= 1
    if _v6_gf_value & 0x200:
        _v6_gf_value ^= 0x211
for _v6_index in range(511, 1022):
    _V6_GF_EXP[_v6_index] = _V6_GF_EXP[_v6_index - 511]


def _v6_gf_exp(exponent: int) -> int:
    return _V6_GF_EXP[exponent % 511]


def _v6_gf_multiply(lhs: int, rhs: int) -> int:
    if lhs == 0 or rhs == 0:
        return 0
    return _v6_gf_exp(_V6_GF_LOG[lhs] + _V6_GF_LOG[rhs])


def _v6_gf_inverse(value: int) -> int:
    if value == 0:
        raise ZeroDivisionError("GF(512) inverse of zero")
    return _v6_gf_exp(511 - _V6_GF_LOG[value])


def _generator():
    roots = set()
    for root in range(1,81):
        value = root
        while value not in roots:
            roots.add(value)
            value = value * 2 % 511
    polynomial = [1]
    for root in sorted(roots):
        nxt = [0] * (len(polynomial) + 1)
        for index, value in enumerate(polynomial):
            nxt[index] ^= _v6_gf_multiply(value, _v6_gf_exp(root))
            nxt[index + 1] ^= value
        polynomial = nxt
    assert len(polynomial) == 301 and set(polynomial) <= {0,1}
    return sum(value << i for i,value in enumerate(polynomial))

V6_BCH_GENERATOR = _generator()

class V6BCH:
    """Binary narrow-sense BCH(511,211), t=40, with an even parity extension."""

    codeword_bits = V6_CODEWORD_BITS
    bch_bits = V6_BCH_BITS
    message_bits = V6_MESSAGE_BITS
    parity_bits = V6_PARITY_BITS
    correction_limit = V6_BCH_CORRECTION_LIMIT
    message_byte_count = V6_PAYLOAD_BYTE_COUNT
    codeword_byte_count = V6_CODEWORD_BYTE_COUNT

    @staticmethod
    def encode(message_bytes: bytes | bytearray) -> bytes:
        message = bytes(message_bytes)
        if len(message) != V6_PAYLOAD_BYTE_COUNT:
            raise ValueError("v6 BCH message must be 27 bytes")
        if message[-1] & 0xF8:
            raise ValueError("v6 message bits 211...215 must be zero padding")
        work = [False] * V6_BCH_BITS
        for index in range(V6_MESSAGE_BITS):
            work[V6_PARITY_BITS + index] = bool(message[index >> 3] & (1 << (index & 7)))
        for pivot in range(V6_BCH_BITS - 1, V6_PARITY_BITS - 1, -1):
            if not work[pivot]:
                continue
            shift = pivot - V6_PARITY_BITS
            for offset in range(V6_PARITY_BITS + 1):
                if (V6_BCH_GENERATOR >> offset) & 1:
                    work[shift + offset] = not work[shift + offset]
        codeword = [False] * V6_CODEWORD_BITS
        codeword[:V6_PARITY_BITS] = work[:V6_PARITY_BITS]
        for index in range(V6_MESSAGE_BITS):
            codeword[V6_PARITY_BITS + index] = bool(message[index >> 3] & (1 << (index & 7)))
        codeword[511] = sum(codeword[:511]) % 2 == 1
        return _v6_pack(codeword)

    @classmethod
    def _syndromes(cls, bits: list[bool]) -> list[int]:
        values = []
        for order in range(1, 2 * cls.correction_limit + 1):
            value = 0
            for degree, bit in enumerate(bits):
                if bit:
                    value ^= _v6_gf_exp(order * degree)
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
                    discrepancy ^= _v6_gf_multiply(connection[coefficient], syndromes[index - coefficient])
            if discrepancy == 0:
                shift += 1
                continue
            previous = connection.copy()
            factor = _v6_gf_multiply(discrepancy, _v6_gf_inverse(scale))
            for coefficient in range(size - shift):
                if backup[coefficient] != 0:
                    connection[coefficient + shift] ^= _v6_gf_multiply(factor, backup[coefficient])
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
    def decode(cls, codeword_bytes: bytes | bytearray) -> V6BCHDecoded | None:
        data = bytes(codeword_bytes)
        if len(data) != V6_CODEWORD_BYTE_COUNT:
            return None
        received = _v6_unpack(data, V6_CODEWORD_BITS)
        bch_received = received[:V6_BCH_BITS]
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
            for error_degree in range(V6_BCH_BITS):
                x = 1 if error_degree == 0 else _v6_gf_exp(511 - error_degree)
                value = 0
                power = 1
                for coefficient in locator:
                    value ^= _v6_gf_multiply(coefficient, power)
                    power = _v6_gf_multiply(power, x)
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
        if received[511] != expected_parity:
            corrected_count += 1
        full = corrected + [expected_parity]
        message = _v6_pack(corrected[V6_PARITY_BITS:V6_BCH_BITS])
        canonical = cls.encode(message)
        corrected_bytes = _v6_pack(full)
        if canonical != corrected_bytes:
            return None
        return V6BCHDecoded(message, corrected_bytes, corrected_count)


BORDER_DARK_LUMA = 32.0
BORDER_MIN_DARK_COVERAGE = 0.90
BORDER_MAX_TRIM_FRACTION = 0.25
BORDER_PROBE_LUMA = 96.0
BORDER_MIN_PROBE_COVERAGE = 0.30
BORDER_PROBE_DEPTH = 8


def trim_uniform_dark_border(image: np.ndarray) -> tuple[np.ndarray, tuple[int, int, int, int]]:
    """裁掉四边纯黑边框，返回 (裁剪后的图, (left, top, right, bottom))。

    黑边本身不含水印信号，但**黑边与内容交界的那几列 cell** 会拿到量级很大、方向固定的假差分，
    按 tile 周期性反复砸在同样的 bit 上，折起来就是十几个固定的错 bit，消耗纠错预算。v6 回归验证裁后恢复相同字段。

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
    with Image.open(path) as handle:
        return np.array(handle.convert("RGBA"), dtype=np.uint8)



def _hash(position):
    value = (position * 0x9E3779B9 + 0x7F4A7C15) & 0xFFFFFFFF
    value ^= value >> 16
    value = value * 0x85EBCA6B & 0xFFFFFFFF
    return value ^ (value >> 13)

PILOT_BITS = np.array([i in set(sorted(range(64), key=_hash)[:32]) for i in range(64)])
CODE_INDICES = np.concatenate(((np.arange(512)*73+19)&511,(np.arange(512)*151+89)&511))
POLARITIES = np.array([-1 if _hash(i) & 1 else 1 for i in range(1024)])
# 每个候选行列平移对应 64 个同步 cell；广播只排名几何，不解读字段。
PILOT_OBSERVED = np.array([[(row-dy)%ROWS*COLUMNS + (col-dx)%COLUMNS
                          for row in range(ROWS) for col in range(DATA_COLUMNS,COLUMNS)]
                         for dy in range(ROWS) for dx in range(COLUMNS)])
PILOT_SIGNS = np.where(PILOT_BITS,-1.0,1.0)


def make_tile(payload: WatermarkPayload, delta=4, plane='chroma'):
    """固定 v6 的预乘 RGBA，与 Swift makeTile 同义。"""
    if not 2 <= delta <= 255 or plane not in ('chroma','luma'):
        raise ValueError('invalid delta/plane')
    word=V6BCH.encode(payload.bytes)
    tile=np.zeros((TILE_HEIGHT,TILE_WIDTH,4),dtype=np.uint8)
    companion=math.floor(0.114*delta/0.886+0.5)
    for row in range(ROWS):
        for col in range(COLUMNS):
            if col<DATA_COLUMNS:
                position=row*DATA_COLUMNS+col
                index=int(CODE_INDICES[position])
                negative=bool(word[index>>3] & (1<<(index&7))) ^ bool(_hash(position)&1)
            else:
                negative=bool(PILOT_BITS[row])
            for x in range(CELL_WIDTH):
                wave=math.sin(2*math.pi*(x+0.5)/CELL_WIDTH)
                yellow=(1-(-wave if negative else wave))/2
                r=math.floor((companion*yellow if plane=='chroma' else delta*(1-yellow))+0.5)
                b=math.floor(delta*(1-yellow)+0.5) if plane=='chroma' else r
                tile[row*CELL_HEIGHT:(row+1)*CELL_HEIGHT,col*CELL_WIDTH+x]=(r,r,b,delta)
    return tile


def blend_tiled(image, tile):
    h,w=image.shape[:2]
    top=np.tile(tile,((h+tile.shape[0]-1)//tile.shape[0],(w+tile.shape[1]-1)//tile.shape[1],1))[:h,:w].astype(np.int32)
    dst=image.astype(np.int32)
    dst[:,:,:3]=np.minimum(255,top[:,:,:3]+dst[:,:,:3]*(255-top[:,:,3:4])//255)
    dst[:,:,3]=np.minimum(255,top[:,:,3]+dst[:,:,3]*(255-top[:,:,3])//255)
    return dst.astype(np.uint8)


def _at(sat,x,y):
    x=np.clip(x,0,sat.shape[1]-1)
    y=np.clip(y,0,sat.shape[0]-1)
    ix=np.floor(x).astype(int)
    iy=np.floor(y).astype(int)
    nx=np.minimum(ix+1,sat.shape[1]-1)
    ny=np.minimum(iy+1,sat.shape[0]-1)
    fx=x-ix
    fy=y-iy
    return (sat[iy,ix]*(1-fx)+sat[iy,nx]*fx)*(1-fy)+(sat[ny,ix]*(1-fx)+sat[ny,nx]*fx)*fy


def evidence_bounds(image):
    """外侧纯色 padding 不增加证据；不改变几何坐标或内部擦除统计。"""
    rgb=image[:,:,:3]
    rows=np.flatnonzero(np.any(rgb != rgb[:,:1,:],axis=(1,2)))
    cols=np.flatnonzero(np.any(rgb != rgb[:1,:,:],axis=(0,2)))
    return (int(cols[0]),int(rows[0]),int(cols[-1])+1,int(rows[-1])+1) if len(rows) and len(cols) else (0,0,0,0)


def _accumulate(sat,scale,x,y,bounds,companion=False):
    h,w=sat.shape[0]-1,sat.shape[1]-1
    if not all(math.isfinite(v) for v in (scale,x,y)) or not 0.5<=scale<=1.5 or x<0 or y<0:
        return None
    cw,ch=CELL_WIDTH*scale,CELL_HEIGHT*scale
    if w-x<cw or h-y<ch:return None
    nx,ny=int((w-x)/cw),int((h-y)/ch)
    xs=x+np.arange(nx)[None,:]*cw
    ys=y+np.arange(ny)[:,None]*ch
    def mean(px):return (_at(sat,px+cw/2,ys+ch)-_at(sat,px,ys+ch)-_at(sat,px+cw/2,ys)+_at(sat,px,ys))/(cw/2*ch)
    d=mean(xs)-mean(xs+cw/2)
    # 物理 cell 即使差分归零也计数；不会凭计数跳过 BCH/CRC。
    d=np.clip(d,-OBSERVATION_CLIP,OBSERVATION_CLIP)
    indices=(np.arange(ny)[:,None]%ROWS)*COLUMNS+np.arange(nx)[None,:]%COLUMNS
    ids=indices.ravel()
    values=d.ravel()
    left,top,right,bottom=bounds
    valid=(xs>=left)&(ys>=top)&(xs+cw<=right)&(ys+ch<=bottom)
    evidence=np.bincount(ids[valid.ravel()],minlength=COLUMNS*ROWS)
    # 伴色包含亮度，纯色框的亮度台阶不能参与判位或导频排名。
    if companion:
        ids=ids[valid.ravel()]
        values=values[valid.ravel()]
    return (np.bincount(ids,weights=values,minlength=COLUMNS*ROWS),np.bincount(ids,weights=values*values,minlength=COLUMNS*ROWS),np.bincount(ids,minlength=COLUMNS*ROWS),evidence)


@dataclass
class Context:
    stats: tuple
    scale: float
    x: float
    y: float
    shifts: list
    companion: bool = False
    @property
    def score(self):return self.shifts[0][2] if self.shifts else 0


def _context(sat,scale,x,y,bounds,search_tile=True,companion=False):
    stats=_accumulate(sat,scale,x,y,bounds,companion)
    if stats is None:return None
    sums,squares,counts,_=stats
    means=np.divide(sums,counts,out=np.zeros(COLUMNS*ROWS),where=counts>0)
    observed=PILOT_OBSERVED if search_tile else PILOT_OBSERVED[:1]
    values=means[observed]
    energy=(values*values).sum(axis=1)*64
    scores=np.divide((values*PILOT_SIGNS).sum(axis=1),np.sqrt(energy),out=np.zeros(len(values)),where=energy>0)
    ranked=np.argsort(-scores,kind='stable')[:SHIFTS_PER_CONTEXT]
    shifts=[(int(i%COLUMNS),int(i//COLUMNS),float(scores[i])) for i in ranked]
    return Context(stats,scale,x,y,shifts,companion)


@dataclass
class Candidate:
    payload: WatermarkPayload
    corrected_bits: int
    soft: bool
    context: Context
    shift_x: int
    shift_y: int
    pilot: float
    min_obs: int
    avg_obs: float
    median_z: float


@dataclass
class Decoded:
    payload: WatermarkPayload | None
    best: Candidate
    candidate_count: int
    ambiguous: bool
    @property
    def is_success(self):return self.payload is not None and not self.ambiguous
    @property
    def has_sufficient_evidence(self):return self.best.min_obs>=MIN_OBSERVATIONS_PER_BIT


def adjudicate(candidates):
    if not candidates:return None
    best=max(candidates,key=lambda c:(c.min_obs,c.median_z,c.pilot))
    distinct={c.payload.bytes for c in candidates}
    ambiguous=len(distinct)>1
    return Decoded(None if ambiguous else best.payload,best,len(distinct),ambiguous)


def _attempt(scores,counts,ctx,x,y,pilot,flips=()):
    hard=scores<0
    bits=hard.copy()
    for i in flips:bits[i]=not bits[i]
    corrected=V6BCH.decode(_v6_pack(bits))
    if corrected is None:return None
    payload=WatermarkPayload.from_bytes(corrected.message_bytes)
    if payload is None:return None
    n=int(np.count_nonzero(hard != np.array(_v6_unpack(corrected.codeword_bytes,512))))
    return Candidate(payload,n,bool(flips),ctx,x,y,pilot,int(counts.min()),float(counts.mean()),float(np.median(np.abs(scores))))


def _candidates(contexts):
    found=[]
    pending=[]
    for ctx in contexts:
        for x,y,pilot in ctx.shifts:
            if pilot<MIN_PILOT_SCORE:continue
            local=np.array([((row-y)%ROWS)*COLUMNS+(col-x)%COLUMNS for row in range(ROWS) for col in range(DATA_COLUMNS)])
            sums,squares,observations,evidence=ctx.stats
            n=np.bincount(CODE_INDICES,weights=observations[local],minlength=512)
            folded=np.bincount(CODE_INDICES,weights=sums[local]*POLARITIES,minlength=512)
            squared=np.bincount(CODE_INDICES,weights=squares[local],minlength=512)
            counts=np.bincount(CODE_INDICES,weights=evidence[local],minlength=512).astype(int)
            mean=np.divide(folded,n,out=np.zeros(512),where=n>0)
            variance=np.maximum(OBSERVATION_VARIANCE_FLOOR,np.divide(squared,n,out=np.zeros(512),where=n>0)-mean*mean)
            scores=mean*np.sqrt(n/variance)
            hit=_attempt(scores,counts,ctx,x,y,pilot)
            if hit:found.append(hit)
            else:pending.append((ctx,x,y,pilot,scores,counts))
    if not found:
        for ctx,x,y,pilot,scores,counts in sorted(pending,key=lambda item:-item[3])[:2]:
            ranked=np.argsort(np.abs(scores),kind='stable')[:SOFT_BITS]
            for a,i in enumerate(ranked):
                hit=_attempt(scores,counts,ctx,x,y,pilot,(i,))
                if hit:found.append(hit)
                for j in ranked[a+1:]:
                    hit=_attempt(scores,counts,ctx,x,y,pilot,(i,j))
                    if hit:found.append(hit)
    return found


def decode(image,plane='chroma',scale=1,offset_x=0,offset_y=0,search_tile=False):
    if not all(math.isfinite(v) for v in (scale,offset_x,offset_y)) or not 0.5<=scale<=1.5 or offset_x<0 or offset_y<0:return None
    bounds=evidence_bounds(image)
    for companion in ([False,True] if plane=='chroma' else [False]):
        sat=integral_image(feature_plane(image,plane,companion))
        ctx=_context(sat,scale,offset_x,offset_y,bounds,search_tile,companion)
        result=adjudicate(_candidates([ctx])) if ctx else None
        # 保留主通道的小图/歧义结论，不使用备用通道绕过拒答。
        if result is not None:return result
    return None


def decode_best(image,scales=None,plane='chroma'):
    bounds=evidence_bounds(image)
    for companion in ([False,True] if plane=='chroma' else [False]):
        sat=integral_image(feature_plane(image,plane,companion))
        result=_search(sat,bounds,scales,companion)
        if result is not None:return result
    return None


def _search(sat,bounds,scales,companion):
    def scan(values):
        found=[]
        for scale in values:
            if not math.isfinite(scale) or not 0.5<=scale<=1.5:continue
            best=None
            for y in np.arange(0,CELL_HEIGHT*scale,2):
                for x in np.arange(0,CELL_WIDTH*scale,4):
                    ctx=_context(sat,float(scale),float(x),float(y),bounds,companion=companion)
                    if ctx and (best is None or ctx.score>best.score):best=ctx
            if best:found.append(best)
        return sorted(found,key=lambda c:-c.score)
    def finish(contexts):
        refined=[]
        for seed in contexts[:MAX_CONTEXTS]:
            for dy in (COMPANION_Y_REFINEMENTS if companion else (-1,0,1)):
                for dx in (COMPANION_X_REFINEMENTS if companion else (-2,0,2)):
                    x,y=seed.x+dx,seed.y+dy
                    if companion:
                        x=x%(CELL_WIDTH*seed.scale)
                        y=y%(CELL_HEIGHT*seed.scale)
                    if x<0 or y<0:continue
                    ctx=_context(sat,seed.scale,x,y,bounds,companion=companion)
                    if ctx:refined.append(ctx)
        return adjudicate(_candidates(sorted(refined,key=lambda c:-c.score)[:MAX_CONTEXTS]))
    if scales is not None:return finish(scan(scales))
    exact=finish(scan([1.0]))
    if exact is not None:return exact
    coarse=scan(DEFAULT_SCALES)
    step=1/(max(sat.shape)-1)
    fine=set()
    for seed in coarse[:3]:
        for value in np.arange(max(0.5,seed.scale-0.03),min(1.5,seed.scale+0.03)+1e-10,step):
            fine.add(math.floor(value*1e6+0.5)/1e6)
    return finish(scan(sorted(fine)))


def main(argv=None):
    parser=argparse.ArgumentParser(description='v6-only 水印解码器；历史截图需要旧版本工具')
    parser.add_argument('path')
    parser.add_argument('--layout',action='store_true')
    parser.add_argument('--protocol',choices=['v6'],default='v6')
    parser.add_argument('--plane',choices=['chroma','luma'],default='chroma')
    parser.add_argument('--auto',action='store_true')
    parser.add_argument('--scale',type=float)
    parser.add_argument('--offset')
    args=parser.parse_args(argv)
    if args.scale is not None and (not math.isfinite(args.scale) or not 0.5<=args.scale<=1.5):parser.error('--scale 需要 0.5...1.5')
    try:image=load_image(args.path)
    except Exception as error:
        print(f'无法读取图片: {error}',file=sys.stderr)
        return 1
    trim=(0,0,0,0)
    if args.offset is not None:
        try:
            x,y=map(float,args.offset.split(','))
            if not all(math.isfinite(v) and v>=0 for v in (x,y)):raise ValueError
        except ValueError:parser.error('--offset 需要非负 X,Y')
        result=decode(image,args.plane,args.scale or 1,x,y,True)
    else:
        image,trim=trim_uniform_dark_border(image)
        result=decode_best(image,[args.scale] if args.scale is not None else None,args.plane)
    if result is None:
        print('NO(protocol=v6，无 BCH + CRC-valid 载荷)',file=sys.stderr)
        return 1
    if result.ambiguous:
        print('ambiguous(protocol=v6，多个不同载荷，拒绝解读)',file=sys.stderr)
        return 1
    c=result.best
    p=result.payload
    verdict='OK' if result.has_sufficient_evidence else f'TOO_SMALL(每 bit 最少 {c.min_obs} 次，需要 ≥ 5)'
    trim_field=f' trim=({",".join(map(str,trim))})' if any(trim) else ''
    print(f'protocol=v6 payload=0x{p.bytes.hex()} plane={args.plane} phase=({c.context.x:.2f},{c.context.y:.2f}) tileShift=({c.shift_x},{c.shift_y}) scale={c.context.scale:.6f} correctedBits={c.corrected_bits} softRecovery={str(c.soft).lower()} companionRecovery={str(c.context.companion).lower()} pilotScore={c.pilot:.3f} minObs={c.min_obs} avgObs={c.avg_obs:.1f} |z|中位={c.median_z:.1f} {verdict}{trim_field}')
    if not result.has_sufficient_evidence:
        print('观测不足，不解读字段，请使用范围更大的原图。',file=sys.stderr)
        return 1 if args.layout else 0
    if args.layout:
        clock=lambda t:datetime.datetime.fromtimestamp(t,datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')
        print(f'uid={p.uid} time={clock(p.timestamp)} page={p.page_code} buildTime={clock(p.build_time)} app={p.app} note={p.note or "（空）"} crcStatus=OK(完整性自检,未验签)')
    return 0

if __name__=='__main__':sys.exit(main())
