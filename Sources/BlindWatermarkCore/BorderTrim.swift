import Foundation

/// 黑边检测结果：四个方向各裁掉多少像素。全 0 = 没裁。
public struct UniformBorderTrim: Equatable {
    public let left: Int
    public let top: Int
    public let right: Int
    public let bottom: Int

    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public static let none = UniformBorderTrim(left: 0, top: 0, right: 0, bottom: 0)

    public var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }

    /// `trim=(左,上,右,下)`，写进 CLI 输出；没裁时返回 nil，保持旧输出格式不变。
    public var outputField: String? {
        isEmpty ? nil : "trim=(\(left),\(top),\(right),\(bottom))"
    }
}

extension RGBAImage {
    /// 判断"这一条边是不是黑边"的阈值。来自实测：微信/企业微信转发、CleanShot、图片查看器
    /// 会在截图外面套一层纯黑，有时带圆角，角上会留几个亮点。
    public enum BorderTrimHeuristic {
        /// 近黑（0...32/255）
        public static let darkLuma = 32.0
        /// 条带里近黑像素占比下限。实测 CleanShot 黑边列的覆盖率是 0.93~0.95（圆角/抗锯齿吃掉几个像素），
        /// 取 0.90 留余量；深色 UI 里夹白字的一列会掉到这条线下。
        public static let minDarkCoverage = 0.90
        /// 单边最多裁掉的比例。走到上限说明这更像"深色内容"而不是黑边，直接放弃裁剪。
        public static let maxTrimFraction = 0.25
        /// 紧贴黑边的内侧探针条带要多亮，才算"黑边外面是内容"；深色页面的黑背景本身不满足。
        public static let probeLuma = 96.0
        /// 探针条带里亮像素占比下限
        public static let minProbeCoverage = 0.30
        /// 探针条带宽度（像素）
        public static let probeDepth = 8
    }

    /// 裁掉四边的纯黑边框（IM 转发、图片查看器给截图套的黑底）。
    ///
    /// 为什么需要：黑边本身不产生观测，但**黑边与内容交界的那几列 pair** 会拿到量级很大、方向固定的
    /// 假差分，并按 tile 周期性反复砸在同样的 bit 上 —— 折起来就是十几个固定的错 bit，超过 BCH t=6
    /// 的纠错能力，整张图解不出。实测一张企业微信转发图：不裁失败，裁完 `correctedBits=0`。
    ///
    /// 保守起见，只在"这条边纯黑 + 紧挨着它就有明显更亮的内容"时才裁：深色 UI 的黑背景、或者跑满
    /// 上限的长条，都当作内容不动。
    public func trimmingUniformDarkBorder() -> (image: RGBAImage, trim: UniformBorderTrim) {
        guard width > 0, height > 0 else { return (self, .none) }
        let luma = featureBuffer(.luma)

        // 每列 / 每行的近黑与高亮像素计数：一次 O(WH) 统计，四边判断都是查表。
        // stride 语义：像素索引 = y * width + x，luma 与 pixels 同步长。
        var columnDark = [Int](repeating: 0, count: width)
        var columnBright = [Int](repeating: 0, count: width)
        var rowDark = [Int](repeating: 0, count: height)
        var rowBright = [Int](repeating: 0, count: height)
        for y in 0..<height {
            let rowBase = y * width
            for x in 0..<width {
                let value = luma[rowBase + x]
                if value <= BorderTrimHeuristic.darkLuma {
                    columnDark[x] += 1
                    rowDark[y] += 1
                } else if value >= BorderTrimHeuristic.probeLuma {
                    columnBright[x] += 1
                    rowBright[y] += 1
                }
            }
        }

        /// 从一条边往里走能裁多少：`counts` 是这一维每条竖/横线的近黑计数，`bright` 是高亮计数。
        func run(counts: [Int], bright: [Int], span: Int, fromStart: Bool) -> Int {
            let extent = counts.count
            let cap = min(extent, max(1, Int(Double(extent) * BorderTrimHeuristic.maxTrimFraction)))
            let minimumDark = Double(span) * BorderTrimHeuristic.minDarkCoverage
            var count = 0
            while count < cap {
                let index = fromStart ? count : extent - 1 - count
                guard Double(counts[index]) >= minimumDark else { break }
                count += 1
            }
            // 全黑一直顶到上限 → 深色内容，不是黑边
            guard count > 0, count < cap else { return 0 }
            // 紧贴黑边的内侧探针条带要有明显更亮的内容，否则同样按内容处理
            var probeBright = 0
            var probePixels = 0
            for step in 0..<BorderTrimHeuristic.probeDepth {
                let index = fromStart ? count + step : extent - 1 - count - step
                guard index >= count, index < extent - count else { continue }
                probeBright += bright[index]
                probePixels += span
            }
            guard probePixels > 0,
                  Double(probeBright) / Double(probePixels) >= BorderTrimHeuristic.minProbeCoverage else {
                return 0
            }
            return count
        }

        let trim = UniformBorderTrim(
            left: run(counts: columnDark, bright: columnBright, span: height, fromStart: true),
            top: run(counts: rowDark, bright: rowBright, span: width, fromStart: true),
            right: run(counts: columnDark, bright: columnBright, span: height, fromStart: false),
            bottom: run(counts: rowDark, bright: rowBright, span: width, fromStart: false)
        )
        guard !trim.isEmpty else { return (self, .none) }
        return (cropped(trim), trim)
    }

    private func cropped(_ trim: UniformBorderTrim) -> RGBAImage {
        let newWidth = width - trim.left - trim.right
        let newHeight = height - trim.top - trim.bottom
        guard newWidth > 0, newHeight > 0 else { return self }
        let rowBytes = newWidth * 4
        var output = RGBAImage(width: newWidth, height: newHeight)
        // 逐行切片拷贝，不用 withUnsafeMutableBytes：后者在这里会写到临时副本上（实测裁完尺寸没变），
        // 而一次裁剪的开销完全不值得为它冒险。
        for row in 0..<newHeight {
            let sourceStart = ((row + trim.top) * width + trim.left) * 4
            let destinationStart = row * rowBytes
            output.pixels.replaceSubrange(
                destinationStart..<(destinationStart + rowBytes),
                with: pixels[sourceStart..<(sourceStart + rowBytes)]
            )
        }
        return output
    }
}
