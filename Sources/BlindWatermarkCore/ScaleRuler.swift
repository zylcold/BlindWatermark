import Accelerate
import Foundation

/// 比例尺（粗定位）：水印在 x 方向是 [block, !block] 交替的块对，所以**水平自相关**在
/// `lag = block` 处最负、`lag = 2*block` 处最正。用"谷 + 2 倍峰"的联合目标直接读出 block 边长，
/// 由 `scale = block / 8` 得到比例，省掉 `V52Codec.decodeBest` 的 21 档粗网格 × 2 平面。
///
/// 精度实测（合成 v5.2 图）：0.50 / 0.75 / 1.00 / 1.50 精确，1.173 / 1.30 误差 ≤1.3%，
/// 0.837 误差 4.5%；企业微信转发的真实缩放图误差 7.6% —— 所以它只是**粗定位**，
/// 候选要留 `span` 余量，快路径失败后必须退回完整网格。
///
/// 置信度 = 谷深 `|ACF(block)|`：水印图实测 0.30~0.74，无水印纯色 / 彩色噪声 ≈ 0.00。
public enum ScaleRuler {
    public struct Estimate: Equatable {
        public let plane: WatermarkPlane
        public let scale: Double
        public let confidence: Double
    }

    /// 低于这个置信度不当作线索（实测无水印图 ≈ 0.00，水印图 ≥ 0.29）
    public static let minConfidence = 0.05
    /// 候选比例范围：±span（真实转发图误差到 7.6%，留到 10%）
    public static let span = 0.10
    /// 候选档数（含中心）
    public static let steps = 5
    /// block 边长的搜索范围：0.50...1.50 比例 → 4...12 px，两侧各留一点余量
    public static let minBlock = 3.5
    public static let maxBlock = 13.0
    /// 自相关最多算到 2*maxBlock 多一点
    static let maxLag = 32
    /// 逐行累加太重：按行抽样，500 行左右足够稳
    static let rowSampleTarget = 512

    public static func estimate(
        _ image: RGBAImage,
        planes: [WatermarkPlane] = [.chroma, .luma]
    ) -> Estimate? {
        var best: Estimate?
        for plane in planes {
            guard let candidate = estimate(image, plane: plane) else { continue }
            if best == nil || candidate.confidence > best!.confidence { best = candidate }
        }
        return best
    }

    public static func candidateScales(
        for estimate: Estimate,
        span: Double = span,
        steps: Int = steps
    ) -> [Double] {
        guard steps > 0 else { return [] }
        var scales = Set<Double>()
        for index in 0..<steps {
            let ratio = 1 + span * (2 * Double(index) / Double(max(1, steps - 1)) - 1)
            let value = (estimate.scale * ratio * 10_000).rounded() / 10_000
            if value > 0 { scales.insert(value) }
        }
        return scales.sorted()
    }

    // MARK: - 内部

    private static func estimate(_ image: RGBAImage, plane: WatermarkPlane) -> Estimate? {
        let width = image.width
        let height = image.height
        guard width > Int(maxBlock * 2) + 2, height > 0 else { return nil }
        let feature = image.featureBuffer(plane)
        // 去均值：自相关只关心相对结构，直流分量会让所有 lag 都是正数
        var mean = 0.0
        vDSP_meanvD(feature, 1, &mean, vDSP_Length(feature.count))
        var centered = [Double](repeating: 0, count: feature.count)
        var negativeMean = -mean
        vDSP_vsaddD(feature, 1, &negativeMean, &centered, 1, vDSP_Length(feature.count))

        guard let acf = averageAutocorrelation(centered, width: width, height: height) else { return nil }
        guard acf[0] > 0 else { return nil }
        let normalized = acf.map { $0 / acf[0] }

        // 细网格上线性插值，避免整点采样把 8px 水印读成 8.16px
        var bestBlock = 0.0
        var bestScore = -Double.infinity
        var confidence = 0.0
        var block = minBlock
        while block <= maxBlock {
            let valley = interpolate(normalized, at: block)
            let peak = interpolate(normalized, at: min(2 * block, Double(maxLag)))
            let score = peak - valley
            if score > bestScore {
                bestScore = score
                bestBlock = block
                confidence = -valley
            }
            block += 0.01
        }
        guard bestBlock > 0 else { return nil }
        return Estimate(plane: plane, scale: bestBlock / 8, confidence: confidence)
    }

    /// 行平均水平自相关。stride 语义：`feature` 是 `y * width + x` 的行主序。
    private static func averageAutocorrelation(_ feature: [Double], width: Int, height: Int) -> [Double]? {
        var acf = [Double](repeating: 0, count: maxLag + 1)
        var rowStep = max(1, height / rowSampleTarget)
        var product = [Double](repeating: 0, count: width)
        var rows = 0
        feature.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var row = 0
            while row < height {
                let rowBase = row * width
                for lag in 0...maxLag where width > lag {
                    let count = width - lag
                    vDSP_vmulD(base + rowBase, 1, base + rowBase + lag, 1, &product, 1, vDSP_Length(count))
                    var sum = 0.0
                    vDSP_sveD(product, 1, &sum, vDSP_Length(count))
                    acf[lag] += sum
                }
                rows += 1
                row += rowStep
            }
        }
        guard rows > 0, acf[0] != 0 else { return nil }
        return acf
    }

    private static func interpolate(_ values: [Double], at position: Double) -> Double {
        guard position > 0 else { return values.first ?? 0 }
        let clamped = min(position, Double(values.count - 1))
        let lower = Int(clamped.rounded(.down))
        let upper = min(values.count - 1, lower + 1)
        let fraction = clamped - Double(lower)
        return values[lower] * (1 - fraction) + values[upper] * fraction
    }
}
