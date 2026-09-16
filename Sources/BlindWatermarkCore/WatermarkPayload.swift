import CryptoKit
import Foundation

/// 推荐的 128 bit 载荷布局 —— 把 uid、时间戳、页面、校验一次装下。
///
/// ```
/// [127:96] uid        UInt32   用户 ID（原样放，不用截断、不用查表）
/// [ 95:64] timestamp  UInt32   Unix 秒，够用到 2106 年，不用再换算时间桶
/// [ 63:48] pageIndex  UInt16   页面注册表索引，最多 65536 个受监控页面
/// [ 47:32] tag        UInt16   App / 端 / 环境 标识
/// [ 31: 0] mac        UInt32   HMAC-SHA256(前 12 字节, 服务端密钥) 截断
/// ```
///
/// 字段全小端。`pageIndex` 不是类名本身 —— 32 字节装不下类名字符串，
/// 由接入端维护「索引 → 类名」注册表，解码端拿索引查表还原。
///
/// **密钥只在服务端持有**：服务端算好 mac 下发完整 16 字节，客户端只负责渲染；
/// 解码端拿 `--key` 校验。客户端自己算 mac 等于把密钥交出去，只防君子。
public struct WatermarkPayload: Equatable {
    public static let byteCount = 16
    public static let payloadBits = 128

    public var uid: UInt32
    public var timestamp: UInt32
    public var pageIndex: UInt16
    public var tag: UInt16
    public var mac: UInt32

    public init(uid: UInt32, timestamp: UInt32, pageIndex: UInt16, tag: UInt16, mac: UInt32) {
        self.uid = uid
        self.timestamp = timestamp
        self.pageIndex = pageIndex
        self.tag = tag
        self.mac = mac
    }

    /// 算好 mac 再构造。给服务端用；客户端别拿这个入口。
    public init(uid: UInt32, timestamp: UInt32, pageIndex: UInt16, tag: UInt16, key: SymmetricKey) {
        self.init(
            uid: uid,
            timestamp: timestamp,
            pageIndex: pageIndex,
            tag: tag,
            mac: WatermarkPayload.mac(uid: uid, timestamp: timestamp, pageIndex: pageIndex, tag: tag, key: key)
        )
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
