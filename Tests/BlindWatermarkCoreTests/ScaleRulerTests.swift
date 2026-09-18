import XCTest
@testable import BlindWatermarkCore

/// 比例尺（粗定位）与"粗筛按比例排名"这两件事的回归测试。
final class ScaleRulerTests: XCTestCase {
    private let payload = WatermarkPayloadV52(
        uid: 0x1234_5678, timestampOffset: 1_234_567, buildMinuteOffset: 89_012,
        pageCode: "profile", app: 42, noteCode: "hotfix")!

    private func source(width: Int = 528, height: Int = 792) -> RGBAImage {
        var image = RGBAImage(width: width, height: height)
        image.fill((200, 200, 200, 255))
        image.blendTiled(V52Codec.makeTile(payload: payload, alpha: 4, plane: .chroma), dx: 3, dy: 5)
        return image
    }

    private func resize(_ input: RGBAImage, _ scale: Double) -> RGBAImage {
        let width = Int(Double(input.width) * scale)
        let height = Int(Double(input.height) * scale)
        var output = RGBAImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let sourceX = min(input.width - 1, Int(Double(x) / scale))
                let sourceY = min(input.height - 1, Int(Double(y) / scale))
                let sourceIndex = (sourceY * input.width + sourceX) * 4
                let destinationIndex = (y * width + x) * 4
                for channel in 0..<4 { output.pixels[destinationIndex + channel] = input.pixels[sourceIndex + channel] }
            }
        }
        return output
    }

    func testScaleRulerEstimatesRescaledImages() throws {
        let base = source()
        for scale in [0.50, 0.837, 1.173, 1.50] {
            let estimate = try XCTUnwrap(
                ScaleRuler.estimate(resize(base, scale), planes: [.chroma]),
                "scale=\(scale) 没给出估计"
            )
            XCTAssertEqual(estimate.plane, .chroma)
            XCTAssertEqual(estimate.scale, scale, accuracy: 0.08, "scale=\(scale)")
            XCTAssertGreaterThanOrEqual(estimate.confidence, ScaleRuler.minConfidence, "scale=\(scale)")
            // 候选区间必须罩住真值（±10%），否则快路径会漏
            let candidates = ScaleRuler.candidateScales(for: estimate)
            XCTAssertEqual(candidates.count, ScaleRuler.steps)
            XCTAssertTrue(candidates.contains { abs($0 - scale) / scale <= 0.03 }, "scale=\(scale) 候选 \(candidates)")
        }
    }

    func testScaleRulerIsQuietOnImagesWithoutWatermark() {
        var plain = RGBAImage(width: 528, height: 792)
        plain.fill((200, 200, 200, 255))
        let estimate = ScaleRuler.estimate(plain, planes: [.chroma, .luma])
        XCTAssertLessThan(estimate?.confidence ?? 0, ScaleRuler.minConfidence, "无水印图不该给出高置信比例尺")
    }

    /// 回归：粗筛必须按**比例**排名。按单个上下文排名时，同一比例的上百个相位会挤满 top-N，
    /// 非粗网格比例（0.837 / 1.173）进不了精搜 —— 症状是"显式 --scale 能解，默认网格解不出"。
    func testDecodeBestFindsUnlistedScalesWithDefaultGrid() throws {
        let base = source()
        for scale in [0.837, 1.173] {
            let decoded = try XCTUnwrap(V52Codec.decodeBest(
                resize(base, scale),
                planes: [.chroma],
                syncModes: [.none],
                searchPhase: true,
                searchTile: true
            ), "scale=\(scale)")
            XCTAssertEqual(decoded.payload, payload, "scale=\(scale)")
            XCTAssertEqual(decoded.estimatedScale, scale, accuracy: 0.004, "scale=\(scale)")
        }
    }
}
