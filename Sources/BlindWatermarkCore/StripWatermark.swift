import Foundation

/// 顶部/底部 1pt 可见条码（「抗微信压缩」档）。
///
/// v6 色度盲水印在「缩放+强压缩」链路（实测 0.969 缩放 + q75、0.685 + q76）会丢失；
/// 条码用高对比亮度块，专补这条链路。代价：**顶部/底部被裁切即失效**，且肉眼可见。
/// 两层并存互补：条码抗压缩、v6 抗裁切。
///
/// 布局（76 bit，低位在后的位串按块展开）：
///   [0:4]   同步标记 1011
///   [4:36]  uid 32 bit（MSB first）
///   [36:60] 分钟偏移 24 bit（UTC 2026-01-01 起，与 v6 timestamp 同基准）
///   [60:76] CRC16-CCITT-FALSE（poly 0x1021, init 0xFFFF，对前 56 bit）
/// 块亮度：bit1 → 205，bit0 → 245（RGB 同值纯亮度条，Δ=40，4:2:0 只砍色度不砍亮度）。
/// 块宽以**像素**为单位编码（渲染端按屏幕 scale 换算），解码端亚像素扫描。
public enum StripWatermark {
    /// 同步标记，必须是条码前 4 块。
    public static let marker: [Bool] = [true, false, true, true]
    public static let payloadBits = 76
    /// 块亮度（8bit）。Δ40 实测经 q60/q76/0.969 缩放仍可判决（2026-09-29 企业微信真图）。
    public static let darkLevel: UInt8 = 205
    public static let lightLevel: UInt8 = 245
    /// 每条最少需要的块数（76 bit + 少量余量）。
    public static let minBlocks = 78

    public enum Edge: String { case top, bottom }

    public struct Decoded: Equatable {
        public let uid: UInt32
        /// 自 timestampEpoch 起的整分钟数。
        public let minuteOffset: UInt32
        /// 弱块纠错翻转的 bit 数（0 = 精确 CRC）。
        public let fixedBits: Int
        /// 命中的条位置（顶部/底部）。
        public let edge: Edge
        /// 复核误差：载荷映射回块亮度与实测的平均绝对差。
        public let verifyError: Double
    }

    // MARK: - 编码

    /// 从 v6 载荷提取条码字段：uid + 分钟粒度时间。buildTime/page/note 不进条码（容量不够）。
    public static func bits(uid: UInt32, minuteOffset: UInt32) -> [Bool] {
        var body: [Bool] = []
        for i in stride(from: 31, through: 0, by: -1) { body.append((uid >> i) & 1 == 1) }
        for i in stride(from: 23, through: 0, by: -1) { body.append((minuteOffset >> i) & 1 == 1) }
        return marker + body + crc16(body)
    }

