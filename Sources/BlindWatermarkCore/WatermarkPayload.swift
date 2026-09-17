import CryptoKit
import Foundation

/// 载荷布局 v4：512 bit / 64 字节，字段全小端。
///
/// ```
/// [511:480] uid        32   UInt32   用户 ID，原样放
/// [479:448] timestamp  32   UInt32   Unix 秒（截图时间）
/// [447:384] build      64   UInt64   构建号，12 位十进制（YYYYMMDDHHMM，如 202609161722）；0 = 未填
/// [383:288] pageCode   96           页面类名短码，15 个 6-bit 字符 = 90 bit（低 6 位必须为 0）
/// [287:272] tag        16   UInt16   App(8) + 环境(8)
/// [271: 96] note      176           自定义 note，22 字节 UTF-8，尾部 0 填充
/// [ 95:  0] 校验值     96           HMAC-SHA256(前 52 字节, 服务端密钥) 截断，或 SHA-256 截断（自检值）
/// ```
///
/// 没有版本位：布局就是这一个，字段边界变了就等于换协议。**v3（256 bit）已废弃，
/// 历史 v3 截图用本版本解不出来** —— 这是显式的破坏性变更，见 README「已知边界」。
///
/// ## 为什么 512 bit，以及它的代价
///
/// 每 bit 的观测次数 = 图像面积 / pair 面积 / payloadBits，**载荷翻倍就是余量减半**。
/// iPhone 16 截图（1179×2556）共 23287 个 pair：512 bit → 每 bit 约 45 次观测（256 bit 时 91 次）。
/// 实测（springboard 壁纸 + 图标，最苛刻的真实内容，chroma，delta 8）：
/// `|z|` 中位 9.4、弱 bit 32/512（判定阈值 64，属 WEAK 边缘）。
/// 想补余量就调 `delta`：8 → 弱 bit 40/512，10 → 22，12 → 9，代价是色度网格更明显。
/// 把块缩到 4px 也能把每 bit 观测拉回 183 次，但实测过不了 JPEG q80 —— 块只能是 8px。
///
/// 512 bit 时每 tile（512 个 pair）只重复 1 份，"隔一份翻转极性抵消内容梯度"的机制关闭；
/// 实测强色度渐变内容上没退化（弱 bit 0/512），把 tile 放大到 512 换回翻转机制收益也很小（40→32），
/// 所以保持 tile 256、不放大几何。
///
/// ## 页面为什么存短码而不是索引
///
/// 索引必须配一张同版本的注册表，表一换历史截图就废；短码是从类名推出来的，
/// 拿着 `chatlist` 直接 `grep -rin "class.*chatlist"` 就能定位。
/// v4 的短码长 15 字符：大多数类名剥完冗余词缀后 ≤ 15 字符，够用；
/// 不够时解码端拿短码 `grep` 类名即可。
///
/// ## 密钥只在服务端持有
///
/// 服务端算好校验值下发完整 64 字节，客户端只负责渲染；解码端拿 `--key` 验签。
/// 无密钥部署用公开自检值（`selfChecked` / `key: nil`）：能证明"解对了"，但拦不住伪造。
public struct WatermarkPayload: Equatable {
    public static let byteCount = 64
    public static let payloadBits = 512
    /// 当前布局版本号，仅用于输出与文档；v4 不在载荷里存版本位
    public static let layoutVersion: UInt32 = 4
    /// 校验值长度
    public static let macByteCount = 12
    /// 校验值覆盖的字节数（uid + timestamp + build + pageCode + tag + note）
    static let signedByteCount = 52
    /// note 字节数
    public static let noteByteCount = 22
    /// 页面短码字符数
    public static let codeLength = PageNameCodec.codeLength
    /// 结构自检认定的合理时间戳区间：2015-01-01 ... 2100-01-01
    static let plausibleTimestampRange: ClosedRange<UInt32> = 1_420_070_400...4_102_444_800

    public var uid: UInt32
    public var timestamp: UInt32
    /// 构建号：12 位十进制（YYYYMMDDHHMM，如 202609161722）原样存整数，0 = 未填
    public var build: UInt64
    /// 页面短码（12 字节小端，每字符 6 bit，低位在前；15 字符用 90 bit，低 6 位留 0）
    public var pageCodeBytes: [UInt8]
    /// App(8) + 环境(8)
    public var tag: UInt32
    /// 22 字节 UTF-8，尾部 0 填充
    public var noteBytes: [UInt8]
    /// 96 bit 校验值：HMAC 截断 / 公开自检值截断 / 全 0
    public var mac: [UInt8]

