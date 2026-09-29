import XCTest
@testable import BlindWatermarkCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class StripEndToEndTests: XCTestCase {
    /// 端到端：真实底图 + 条码渲染 + CG JPEG 重压缩后解码（q90/76/60）。
    func testEndToEndJPEG() throws {
        let url = URL(fileURLWithPath: "docs/samples/v6-mixed-original.png")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              var image = RGBAImage(cgImage: cg) else {
            throw XCTSkip("样本缺失：\(url.path)")
        }
        let bits = StripWatermark.bits(uid: 124_914_474, minuteOffset: 389_398)
        let blockPx = Double(image.width) / 88.0
        StripWatermark.render(into: &image, bits: bits, blockWidthPx: blockPx,
                              stripHeightPx: 3, edge: .top)
        StripWatermark.render(into: &image, bits: bits, blockWidthPx: blockPx,
                              stripHeightPx: 3, edge: .bottom)
        guard let out = image.makeCGImage() else { return XCTFail("makeCGImage") }

        for quality in [0.9, 0.76, 0.6] {
            let tmp = URL(fileURLWithPath: "/tmp/bw-strip-e2e-q\(Int(quality * 100)).jpg")
            let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            let props = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            CGImageDestinationAddImage(dest, out, props)
            XCTAssertTrue(CGImageDestinationFinalize(dest))

            let back = CGImageSourceCreateWithURL(tmp as CFURL, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                .flatMap { RGBAImage(cgImage: $0) }
            let decoded = back.flatMap { StripWatermark.decode(image: $0) }
            XCTAssertEqual(decoded?.uid, 124_914_474, "q=\(quality)")
            XCTAssertEqual(decoded?.minuteOffset, 389_398, "q=\(quality)")
        }
    }
}
