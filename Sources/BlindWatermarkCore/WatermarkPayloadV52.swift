import Foundation

/// The compact v5.2 payload before BCH encoding.
///
/// The field order is deliberately a bit stream rather than a byte layout.  Bit 0
/// of the first field is written first, and the resulting 207 bits are packed
/// little-endian into 26 bytes (the last byte has one zero padding bit).
public struct WatermarkPayloadV52: Equatable {
    public static let payloadBits = 207
    public static let byteCount = 26
    public static let profile: UInt8 = 1
    public static let timestampEpoch: UInt64 = 1_767_225_600 // 2026-01-01 00:00:00 UTC
    public static let pageLength = 8
    public static let noteLength = 6
    public static let pageBits = 42
    public static let noteBits = 32

    public private(set) var uid: UInt32
    /// Seconds after `timestampEpoch`, limited to 31 bits.
    public private(set) var timestampOffset: UInt32
    /// Minutes after `timestampEpoch`, limited to 24 bits.
    public private(set) var buildMinuteOffset: UInt32
    /// Canonical page code, without right-padding underscores.
    public private(set) var pageCode: String
    public private(set) var app: UInt16
    /// Canonical note code, without right-padding underscores.
    public private(set) var noteCode: String
    public private(set) var crc24: UInt32

    /// Build from absolute Unix seconds. `buildTime` is rounded down to a UTC minute.
    /// Page names use the existing PageNameCodec normalization, then keep at most
    /// eight base-37 symbols. Notes are deliberately narrower: only `[a-z0-9_]`
    /// is accepted and at most six symbols are accepted (longer notes are rejected).
    public init?(
        uid: UInt32,
        timestamp: UInt64,
        buildTime: UInt64,
        pageClassName: String,
        app: UInt16 = 0,
        note: String = ""
    ) {
        guard timestamp >= Self.timestampEpoch else { return nil }
        let timestampOffset = timestamp - Self.timestampEpoch
        guard timestampOffset <= UInt64((1 << 31) - 1), buildTime >= Self.timestampEpoch else { return nil }
        let buildMinuteOffset = (buildTime - Self.timestampEpoch) / 60
        guard buildMinuteOffset <= UInt64((1 << 24) - 1) else { return nil }
        guard app <= 9_999 else { return nil }
        guard let pageCode = Self.pageCode(for: pageClassName), let noteCode = Self.noteCode(note) else {
            return nil
        }
        self.init(
            uid: uid,
            timestampOffset: UInt32(timestampOffset),
            buildMinuteOffset: UInt32(buildMinuteOffset),
            pageCode: pageCode,
            app: app,
            noteCode: noteCode,
            crc24: 0
        )
        self.crc24 = Self.crc24(for: Self.bodyBits(
            uid: uid,
            timestampOffset: UInt32(timestampOffset),
            buildMinuteOffset: UInt32(buildMinuteOffset),
            pageCode: pageCode,
            app: app,
            noteCode: noteCode
        ))
    }

    /// Build from protocol-relative values. This initializer is useful for
    /// deterministic vectors and does not involve Calendar or time zones.
    public init?(
        uid: UInt32,
        timestampOffset: UInt32,
        buildMinuteOffset: UInt32,
        pageClassName: String,
        app: UInt16 = 0,
        note: String = ""
    ) {
        guard timestampOffset <= UInt32((1 << 31) - 1), buildMinuteOffset < (1 << 24), app <= 9_999,
              let pageCode = Self.pageCode(for: pageClassName), let noteCode = Self.noteCode(note) else {
            return nil
        }
        self.init(
            uid: uid,
            timestampOffset: timestampOffset,
            buildMinuteOffset: buildMinuteOffset,
            pageCode: pageCode,
            app: app,
            noteCode: noteCode,
            crc24: 0
        )
        self.crc24 = Self.crc24(for: Self.bodyBits(
            uid: uid,
            timestampOffset: timestampOffset,
            buildMinuteOffset: buildMinuteOffset,
            pageCode: pageCode,
            app: app,
            noteCode: noteCode
        ))
    }

