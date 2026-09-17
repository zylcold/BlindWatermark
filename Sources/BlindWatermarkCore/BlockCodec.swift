import CoreGraphics
import Foundation

/// 水印压在哪个平面上。
public enum WatermarkPlane: String, CaseIterable {
    /// 亮度平面：全通道等量加亮/压暗。解码信噪比最好，但会在平坦区域留下可见的棋盘网格。
    case luma
    /// 蓝-黄对色平面：一对块**等亮度**、只差色度。
    ///
    /// 混色是 RGB 上的线性运算，两个等亮度的叠加色混出来的结果也等亮度，
    /// 所以亮度平面**一个像素都没动** —— 没有亮度网格可看。
    /// 人眼对高频色度的分辨力只有亮度的大约四分之一，且灰阶内容在色度通道上恒为 0，
    /// 内容噪声几乎消失。代价是彩色内容（照片）会引入色度噪声。
    case chroma
}

/// 屏上盲水印编解码。
///
/// ## 编码
/// 覆盖全屏的是 8×8 **像素块**平铺图案，不是单像素噪点 —— 块内平坦，过 JPEG 不会被抹掉。
/// 每两个相邻块 (A,B) 编码 1 bit：`1` → A 特征值低、B 高；`0` → 反过来。
///
/// ## 为什么是差分
/// 解码取 `d = mean(A) - mean(B)`。亮度模式下压暗减益是 `−base·α`、提亮增益是 `(255−base)·α`，
/// 相加后 `base` 项抵消：`d ≈ ∓alpha`，**与底色无关**。
///
/// ## 为什么翻转极性
/// 相邻块差值里混着**内容本身的梯度**（渐变、照片），大时能压过 delta。
/// 同一个 bit 的重复观测里隔一份把极性反过来（解码端同步翻符号）：水印同向累加，梯度成对相消。
///
/// ## 为什么软累加而不是符号投票
/// 内容差异经常远大于 delta，只取符号等于把水印丢掉。按带符号差值累加再除以标准误得到 z 值：
/// 水印随观测次数线性累加，内容噪声按 `1/√n` 衰减。
///
/// ## 观测按 tile 本地 pair 索引累积，再按 payloadBits 折叠
/// 累加阶段不区分 bit，先按 512 个 tile 本地 pair 存和、平方和、计数；
/// 折叠阶段才做 `% payloadBits` 分组与极性翻转（翻转只是符号，平方和不变）。
/// 于是**一次累加可以廉价地换任意 payloadBits 重读** —— 这是自动探测位数的基础。
///
/// ## 相位与参数的自动探测
/// `decodeBest` 穷举相位 / 双平面 / 多种位数，用 `validate`（通常是 MAC 校验）裁决，
/// 没有校验器时退回 `medianAbsZ`。裸穷举不可信：错位相位在低变化画面上也能自洽。
///
/// ## 限制
/// 截图必须是**原始设备像素**分辨率。缩放会改变块边长与平铺周期，解码失效。
public enum BlockCodec {
    /// 块边长（设备像素）。8：模拟器实测 16 块在真实 UI 上 |z| 中位只有 1.9，
    /// 块减半让观测数 x4 且相邻块内容更相关，z 提升约 3 倍。
    public static let blockSize = 8
    /// 平铺周期（设备像素）
    public static let tileSize = 256
    /// tile 内每行的 pair 数
    static let pairsPerRow = tileSize / blockSize / 2
    /// tile 内的块行数
    static let blockRowsPerTile = tileSize / blockSize
    /// 每个 tile 的 pair 总数
    public static let pairsPerTile = pairsPerRow * blockRowsPerTile
    /// 载荷上限（bit）。再大每 tile 重复次数会低于 2，翻转极性就没戏了
    public static let maxPayloadBits = 256
    /// 第二阶段会对入围相位继续做 tile 旋转穷举；保留 16 组足够覆盖常见退化相位，
    /// 同时把 64×512×位数 的最坏开销压在可接受范围内。
    static let maxPhaseFinalists = 16

