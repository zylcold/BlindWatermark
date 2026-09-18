import XCTest
@testable import BlindWatermarkCore

/// 黑边（IM 转发 / 图片查看器套的纯黑边框）会让交界列的假差分周期性砸在同一批 bit 上，
/// 把 BCH 的纠错预算用光。这里钉住"能识别"和"不该动的别动"两侧。
final class BorderTrimTests: XCTestCase {
    private let payload = WatermarkPayloadV52(
        uid: 0x1234_5678, timestampOffset: 1_234_567, buildMinuteOffset: 89_012,
        pageCode: "profile", app: 42, noteCode: "hotfix")!

    /// 给图套一层纯黑边框，模拟 IM 转发。
    private func padded(_ source: RGBAImage, left: Int, top: Int, right: Int, bottom: Int) -> RGBAImage {
        var output = RGBAImage(width: source.width + left + right, height: source.height + top + bottom)
        output.fill((0, 0, 0, 255))
        for y in 0..<source.height {
            for x in 0..<source.width {
                let from = (y * source.width + x) * 4
                let to = ((y + top) * output.width + x + left) * 4
                for channel in 0..<4 { output.pixels[to + channel] = source.pixels[from + channel] }
            }
        }
        return output
    }

    func testTrimsBlackBarsAndDecodesAfterwards() throws {
        var source = RGBAImage(width: 640, height: 900)
        source.fill((200, 200, 200, 255))
        source.blendTiled(V52Codec.makeTile(payload: payload, alpha: 4, plane: .chroma), dx: 3, dy: 5)
        let barred = padded(source, left: 9, top: 0, right: 14, bottom: 0)

        let (working, trim) = barred.trimmingUniformDarkBorder()
        XCTAssertEqual(trim, UniformBorderTrim(left: 9, top: 0, right: 14, bottom: 0))
        XCTAssertEqual(working.width, 640)
        XCTAssertEqual(working.height, 900)
        XCTAssertEqual(trim.outputField, "trim=(9,0,14,0)")

        let decoded = try XCTUnwrap(V52Codec.decodeBest(
            working, scales: [1.0], planes: [.chroma], syncModes: [.none],
            searchPhase: true, searchTile: true, maxContexts: 4
        ))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.correctedBits, 0)
    }

    /// 深色页不能整片当成黑边裁掉：黑背景一路顶到裁剪比例上限（25%）时必须整体放弃。
    func testDoesNotTrimLargeDarkMargins() {
        var dark = RGBAImage(width: 640, height: 900)
        dark.fill((4, 4, 4, 255))
        // 白字只占中间 50%，四边各留 >25% 的纯黑 —— 这是深色页的留白，不是 IM 加的黑边
        for row in stride(from: 250, to: 650, by: 40) {
            dark.fillRect(x: 200, y: row, width: 240, height: 6, rgba: (240, 240, 240, 255))
        }
        let (working, trim) = dark.trimmingUniformDarkBorder()
        XCTAssertTrue(trim.isEmpty, "深色内容被误当黑边：\(trim)")
        XCTAssertEqual(working.width, 640)
        XCTAssertEqual(working.height, 900)
    }

    func testKeepsImageWithoutBorders() {
        var plain = RGBAImage(width: 320, height: 480)
        plain.fill((180, 180, 180, 255))
        let (working, trim) = plain.trimmingUniformDarkBorder()
        XCTAssertTrue(trim.isEmpty)
        XCTAssertEqual(working.width, 320)
    }
}