    /// Build from already normalized compact strings. The strings may be shorter
    /// than their fields; they are right-padded with `_` and decode back without
    /// those padding symbols. A literal trailing `_` is therefore not representable.
    public init?(
        uid: UInt32,
        timestampOffset: UInt32,
        buildMinuteOffset: UInt32,
        pageCode: String,
        app: UInt16 = 0,
        noteCode: String = ""
    ) {
        guard timestampOffset <= UInt32((1 << 31) - 1), buildMinuteOffset < (1 << 24), app <= 9_999,
              let pageCode = Self.compactCode(pageCode, maxLength: Self.pageLength),
              let noteCode = Self.compactCode(noteCode, maxLength: Self.noteLength) else {
            return nil
        }
        self.init(
            uid: uid,
            timestampOffset: timestampOffset,
            buildMinuteOffset: buildMinuteOffset,
            pageCode: pageCode,
            app: app,
            noteCode: noteCode,
            crc24: 0
        )
        self.crc24 = Self.crc24(for: Self.bodyBits(
            uid: uid,
            timestampOffset: timestampOffset,
            buildMinuteOffset: buildMinuteOffset,
            pageCode: pageCode,
            app: app,
            noteCode: noteCode
        ))
    }

    private init(
        uid: UInt32,
        timestampOffset: UInt32,
        buildMinuteOffset: UInt32,
        pageCode: String,
        app: UInt16,
        noteCode: String,
        crc24: UInt32
    ) {
        self.uid = uid
        self.timestampOffset = timestampOffset
        self.buildMinuteOffset = buildMinuteOffset
        self.pageCode = pageCode
        self.app = app
        self.noteCode = noteCode
        self.crc24 = crc24
    }

    /// Decode and validate a 207-bit payload. Unknown profile, non-zero reserved
    /// bits, illegal radix values, overflow, or a CRC mismatch all return nil.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount, bytes[Self.byteCount - 1] & 0x80 == 0 else { return nil }
        let bits = Self.unpack(bytes)
        guard bits.count == Self.payloadBits else { return nil }

        var cursor = 0
        let profile = Self.read(bits, at: cursor, width: 4); cursor += 4
        guard profile == UInt64(Self.profile) else { return nil }
        let uid = UInt32(Self.read(bits, at: cursor, width: 32)); cursor += 32
        let timestampOffset = UInt32(Self.read(bits, at: cursor, width: 31)); cursor += 31
        let buildMinuteOffset = UInt32(Self.read(bits, at: cursor, width: 24)); cursor += 24
        let pageValue = Self.read(bits, at: cursor, width: Self.pageBits); cursor += Self.pageBits
        let appValue = Self.read(bits, at: cursor, width: 14); cursor += 14
        let noteValue = Self.read(bits, at: cursor, width: Self.noteBits); cursor += Self.noteBits
        let crc = UInt32(Self.read(bits, at: cursor, width: 24)); cursor += 24
        guard Self.read(bits, at: cursor, width: 4) == 0 else { return nil }
        guard let pageCode = Self.decodeBase37(pageValue, length: Self.pageLength),
              let noteCode = Self.decodeBase37(noteValue, length: Self.noteLength),
              appValue <= 9_999 else { return nil }
        let expected = Self.crc24(for: Array(bits.prefix(179)))
        guard crc == expected else { return nil }

