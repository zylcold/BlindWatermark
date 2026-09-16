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
/// 注意不能做成棋盘：bit 索引固定了列，同一 bit 的观测行奇偶性一致，棋盘翻不动它。
///
/// ## 为什么软累加而不是符号投票
/// 内容差异经常远大于 delta，只取符号等于把水印丢掉。按带符号差值累加再除以标准误得到 z 值：
/// 水印随观测次数线性累加，内容噪声按 `1/√n` 衰减。手机截图几十个 tile 重复，每 bit 上百次观测。
///
/// ## 容量
/// 每 tile 有 `pairsPerTile`(=512) 个 pair。payloadBits 上限 **256**（此时每 tile 只重复 2 份，
/// 刚好还够翻转极性用）。chroma 模式下 128 bit 在 iPhone 16 上每 bit 约 182 次观测，\|z\| 中位 200+，
/// 余量仍然非常充裕。
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
    ///
    ///     默认 8 是模拟器实测调出来的：
    ///     - luma 模式：alpha=3 时真实界面上 \|z\| 中位只有 3.3、半数 bit 证据不足，必須 6 以上；
    ///       代价是平坦区 6/255 的 8px 亮度棋盘，肉眼可见。
    ///     - chroma 模式：灰阶内容在色度平面几乎零噪声，alpha=8 时 128 bit 载荷 \|z\| 中位 200+，
    ///       且 8 与 1 这组预乘值让**亮度残差只有 0.026/255**。
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
            //
            // 亮度零方向的向量是 (0.128, 0.128, -1)：0.299*0.128 + 0.587*0.128 - 0.114 = 0。
            // 于是取 (0, 0, a) 与 (p, p, 0)，令 0.114a = 0.886p，即 p = 0.1287a。
            //
            // 关键：混色是预乘 alpha 的线性运算，合成分的亮度差**等于叠加色在预乘空间的亮度差**，
            // 不随 alpha 衰减。所以 p 必须精确到这个关系，否则亮度网格立刻显形：
            // a=6 时 p 取整成 0，等于拿纯黑去配纯蓝，亮度差 0.68/255 —— 肉眼可见。
            let p = chromaCompanion(alpha)
            // 注意极性：解码特征 B - (R+G)/2 在 (0,0,a) 上是 +a、在 (p,p,0) 上是 -p。
            // 「dark」的语义是**特征值更低**，所以暗块配陪色，亮块配蓝。配反了 bit 全翻。
            if dark {
                image.fillRect(x: x, y: y, width: blockSize, height: blockSize, rgba: (p, p, 0, alpha))
            } else {
                image.fillRect(x: x, y: y, width: blockSize, height: blockSize, rgba: (0, 0, alpha, alpha))
            }
        }
    }

    // MARK: - 解码

    /// 从整屏截图解码。
    ///
    /// 相位默认 (0, 0)：水印层铺在窗口原点，整屏截图的图案原点就是图片原点。
    /// **截图被裁过**（比如裁掉状态栏）时才需要手动给偏移量。
    ///
    /// 不做相位自动搜索。图案按块网格坐标派生 bit 索引，存在天然的位置简并 ——
    /// 错位相位在纯色/低变化画面上也能让所有 bit 自洽，只是解出一份被打乱的结果。
    /// 与其猜，不如把偏移交给调用方。
    ///
    /// **payloadBits 必须与编码端一致**，给错会得到一份自洽但错误的载荷，置信度还很高。
    public static func decode(
        _ image: RGBAImage,
        payloadBits: Int = WatermarkPayload.payloadBits,
        offsetX: Int = 0,
        offsetY: Int = 0,
        plane: WatermarkPlane = .chroma
    ) -> Decoded? {
        precondition((1...maxPayloadBits).contains(payloadBits), "payloadBits 必须在 1...\(maxPayloadBits)")
        guard image.width >= blockSize * 2, image.height >= blockSize else { return nil }

        let feature = image.featureBuffer(plane)
        let stride = image.width + 1
        let integral = integralImage(feature, width: image.width, height: image.height)
        let observation = accumulate(
            integral, stride, image,
            ox: offsetX, oy: offsetY, payloadBits: payloadBits,
            rowStride: 1, colStride: 1
        )
        let scores = observation.scores()
        var payloadBytes = [UInt8](repeating: 0, count: (payloadBits + 7) / 8)
        for i in 0..<payloadBits where scores[i] < 0 {
            payloadBytes[i >> 3] |= 1 << UInt8(i & 7)
        }
        return Decoded(
            payloadBytes: payloadBytes,
            payloadBits: payloadBits,
            plane: plane,
            offsetX: offsetX,
            offsetY: offsetY,
            signal: observation.signal,
            confidence: observation.confidence,
            weakBits: observation.weakBits,
            medianAbsZ: observation.medianAbsZ
        )
    }

    // MARK: - 观测累加

    /// 低于此方差的观测按此方差计算，避免纯色画面上 z 值除以 0 而爆掉
    static let minVariance = 0.25

    /// 观测幅度下限。低于此值的 pair 一律**弃权**，不参与累加。
    /// 否则纯色背景上 `d == 0` 会被当成一个方向的观测，让无水印画面凭空拿到高置信度。
    static let minMagnitude = 0.5

    private struct Observation {
        var sums: [Double]
        var sumSquares: [Double]
        var counts: [Int]
        var absSum = 0.0
        var observed = 0

        init(payloadBits: Int) {
            sums = [Double](repeating: 0, count: payloadBits)
            sumSquares = [Double](repeating: 0, count: payloadBits)
            counts = [Int](repeating: 0, count: payloadBits)
        }

        var signal: Double { observed > 0 ? absSum / Double(observed) : 0 }

        /// 每个 bit 的 z 值 = 均值 / 标准误
        func scores() -> [Double] {
            var out = [Double](repeating: 0, count: sums.count)
            for i in 0..<sums.count where counts[i] >= 2 {
                let n = Double(counts[i])
                let mean = sums[i] / n
                let variance = max(sumSquares[i] / n - mean * mean, BlockCodec.minVariance)
                out[i] = mean / (variance / n).squareRoot()
            }
            return out
        }

        var absoluteZScores: [Double] {
            scores().filter { $0 != 0 }.map { abs($0) }
        }

        /// 最弱 bit 的显著度。|z| < 3 说明该 bit 的证据不足，不能只信它
        var confidence: Double { absoluteZScores.min() ?? 0 }

        var weakBits: Int { absoluteZScores.filter { $0 < 3 }.count }

        var medianAbsZ: Double {
            let z = absoluteZScores.sorted()
            guard !z.isEmpty else { return 0 }
            return z[z.count / 2]
        }
    }

    private static func accumulate(
        _ integral: [Double],
        _ stride: Int,
        _ image: RGBAImage,
        ox: Int,
        oy: Int,
        payloadBits: Int,
        rowStride: Int,
        colStride: Int
    ) -> Observation {
        var obs = Observation(payloadBits: payloadBits)

        let pairRows = (image.height - oy) / blockSize
        let pairCols = ((image.width - ox) / blockSize) / 2
        guard pairRows > 0, pairCols > 0 else { return obs }

        var row = 0
        while row < pairRows {
            let localRow = row % blockRowsPerTile
            let by = oy + row * blockSize
            var col = 0
            while col < pairCols {
                let localCol = col % pairsPerRow
                let bx = ox + col * 2 * blockSize
                var d = blockMean(integral, stride, bx, by)
                    - blockMean(integral, stride, bx + blockSize, by)
                let localPairIndex = localRow * pairsPerRow + localCol
                if isFlipped(localPairIndex, payloadBits: payloadBits) { d = -d }

                guard abs(d) >= minMagnitude else {
                    col += colStride
                    continue
                }
                let bit = localPairIndex % payloadBits
                obs.sums[bit] += d
                obs.sumSquares[bit] += d * d
                obs.counts[bit] += 1
                obs.absSum += abs(d)
                obs.observed += 1
                col += colStride
            }
            row += rowStride
        }
        return obs
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

    private static func blockMean(_ integral: [Double], _ stride: Int, _ x: Int, _ y: Int) -> Double {
        let x2 = x + blockSize
        let y2 = y + blockSize
        let sum = integral[y2 * stride + x2]
            - integral[y * stride + x2]
            - integral[y2 * stride + x]
            + integral[y * stride + x]
        return sum / Double(blockSize * blockSize)
    }
}
