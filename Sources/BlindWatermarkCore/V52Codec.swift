import Foundation

/// Synchronization pilot used by the v5.2 experiment path.
public enum V52SyncMode: String, CaseIterable, Equatable {
    /// Data only. This is the protocol baseline.
    case none
    /// A deterministic PN sequence is added to the two sides of each pair.
    case pn
    /// The PN sequence is shared by the two BCH copies, so pilot correlation can
    /// be summed while data is recovered by differencing their opposite polarity.
    case separated
}

/// v5.2 spatial encoder/decoder.
///
/// The normal tile contains two 256-bit BCH codeword copies. The second copy has
/// opposite business polarity. BCH decoding and CRC validation are both required;
/// a candidate is never accepted merely because it is the first one to pass CRC.
public enum V52Codec {
    public static let blockSize = 8
    public static let tileSize = 256
    public static let pairsPerRow = 16
    public static let blockRowsPerTile = 32
    public static let pairsPerTile = 512
    public static let codewordBits = V52BCH.codewordBits
    /// Coarse, continuous search grid. The decoder refines the best contexts
    /// locally; the values are not a whitelist of the validation samples.
    public static let defaultScales: [Double] = Array(stride(from: 0.50, through: 1.50, by: 0.05))
    public static let defaultChaseBits = 12
    public static let defaultChaseFlips = 2

    public struct Decoded: Equatable {
        /// Nil for an ambiguous or unsuccessful search result.
        public let payload: WatermarkPayloadV52?
        public let codewordBytes: [UInt8]?
        public let plane: WatermarkPlane
        public let sync: V52SyncMode
        public let offsetX: Int
        public let offsetY: Int
        public let estimatedScale: Double
        public let correctedBits: Int
        public let softRecoveryUsed: Bool
        public let pilotScore: Double
        /// Number of CRC-valid BCH candidates considered before deduplication.
        public let candidateCount: Int
        public let ambiguous: Bool
        public let failureReason: String?
        public let medianAbsZ: Double
        public let minObservations: Int
        public let averageObservations: Double

        public var isSuccess: Bool { payload != nil && !ambiguous }
    }

    // MARK: - Encoding

    public static func makeTile(
        payload: WatermarkPayloadV52,
        alpha: UInt8 = 8,
        plane: WatermarkPlane = .chroma,
        sync: V52SyncMode = .none
    ) -> RGBAImage {
        makeTile(payloadBytes: payload.bytes, alpha: alpha, plane: plane, sync: sync)
    }

    public static func makeTile(
        payloadBytes: [UInt8],
        alpha: UInt8 = 8,
        plane: WatermarkPlane = .chroma,
        sync: V52SyncMode = .none
    ) -> RGBAImage {
        precondition(payloadBytes.count == WatermarkPayloadV52.byteCount, "v5.2 payload must be 26 bytes")
        precondition(WatermarkPayloadV52(bytes: payloadBytes) != nil, "v5.2 payload must pass profile, field, reserved, and CRC checks")
        precondition(alpha >= 2, "v5.2 alpha must be at least 2")
        let codeword = V52BCH.encode(messageBytes: payloadBytes)
        var tile = RGBAImage(width: tileSize, height: tileSize)
        let pilotAmplitude = sync == .none || plane == .luma ? 0 : max(1, min(2, Int(alpha) / 4))
        let dataAmplitude = max(1, Int(alpha) - pilotAmplitude)
        let companion = chromaCompanion(UInt8(dataAmplitude))

        for pair in 0..<pairsPerTile {
            let row = pair / pairsPerRow
            let col = pair % pairsPerRow
            let codeIndex = pair % codewordBits
            var dataBit = bit(codeword, at: codeIndex)
            if pair >= codewordBits { dataBit.toggle() }
            let pilotIndex: Int
            switch sync {
            case .none: pilotIndex = 0
            case .pn: pilotIndex = pair
            case .separated: pilotIndex = pair % codewordBits
            }
            let pilotBit = sync == .none ? false : pnBit(pilotIndex)
            let x = col * blockSize * 2
            let y = row * blockSize
            paint(
                &tile,
                x: x,
                y: y,
                dark: dataBit,
                pilotOn: pilotBit,
                alpha: alpha,
                dataAmplitude: dataAmplitude,
                companion: companion,
                plane: plane,
                pilotAmplitude: pilotAmplitude
            )
            paint(
                &tile,
                x: x + blockSize,
                y: y,
                dark: !dataBit,
                pilotOn: sync == .none ? false : !pilotBit,
                alpha: alpha,
                dataAmplitude: dataAmplitude,
                companion: companion,
                plane: plane,
                pilotAmplitude: pilotAmplitude
            )
        }
        return tile
    }

