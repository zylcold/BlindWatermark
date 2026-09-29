import Foundation

/// 顶部/底部 1pt 可见条码（「抗微信压缩」档）。
///
/// v6 色度盲水印在「缩放+强压缩」链路（实测 0.969 缩放 + q75、0.685 + q76）会丢失；
/// 条码用高对比亮度块，专补这条链路。代价：**顶部/底部被裁切即失效**，且肉眼可见。
/// 两层并存互补：条码抗压缩、v6 抗裁切。顶底两条内容相同（保留双条仲裁与单边生存）。
///
/// 三档载荷，按屏幕可用块数自动选档（解码端用 CRC 试解区分，无需档位位）：
///
/// | 档 | bit | 字段 |
/// |---|---:|---|
/// | identity（tier0） | 76 | marker4 + uid32 + 分钟偏移24 + CRC16 |
/// | buildDay（tier1） | 91 | 同上 + buildDay15（2026-01-01 起的**天**） |
/// | full（tier2） | 123 | 同上 + page32（6 字符 base37，37^6 < 2^32） |
///
/// 档位不写进位流：三档 CRC 段位置不同，各自试解后要求唯一有效档位，
/// 多个档位同时通过则拒答。这样 tier0 与 3.1.0 的 76 bit 布局字节级兼容。
///
/// 块亮度：bit1 → 205，bit0 → 245（RGB 同值纯亮度条，Δ=40，4:2:0 只砍色度不砍亮度）。
/// 块宽以**像素**为单位编码（渲染端按屏幕 scale 换算），解码端亚像素扫描。
public enum StripWatermark {
    /// 同步标记，必须是条码前 4 块。
    public static let marker: [Bool] = [true, false, true, true]
    /// 块亮度（8bit）。Δ40 实测经 q60/q76/0.969/0.685 缩放仍可判决。
    public static let darkLevel: UInt8 = 205
    public static let lightLevel: UInt8 = 245
    /// 每条最少需要的块数（最小档 76 bit + 余量）。
    public static let minBlocks = 78
    /// 块宽下限（px）：实测 9px 在 q76/q60/0.969+q76/0.685+q60 全链路可解，8px 在 q60+0.685 失败。
    public static let minBlockPx = 9.0
    /// 块宽上限（px）：与解码扫描区间一致。
    public static let maxBlockPx = 32.0
    /// 自 UTC 2026-01-01 起的天数上限（15 bit ≈ 89 年）。
    public static let buildDayMax: UInt32 = (1 << 15) - 1
    /// tier2 的 page 短码长度（base37）。
    public static let pageLength = 6

    public enum Edge: String { case top, bottom }

    /// 载荷档位。`rawValue` 同时是 CRC 段的档位序号（0/1/2）。
    public enum Tier: Int, CaseIterable {
        case identity = 0
        case buildDay = 1
        case full = 2

        public var payloadBits: Int {
            switch self {
            case .identity: return 76
            case .buildDay: return 91
            case .full: return 123
            }
        }

        /// CRC16 所在的位区间（其后无字段）。
        var crcRange: Range<Int> { (payloadBits - 16)..<payloadBits }
        var bodyRange: Range<Int> { 4..<(payloadBits - 16) }

        /// 在给定像素宽下能用的最小块宽；不够则返回 nil。
        public func blockPx(forWidthPx widthPx: Int) -> Double? {
            guard widthPx >= payloadBits else { return nil }
            let px = Double(widthPx) / Double(payloadBits)
            guard px >= minBlockPx else { return nil }
            return min(maxBlockPx, (px * 100).rounded(.down) / 100)
        }

        /// 按屏宽选最高可用档。
        public static func best(forWidthPx widthPx: Int) -> (Tier, Double)? {
            for tier in Tier.allCases.reversed() {
                if let px = tier.blockPx(forWidthPx: widthPx) { return (tier, px) }
            }
            return nil
        }
    }

    public struct Decoded: Equatable {
        public let uid: UInt32
        /// 自 timestampEpoch 起的整分钟数。
        public let minuteOffset: UInt32
        /// tier1/tier2 才有：自 timestampEpoch 起的整**天**数。
        public let buildDay: UInt32?
        /// tier2 才有：6 字符 base37 页面短码。
        public let pageCode: String?
        /// 弱块纠错翻转的 bit 数（0 = 精确 CRC）。
        public let fixedBits: Int
        /// 命中的条位置（顶部/底部）。
        public let edge: Edge
        /// 命中的档位。
        public let tier: Tier
        /// 复核误差：载荷映射回块亮度与实测的平均绝对差。
        public let verifyError: Double
    }

