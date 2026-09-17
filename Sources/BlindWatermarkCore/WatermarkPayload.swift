import CryptoKit
import Foundation

/// 推荐的 128 bit 载荷布局 —— 把 uid、时间戳、页面、校验一次装下。
///
/// ```
/// [127:96] uid        UInt32   用户 ID（原样放，不用截断、不用查表）
/// [ 95:64] timestamp  UInt32   Unix 秒，够用到 2106 年，不用再换算时间桶
/// [ 63:48] pageIndex  UInt16   页面注册表索引，最多 65536 个受监控页面
/// [ 47:44] magic      UInt4    固定为 0xA，解码端用来自检 payloadBits 是否与编码端一致
/// [ 43:32] appTag     UInt12   App / 端 / 环境 标识（最多 4096 个枚举值）
/// [ 31: 0] mac        UInt32   HMAC-SHA256(前 12 字节, 服务端密钥) 截断；无后端时填 0
/// ```
///
/// 字段全小端。`pageIndex` 不是类名本身 —— 32 字节装不下类名字符串，
/// 由接入端维护「索引 → 类名」注册表，解码端拿索引查表还原。
///
/// **magic 自检**：解码端验证 `hasMagic`，可快速发现 `--bits` 与编码端不一致的情况，
/// 避免解出高置信度但错误的载荷而无从察觉。
///
/// **密钥只在服务端持有**：服务端算好 mac 下发完整 16 字节，客户端只负责渲染；
/// 解码端拿 `--key` 校验。无后端模式下 mac 填 0 即可。
public struct WatermarkPayload: Equatable {
    public static let byteCount = 16
    public static let payloadBits = 128

    /// tag 字段高 4 bit 的固定魔数。解码端用 `hasMagic` 校验，
    /// 不符说明 `payloadBits` 与编码端不一致、图像不含水印或载荷损坏。
    public static let magic: UInt16 = 0xA

    public var uid: UInt32
    public var timestamp: UInt32
    public var pageIndex: UInt16
    /// 原始 tag 字段：高 4 bit 为 `magic`，低 12 bit 为业务标签 `appTag`。
    /// 直接构造时请用 `init(uid:timestamp:pageIndex:appTag:mac:)` 以自动嵌入 magic。
    public var tag: UInt16
    public var mac: UInt32

    /// 业务标签（tag 低 12 bit，0–4095）。
    public var appTag: UInt16 { tag & 0x0FFF }

    /// 高 4 bit 是否等于 `magic`。
    /// 解码后第一步就应检查此属性；不符时请勿相信其余字段。
    public var hasMagic: Bool { (tag >> 12) == Self.magic }

    // MARK: - 构造

    /// 底层构造，保留 tag 原值。用于从字节流反序列化。
    public init(uid: UInt32, timestamp: UInt32, pageIndex: UInt16, tag: UInt16, mac: UInt32) {
        self.uid = uid
        self.timestamp = timestamp
        self.pageIndex = pageIndex
        self.tag = tag
        self.mac = mac
    }

    /// 推荐构造：自动将 magic 嵌入 tag 高 4 bit。`appTag` 只取低 12 bit。
    public init(uid: UInt32, timestamp: UInt32, pageIndex: UInt16, appTag: UInt16 = 0, mac: UInt32) {
        let tagWithMagic = (Self.magic << 12) | (appTag & 0x0FFF)
        self.init(uid: uid, timestamp: timestamp, pageIndex: pageIndex, tag: tagWithMagic, mac: mac)
    }

    /// 算好 mac 再构造（服务端用）。客户端别拿这个入口。
    public init(uid: UInt32, timestamp: UInt32, pageIndex: UInt16, tag: UInt16, key: SymmetricKey) {
        self.init(
            uid: uid,
            timestamp: timestamp,
            pageIndex: pageIndex,
            tag: tag,
            mac: WatermarkPayload.mac(uid: uid, timestamp: timestamp, pageIndex: pageIndex, tag: tag, key: key)
        )
    }

    /// 嵌入 magic + HMAC 的构造（服务端用）。
    public init(uid: UInt32, timestamp: UInt32, pageIndex: UInt16, appTag: UInt16 = 0, key: SymmetricKey) {
        let tagWithMagic = (Self.magic << 12) | (appTag & 0x0FFF)
        self.init(uid: uid, timestamp: timestamp, pageIndex: pageIndex, tag: tagWithMagic, key: key)
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == WatermarkPayload.byteCount else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        func u16(_ o: Int) -> UInt16 {
            UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8
        }
        self.init(uid: u32(0), timestamp: u32(4), pageIndex: u16(8), tag: u16(10), mac: u32(12))
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
        out.append(UInt8(pageIndex & 0xFF))
        out.append(UInt8((pageIndex >> 8) & 0xFF))
        out.append(UInt8(tag & 0xFF))
        out.append(UInt8((tag >> 8) & 0xFF))
        out.append(contentsOf: [
            UInt8(mac & 0xFF), UInt8((mac >> 8) & 0xFF), UInt8((mac >> 16) & 0xFF), UInt8((mac >> 24) & 0xFF),
        ])
        return out
    }

    public func isValid(key: SymmetricKey) -> Bool {
        mac == WatermarkPayload.mac(uid: uid, timestamp: timestamp, pageIndex: pageIndex, tag: tag, key: key)
    }

    /// 前 12 字节的 HMAC-SHA256 截断到 32 bit。
    /// 32 bit 意味着伪造者单次尝试的命中概率是 1/2^32，够挡住顺手伪造，挡不住针对性碰撞 ——
    /// 真要对抗强攻击，把 mac 换成整个 128 bit 都拿来做校验（uid/时间/页面走服务端表）。
    public static func mac(
        uid: UInt32,
        timestamp: UInt32,
        pageIndex: UInt16,
        tag: UInt16,
        key: SymmetricKey
    ) -> UInt32 {
        var body = WatermarkPayload(uid: uid, timestamp: timestamp, pageIndex: pageIndex, tag: tag, mac: 0).bytes
        body.removeLast(4)
        let code = HMAC<SHA256>.authenticationCode(for: Data(body), using: key)
        let raw = [UInt8](code)
        return UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
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