    private static func paint(
        _ image: inout RGBAImage,
        x: Int,
        y: Int,
        dark: Bool,
        pilotOn: Bool,
        alpha: UInt8,
        dataAmplitude: Int,
        companion: UInt8,
        plane: WatermarkPlane,
        pilotAmplitude: Int
    ) {
        switch plane {
        case .luma:
            let value = dark ? 0 : dataAmplitude
            image.fillRect(x: x, y: y, width: blockSize, height: blockSize,
                           rgba: (UInt8(value), UInt8(value), UInt8(value), alpha))
        case .chroma:
            var r = dark ? Int(companion) : 0
            var g = r
            var b = dark ? 0 : dataAmplitude
            // Keep alpha constant and compose pilot + data in one premultiplied
            // layer. The data amplitude reserves pilot headroom, so no channel
            // can exceed alpha and source-over semantics remain well-defined.
            if pilotOn {
                r += pilotAmplitude
                g += pilotAmplitude
                b += pilotAmplitude
            }
            image.fillRect(
                x: x,
                y: y,
                width: blockSize,
                height: blockSize,
                rgba: (UInt8(min(Int(alpha), r)), UInt8(min(Int(alpha), g)), UInt8(min(Int(alpha), b)), alpha)
            )
        }
    }

    // MARK: - Public decoding entry points

    /// Decode one known scale/phase. It still performs BCH + CRC and a bounded
    /// Chase search, so a returned value is suitable for protocol diagnostics.
    public static func decode(
        _ image: RGBAImage,
        plane: WatermarkPlane = .chroma,
        sync: V52SyncMode = .none,
        scale: Double = 1.0,
        offsetX: Int = 0,
        offsetY: Int = 0,
        searchTile: Bool = false,
        maxChaseBits: Int = defaultChaseBits,
        maxChaseFlips: Int = defaultChaseFlips
    ) -> Decoded? {
        guard scale.isFinite, scale > 0 else { return nil }
        let feature = image.featureBuffer(plane)
        let integral = Integral(feature: feature, width: image.width, height: image.height)
        let lumaIntegral = sync == .none ? nil : Integral(feature: image.featureBuffer(.luma), width: image.width, height: image.height)
        guard let stats = accumulate(integral: integral, image: image, scale: scale,
                                     offsetX: offsetX, offsetY: offsetY, sync: sync,
                                     lumaIntegral: lumaIntegral) else { return nil }
        let rotations = searchTile ? Array(0..<pairsPerTile) : [0]
        let candidates = collectCandidates(stats: stats, rotations: rotations, plane: plane,
                                            sync: sync, scale: scale, offsetX: offsetX,
                                            offsetY: offsetY, maxChaseBits: maxChaseBits,
                                            maxChaseFlips: maxChaseFlips)
        return adjudicate(candidates, plane: plane, sync: sync, scale: scale,
                          offsetX: offsetX, offsetY: offsetY)
    }