    public struct Decoded: Equatable {
        /// 解出的载荷，小端按 bit 打包，长度 = ceil(payloadBits / 8)
        public let payloadBytes: [UInt8]
        public let payloadBits: Int
        public let plane: WatermarkPlane
        /// 块网格相位，0..<blockSize
        public let offsetX: Int
        public let offsetY: Int
        /// 平均 |d|，理想值 ≈ alpha。被内容噪声主导，只作诊断用
        public let signal: Double
        /// 各 bit |z| 的**最小值**，最弱那个 bit 的显著度
        public let confidence: Double
        /// |z| < 3 的 bit 数。真实界面上用来判断这次读码能不能信
        public let weakBits: Int
        /// 各 bit |z| 的中位数
        public let medianAbsZ: Double

        /// 低 32 bit 视图。payloadBits ≤ 32 时就是完整值；更长时只取前 4 字节，别拿来当完整载荷用
        public var payload: UInt32 {
            var value: UInt32 = 0
            for (i, byte) in payloadBytes.prefix(4).enumerated() {
                value |= UInt32(byte) << (8 * UInt32(i))
            }
            return value
        }
    }

    // MARK: - 编码

    /// 生成平铺用的水印 tile。未着色像素完全透明，不产生任何扰动。
    /// - Parameters:
    ///   - payload: 待嵌入的字节，bit 0 在 payload[0] 的最低位
    ///   - payloadBits: 有效位数，默认取 `payload.count * 8`。同一 payload 在 tile 内重复
    ///     `pairsPerTile / payloadBits` 份
    ///   - alpha: 扰动幅度。解码端看到的 |d|：luma 模式下 ≈ alpha，chroma 模式下 ≈ 1.13×alpha。
    ///     **下限 2**，更低会被色域转换与量化吃掉。
    public static func makeTile(
        payload: [UInt8],
        payloadBits: Int? = nil,
        alpha: UInt8 = 8,
        plane: WatermarkPlane = .chroma
    ) -> RGBAImage {
        let bits = payloadBits ?? payload.count * 8
        precondition(!payload.isEmpty, "payload 不能为空")
        precondition((1...maxPayloadBits).contains(bits), "payloadBits 必须在 1...\(maxPayloadBits)")
        precondition(bits <= payload.count * 8, "payloadBits 超过了 payload 自带的位数")

        var tile = RGBAImage(width: tileSize, height: tileSize)
        for p in 0..<pairsPerTile {
            let row = p / pairsPerRow
            let col = p % pairsPerRow
            let index = p % bits
            let bit = Int((payload[index >> 3] >> UInt8(index & 7)) & 1)
            var leftDark = (bit == 1)
            if isFlipped(p, payloadBits: bits) { leftDark.toggle() }
            let x = col * 2 * blockSize
            let y = row * blockSize
            paint(&tile, x: x, y: y, dark: leftDark, alpha: alpha, plane: plane)
            paint(&tile, x: x + blockSize, y: y, dark: !leftDark, alpha: alpha, plane: plane)
        }
        return tile
    }

    /// 32 bit 便捷入口。等价于把 UInt32 小端展开后走字节版。
    public static func makeTile(
        payload: UInt32,
        payloadBits: Int = 32,
        alpha: UInt8 = 8,
        plane: WatermarkPlane = .chroma
    ) -> RGBAImage {
        var bytes = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { bytes[i] = UInt8((payload >> (8 * UInt32(i))) & 0xFF) }
        return makeTile(payload: bytes, payloadBits: payloadBits, alpha: alpha, plane: plane)
    }

    /// 同一个 bit 的重复观测隔一份翻转极性，让梯度偏置成对相消。
    /// 重复份数为奇数时不翻，宁可不抵消也不能翻错。
    static func isFlipped(_ localPairIndex: Int, payloadBits: Int) -> Bool {
        let repetitions = pairsPerTile / payloadBits
        guard repetitions >= 2, repetitions % 2 == 0 else { return false }
        return (localPairIndex / payloadBits) % 2 == 1
    }

    /// 陪色分量。`p = round(0.114 * a / 0.886)`，至少 1 且不超过 a。
    /// 下限 1 是为了不让 a 小时的取整把陪色打成纯黑（那就退化成亮度模式了）。
    static func chromaCompanion(_ alpha: UInt8) -> UInt8 {
        let ideal = (0.114 * Double(alpha) / 0.886).rounded()
        return UInt8(max(1, min(Double(alpha), ideal)))
    }

