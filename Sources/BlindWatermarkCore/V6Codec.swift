import Foundation

/// v6 的独立色度同步列不占用数据幅度；全部像素使用同一个预乘 alpha。
public enum V6Codec {
    public static let cellWidth = 32
    public static let cellHeight = 8
    public static let dataColumns = 16
    public static let columns = 17
    public static let rows = 64
    public static let tileWidth = cellWidth * columns
    public static let tileHeight = cellHeight * rows
    public static let defaultDelta: UInt8 = 4
    public static let minObservationsPerBit = 5
    public static let defaultScales = Array(stride(from: 0.50, through: 1.501, by: 0.05))
    // 固定实验预算；不是正确率承诺。镜像实现与回归样本共同约束这些值。
    static let observationClip = 12.0
    static let observationVarianceFloor = 0.25
    static let maxContexts = 12
    static let shiftsPerContext = 2
    static let softBits = 6
    static let minimumPilotScore = 0.35
    static let cells = columns * rows

    public struct Decoded {
        public let payload: WatermarkPayload?
        public let correctedBits: Int
        public let softRecoveryUsed: Bool
        public let estimatedScale: Double
        public let offsetX: Double
        public let offsetY: Double
        public let tileShiftX: Int
        public let tileShiftY: Int
        public let pilotScore: Double
        public let minObservations: Int
        public let averageObservations: Double
        public let medianAbsZ: Double
        public let candidateCount: Int
        public let ambiguous: Bool
        public var isSuccess: Bool { payload != nil && !ambiguous }
        public var hasSufficientEvidence: Bool { minObservations >= minObservationsPerBit }
    }

    /// 奇数乘子使 512 个物理位置与码字位一一对应。
    static func codeIndex(_ position: Int) -> Int {
        let local = position & 511
        return position < 512 ? (local * 73 + 19) & 511 : (local * 151 + 89) & 511
    }

    static func polarity(_ position: Int) -> Bool {
        var value = UInt32(position) &* 0x9E37_79B9 &+ 0x7F4A_7C15
        value ^= value >> 16
        value = value &* 0x85EB_CA6B
        value ^= value >> 13
        return value & 1 != 0
    }

    static let pilotBits: [Bool] = {
        let ordered = (0..<64).sorted { pilotHash($0) < pilotHash($1) }
        let negative = Set(ordered.prefix(32))
        return (0..<64).map { negative.contains($0) }
    }()

    private static func pilotHash(_ position: Int) -> UInt32 {
        var value = UInt32(position) &* 0x9E37_79B9 &+ 0x7F4A_7C15
        value ^= value >> 16
        value = value &* 0x85EB_CA6B
        return value ^ (value >> 13)
    }

    public static func makeTile(payload: WatermarkPayload, delta: UInt8 = defaultDelta,
                                plane: WatermarkPlane = .chroma) -> RGBAImage {
        precondition(delta >= 2, "v6 delta must be at least 2")
        let word = V6BCH.encode(messageBytes: payload.bytes)
        var image = RGBAImage(width: tileWidth, height: tileHeight)
        let companion = Int((0.114 * Double(delta) / 0.886).rounded())
        for row in 0..<rows {
            for col in 0..<columns {
                let negative: Bool
                if col < dataColumns {
                    let position = row * dataColumns + col
                    let index = codeIndex(position)
                    negative = (word[index >> 3] & (1 << UInt8(index & 7)) != 0) != polarity(position)
                } else {
                    negative = pilotBits[row]
                }
                for x in 0..<cellWidth {
                    // 正弦模板不引入额外 alpha；端点色差预算与 delta 相同。
                    let wave = sin(2 * Double.pi * (Double(x) + 0.5) / Double(cellWidth))
                    let yellow = (1 - (negative ? -wave : wave)) / 2
                    let r = plane == .chroma ? Int((Double(companion) * yellow).rounded())
                        : Int((Double(delta) * (1 - yellow)).rounded())
                    let b = plane == .chroma ? Int((Double(delta) * (1 - yellow)).rounded()) : r
                    image.fillRect(x: col * cellWidth + x, y: row * cellHeight,
                                   width: 1, height: cellHeight,
                                   rgba: (UInt8(r), UInt8(r), UInt8(b), delta))
                }
            }
        }
        return image
    }