    // MARK: - 编码

    /// 构造条码位流。缺省字段按档位要求补齐：tier0 忽略 buildDay/page，tier1 忽略 page。
    public static func bits(uid: UInt32, minuteOffset: UInt32, tier: Tier = .identity,
                            buildDay: UInt32 = 0, pageCode: String? = nil) -> [Bool] {
        var body: [Bool] = []
        for i in stride(from: 31, through: 0, by: -1) { body.append((uid >> i) & 1 == 1) }
        for i in stride(from: 23, through: 0, by: -1) { body.append((minuteOffset >> i) & 1 == 1) }
        if tier != .identity {
            let day = min(buildDay, buildDayMax)
            for i in stride(from: 14, through: 0, by: -1) { body.append((day >> i) & 1 == 1) }
        }
        if tier == .full {
            // pageCode 传入的可能是 8 字符类名短码，条码只存前 6 位（base37 上限 37^6 < 2^32）
            let trimmed = String((pageCode ?? "").prefix(pageLength))
            let code = WatermarkPayload.encodeBase37(trimmed, length: pageLength) ?? 0
            for i in stride(from: 31, through: 0, by: -1) { body.append((UInt32(truncatingIfNeeded: code) >> i) & 1 == 1) }
        }
        return marker + body + crc16(body)
    }

    /// 从 v6 载荷取条码字段：uid + 分钟 + build 天 + page 短码。
    public static func bits(payload: WatermarkPayload, tier: Tier = .identity) -> [Bool] {
        let mins = UInt32(truncatingIfNeeded: (payload.timestamp - WatermarkPayload.timestampEpoch) / 60)
        let day = UInt32(truncatingIfNeeded: (payload.buildTime - WatermarkPayload.timestampEpoch) / 86_400)
        let page = String(payload.pageNameCode.prefix(pageLength))
        return bits(uid: payload.uid, minuteOffset: mins, tier: tier, buildDay: day, pageCode: page)
    }

    public static func crc16(_ body: [Bool]) -> [Bool] {
        // CRC-16/CCITT-FALSE 逐位形式：输入 bit 不进寄存器，只与当前最高位异或决定是否回喷多项式。
        var reg: UInt16 = 0xFFFF
        for b in body {
            let msb = (reg >> 15) & 1
            reg <<= 1
            if msb ^ (b ? 1 : 0) == 1 { reg ^= 0x1021 }
        }
        return (0..<16).map { (reg >> UInt16(15 - $0)) & 1 == 1 }
    }

    /// 把一条画进 RGBA 位图的顶部或底部行区间。同一图案逐行重复（1pt 内多行）。
    public static func render(into image: inout RGBAImage, bits: [Bool], blockWidthPx: Double,
                              stripHeightPx: Int, edge: Edge) {
        guard stripHeightPx > 0, blockWidthPx >= 1 else { return }
        let blocks = min(bits.count, Int(Double(image.width) / blockWidthPx))
        let y0 = edge == .top ? 0 : max(0, image.height - stripHeightPx)
        for y in y0..<min(y0 + stripHeightPx, image.height) {
            var b = 0
            var x = 0
            while b < blocks {
                let level = bits[b] ? darkLevel : lightLevel
                let end = min(image.width, Int(Double(b + 1) * blockWidthPx))
                while x < end {
                    let o = (y * image.width + x) * 4
                    image.pixels[o] = level
                    image.pixels[o + 1] = level
                    image.pixels[o + 2] = level
                    image.pixels[o + 3] = 255
                    x += 1
                }
                b += 1
            }
            // 载荷块之后的剩余像素补亮：避免黑尾拉低 lo 破坏阈值（RGBAImage 初始全 0）
            while x < image.width {
                let o = (y * image.width + x) * 4
                image.pixels[o] = lightLevel
                image.pixels[o + 1] = lightLevel
                image.pixels[o + 2] = lightLevel
                image.pixels[o + 3] = 255
                x += 1
            }
        }
    }

    // MARK: - 解码