    private static func paint(
        _ image: inout RGBAImage,
        x: Int,
        y: Int,
        dark: Bool,
        alpha: UInt8,
        plane: WatermarkPlane
    ) {
        switch plane {
        case .luma:
            // 预乘 alpha：纯黑 (0,0,0,a)，纯白 (a,a,a,a)
            let v = dark ? UInt8(0) : alpha
            image.fillRect(x: x, y: y, width: blockSize, height: blockSize, rgba: (v, v, v, alpha))
        case .chroma:
            // 两个叠加色必须**等亮度**，否则亮度平面会被动到，网格就看得见了。
            // 亮度零方向是 (0.128, 0.128, -1)，取 (0,0,a) 与 (p,p,0)，令 0.114a = 0.886p。
            // 混色是预乘 alpha 的线性运算，合成分的亮度差等于叠加色在预乘空间的亮度差，
            // 不随 alpha 衰减 —— 所以 p 必须精确到这个关系，否则亮度网格立刻显形。
            let p = chromaCompanion(alpha)
            // 极性：特征 B - (R+G)/2 在 (0,0,a) 上是 +a、在 (p,p,0) 上是 -p。
            // 「dark」= 特征值更低，所以暗块配陪色，亮块配蓝。配反了 bit 全翻。
            if dark {
                image.fillRect(x: x, y: y, width: blockSize, height: blockSize, rgba: (p, p, 0, alpha))
            } else {
                image.fillRect(x: x, y: y, width: blockSize, height: blockSize, rgba: (0, 0, alpha, alpha))
            }
        }
    }

    // MARK: - 解码

    /// 只搜索块网格相位（`0..<blockSize`）。
    ///
    /// 给只知道截图被裁过、但其余参数（平面 / 位数）已经确定的调用方用。
    /// 特征图与积分图只算一次；64 个候选相位只重复廉价的累加与折叠。
    /// 注意它只修块对齐，**修不了**裁剪造成的 tile 平移（那要 `fold` 的 rotation，见 `decodeBest`）。
    ///
    /// 裁决规则：
    /// - 给了 `validate`（通常是 MAC 校验）：在**通过校验**的候选里取 `medianAbsZ` 最高的那一组。
    /// - 一个都没通过校验，或没给 `validate`：退回 `medianAbsZ` 最高的那一组 ——
    ///   这个返回值只代表「块对齐得最好」，**不保证解出正确载荷**：错位相位在低变化画面上
    ///   同样能给出高 `|z|` 的自洽结果（见 `BlockCodec` 类型文档）。调用方必须自己 MAC 验证，
    ///   或至少按 `weakBits` 如实报 WEAK / NO。
    public static func findBestOffset(
        in image: RGBAImage,
        payloadBits: Int = WatermarkPayload.payloadBits,
        plane: WatermarkPlane = .chroma,
        validate: ((Decoded) -> Bool)? = nil
    ) -> (offsetX: Int, offsetY: Int) {
        precondition((1...maxPayloadBits).contains(payloadBits), "payloadBits 必须在 1...\(maxPayloadBits)")
        guard let feature = featureAndIntegral(image, plane) else { return (0, 0) }

        var bestOffset = (offsetX: 0, offsetY: 0)
        var bestScore = -Double.infinity
        var validated: (offset: (offsetX: Int, offsetY: Int), score: Double)?

        for oy in 0..<blockSize {
            for ox in 0..<blockSize {
                let stats = accumulate(feature, image, ox: ox, oy: oy)
                let folded = fold(stats, payloadBits: payloadBits)
                if folded.medianAbsZ > bestScore {
                    bestScore = folded.medianAbsZ
                    bestOffset = (ox, oy)
                }
                guard let validate else { continue }
                let candidate = makeDecoded(
                    folded,
                    payloadBits: payloadBits,
                    plane: plane,
                    ox: ox,
                    oy: oy
                )
                guard validate(candidate) else { continue }
                if validated == nil || folded.medianAbsZ > validated!.score {
                    validated = ((ox, oy), folded.medianAbsZ)
                }
            }
        }
        // 相位按 oy 外层、ox 内层顺序遍历，`>` 而非 `>=`，所以同分时取先遇到的，结果可复现
        return validated?.offset ?? bestOffset
    }