    /// Search the fixed experiment scale set, block phase, tile phase and pilot
    /// mode. Geometric contexts are ranked first; only the best 16 contexts enter
    /// the 512-rotation BCH/CRC stage. This keeps the candidate budget explicit.
    public static func decodeBest(
        _ image: RGBAImage,
        scales: [Double] = defaultScales,
        planes: [WatermarkPlane] = [.chroma, .luma],
        syncModes: [V52SyncMode] = [.none],
        searchPhase: Bool = true,
        searchTile: Bool = true,
        maxContexts: Int = 16,
        maxChaseBits: Int = defaultChaseBits,
        maxChaseFlips: Int = defaultChaseFlips
    ) -> Decoded? {
        struct Context {
            let stats: PairStats
            let plane: WatermarkPlane
            let sync: V52SyncMode
            let scale: Double
            let offsetX: Int
            let offsetY: Int
            let score: Double
        }

        var contexts = [Context]()
        // Feature planes do not depend on scale or phase. Build each once and
        // reuse its integral image across the complete geometry search.
        let chromaIntegral = Integral(feature: image.featureBuffer(.chroma), width: image.width, height: image.height)
        let lumaIntegral = Integral(feature: image.featureBuffer(.luma), width: image.width, height: image.height)
        let pilotIntegral: Integral? = syncModes.contains(where: { $0 != .none }) ? lumaIntegral : nil
        for scale in scales where scale > 0 {
            let block = Double(blockSize) * scale
            // x phase spans a complete pair (two blocks); stopping at one block
            // silently loses odd-block crops and mixes adjacent data pairs.
            let phaseXCount = searchPhase ? max(1, Int(ceil(block * 2))) : 1
            let phaseYCount = searchPhase ? max(1, Int(ceil(block))) : 1
            for plane in planes {
                let integral = plane == .chroma ? chromaIntegral : lumaIntegral
                for sync in syncModes {
                    for oy in 0..<phaseYCount {
                        for ox in 0..<phaseXCount {
                            guard let stats = accumulate(integral: integral, image: image, scale: scale,
                                                         offsetX: ox, offsetY: oy, sync: sync,
                                                         lumaIntegral: pilotIntegral) else { continue }
                            let folded = fold(stats, rotation: 0, sync: sync)
                            guard folded.counts.min() ?? 0 > 0 else { continue }
                            contexts.append(Context(stats: stats, plane: plane, sync: sync,
                                                     scale: scale, offsetX: ox, offsetY: oy,
                                                     score: folded.medianAbsZ + abs(folded.pilotScore) * 0.05))
                        }
                    }
                }
            }
        }
        guard !contexts.isEmpty else { return nil }
        contexts.sort { $0.score > $1.score }
        let coarseFinalists = contexts.prefix(max(1, min(maxContexts, contexts.count)))
        var seeds = [Context]()
        var seenSeeds = Set<String>()
        for context in coarseFinalists {
            let key = "\(context.plane.rawValue):\(context.sync.rawValue):\(Int((context.scale * 100).rounded()))"
            if seenSeeds.insert(key).inserted { seeds.append(context) }
            if seeds.count >= min(4, max(1, maxContexts)) { break }
        }
        var finalists = [Context]()
        // Refine each winning scale with coordinate descent. The step halves
        // until it is below half a pixel over the image span, so an arbitrary
        // ratio such as 0.837 is not accidentally treated as a known fixture.
        func evaluated(_ seed: Context, scale: Double, offsetX: Int, offsetY: Int) -> Context? {
            guard scale >= 0.5, scale <= 1.5 else { return nil }
            let integral = seed.plane == .chroma ? chromaIntegral : lumaIntegral
            guard let stats = accumulate(integral: integral, image: image, scale: scale,
                                         offsetX: offsetX, offsetY: offsetY, sync: seed.sync,
                                         lumaIntegral: seed.sync == .none ? nil : lumaIntegral) else { return nil }
            let folded = fold(stats, rotation: 0, sync: seed.sync)
            guard folded.counts.min() ?? 0 > 0 else { return nil }
            return Context(stats: stats, plane: seed.plane, sync: seed.sync, scale: scale,
                           offsetX: offsetX, offsetY: offsetY,
                           score: folded.medianAbsZ + abs(folded.pilotScore) * 0.05)
        }

        for context in seeds {
            var best = context
            // A dense local pass prevents a coarse 0.05 grid from becoming a
            // hidden whitelist. Coordinate descent below then reaches the
            // image-span tolerance without special-casing validation scales.
            let fineStep = 0.005
            var fineScale = max(0.5, context.scale - 0.05)
            while fineScale <= min(1.5, context.scale + 0.05) + 0.000_001 {
                if let probe = evaluated(context, scale: fineScale,
                                         offsetX: context.offsetX, offsetY: context.offsetY),
                   probe.score > best.score {
                    best = probe
                }
                fineScale += fineStep
            }
            var step = 0.025
            let tolerance = 0.5 / Double(max(image.width, image.height))
            while step > tolerance {
                var probes = [best.scale - step, best.scale + step]
                probes.append(best.scale)
                var bestProbe = best
                for refinedScale in probes where refinedScale >= 0.5 && refinedScale <= 1.5 {
                    // Recheck a one-pixel phase neighborhood whenever scale
                    // changes; fractional resampling can move the best boundary.
                    for oy in max(0, best.offsetY - 1)...(best.offsetY + 1) {
                        for ox in max(0, best.offsetX - 1)...(best.offsetX + 1) {
                            guard let probe = evaluated(best, scale: refinedScale, offsetX: ox, offsetY: oy),
                                  probe.score > bestProbe.score else { continue }
                            bestProbe = probe
                        }
                    }
                }
                best = bestProbe
                step *= 0.5
            }
            finalists.append(best)
        }
        let rotations = searchTile ? Array(0..<pairsPerTile) : [0]
        var allCandidates = [Candidate]()
        for context in finalists {
            allCandidates.append(contentsOf: collectCandidates(
                stats: context.stats,
                rotations: rotations,
                plane: context.plane,
                sync: context.sync,
                scale: context.scale,
                offsetX: context.offsetX,
                offsetY: context.offsetY,
                maxChaseBits: maxChaseBits,
                maxChaseFlips: maxChaseFlips
            ))
        }
        return adjudicate(allCandidates, plane: nil, sync: nil, scale: nil, offsetX: nil, offsetY: nil)
    }

