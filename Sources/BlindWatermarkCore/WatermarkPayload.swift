import CryptoKit
import Foundation

/// 推荐的 256 bit 载荷布局 —— uid、时间戳、页面短码、校验一次装下。
///
/// ```
/// [255:224] uid        32   UInt32   用户 ID，原样放，不用截断、不用查表
/// [223:192] timestamp  32   UInt32   Unix 秒，精确到秒且够用到 2106 年
/// [191:128] pageCode   64   UInt64   页面类名短码，10 个 6-bit 字符 = 60 bit（高 4 位留 0）
/// [127: 96] tag        32   UInt32   [31:28] 布局版本 [27:20] App [19:12] 环境 [11:0] 保留
/// [ 95:  0] mac        96            HMAC-SHA256(前 20 字节, 服务端密钥) 截断到 96 bit
/// ```
///
/// 共 32 字节，字段全小端。
///
/// **为什么是 256 bit**：10 字符页面短码要 60 bit，加上 uid/时间/mac 后 128 bit 装不下。
/// 256 bit 是设计上限 —— 每 tile 512 个 pair，此时每 tile 正好重复 2 份，还是偶数，
/// 翻转极性抵消亮度梯度这一机制仍然成立（再大就没法成对相消了）。
/// 实测 256 bit 在 chroma 模式下每 bit 仍有约 91 次观测，余量足够。
///
/// **页面为什么存短码而不是索引**：索引必须配一张同版本的注册表，表一换历史截图就废；
/// 短码是从类名推出来的，拿着 `chatlist` 直接 `grep -rin "class.*chatlist"` 就能定位。
///
/// **密钥只在服务端持有**：服务端算好 mac 下发完整 32 字节，客户端只负责渲染；
/// 解码端拿 `--key` 校验。客户端自己算 mac 等于把密钥交出去，只防君子。
public struct WatermarkPayload: Equatable {
    public static let byteCount = 32
    public static let payloadBits = 256
    /// 当前布局版本，写进 tag 高 4 位
    public static let layoutVersion: UInt32 = 3
    /// mac 长度
    public static let macByteCount = 12
    /// mac 覆盖的字节数（uid + timestamp + pageCode + tag）
    static let signedByteCount = 20

    public var uid: UInt32
    public var timestamp: UInt32
    /// 60 bit 有效（10 个 6-bit 字符），高 4 位保留为 0
    public var pageCode: UInt64
    /// 布局版本 / App / 环境
    public var tag: UInt32
    /// 96 bit（12 字节）
    public var mac: [UInt8]

    public init(uid: UInt32, timestamp: UInt32, pageCode: UInt64, tag: UInt32, mac: [UInt8]) {
        self.uid = uid
        self.timestamp = timestamp
        self.pageCode = pageCode & 0x0FFF_FFFF_FFFF_FFFF
        self.tag = tag
        self.mac = mac
    }

    /// 算好 mac 再构造。给服务端用；客户端别拿这个入口。
    public init(uid: UInt32, timestamp: UInt32, pageCode: UInt64, tag: UInt32, key: SymmetricKey) {
        let rounded = pageCode & 0x0FFF_FFFF_FFFF_FFFF
        self.init(
            uid: uid,
            timestamp: timestamp,
            pageCode: rounded,
            tag: tag,
            mac: WatermarkPayload.mac(uid: uid, timestamp: timestamp, pageCode: rounded, tag: tag, key: key)
        )
    }

    /// 从类名直接构造，短码由 `PageNameCodec` 算。
    public init(
        uid: UInt32,
        timestamp: UInt32,
        pageClassName: String,
        app: UInt32 = 0,
        environment: UInt32 = 0,
        key: SymmetricKey
    ) {
        let tag = (WatermarkPayload.layoutVersion << 28)
            | ((app & 0xFF) << 20)
            | ((environment & 0xFF) << 12)
        self.init(
            uid: uid,
            timestamp: timestamp,
            pageCode: PageNameCodec.encode(PageNameCodec.code(for: pageClassName)),
            tag: tag,
            key: key
        )
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == WatermarkPayload.byteCount else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        var code: UInt64 = 0
        for i in 0..<8 { code |= UInt64(bytes[8 + i]) << (8 * UInt64(i)) }
        self.init(
            uid: u32(0),
            timestamp: u32(4),
            pageCode: code,
            tag: u32(16),
            mac: Array(bytes[20..<32])
        )
    }

    public var bytes: [UInt8] {
        var out = [UInt8]()
        out.append(contentsOf: [
            UInt8(uid & 0xFF), UInt8((uid >> 8) & 0xFF), UInt8((uid >> 16) & 0xFF), UInt8((uid >> 24) & 0xFF),
        ])
        out.append(contentsOf: [
            UInt8(timestamp & 0xFF), UInt8((timestamp >> 8) & 0xFF),
            UInt8((timestamp >> 16) & 0xFF), UInt8((timestamp >> 24) & 0xFF),
        ])
        for i in 0..<8 { out.append(UInt8((pageCode >> (8 * UInt64(i))) & 0xFF)) }
        out.append(contentsOf: [
            UInt8(tag & 0xFF), UInt8((tag >> 8) & 0xFF),
            UInt8((tag >> 16) & 0xFF), UInt8((tag >> 24) & 0xFF),
        ])
        var macBytes = mac
        if macBytes.count < WatermarkPayload.macByteCount {
            macBytes.append(contentsOf: [UInt8](
                repeating: 0,
                count: WatermarkPayload.macByteCount - macBytes.count
            ))
        }
        out.append(contentsOf: macBytes.prefix(WatermarkPayload.macByteCount))
        return out
    }

    /// 10 字符页面短码，拿去 grep 类名
    public var pageNameCode: String { PageNameCodec.decode(pageCode) }

    public var layoutVersion: UInt32 { tag >> 28 }
    public var app: UInt32 { (tag >> 20) & 0xFF }
    public var environment: UInt32 { (tag >> 12) & 0xFF }

    public func isValid(key: SymmetricKey) -> Bool {
        let expected = WatermarkPayload.mac(
            uid: uid,
            timestamp: timestamp,
            pageCode: pageCode,
            tag: tag,
            key: key
        )
        // 定长比较，避免因为长度差异提前返回
        guard mac.count == expected.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<expected.count { diff |= mac[i] ^ expected[i] }
        return diff == 0
    }

    /// 前 20 字节的 HMAC-SHA256 截断到 96 bit。
    public static func mac(
        uid: UInt32,
        timestamp: UInt32,
        pageCode: UInt64,
        tag: UInt32,
        key: SymmetricKey
    ) -> [UInt8] {
        let body = WatermarkPayload(
            uid: uid,
            timestamp: timestamp,
            pageCode: pageCode,
            tag: tag,
            mac: []
        ).bytes.prefix(signedByteCount)
        let code = HMAC<SHA256>.authenticationCode(for: Data(body), using: key)
        return Array([UInt8](code).prefix(macByteCount))
    }
}

extension SymmetricKey {
    /// 十六进制字符串构造，例如 `"00112233445566778899aabbccddeeff"`
    public init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = chars[index].hexDigitValue, let low = chars[index + 1].hexDigitValue else {
                return nil
            }
            bytes.append(UInt8(high << 4 | low))
            index += 2
        }
        self.init(data: Data(bytes))
    }
}