    /// 从整屏截图解码，参数全部显式给定。
    ///
    /// 相位默认 (0, 0)：水印层铺在窗口原点，整屏截图的图案原点就是图片原点。
    /// **payloadBits / plane 必须与编码端一致**，给错会得到一份自洽但错误的载荷。
    /// 参数没把握时用 `decodeBest`，让 MAC 或 `medianAbsZ` 替你裁决。
    public static func decode(
        _ image: RGBAImage,
        payloadBits: Int = WatermarkPayload.payloadBits,
        offsetX: Int = 0,
        offsetY: Int = 0,
        plane: WatermarkPlane = .chroma
    ) -> Decoded? {
        precondition((1...maxPayloadBits).contains(payloadBits), "payloadBits 必须在 1...\(maxPayloadBits)")
        guard let feature = featureAndIntegral(image, plane) else { return nil }
        let pairs = accumulate(feature, image, ox: offsetX, oy: offsetY)
        let folded = fold(pairs, payloadBits: payloadBits)
        return makeDecoded(folded, payloadBits: payloadBits, plane: plane, ox: offsetX, oy: offsetY)
    }

    /// 自动探测解码：穷举相位 / 双平面 / 多种位数，选一个最可信的结果。
    ///
    /// 裁剪过的截图（相位未知）、不确定编码端用的平面或位数时用这个。
    ///
    /// 裁决规则：**先看 `validate`**（通常是 `WatermarkPayload.isValid(key:)` 的 MAC 校验），
    /// 通过校验的候选里取 `medianAbsZ` 最高的；一个都没有才退回未通过校验里 `medianAbsZ` 最高的。
    /// 裸穷举不可信 —— 错位相位在低变化画面上也能让所有 bit 自洽，必须靠 MAC 兜底。
    ///
    /// 开销：特征图与积分图每平面只算一次（这是大头），相位穷举只重复廉价的累加，
    /// 位数换读复用同一份按 pair 累积的统计，实测 64 相位 × 2 平面 × 2 位数在 1 秒以内。
    public static func decodeBest(
        _ image: RGBAImage,
        payloadBitsCandidates: [Int] = [WatermarkPayload.payloadBits, 32],
        planes: [WatermarkPlane] = [.chroma, .luma],
        searchPhase: Bool = true,
        searchTile: Bool = true,
        validate: ((Decoded) -> Bool)? = nil
    ) -> Decoded? {
        let bitsList = payloadBitsCandidates.filter { (1...maxPayloadBits).contains($0) }
        guard !bitsList.isEmpty else { return nil }

        // 阶段一：全平面全相位累加一次，排出「块对齐 + 图案自洽」最好的几组。
        //
        // 排序不能用 `signal`（平均 |d|）：那个量被内容本身撑大，没水印的 luma 平面能拿到 19，
        // 带水印的 chroma 平面才 9，纯按它排会挑错平面。
        // 用 z 值：对齐的相位 → 每个 bit 的观测同向 → |z| 高；没水印 → 符号随机 → |z| 塌。
        // 与位数无关这点靠对每个候选位数取最大值解决（tile 平移不影响 z，留给阶段二的旋转穷举）。
        struct Context {
            let plane: WatermarkPlane
            let ox: Int
            let oy: Int
            let stats: PairStats
        }
        var scored: [(context: Context, score: Double)] = []
        for plane in planes {
            guard let feature = featureAndIntegral(image, plane) else { continue }
            let phases: [(Int, Int)] = searchPhase
                ? (0..<(blockSize * blockSize)).map { ($0 % blockSize, $0 / blockSize) }
                : [(0, 0)]
            for (ox, oy) in phases {
                let stats = accumulate(feature, image, ox: ox, oy: oy)
                let score = bitsList
                    .map { fold(stats, payloadBits: $0).medianAbsZ }
                    .max() ?? 0
                scored.append((Context(plane: plane, ox: ox, oy: oy, stats: stats), score))
            }
        }
        guard !scored.isEmpty else { return nil }
        scored.sort { $0.score > $1.score }
        let finalists = scored.prefix(min(scored.count, maxPhaseFinalists)).map(\.context)

        let rotations = searchTile ? Array(0..<pairsPerTile) : [0]

        func decode(_ context: Context, bits: Int, rotation: Int) -> Decoded {
            let folded = fold(context.stats, payloadBits: bits, rotation: rotation)
            return makeDecoded(
                folded,
                payloadBits: bits,
                plane: context.plane,
                ox: context.ox,
                oy: context.oy
            )
        }

        guard let validate else {
            // 没有校验器就不敢乱猜相位 —— 只信块对齐最好那一组的原始相位、原始旋转。
            let context = finalists[0]
            return decode(context, bits: bitsList[0], rotation: 0)
        }

        // 阶段二：在入围相位上穷举 tile 旋转（补偿裁剪）。错误旋转同样能给出很干净的自洽载荷，
        // 唯一可靠的裁决是 MAC —— 所以校验器通过即返回，不按分数排序。
        for context in finalists {
            for bits in bitsList {
                for rotation in rotations {
                    let candidate = decode(context, bits: bits, rotation: rotation)
                    if validate(candidate) {
                        return candidate
                    }
                }
            }
        }
        // 一个都没过校验：退回块对齐最好那一组的原始解，让调用方从 weakBits 和校验结果自行判断
        let context = finalists[0]
        return decode(context, bits: bitsList[0], rotation: 0)
    }