    // MARK: - Candidate scoring

    private struct Candidate {
        let payload: WatermarkPayloadV52
        let codewordBytes: [UInt8]
        let correctedBits: Int
        let softRecoveryUsed: Bool
        let plane: WatermarkPlane
        let sync: V52SyncMode
        let scale: Double
        let offsetX: Int
        let offsetY: Int
        let pilotScore: Double
        let medianAbsZ: Double
        let minObservations: Int
        let averageObservations: Double
        let score: Double
    }

    private static func collectCandidates(
        stats: PairStats,
        rotations: [Int],
        plane: WatermarkPlane,
        sync: V52SyncMode,
        scale: Double,
        offsetX: Int,
        offsetY: Int,
        maxChaseBits: Int,
        maxChaseFlips: Int
    ) -> [Candidate] {
        var candidates = [Candidate]()
        // Scan every tile rotation for a hard BCH/CRC hit before spending the
        // bounded Chase budget. Interleaving Chase attempts here can exhaust
        // the budget on an early wrong rotation and skip a later exact copy.
        var pendingSoft = [(folded: Folded, hard: [UInt8])]()
        for rotation in rotations {
            let folded = fold(stats, rotation: rotation, sync: sync)
            let hard = pack(folded.scores.map { $0 < 0 })
            let hardCandidate = tryCandidate(hard, folded: folded, plane: plane, sync: sync,
                                             scale: scale, offsetX: offsetX, offsetY: offsetY,
                                             hardBytes: hard, soft: false)
            if let hardCandidate {
                candidates.append(hardCandidate)
                continue
            }
            pendingSoft.append((folded, hard))
        }
        // Exact candidates are already stronger evidence than a bounded soft
        // recovery. If none exists, spend the budget in rotation order.
        guard candidates.isEmpty else { return candidates }
        var softAttempts = 0
        let maxSoftAttempts = 256
        for pending in pendingSoft where maxChaseFlips > 0 && softAttempts < maxSoftAttempts {
            let ranked = pending.folded.scores.indices.sorted { abs(pending.folded.scores[$0]) < abs(pending.folded.scores[$1]) }
                .prefix(max(0, min(maxChaseBits, pending.folded.scores.count)))
            guard !ranked.isEmpty else { continue }
            let indices = Array(ranked)
            for flipCount in 1...min(maxChaseFlips, indices.count) {
                for combination in combinations(indices, taking: flipCount) {
                    guard softAttempts < maxSoftAttempts else { break }
                    softAttempts += 1
                    var bits = pending.folded.scores.map { $0 < 0 }
                    for index in combination { bits[index].toggle() }
                    if let candidate = tryCandidate(pack(bits), folded: pending.folded, plane: plane,
                                                    sync: sync, scale: scale, offsetX: offsetX,
                                                    offsetY: offsetY, hardBytes: pending.hard, soft: true) {
                        candidates.append(candidate)
                    }
                }
                if softAttempts >= maxSoftAttempts { break }
            }
        }
        return candidates
    }

