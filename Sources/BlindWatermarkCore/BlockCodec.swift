import CoreGraphics
import Foundation

/// 屏上盲水印编解码。
///
/// ## 编码
/// 覆盖全屏的是 8×8 **像素块**平铺图案，不是单像素噪点 —— 块内平坦，过 JPEG 不会被抹掉。
/// 每两个相邻块 (A,B) 编码 1 bit：
/// - `1` → A 压暗、B 提亮
/// - `0` → A 提亮、B 压暗
///
/// ## 为什么是差分
/// 解码只取 `d = mean(A) - mean(B)` 的符号。压暗块的减益是 `−base·α`，提亮块的增益是
/// `(255−base)·α`，两者相加把 `base` 项抵消掉：`d ≈ ∓255α = ∓delta`。
/// **与底色无关** —— 白底、黑底、深色照片都能解。
///
/// ## 为什么翻转极性
/// 相邻块的均值差里还混着**内容本身的亮度梯度**（渐变背景、照片），梯度大时能压过 delta。
/// 于是同一个 bit 的多份重复观测里，隔一份把黑白极性反过来（解码端同步翻符号）：
/// 水印分量同向累加，梯度分量正负相消。
///
/// 注意不能把翻转做成棋盘：bit 索引固定了列，同一 bit 的所有观测行奇偶性一致，棋盘翻不动它。
///
/// ## 为什么软累加而不是符号投票
/// 相邻块的差异里，内容本身（文字边缘、照片细节）经常远大于 delta。只取符号等于把水印丢掉。
/// 于是按**带符号的差值累加**，再除以标准误得到每个 bit 的 z 值：
/// 水印分量随观测次数线性累加，内容噪声按 1/√n 衰减。手机截图有几十个 tile 重复，
/// 每个 bit 上百次观测，足以把信噪比拉回来。
///
/// 相位选择与「画面里到底有没有水印」都看 z 值，不看平均幅度 —— 平均幅度被内容噪声主导。
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

    public struct Decoded: Equatable {
        public let payload: UInt32
        public let payloadBits: Int
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
    }

    // MARK: - 编码

    /// 生成平铺用的水印 tile。未着色像素完全透明，不产生任何扰动。
    /// - Parameters:
    ///   - payload: 待嵌入的比特，低位在前
    ///   - payloadBits: 有效位数 1...32。同一 payload 在 tile 内重复 `pairsPerTile / payloadBits` 次
    ///   - alpha: 扰动幅度，即解码端观察到的 |d|。**下限 2**，更低会被色域转换与量化吃掉。
    ///     默认 6 是模拟器实测值：真实界面上块差分的内容噪声 σ≈30，alpha=3 时每 bit 的
    ///     \|z\| 中位只有 3.3、过半 bit 证据不足；6 时 \|z\| 中位 6.4、全部 bit 显著。
    ///     代价是平坦区域会有 6/255 ≈ 2.4% 的 8px 棋盘纹理，凑近能看出来。
    public static func makeTile(payload: UInt32, payloadBits: Int = 32, alpha: UInt8 = 6) -> RGBAImage {
        precondition((1...32).contains(payloadBits), "payloadBits 必须在 1...32")
        var tile = RGBAImage(width: tileSize, height: tileSize)
        for p in 0..<pairsPerTile {
            let row = p / pairsPerRow
            let col = p % pairsPerRow
            let bit = Int((payload >> UInt32(p % payloadBits)) & 1)
            var leftDark = (bit == 1)
            if isFlipped(p, payloadBits: payloadBits) { leftDark.toggle() }
            let x = col * 2 * blockSize
            let y = row * blockSize
            paint(&tile, x: x, y: y, dark: leftDark, alpha: alpha)
            paint(&tile, x: x + blockSize, y: y, dark: !leftDark, alpha: alpha)
        }
        return tile
    }

    /// 同一个 bit 的重复观测隔一份翻转极性，让梯度偏置成对相消。
    /// 重复份数为奇数时不翻，宁可不抵消也不能翻错。
    static func isFlipped(_ localPairIndex: Int, payloadBits: Int) -> Bool {
        let repetitions = pairsPerTile / payloadBits
        guard repetitions >= 2, repetitions % 2 == 0 else { return false }
        return (localPairIndex / payloadBits) % 2 == 1
    }

    private static func paint(_ image: inout RGBAImage, x: Int, y: Int, dark: Bool, alpha: UInt8) {
        // 预乘 alpha：纯黑 (0,0,0,a)，纯白 (a,a,a,a)
        let v = dark ? UInt8(0) : alpha
        image.fillRect(x: x, y: y, width: blockSize, height: blockSize, rgba: (v, v, v, alpha))
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
    public static func decode(
        _ image: RGBAImage,
        payloadBits: Int = 32,
        offsetX: Int = 0,
        offsetY: Int = 0
    ) -> Decoded? {
        precondition((1...32).contains(payloadBits), "payloadBits 必须在 1...32")
        guard image.width >= blockSize * 2, image.height >= blockSize else { return nil }

        let luma = image.lumaBuffer()
        let stride = image.width + 1
        let integral = integralImage(luma, width: image.width, height: image.height)
        let observation = accumulate(
            integral, stride, image,
            ox: offsetX, oy: offsetY, payloadBits: payloadBits,
            rowStride: 1, colStride: 1
        )
        let scores = observation.scores()
        var payload: UInt32 = 0
        for i in 0..<payloadBits where scores[i] < 0 {
            payload |= (1 << UInt32(i))
        }
        return Decoded(
            payload: payload,
            payloadBits: payloadBits,
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
    private static func integralImage(_ luma: [Double], width: Int, height: Int) -> [Double] {
        let stride = width + 1
        var sat = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            let srcRow = y * width
            let dstRow = (y + 1) * stride
            let prevRow = y * stride
            for x in 0..<width {
                rowSum += luma[srcRow + x]
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