    // MARK: - 特征图与积分图

    private struct FeatureContext {
        let integral: [Double]
        let stride: Int
    }

    private static func featureAndIntegral(_ image: RGBAImage, _ plane: WatermarkPlane) -> FeatureContext? {
        guard image.width >= blockSize * 2, image.height >= blockSize else { return nil }
        let feature = image.featureBuffer(plane)
        let stride = image.width + 1
        return FeatureContext(integral: integralImage(feature, width: image.width, height: image.height), stride: stride)
    }

    // MARK: - 按 tile 本地 pair 累积

    /// 低于此方差的观测按此方差计算，避免纯色画面上 z 值除以 0 而爆掉
    static let minVariance = 0.25

    /// 观测幅度下限。低于此值的 pair 一律**弃权**，不参与累加。
    /// 否则纯色背景上 `d == 0` 会被当成一个方向的观测，让无水印画面凭空拿到高置信度。
    static let minMagnitude = 0.5

    /// 按 tile 本地 pair 索引（0..<pairsPerTile）累积的统计。
    /// 不做 `% payloadBits` 分组、不翻极性 —— 这两步推迟到折叠阶段，
    /// 因此同一份统计可以廉价地按任意位数重读。
    private struct PairStats {
        var sums: [Double]
        var sumSquares: [Double]
        var counts: [Int]
        var absSum = 0.0
        var observed = 0

        init() {
            sums = [Double](repeating: 0, count: pairsPerTile)
            sumSquares = [Double](repeating: 0, count: pairsPerTile)
            counts = [Int](repeating: 0, count: pairsPerTile)
        }

        /// 平均 |d|。与 payloadBits 无关，正好用来量「块对齐得好不好」，
        /// 阶段一拿它给相位排序。
        var signal: Double { observed > 0 ? absSum / Double(observed) : 0 }
    }

    private static func accumulate(
        _ feature: FeatureContext,
        _ image: RGBAImage,
        ox: Int,
        oy: Int
    ) -> PairStats {
        var stats = PairStats()

        let pairRows = (image.height - oy) / blockSize
        let pairCols = ((image.width - ox) / blockSize) / 2
        guard pairRows > 0, pairCols > 0 else { return stats }

        var row = 0
        while row < pairRows {
            let localRow = row % blockRowsPerTile
            let by = oy + row * blockSize
            var col = 0
            while col < pairCols {
                let localCol = col % pairsPerRow
                let bx = ox + col * 2 * blockSize
                let d = blockMean(feature, bx, by)
                    - blockMean(feature, bx + blockSize, by)

                if abs(d) >= minMagnitude {
                    let index = localRow * pairsPerRow + localCol
                    stats.sums[index] += d
                    stats.sumSquares[index] += d * d
                    stats.counts[index] += 1
                    stats.absSum += abs(d)
                    stats.observed += 1
                }
                col += 1
            }
            row += 1
        }
        return stats
    }