    private static func tryCandidate(
        _ bytes: [UInt8],
        folded: Folded,
        plane: WatermarkPlane,
        sync: V52SyncMode,
        scale: Double,
        offsetX: Int,
        offsetY: Int,
        hardBytes: [UInt8],
        soft: Bool
    ) -> Candidate? {
        guard let corrected = V52BCH.decode(codewordBytes: bytes),
              let payload = WatermarkPayloadV52(bytes: corrected.messageBytes) else { return nil }
        let correctedBits = zip(hardBytes, corrected.codewordBytes)
            .reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        return Candidate(
            payload: payload,
            codewordBytes: corrected.codewordBytes,
            correctedBits: correctedBits,
            softRecoveryUsed: soft,
            plane: plane,
            sync: sync,
            scale: scale,
            offsetX: offsetX,
            offsetY: offsetY,
            pilotScore: folded.pilotScore,
            medianAbsZ: folded.medianAbsZ,
            minObservations: folded.minObservations,
            averageObservations: folded.averageObservations,
            score: folded.medianAbsZ - Double(correctedBits) * 0.25 + folded.pilotScore * 0.05
        )
    }

    private static func adjudicate(
        _ candidates: [Candidate],
        plane: WatermarkPlane?,
        sync: V52SyncMode?,
        scale: Double?,
        offsetX: Int?,
        offsetY: Int?
    ) -> Decoded? {
        guard !candidates.isEmpty else { return nil }
        var byPayload = [String: Candidate]()
        for candidate in candidates {
            let key = candidate.payload.bytes.map { String(format: "%02x", $0) }.joined()
            if byPayload[key] == nil || byPayload[key]!.score < candidate.score {
                byPayload[key] = candidate
            }
        }
        let distinct = Array(byPayload.values).sorted { $0.score > $1.score }
        guard let best = distinct.first else { return nil }
        let isAmbiguous = distinct.count > 1
        return Decoded(
            payload: isAmbiguous ? nil : best.payload,
            codewordBytes: isAmbiguous ? nil : best.codewordBytes,
            plane: plane ?? best.plane,
            sync: sync ?? best.sync,
            offsetX: offsetX ?? best.offsetX,
            offsetY: offsetY ?? best.offsetY,
            estimatedScale: scale ?? best.scale,
            correctedBits: best.correctedBits,
            softRecoveryUsed: best.softRecoveryUsed,
            pilotScore: best.pilotScore,
            candidateCount: candidates.count,
            ambiguous: isAmbiguous,
            failureReason: isAmbiguous ? "multiple distinct CRC-valid payloads" : nil,
            medianAbsZ: best.medianAbsZ,
            minObservations: best.minObservations,
            averageObservations: best.averageObservations
        )
    }

    // MARK: - Geometry and soft observations

    private struct PairStats {
        var sums = [Double](repeating: 0, count: pairsPerTile)
        var squares = [Double](repeating: 0, count: pairsPerTile)
        var counts = [Int](repeating: 0, count: pairsPerTile)
        var pilotSums = [Double](repeating: 0, count: pairsPerTile)
        var pilotSquares = [Double](repeating: 0, count: pairsPerTile)
        var pilotCounts = [Int](repeating: 0, count: pairsPerTile)
        var absSum = 0.0
        var observed = 0
    }