    public static func bits(payload: WatermarkPayload) -> [Bool] {
        // 分钟向下取整，与解码端 time.gmtime 对齐；偏移复用 24 bit（约到 2070 年）。
        let mins = (payload.timestamp - WatermarkPayload.timestampEpoch) / 60
        return bits(uid: payload.uid, minuteOffset: UInt32(truncatingIfNeeded: mins))
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

    /// 把一条画进 RGBA 位图的顶部或底部行区间。bit 高度覆盖 `stripHeightPx` 行，同一图案逐行重复。
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
    static let blockScanStepPx = 0.02   // 0.969 缩放后块宽 15.58，粗步 0.02 实测可命中
    static let phases: [Double] = [0, 0.25, 0.5, 0.75]
    static let weakFixMaxFlips = 3      // 企业微信真图实测 3 bit（全在 CRC 段）
    /// 弱块纠错只翻 CRC 段（60..<76）：载荷区（uid/分钟）不参与翻转，
    /// 避免穷举出 CRC 有效但载荷错误的假阳性（实测真图上翻进分钟段会差出 20 分钟）。
    static let weakFixSegment = 60..<76
    static let weakFixPool = 12
    static let minContrast = 8.0
    /// 复核误差上限（块均值平均绝对差）。真值含噪声/缩放混合后实测 ≈8-10，
    /// 纠错凑 CRC 的假载荷实测 >15；取中间值。超标一律拒答，宁缺毋假。
    static let maxVerifyError = 13.0
    /// 单边（另一条缺失/被裁）采信门槛：只接受无纠错且复核误差 ≤ 此值的精确解。
    static let strictVerifyError = 4.0

    public static func decode(image: RGBAImage) -> Decoded? {
        let top = decodeEdge(image: image, edge: .top)
        let bottom = decodeEdge(image: image, edge: .bottom)
        // 双条一致才采信；单边只接受无纠错且复核误差小的精确解。
        // 溯源场景假 uid 不可接受：错位/部分遮挡可能形成 CRC 自洽的假载荷，
        // 单边纠错解不足以自证（实测错位样本能凑出稳定假值），一律拒答。
        switch (top, bottom) {
        case let (t?, b?):
            // 载荷一致即采信（fixedBits/verifyError 是逐边诊断，浮点不要求相等）
            return t.uid == b.uid && t.minuteOffset == b.minuteOffset ? t : nil
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
        // 亮度行向量（3 行平均）
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

        struct Cand { let bits: [Bool]; let conf: [Double]; let fixed: [Bool]; let flips: Int; let bw: Double; let ph: Double; let err: Double }

        var cands: [Cand] = []
        var bw = 6.0
        while bw <= 32.0 + 1e-9 {
            for ph in phases {
                let n = Int(Double(strip.count) / bw)
                guard n >= minBlocks else { continue }
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
                // lo/hi 只统计载荷 76 块：尾部的残块可能落在页面内容上，
                // 混入会拉偏阈值（实测缺陷样本：末块内容暗像素把 lo 拽到 0，全块判亮）
                let head = m.prefix(payloadBits)
                let lo = head.min() ?? 0, hi = head.max() ?? 0
                guard hi - lo >= minContrast else { continue }
                let th = (lo + hi) / 2
                var bits = [Bool]()
                bits.reserveCapacity(payloadBits)
                for b in 0..<payloadBits { bits.append(m[b] < th) }
                guard zip(bits.prefix(4), marker).allSatisfy(==) else { continue }
                var conf = [Double]()
                for b in 0..<payloadBits { conf.append(abs(m[b] - th)) }
                if let (fixed, flips) = weakFix(bits: bits, conf: conf) {
                    // 复核误差：候选载荷映射回块亮度后与实测块均值的平均偏差。
                    // 真值 ≈0（只差噪声）；纠错凑 CRC 的假载荷误差大，靠它一票否决。
                    var err = 0.0
                    for b in 0..<payloadBits {
                        let level = fixed[b] ? Double(darkLevel) : Double(lightLevel)
                        err += abs(level - m[b])
                    }
                    err /= Double(payloadBits)
                    cands.append(Cand(bits: bits, conf: conf, fixed: fixed, flips: flips, bw: bw, ph: ph, err: err))
                }
            }
            bw += blockScanStepPx
        }
        guard !cands.isEmpty else { return nil }
        guard let best = cands.min(by: { $0.err < $1.err }), best.err <= maxVerifyError else { return nil }
        return makeDecoded(bits: best.fixed, fixedBits: best.flips, err: best.err, edge: edge)
    }

    static func payloadKey(_ bits: [Bool]) -> String {
        bits.map { $0 ? "1" : "0" }.joined()
    }

    static func makeDecoded(bits: [Bool], fixedBits: Int, err: Double, edge: Edge) -> Decoded? {
        var uid: UInt32 = 0
        for i in 0..<32 where bits[4 + i] { uid |= 1 << UInt32(31 - i) }
        var mins: UInt32 = 0
        for i in 0..<24 where bits[36 + i] { mins |= 1 << UInt32(23 - i) }
        guard uid != 0, uid != .max else { return nil }
        return Decoded(uid: uid, minuteOffset: mins, fixedBits: fixedBits, edge: edge, verifyError: err)
    }

    /// 弱块纠错：只在 CRC 段内翻离阈值最近的 1…maxFlips 位，找 CRC 通过的最小翻转。
    /// 载荷区不参与，保证 uid/分钟不会被纠错改写。
    static func weakFix(bits: [Bool], conf: [Double]) -> ([Bool], Int)? {
        func crcOK(_ b: [Bool]) -> Bool { crc16(Array(b[4..<60])) == Array(b[60..<76]) }
        if crcOK(bits) { return (bits, 0) }
        let seg = Array(weakFixSegment)
        let order = seg.sorted { conf[$0] < conf[$1] }.prefix(weakFixPool)
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