    /// 解码扫描参数；来源见各常量注释。
    static let blockScanStepPx = 0.02   // 0.969 缩放后块宽非整数，0.02 步长实测可命中
    static let phases: [Double] = [0, 0.25, 0.5, 0.75]
    static let weakFixMaxFlips = 3      // 企业微信真图实测 3 bit（全在 CRC 段）
    /// 弱块纠错只翻 CRC 段：载荷区（uid/时间/buildDay/page）不参与翻转，
    /// 避免穷举出 CRC 有效但载荷错误的假阳性。
    static let weakFixPool = 12
    static let minContrast = 8.0
    /// 复核误差上限（块均值平均绝对差）。真值含噪声/缩放混合后实测 ≈8-10，
    /// 纠错凑 CRC 的假载荷实测 >15；取中间值。超标一律拒答，宁缺毋假。
    static let maxVerifyError = 13.0
    /// 单边（另一条缺失/被裁）采信门槛：只接受无纠错且复核误差 ≤ 此值的精确解。
    static let strictVerifyError = 4.0
    /// 两个档位同时有效且复核误差差在此范围内时视为歧义，拒答。
    static let tierAmbiguityMargin = 2.0

    public static func decode(image: RGBAImage) -> Decoded? {
        let top = decodeEdge(image: image, edge: .top)
        let bottom = decodeEdge(image: image, edge: .bottom)
        // 双条一致才采信；单边只接受无纠错且复核误差小的精确解。
        // 溯源场景假 uid 不可接受：错位/部分遮挡可能形成 CRC 自洽的假载荷。
        switch (top, bottom) {
        case let (t?, b?):
            return (t.uid == b.uid && t.minuteOffset == b.minuteOffset) ? t : nil
        case let (t?, nil):
            return (t.fixedBits == 0 && t.verifyError <= strictVerifyError) ? t : nil
        case let (nil, b?):
            return (b.fixedBits == 0 && b.verifyError <= strictVerifyError) ? b : nil
        default:
            return nil
        }
    }

    static func decodeEdge(image: RGBAImage, edge: Edge) -> Decoded? {
        let y0 = edge == .top ? 0 : max(0, image.height - 3)
        guard image.width >= minBlocks, y0 < image.height else { return nil }
        var strip = [Double](repeating: 0, count: image.width)
        for y in y0..<min(y0 + 3, image.height) {
            for x in 0..<image.width {
                let o = (y * image.width + x) * 4
                strip[x] += 0.299 * Double(image.pixels[o]) + 0.587 * Double(image.pixels[o + 1])
                    + 0.114 * Double(image.pixels[o + 2])
            }
        }
        let rows = max(1, min(3, image.height - y0))
        for i in 0..<strip.count { strip[i] /= Double(rows) }

        struct Cand {
            let tier: Tier
            let fixed: [Bool]
            let flips: Int
            let err: Double
        }

        var cands: [Cand] = []
        var bw = 6.0
        while bw <= maxBlockPx + 1e-9 {
            for ph in phases {
                let n = Int(Double(strip.count) / bw)
                guard n >= Tier.identity.payloadBits else { continue }
                var edges = [Int]()
                edges.reserveCapacity(n + 1)
                for b in 0...n { edges.append(min(strip.count, Int(Double(b) * bw + ph))) }
                guard edges[n] <= strip.count, edges[0] < edges[n] else { continue }
                var m = [Double](repeating: 0, count: n)
                for b in 0..<n {
                    var s = 0.0
                    for x in edges[b]..<edges[b + 1] { s += strip[x] }
                    m[b] = s / Double(max(1, edges[b + 1] - edges[b]))
                }
                for tier in Tier.allCases {
                    let bits = tier.payloadBits
                    guard n >= bits else { continue }
                    // lo/hi 只统计载荷块：尾部的残块可能落在页面内容上，
                    // 混入会拉偏阈值（实测缺陷样本：末块内容暗像素把 lo 拽到 0，全块判亮）
                    let head = m.prefix(bits)
                    let lo = head.min() ?? 0, hi = head.max() ?? 0
                    guard hi - lo >= minContrast else { continue }
                    let th = clusterThreshold(head)
                    var raw = [Bool]()
                    raw.reserveCapacity(bits)
                    for b in 0..<bits { raw.append(m[b] < th) }
                    guard zip(raw.prefix(4), marker).allSatisfy(==) else { continue }
                    var conf = [Double]()
                    for b in 0..<bits { conf.append(abs(m[b] - th)) }
                    if let (fixed, flips) = weakFix(bits: raw, conf: conf, tier: tier) {
                        // 复核误差：候选载荷映射回块亮度后与实测块均值的平均偏差。
                        var err = 0.0
                        for b in 0..<bits {
                            let level = fixed[b] ? Double(darkLevel) : Double(lightLevel)
                            err += abs(level - m[b])
                        }
                        err /= Double(bits)
                        guard err <= maxVerifyError else { continue }
                        cands.append(Cand(tier: tier, fixed: fixed, flips: flips, err: err))
                    }
                }
            }
            bw += blockScanStepPx
        }
        guard let best = cands.min(by: { $0.err < $1.err }) else { return nil }
        // 档位歧义：另一个档位也有效且复核误差接近时拒答（不同档位解出的字段不同）
        for other in cands where other.tier != best.tier {
            if other.err <= best.err + tierAmbiguityMargin,
               payloadKey(other.fixed) != payloadKey(best.fixed) {
                return nil
            }
        }
        return makeDecoded(bits: best.fixed, tier: best.tier, fixedBits: best.flips,
                           err: best.err, edge: edge)
    }