    struct Stats {
        var sums = [Double](repeating: 0, count: cells)
        var squares = [Double](repeating: 0, count: cells)
        var counts = [Int](repeating: 0, count: cells)
    }

    struct Context {
        let stats: Stats
        let scale: Double
        let x: Double
        let y: Double
        let shifts: [(x: Int, y: Int, score: Double)]
        var score: Double { shifts.first?.score ?? 0 }
    }

    struct Candidate {
        let payload: WatermarkPayload
        let correctedBits: Int
        let soft: Bool
        let context: Context
        let shiftX: Int
        let shiftY: Int
        let pilot: Double
        let minObs: Int
        let avgObs: Double
        let medianZ: Double
    }

    private struct Integral {
        let width: Int
        let height: Int
        let values: [Double]
        init(_ image: RGBAImage, plane: WatermarkPlane) {
            width = image.width
            height = image.height
            let feature = image.featureBuffer(plane)
            var sums = [Double](repeating: 0, count: (width + 1) * (height + 1))
            for y in 0..<height {
                var sum = 0.0
                for x in 0..<width {
                    sum += feature[y * width + x]
                    sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + sum
                }
            }
            values = sums
        }
        func at(_ x: Double, _ y: Double) -> Double {
            let px = max(0, min(Double(width), x))
            let py = max(0, min(Double(height), y))
            let ix = Int(px), iy = Int(py)
            let nx = min(width, ix + 1), ny = min(height, iy + 1)
            let fx = px - Double(ix), fy = py - Double(iy)
            let stride = width + 1
            return (values[iy * stride + ix] * (1 - fx) + values[iy * stride + nx] * fx) * (1 - fy)
                + (values[ny * stride + ix] * (1 - fx) + values[ny * stride + nx] * fx) * fy
        }
        func mean(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Double {
            (at(x + w, y + h) - at(x, y + h) - at(x + w, y) + at(x, y)) / (w * h)
        }
    }

    private static func accumulate(_ integral: Integral, scale: Double, x: Double, y: Double) -> Stats? {
        guard scale.isFinite, scale > 0, x.isFinite, y.isFinite, x >= 0, y >= 0 else { return nil }
        let w = Double(cellWidth) * scale, h = Double(cellHeight) * scale
        guard Double(integral.width) - x >= w, Double(integral.height) - y >= h else { return nil }
        let nx = Int((Double(integral.width) - x) / w), ny = Int((Double(integral.height) - y) / h)
        var stats = Stats()
        for row in 0..<ny {
            for col in 0..<nx {
                let px = x + Double(col) * w, py = y + Double(row) * h
                let difference = integral.mean(px, py, w / 2, h) - integral.mean(px + w / 2, py, w / 2, h)
                // v6 计数的是不重叠 cell 的物理观测。JPEG 量化成 0 时仍保留擦除信息，
                // z 保持为 0，不伪造方向或置信度；恢复必须通过 BCH 与 CRC。
                // 限制文字/照片硬边缘的支配力，保留符号；实际观测数仍按非重叠 cell 计数。
                let d = max(-observationClip, min(observationClip, difference))
                let index = (row % rows) * columns + col % columns
                stats.sums[index] += d
                stats.squares[index] += d * d
                stats.counts[index] += 1
            }
        }
        return stats
    }

    private static func pilotShifts(_ stats: Stats, searchTile: Bool) -> [(x: Int, y: Int, score: Double)] {
        let means = zip(stats.sums, stats.counts).map { $1 > 0 ? $0 / Double($1) : 0 }
        var ranked = [(x: Int, y: Int, score: Double)]()
        for dy in 0..<(searchTile ? rows : 1) {
            for dx in 0..<(searchTile ? columns : 1) {
                var numerator = 0.0, energy = 0.0
                for row in 0..<rows {
                    for col in dataColumns..<columns {
                        let observed = ((row - dy + rows) % rows) * columns + (col - dx + columns) % columns
                        let mean = means[observed]
                        numerator += mean * (pilotBits[row] ? -1 : 1)
                        energy += mean * mean
                    }
                }
                let score = energy > 0 ? numerator / sqrt(64 * energy) : 0
                ranked.append((dx, dy, score))
            }
        }
        return Array(ranked.sorted { $0.score > $1.score }.prefix(shiftsPerContext))
    }