    private struct Integral {
        let values: [Double]
        let width: Int
        let height: Int
        let stride: Int

        init(feature: [Double], width: Int, height: Int) {
            self.width = width
            self.height = height
            self.stride = width + 1
            var values = [Double](repeating: 0, count: (width + 1) * (height + 1))
            for y in 0..<height {
                var rowSum = 0.0
                for x in 0..<width {
                    rowSum += feature[y * width + x]
                    values[(y + 1) * stride + x + 1] = values[y * stride + x + 1] + rowSum
                }
            }
            self.values = values
        }

        func at(_ x: Double, _ y: Double) -> Double {
            let xx = min(Double(width), max(0, x))
            let yy = min(Double(height), max(0, y))
            let x0 = min(width, Int(floor(xx)))
            let y0 = min(height, Int(floor(yy)))
            let x1 = min(width, x0 + 1)
            let y1 = min(height, y0 + 1)
            let fx = xx - Double(x0)
            let fy = yy - Double(y0)
            func value(_ x: Int, _ y: Int) -> Double { values[y * stride + x] }
            let top = value(x0, y0) * (1 - fx) + value(x1, y0) * fx
            let bottom = value(x0, y1) * (1 - fx) + value(x1, y1) * fx
            return top * (1 - fy) + bottom * fy
        }

        func mean(x: Double, y: Double, size: Double) -> Double {
            guard size > 0 else { return 0 }
            let x1 = min(Double(width), x + size)
            let y1 = min(Double(height), y + size)
            guard x1 > x, y1 > y else { return 0 }
            let area = (x1 - x) * (y1 - y)
            let total = at(x1, y1) - at(x, y1) - at(x1, y) + at(x, y)
            return total / area
        }
    }

    private static func accumulate(
        integral: Integral,
        image: RGBAImage,
        scale: Double,
        offsetX: Int,
        offsetY: Int,
        sync: V52SyncMode,
        lumaIntegral: Integral?
    ) -> PairStats? {
        let block = Double(blockSize) * scale
        guard block > 0, Double(image.width - offsetX) >= block * 2, Double(image.height - offsetY) >= block else {
            return nil
        }
        let rows = Int(floor((Double(image.height - offsetY)) / block))
        let cols = Int(floor((Double(image.width - offsetX)) / (block * 2)))
        guard rows > 0, cols > 0 else { return nil }
        var stats = PairStats()
        for row in 0..<rows {
            let localRow = row % blockRowsPerTile
            let y = Double(offsetY) + Double(row) * block
            for col in 0..<cols {
                let localCol = col % pairsPerRow
                let index = localRow * pairsPerRow + localCol
                let x = Double(offsetX) + Double(col) * block * 2
                let left = integral.mean(x: x, y: y, size: block)
                let right = integral.mean(x: x + block, y: y, size: block)
                let d = left - right
                if abs(d) >= 0.25 {
                    stats.sums[index] += d
                    stats.squares[index] += d * d
                    stats.counts[index] += 1
                    stats.absSum += abs(d)
                    stats.observed += 1
                }
                if let lumaIntegral {
                    let pd = lumaIntegral.mean(x: x, y: y, size: block)
                        - lumaIntegral.mean(x: x + block, y: y, size: block)
                    stats.pilotSums[index] += pd
                    stats.pilotSquares[index] += pd * pd
                    stats.pilotCounts[index] += 1
                }
            }
        }
        return stats
    }

    private struct Folded {
        let scores: [Double]
        let counts: [Int]
        let signal: Double
        let pilotScore: Double
        let medianAbsZ: Double
        let minObservations: Int
        let averageObservations: Double
    }