    /// 主体构造。`key` 为 nil 时校验值填公开自检值（无密钥部署）。
    public init(
        uid: UInt32,
        timestamp: UInt32,
        build: UInt64,
        pageClassName: String,
        note: String = "",
        app: UInt32 = 0,
        environment: UInt32 = 0,
        key: SymmetricKey? = nil
    ) {
        self.init(
            uid: uid,
            timestamp: timestamp,
            build: build,
            pageCodeBytes: PageNameCodec.encodeBytes(PageNameCodec.code(for: pageClassName)),
            app: app,
            environment: environment,
            noteBytes: Array(note.utf8),
            mac: []
        )
        let body = WatermarkPayload.signedBody(
            uid: uid,
            timestamp: timestamp,
            build: build,
            pageCodeBytes: pageCodeBytes,
            tag: tag,
            noteBytes: noteBytes
        )
        if let key {
            mac = Array(HMAC<SHA256>.authenticationCode(for: Data(body), using: key).prefix(WatermarkPayload.macByteCount))
        } else {
            mac = Array(SHA256.hash(data: Data(body)).prefix(WatermarkPayload.macByteCount))
        }
    }

    /// 底层构造：字段原样接收，不重算校验值（解码路径与测试用）。
    public init(
        uid: UInt32,
        timestamp: UInt32,
        build: UInt64,
        pageCodeBytes: [UInt8],
        app: UInt32,
        environment: UInt32,
        noteBytes: [UInt8],
        mac: [UInt8]
    ) {
        self.uid = uid
        self.timestamp = timestamp
        self.build = build
        self.pageCodeBytes = WatermarkPayload.pad(pageCodeBytes, to: PageNameCodec.codeByteCount)
        self.tag = ((app & 0xFF) << 8) | (environment & 0xFF)
        self.noteBytes = WatermarkPayload.pad(noteBytes, to: WatermarkPayload.noteByteCount)
        self.mac = mac
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count == WatermarkPayload.byteCount else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        func u64(_ o: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(bytes[o + i]) << (8 * UInt64(i)) }
            return value
        }
        self.init(
            uid: u32(0),
            timestamp: u32(4),
            build: u64(8),
            pageCodeBytes: Array(bytes[16..<28]),
            app: UInt32(bytes[28]),
            environment: UInt32(bytes[29]),
            noteBytes: Array(bytes[30..<52]),
            mac: Array(bytes[52..<64])
        )
    }

    /// 带公开自检值的载荷（无密钥部署）
    public static func selfChecked(
        uid: UInt32,
        timestamp: UInt32,
        build: UInt64,
        pageClassName: String,
        note: String = "",
        app: UInt32 = 0,
        environment: UInt32 = 0
    ) -> WatermarkPayload {
        WatermarkPayload(
            uid: uid,
            timestamp: timestamp,
            build: build,
            pageClassName: pageClassName,
            note: note,
            app: app,
            environment: environment,
            key: nil
        )
    }

    public var bytes: [UInt8] {
        var out = WatermarkPayload.signedBody(
            uid: uid,
            timestamp: timestamp,
            build: build,
            pageCodeBytes: pageCodeBytes,
            tag: tag,
            noteBytes: noteBytes
        )
        out.append(contentsOf: WatermarkPayload.pad(mac, to: WatermarkPayload.macByteCount))
        return out
    }

    // MARK: - 字段视图

    /// 15 字符页面短码，拿去 grep 类名
    public var pageNameCode: String {
        PageNameCodec.decodeBytes(pageCodeBytes, length: WatermarkPayload.codeLength)
    }

    /// note 字符串（非法 UTF-8 时返回 nil），尾部 0 已去掉
    public var note: String? {
        var trimmed = noteBytes
        while trimmed.last == 0 { trimmed.removeLast() }
        return String(bytes: trimmed, encoding: .utf8)
    }

    /// build 的 12 位十进制形式（0 表示未填）
    public var buildNumber: String {
        build == 0 ? "" : String(format: "%012llu", build)
    }

    public var app: UInt32 { (tag >> 8) & 0xFF }
    public var environment: UInt32 { tag & 0xFF }

    // MARK: - 校验值

    /// 校验值字段里装的是哪种校验值。
    public enum Verification: Equatable {
        /// HMAC 验签通过（需要密钥）
        case signed
        /// 公开自检值通过：能证明"解对了"，**不能**证明"没被伪造"
        case selfChecked
        /// 校验值全 0：载荷没带任何校验值
        case unsigned
        /// 带了校验值但两种都对不上
        case failed
    }

    public var isUnsigned: Bool { mac.allSatisfy { $0 == 0 } }

    /// 判定载荷带的是哪种校验值。没给密钥时签名载荷落在 `.failed`，
    /// 调用方应报"未校验(需要 --key)"而不是"被篡改"。
    public func verification(key: SymmetricKey?) -> Verification {
        guard !isUnsigned else { return .unsigned }
        if let key, isValid(key: key) { return .signed }
        if mac.count == WatermarkPayload.macByteCount,
           Array(mac.prefix(WatermarkPayload.macByteCount)) == WatermarkPayload.selfCheck(for: self) {
            return .selfChecked
        }
        return .failed
    }

    public func isValid(key: SymmetricKey) -> Bool {
        let body = WatermarkPayload.signedBody(
            uid: uid,
            timestamp: timestamp,
            build: build,
            pageCodeBytes: pageCodeBytes,
            tag: tag,
            noteBytes: noteBytes
        )
        let expected = Array(
            HMAC<SHA256>.authenticationCode(for: Data(body), using: key).prefix(WatermarkPayload.macByteCount)
        )
        guard mac.count == expected.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<expected.count { diff |= mac[i] ^ expected[i] }
        return diff == 0
    }

    /// 公开自检值：`SHA-256(覆盖部分)` 截断到 96 bit，与校验值字段同位。
    ///
    /// 无密钥部署用它代替 HMAC：任何一位不同都过不了，所以能拦住"对齐错了几个 bit"的近似解。
    /// 拦不住伪造 —— 谁都能算。
    public static func selfCheck(for payload: WatermarkPayload) -> [UInt8] {
        let body = WatermarkPayload.signedBody(
            uid: payload.uid,
            timestamp: payload.timestamp,
            build: payload.build,
            pageCodeBytes: payload.pageCodeBytes,
            tag: payload.tag,
            noteBytes: payload.noteBytes
        )
        return Array(SHA256.hash(data: Data(body)).prefix(macByteCount))
    }

    /// 结构自检：只用布局本身的结构约束，不需要密钥，也不依赖任何额外字段。
    ///
    /// 判别力来自：时间戳落在 2015~2100、build 要么为 0 要么是日历上合法的
    /// 12 位 YYYYMMDDHHMM、note 必须是合法 UTF-8、20 个 6-bit 字符都落在 37 符号表内。
    /// 但**实测仍会放过近似解**（半块相位错位解出的是真载荷改几个 bit 的拷贝，结构字段根本没动）——
    /// 所以它只是"没有任何校验值时的兵底"，不能替代校验值，调用方必须如实报未校验。
    public var isPlausible: Bool {
        guard WatermarkPayload.plausibleTimestampRange.contains(timestamp) else { return false }
        var trimmed = noteBytes
        while trimmed.last == 0 { trimmed.removeLast() }
        guard String(bytes: trimmed, encoding: .utf8) != nil else { return false }
        guard WatermarkPayload.isPlausibleBuild(build) else { return false }
        return PageNameCodec.validateBytes(pageCodeBytes, length: WatermarkPayload.codeLength)
    }

    /// build = 0（未填）或一个日历上合法的 12 位 YYYYMMDDHHMM。
    /// 12 位十进制最大 999999999999 < 2^40，但字段留了 64 bit：够用且不用做位压缩。
    static func isPlausibleBuild(_ build: UInt64) -> Bool {
        guard build != 0 else { return true }
        let digits = String(build)
        guard digits.count == 12, digits.allSatisfy(\.isNumber) else { return false }
        func number(_ offset: Int, _ length: Int) -> Int {
            Int(digits.dropFirst(offset).prefix(length)) ?? 0
        }
        return (2000...2099).contains(number(0, 4))
            && (1...12).contains(number(4, 2))
            && (1...31).contains(number(6, 2))
            && (0...23).contains(number(8, 2))
            && (0...59).contains(number(10, 2))
    }

    // MARK: - 序列化细节

    /// 校验值覆盖的字节（前 52 字节）
    static func signedBody(
        uid: UInt32,
        timestamp: UInt32,
        build: UInt64,
        pageCodeBytes: [UInt8],
        tag: UInt32,
        noteBytes: [UInt8]
    ) -> [UInt8] {
        var body = [UInt8]()
        body.reserveCapacity(signedByteCount)
        body.append(contentsOf: littleEndianBytes(UInt64(uid), count: 4))
        body.append(contentsOf: littleEndianBytes(UInt64(timestamp), count: 4))
        body.append(contentsOf: littleEndianBytes(build, count: 8))
        body.append(contentsOf: pad(pageCodeBytes, to: PageNameCodec.codeByteCount))
        body.append(UInt8((tag >> 8) & 0xFF))
        body.append(UInt8(tag & 0xFF))
        body.append(contentsOf: pad(noteBytes, to: noteByteCount))
        return body
    }

    static func littleEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
    }

    /// 补足 / 截断到指定字节数
    static func pad(_ bytes: [UInt8], to count: Int) -> [UInt8] {
        var out = Array(bytes.prefix(count))
        if out.count < count {
            out.append(contentsOf: [UInt8](repeating: 0, count: count - out.count))
        }
        return out
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