    private static func context(_ integral: Integral, scale: Double, x: Double, y: Double,
                                searchTile: Bool) -> Context? {
        guard let stats = accumulate(integral, scale: scale, x: x, y: y) else { return nil }
        return Context(stats: stats, scale: scale, x: x, y: y,
                       shifts: pilotShifts(stats, searchTile: searchTile))
    }

    public static func decode(_ image: RGBAImage, plane: WatermarkPlane = .chroma, scale: Double = 1,
                              offsetX: Double = 0, offsetY: Double = 0, searchTile: Bool = false) -> Decoded? {
        guard image.width > 0, image.height > 0,
              image.pixels.count == image.width * image.height * 4 else { return nil }
        let integral = Integral(image, plane: plane)
        guard let ctx = context(integral, scale: scale, x: offsetX, y: offsetY, searchTile: searchTile) else { return nil }
        return adjudicate(candidates([ctx]))
    }

    public static func decodeBest(_ image: RGBAImage, scales: [Double]? = nil,
                                  plane: WatermarkPlane = .chroma) -> Decoded? {
        guard image.width > 0, image.height > 0,
              image.pixels.count == image.width * image.height * 4 else { return nil }
        let integral = Integral(image, plane: plane)
        func scan(_ values: [Double]) -> [Context] {
            var found = [Context]()
            for scale in values where scale.isFinite && (0.5...1.5).contains(scale) {
                var best: Context?
                for y in stride(from: 0.0, to: Double(cellHeight) * scale, by: 2) {
                    for x in stride(from: 0.0, to: Double(cellWidth) * scale, by: 4) {
                        guard let ctx = context(integral, scale: scale, x: x, y: y, searchTile: true) else { continue }
                        if best == nil || ctx.score > best!.score { best = ctx }
                    }
                }
                if let best { found.append(best) }
            }
            // 每个比例只留一个上下文，避免某一比例的相位挤掉非粗网格比例。
            return found.sorted { $0.score > $1.score }
        }
        func finish(_ contexts: [Context]) -> Decoded? {
            var refined = [Context]()
            for seed in contexts.prefix(maxContexts) {
                for dy in [-1.0, 0, 1] {
                    for dx in [-2.0, 0, 2] {
                        let x = seed.x + dx, y = seed.y + dy
                        guard x >= 0, y >= 0,
                              let ctx = context(integral, scale: seed.scale, x: x, y: y, searchTile: true) else { continue }
                        refined.append(ctx)
                    }
                }
            }
            return adjudicate(candidates(Array(refined.sorted { $0.score > $1.score }.prefix(maxContexts))))
        }
        if let scales { return finish(scan(scales)) }
        // 原始尺度是最常见通道；检查所搜索的全部相位候选后，再决定是否需要缩放搜索。
        if let exact = finish(scan([1.0])), exact.isSuccess { return exact }
        let coarse = scan(defaultScales)
        let step = 1 / Double(max(1, max(image.width, image.height)))
        var fine = Set<Double>()
        for seed in coarse.prefix(3) {
            for value in stride(from: max(0.5, seed.scale - 0.03), through: min(1.5, seed.scale + 0.03), by: step) {
                fine.insert((value * 1_000_000).rounded() / 1_000_000)
            }
        }
        return finish(scan(fine.sorted()))
    }