        self.init(
            uid: uid,
            timestampOffset: timestampOffset,
            buildMinuteOffset: buildMinuteOffset,
            pageCode: pageCode,
            app: UInt16(appValue),
            noteCode: noteCode,
            crc24: crc
        )
    }

    public var bytes: [UInt8] {
        var bits = Self.bodyBits(
            uid: uid,
            timestampOffset: timestampOffset,
            buildMinuteOffset: buildMinuteOffset,
            pageCode: pageCode,
            app: app,
            noteCode: noteCode
        )
        bits.append(contentsOf: Self.bits(UInt64(crc24), width: 24))
        bits.append(contentsOf: [Bool](repeating: false, count: 4))
        return Self.pack(bits)
    }

    public var timestamp: UInt64 { Self.timestampEpoch + UInt64(timestampOffset) }
    public var buildTime: UInt64 { Self.timestampEpoch + UInt64(buildMinuteOffset) * 60 }
    public var pageNameCode: String { pageCode }
    public var note: String { noteCode }
    public var isValid: Bool {
        Self.crc24(for: Self.bodyBits(
            uid: uid,
            timestampOffset: timestampOffset,
            buildMinuteOffset: buildMinuteOffset,
            pageCode: pageCode,
            app: app,
            noteCode: noteCode
        )) == crc24
    }

    // MARK: - Public protocol primitives

    public static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789_")

    /// Encode a fixed-width base-37 field into its numeric value. The first
    /// character is the most significant radix digit; padding is `_`.
    public static func encodeBase37(_ string: String, length: Int) -> UInt64? {
        guard (1...8).contains(length) else { return nil }
        guard let code = compactCode(string, maxLength: length) else { return nil }
        let chars = Array(code) + Array(repeating: Character("_"), count: max(0, length - code.count))
        var value: UInt64 = 0
        for character in chars {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            value = value * 37 + UInt64(digit)
        }
        return value
    }

    public static func decodeBase37(_ value: UInt64, length: Int) -> String? {
        guard (1...8).contains(length) else { return nil }
        var limit: UInt64 = 1
        for _ in 0..<length { limit *= 37 }
        guard value < limit else { return nil }
        var remaining = value
        var chars = [Character](repeating: "_", count: length)
        if length > 0 {
            for index in stride(from: length - 1, through: 0, by: -1) {
                chars[index] = alphabet[Int(remaining % 37)]
                remaining /= 37
            }
        }
        while chars.last == "_" { chars.removeLast() }
        return String(chars)
    }

    /// CRC-24/OPENPGP polynomial with an explicit bit-stream definition:
    /// poly=0x864CFB, init=0xB704CE, refin=false, refout=false, xorout=0.
    /// Input is the 179 field bits in protocol order; there is no implicit byte
    /// padding in the CRC. This avoids the ambiguity caused by the 207-bit tail.
    public static func crc24(for bits: [Bool]) -> UInt32 {
        var crc: UInt32 = 0xB7_04_CE
        for bit in bits {
            let top = ((crc >> 23) & 1) ^ (bit ? 1 : 0)
            crc = (crc << 1) & 0xFF_FFFF
            if top != 0 { crc ^= 0x86_4C_FB }
        }
        return crc
    }

    // MARK: - Bit layout

    private static func bodyBits(
        uid: UInt32,
        timestampOffset: UInt32,
        buildMinuteOffset: UInt32,
        pageCode: String,
        app: UInt16,
        noteCode: String
    ) -> [Bool] {
        let page = encodeBase37(pageCode, length: pageLength) ?? 0
        let note = encodeBase37(noteCode, length: noteLength) ?? 0
        var bits = [Bool]()
        bits.reserveCapacity(179)
        bits.append(contentsOf: Self.bits(UInt64(profile), width: 4))
        bits.append(contentsOf: Self.bits(UInt64(uid), width: 32))
        bits.append(contentsOf: Self.bits(UInt64(timestampOffset), width: 31))
        bits.append(contentsOf: Self.bits(UInt64(buildMinuteOffset), width: 24))
        bits.append(contentsOf: Self.bits(page, width: pageBits))
        bits.append(contentsOf: Self.bits(UInt64(app), width: 14))
        bits.append(contentsOf: Self.bits(note, width: noteBits))
        return bits
    }

    private static func bits(_ value: UInt64, width: Int) -> [Bool] {
        (0..<width).map { ((value >> UInt64($0)) & 1) != 0 }
    }

    private static func read(_ bits: [Bool], at offset: Int, width: Int) -> UInt64 {
        var value: UInt64 = 0
        for bit in 0..<width where bits[offset + bit] {
            value |= UInt64(1) << UInt64(bit)
        }
        return value
    }

    private static func pack(_ bits: [Bool]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (index, bit) in bits.enumerated() where bit {
            bytes[index >> 3] |= 1 << UInt8(index & 7)
        }
        return bytes
    }

    private static func unpack(_ bytes: [UInt8]) -> [Bool] {
        (0..<Self.payloadBits).map { bytes[$0 >> 3] & (1 << UInt8($0 & 7)) != 0 }
    }

    private static func pageCode(for className: String) -> String? {
        // PageNameCodec already defines the historical normalization and truncation
        // boundary. v5.2 keeps the first eight normalized symbols for the compact field.
        compactCode(String(PageNameCodec.code(for: className).prefix(pageLength)), maxLength: pageLength)
    }

    private static func noteCode(_ note: String) -> String? {
        compactCode(note.lowercased(), maxLength: noteLength)
    }

    private static func compactCode(_ string: String, maxLength: Int) -> String? {
        guard maxLength > 0 else { return nil }
        var chars = Array(string.lowercased())
        // `_` is the fixed-field pad and is not part of the canonical decoded
        // value. Trimming here makes `a_` and `a` encode to the same value and
        // prevents an object from round-tripping to a different public string.
        while chars.last == "_" { chars.removeLast() }
        guard chars.count <= maxLength else { return nil }
        guard chars.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return String(chars)
    }
}