    private static func fold(_ stats: PairStats, rotation: Int, sync: V52SyncMode) -> Folded {
        var sums = [Double](repeating: 0, count: codewordBits)
        var squares = [Double](repeating: 0, count: codewordBits)
        var counts = [Int](repeating: 0, count: codewordBits)
        var pilotNumerator = 0.0
        var pilotDenominator = 0.0
        for index in 0..<pairsPerTile {
            let row = index / pairsPerRow
            let col = index % pairsPerRow
            let rowShift = rotation / pairsPerRow
            let colShift = rotation % pairsPerRow
            let shifted = ((row + rowShift) % blockRowsPerTile) * pairsPerRow
                + (col + colShift) % pairsPerRow
            let codeIndex = shifted % codewordBits
            let copySign = shifted >= codewordBits ? -1.0 : 1.0
            sums[codeIndex] += copySign * stats.sums[index]
            squares[codeIndex] += stats.squares[index]
            counts[codeIndex] += stats.counts[index]

            if stats.pilotCounts[index] > 0, sync != .none {
                let pilotIndex: Int
                switch sync {
                case .none:
                    pilotIndex = 0
                case .pn:
                    // `.pn` uses a unique sequence over all 512 pairs.
                    pilotIndex = shifted
                case .separated:
                    // `.separated` repeats the pilot over both BCH copies so
                    // it can be summed while business polarity is cancelled.
                    pilotIndex = shifted % codewordBits
                }
                let expectedSign = pnBit(pilotIndex) ? 1.0 : -1.0
                // pilotSums are left-right feature differences; the encoder
                // makes pilot-on positive. This is diagnostic only.
                pilotNumerator += expectedSign * stats.pilotSums[index]
                pilotDenominator += stats.pilotSquares[index]
            }
        }

        var scores = [Double](repeating: 0, count: codewordBits)
        for index in 0..<codewordBits where counts[index] >= 2 {
            let n = Double(counts[index])
            let mean = sums[index] / n
            let variance = max(squares[index] / n - mean * mean, 0.25)
            scores[index] = mean / sqrt(variance / n)
        }
        let absolute = scores.map(abs).filter { $0 > 0 }.sorted()
        let pilotScore = pilotDenominator > 0 ? pilotNumerator / sqrt(pilotDenominator * Double(max(1, stats.pilotCounts.reduce(0, +)))) : 0
        return Folded(
            scores: scores,
            counts: counts,
            signal: stats.observed > 0 ? stats.absSum / Double(stats.observed) : 0,
            pilotScore: pilotScore,
            medianAbsZ: absolute.isEmpty ? 0 : absolute[absolute.count / 2],
            minObservations: counts.min() ?? 0,
            averageObservations: Double(stats.observed) / Double(codewordBits)
        )
    }

    private static func combinations(_ values: [Int], taking count: Int) -> [[Int]] {
        guard count > 0, count <= values.count else { return [] }
        if count == 1 { return values.map { [$0] } }
        var output = [[Int]]()
        func visit(_ start: Int, _ current: [Int]) {
            if current.count == count { output.append(current); return }
            let remaining = count - current.count
            guard values.count - start >= remaining else { return }
            for index in start..<values.count {
                visit(index + 1, current + [values[index]])
            }
        }
        visit(0, [])
        return output
    }

    private static func pnBit(_ index: Int) -> Bool {
        var x = UInt32(truncatingIfNeeded: index &* 0x9E37_79B9 &+ 0x7F4A_7C15)
        x ^= x >> 16
        x &*= 0x85EB_CA6B
        x ^= x >> 13
        return (x & 1) != 0
    }

    private static func bit(_ bytes: [UInt8], at index: Int) -> Bool {
        bytes[index >> 3] & (1 << UInt8(index & 7)) != 0
    }

    private static func pack(_ bits: [Bool]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (index, value) in bits.enumerated() where value {
            bytes[index >> 3] |= 1 << UInt8(index & 7)
        }
        return bytes
    }

    private static func chromaCompanion(_ amplitude: UInt8) -> UInt8 {
        let ideal = (0.114 * Double(amplitude) / 0.886).rounded()
        return UInt8(max(1, min(Double(amplitude), ideal)))
    }
}