    private static func candidates(_ contexts: [Context]) -> [Candidate] {
        var found = [Candidate]()
        var pending = [(Context, Int, Int, Double, [Double], [Int])]()
        for ctx in contexts {
            for shift in ctx.shifts where shift.score >= minimumPilotScore {
                var scores = [Double](repeating: 0, count: 512)
                var counts = [Int](repeating: 0, count: 512)
                var sums = [Double](repeating: 0, count: 512)
                var squares = [Double](repeating: 0, count: 512)
                for row in 0..<rows {
                    for col in 0..<dataColumns {
                        let local = ((row - shift.y + rows) % rows) * columns + (col - shift.x + columns) % columns
                        let position = row * dataColumns + col, index = codeIndex(position)
                        counts[index] += ctx.stats.counts[local]
                        sums[index] += ctx.stats.sums[local] * (polarity(position) ? -1 : 1)
                        squares[index] += ctx.stats.squares[local]
                    }
                }
                for index in scores.indices where counts[index] > 0 {
                    let n = Double(counts[index]), mean = sums[index] / Double(counts[index])
                    let variance = max(observationVarianceFloor, squares[index] / n - mean * mean)
                    scores[index] = mean / sqrt(variance / n)
                }
                if let hit = attempt(scores, counts, ctx, shift.x, shift.y, shift.score, flips: []) {
                    found.append(hit)
                } else {
                    pending.append((ctx, shift.x, shift.y, shift.score, scores, counts))
                }
            }
        }
        if found.isEmpty {
            for (ctx, x, y, pilot, scores, counts) in pending.prefix(2) {
                let ranked = Array(scores.indices.sorted { abs(scores[$0]) < abs(scores[$1]) }.prefix(softBits))
                for a in ranked.indices {
                    if let hit = attempt(scores, counts, ctx, x, y, pilot, flips: [ranked[a]]) { found.append(hit) }
                    for b in ranked.indices where b > a {
                        if let hit = attempt(scores, counts, ctx, x, y, pilot, flips: [ranked[a], ranked[b]]) { found.append(hit) }
                    }
                }
            }
        }
        return found
    }

    private static func attempt(_ scores: [Double], _ counts: [Int], _ ctx: Context,
                                _ x: Int, _ y: Int, _ pilot: Double, flips: [Int]) -> Candidate? {
        var bytes = [UInt8](repeating: 0, count: 64)
        for index in scores.indices where (scores[index] < 0) != flips.contains(index) {
            bytes[index >> 3] |= 1 << UInt8(index & 7)
        }
        guard let corrected = V6BCH.decode(codewordBytes: bytes),
              let payload = WatermarkPayload(bytes: corrected.messageBytes) else { return nil }
        let hard = scores.enumerated().map { index, score in (score < 0) != ((corrected.codewordBytes[index >> 3] & (1 << UInt8(index & 7))) != 0) }
        let absolute = scores.map(abs).sorted()
        return Candidate(payload: payload, correctedBits: hard.filter { $0 }.count, soft: !flips.isEmpty,
                         context: ctx, shiftX: x, shiftY: y, pilot: pilot,
                         minObs: counts.min() ?? 0, avgObs: Double(counts.reduce(0, +)) / 512,
                         medianZ: (absolute[255] + absolute[256]) / 2)
    }

    static func adjudicate(_ candidates: [Candidate]) -> Decoded? {
        guard let best = candidates.max(by: {
            if $0.minObs != $1.minObs { return $0.minObs < $1.minObs }
            if $0.medianZ != $1.medianZ { return $0.medianZ < $1.medianZ }
            return $0.pilot < $1.pilot
        }) else { return nil }
        let distinct = Set(candidates.map { $0.payload.bytes })
        let ambiguous = distinct.count > 1
        return Decoded(payload: ambiguous ? nil : best.payload, correctedBits: best.correctedBits,
                       softRecoveryUsed: best.soft, estimatedScale: best.context.scale,
                       offsetX: best.context.x, offsetY: best.context.y,
                       tileShiftX: best.shiftX, tileShiftY: best.shiftY, pilotScore: best.pilot,
                       minObservations: best.minObs, averageObservations: best.avgObs,
                       medianAbsZ: best.medianZ, candidateCount: distinct.count, ambiguous: ambiguous)
    }
}