    // MARK: - 折叠成 per-bit 统计

    private struct Folded {
        let payloadBytes: [UInt8]
        let scores: [Double]
        let signal: Double
        let confidence: Double
        let weakBits: Int
        let medianAbsZ: Double
    }

    /// 把按 pair 累积的统计折叠成 per-bit 统计。
    ///
    /// 极性翻转只是符号，平方和不动，所以一次累加可以按任意位数、任意 tile 旋转反复折叠。
    ///
    /// `rotation` 补偿裁剪：裁掉非 256 整数倍的内容会让图案的 tile 原点相对图片平移，
    /// 观测到的「解码器本地索引 i」其实对应图案的「真实本地索引 (i + rotation) % pairsPerTile」。
    /// 相位搜索（ox/oy mod 8）只修块对齐，修不了这个平移 —— 修不了的表现就是载荷整体旋转。
    private static func fold(_ stats: PairStats, payloadBits: Int, rotation: Int = 0) -> Folded {
        var sums = [Double](repeating: 0, count: payloadBits)
        var sumSquares = [Double](repeating: 0, count: payloadBits)
        var counts = [Int](repeating: 0, count: payloadBits)

        for index in 0..<pairsPerTile where stats.counts[index] > 0 {
            let shifted = (index + rotation) % pairsPerTile
            let sign = isFlipped(shifted, payloadBits: payloadBits) ? -1.0 : 1.0
            let bit = shifted % payloadBits
            sums[bit] += sign * stats.sums[index]
            sumSquares[bit] += stats.sumSquares[index]
            counts[bit] += stats.counts[index]
        }

        // 每个 bit 的 z 值 = 均值 / 标准误
        var scores = [Double](repeating: 0, count: payloadBits)
        for i in 0..<payloadBits where counts[i] >= 2 {
            let n = Double(counts[i])
            let mean = sums[i] / n
            let variance = max(sumSquares[i] / n - mean * mean, minVariance)
            scores[i] = mean / (variance / n).squareRoot()
        }

        var payloadBytes = [UInt8](repeating: 0, count: (payloadBits + 7) / 8)
        for i in 0..<payloadBits where scores[i] < 0 {
            payloadBytes[i >> 3] |= 1 << UInt8(i & 7)
        }

        let absolute = scores.filter { $0 != 0 }.map { abs($0) }
        let sorted = absolute.sorted()
        return Folded(
            payloadBytes: payloadBytes,
            scores: scores,
            signal: stats.observed > 0 ? stats.absSum / Double(stats.observed) : 0,
            confidence: sorted.first ?? 0,
            weakBits: sorted.filter { $0 < 3 }.count,
            medianAbsZ: sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        )
    }

    private static func makeDecoded(
        _ folded: Folded,
        payloadBits: Int,
        plane: WatermarkPlane,
        ox: Int,
        oy: Int
    ) -> Decoded {
        Decoded(
            payloadBytes: folded.payloadBytes,
            payloadBits: payloadBits,
            plane: plane,
            offsetX: ox,
            offsetY: oy,
            signal: folded.signal,
            confidence: folded.confidence,
            weakBits: folded.weakBits,
            medianAbsZ: folded.medianAbsZ
        )
    }

    // MARK: - 积分图

    /// 尺寸 (width+1) × (height+1)，首行首列为 0。块均值 O(1) 取值。
    private static func integralImage(_ feature: [Double], width: Int, height: Int) -> [Double] {
        let stride = width + 1
        var sat = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            let srcRow = y * width
            let dstRow = (y + 1) * stride
            let prevRow = y * stride
            for x in 0..<width {
                rowSum += feature[srcRow + x]
                sat[dstRow + x + 1] = sat[prevRow + x + 1] + rowSum
            }
        }
        return sat
    }

    private static func blockMean(_ feature: FeatureContext, _ x: Int, _ y: Int) -> Double {
        let x2 = x + blockSize
        let y2 = y + blockSize
        let stride = feature.stride
        let integral = feature.integral
        let sum = integral[y2 * stride + x2]
            - integral[y * stride + x2]
            - integral[y2 * stride + x]
            + integral[y * stride + x]
        return sum / Double(blockSize * blockSize)
    }
}