    static func payloadKey(_ bits: [Bool]) -> String {
        bits.map { $0 ? "1" : "0" }.joined()
    }

    /// Otsu 阈值（最大化类间方差）。比 (min+max)/2 与 k-means 抗少量离群块：
    /// 实测顶部条码最前 4 像素被系统绘制内容盖住（0/154，块均值 ≈144），
    /// 与真实暗块（205）一起构成第三个簇；min/max 中点与 k-means 都会把阈值拉到 180 左右，
    /// 导致 205 的暗块被整批判亮。Otsu 在 {144}与 {205,245} 之间分割，不受影响。
    static func clusterThreshold(_ values: ArraySlice<Double>) -> Double {
        let v = values.sorted()
        guard v.count > 1 else { return v.first ?? 0 }
        let total = v.reduce(0, +)
        var sumLow = 0.0
        var best = (v.first! + v.last!) / 2
        var bestVar = -1.0
        for i in 1..<v.count {
            sumLow += v[i - 1]
            let wLow = Double(i) / Double(v.count)
            let wHigh = 1 - wLow
            let mLow = sumLow / Double(i)
            let mHigh = (total - sumLow) / Double(v.count - i)
            let between = wLow * wHigh * (mLow - mHigh) * (mLow - mHigh)
            if between > bestVar {
                bestVar = between
                best = (mLow + mHigh) / 2
            }
        }
        return best
    }

    static func makeDecoded(bits: [Bool], tier: Tier, fixedBits: Int, err: Double, edge: Edge) -> Decoded? {
        var uid: UInt32 = 0
        for i in 0..<32 where bits[4 + i] { uid |= 1 << UInt32(31 - i) }
        var mins: UInt32 = 0
        for i in 0..<24 where bits[36 + i] { mins |= 1 << UInt32(23 - i) }
        guard uid != 0, uid != .max else { return nil }
        var day: UInt32?
        if tier != .identity {
            var v: UInt32 = 0
            for i in 0..<15 where bits[60 + i] { v |= 1 << UInt32(14 - i) }
            day = v
        }
        var page: String?
        if tier == .full {
            var v: UInt32 = 0
            for i in 0..<32 where bits[75 + i] { v |= 1 << UInt32(31 - i) }
            page = WatermarkPayload.decodeBase37(UInt64(v), length: pageLength)
        }
        return Decoded(uid: uid, minuteOffset: mins, buildDay: day, pageCode: page,
                       fixedBits: fixedBits, edge: edge, tier: tier, verifyError: err)
    }

    /// 弱块纠错：只在该档的 CRC 段内翻离阈值最近的 1…maxFlips 位，找 CRC 通过的最小翻转。
    /// 载荷区不参与，保证 uid/时间/buildDay/page 不会被纠错改写。
    static func weakFix(bits: [Bool], conf: [Double], tier: Tier) -> ([Bool], Int)? {
        let crcRange = tier.crcRange
        func crcOK(_ b: [Bool]) -> Bool {
            crc16(Array(b[tier.bodyRange])) == Array(b[crcRange])
        }
        if crcOK(bits) { return (bits, 0) }
        let order = crcRange.sorted { conf[$0] < conf[$1] }.prefix(weakFixPool)
        func walk(_ start: Int, _ chosen: [Int], _ r: Int, _ hit: inout ([Bool], Int)?) {
            if hit != nil { return }
            if chosen.count == r {
                var b = bits
                for i in chosen { b[i].toggle() }
                if crcOK(b) { hit = (b, r) }
                return
            }
            for i in start..<order.count where hit == nil {
                walk(i + 1, chosen + [order[i]], r, &hit)
            }
        }
        for r in 1...weakFixMaxFlips {
            var hit: ([Bool], Int)?
            walk(0, [], r, &hit)
            if let h = hit { return h }
        }
        return nil
    }
}
