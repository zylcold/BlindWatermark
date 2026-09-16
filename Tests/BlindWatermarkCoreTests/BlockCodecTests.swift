import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import BlindWatermarkCore

final class BlockCodecTests: XCTestCase {

    /// 造一张「模拟截图」：先画底图，再按随机相位贴水印 tile。
    private func makeScreenshot(
        width: Int = 640,
        height: Int = 900,
        payload: UInt32,
        payloadBits: Int = 32,
        delta: UInt8 = 3,
        offset: (Int, Int) = (0, 0),
        drawBase: (inout RGBAImage) -> Void
    ) -> RGBAImage {
        var base = RGBAImage(width: width, height: height)
        drawBase(&base)
        let tile = BlockCodec.makeTile(payload: payload, payloadBits: payloadBits, alpha: delta)
        base.blendTiled(tile, dx: offset.0, dy: offset.1)
        return base
    }

    private func jpegRoundTrip(_ image: RGBAImage, quality: CGFloat) throws -> RGBAImage {
        let cgImage = try XCTUnwrap(image.makeCGImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(RGBAImage(cgImage: decoded))
    }

    // MARK: - 底色无关性：差分编码的核心卖点

    func testWhiteBackground() throws {
        let payload: UInt32 = 0xA5C3_1F07
        let image = makeScreenshot(payload: payload) { $0.fill((255, 255, 255, 255)) }
        let decoded = try XCTUnwrap(BlockCodec.decode(image))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertGreaterThan(decoded.signal, 2.0)
        XCTAssertGreaterThan(decoded.confidence, 30)
    }

    func testBlackBackground() throws {
        let payload: UInt32 = 0x1234_ABCD
        let image = makeScreenshot(payload: payload) { $0.fill((0, 0, 0, 255)) }
        let decoded = try XCTUnwrap(BlockCodec.decode(image))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertGreaterThan(decoded.signal, 2.0)
        XCTAssertGreaterThan(decoded.confidence, 30)
    }

    func testMidGrayBackground() throws {
        let payload: UInt32 = 0x0F0F_0F0F
        let image = makeScreenshot(payload: payload) { $0.fill((128, 128, 128, 255)) }
        let decoded = try XCTUnwrap(BlockCodec.decode(image))
        XCTAssertEqual(decoded.payload, payload)
    }

    /// 真实界面大多是渐变 + 照片细节，不是纯色
    func testGradientWithPhotoLikeDetail() throws {
        let payload: UInt32 = 0xDEAD_BEEF
        let image = makeScreenshot(payload: payload) { base in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            for y in 0..<base.height {
                for x in 0..<base.width {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let noise = Int8(truncatingIfNeeded: Int((seed >> 33) % 13) - 6)
                    let r = (x * 255) / base.width
                    let g = (y * 255) / base.height
                    let b = ((x + y) * 255) / (base.width + base.height)
                    let i = (y * base.width + x) * 4
                    base.pixels[i] = UInt8(clamping: r + Int(noise))
                    base.pixels[i + 1] = UInt8(clamping: g + Int(noise))
                    base.pixels[i + 2] = UInt8(clamping: b + Int(noise))
                    base.pixels[i + 3] = 255
                }
            }
        }
        let decoded = try XCTUnwrap(BlockCodec.decode(image))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertGreaterThan(decoded.confidence, 2, "内容噪声下 z 值仍应明显为正")
    }

    // MARK: - 鲁棒性

    func testSurvivesJPEGQuality80() throws {
        let payload: UInt32 = 0x5A5A_0001
        let image = makeScreenshot(payload: payload) { $0.fill((240, 240, 240, 255)) }
        let compressed = try jpegRoundTrip(image, quality: 0.8)
        let decoded = try XCTUnwrap(BlockCodec.decode(compressed))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertGreaterThan(decoded.confidence, 30)
    }

    func testSurvivesJPEGQuality60() throws {
        let payload: UInt32 = 0x5A5A_0002
        let image = makeScreenshot(payload: payload) { $0.fill((200, 200, 200, 255)) }
        let compressed = try jpegRoundTrip(image, quality: 0.6)
        let decoded = try XCTUnwrap(BlockCodec.decode(compressed))
        XCTAssertEqual(decoded.payload, payload)
    }

    /// 局部裁剪：tile 平铺 + 差分编码，剪一半仍可解
    func testSurvivesCropping() throws {
        let payload: UInt32 = 0x0000_CAFE
        let image = makeScreenshot(payload: payload) { $0.fill((255, 255, 255, 255)) }
        var cropped = RGBAImage(width: 320, height: 452)
        for y in 0..<cropped.height {
            for x in 0..<cropped.width {
                let si = (y * image.width + x) * 4
                let di = (y * cropped.width + x) * 4
                for c in 0..<4 { cropped.pixels[di + c] = image.pixels[si + c] }
            }
        }
        let decoded = try XCTUnwrap(BlockCodec.decode(cropped))
        XCTAssertEqual(decoded.payload, payload)
    }

    func testShortPayload() throws {
        let payload: UInt32 = 0b1011
        let image = makeScreenshot(payload: payload, payloadBits: 4) { $0.fill((255, 255, 255, 255)) }
        let decoded = try XCTUnwrap(BlockCodec.decode(image, payloadBits: 4))
        XCTAssertEqual(decoded.payload, payload)
    }

    /// delta 低于 2 会被量化吃掉，这里固化下限
    func testMinimumDeltaIsTwo() throws {
        let payload: UInt32 = 0x00FF_00FF
        let image = makeScreenshot(payload: payload, delta: 2) { $0.fill((255, 255, 255, 255)) }
        let decoded = try XCTUnwrap(BlockCodec.decode(image))
        XCTAssertEqual(decoded.payload, payload)
    }

    func testImageWithoutWatermarkHasLowConfidence() throws {
        // 不贴 tile，纯底图
        var plain = RGBAImage(width: 640, height: 900)
        plain.fill((255, 255, 255, 255))
        let decoded = try XCTUnwrap(BlockCodec.decode(plain))
        XCTAssertLessThan(decoded.confidence, 2, "无水印画面不应给出高置信度")
    }

    // MARK: - 端到端产物

    /// 产出一张带水印的模拟截图，供 `swift run bwdecode <path>` 验证解码链路。
    func testWriteSampleScreenshot() throws {
        let payload: UInt32 = 0x00AB_CDEF
        let image = makeScreenshot(
            width: 1170,
            height: 2532,
            payload: payload,
        ) { base in
            let span = base.width + base.height
            for y in 0..<base.height {
                for x in 0..<base.width {
                    let v = UInt8(160 + (x + y) * 80 / span)
                    let i = (y * base.width + x) * 4
                    base.pixels[i] = v
                    base.pixels[i + 1] = v
                    base.pixels[i + 2] = v
                    base.pixels[i + 3] = 255
                }
            }
        }
        let cgImage = try XCTUnwrap(image.makeCGImage())
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("blindwatermark-sample.png")
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        print("[sample] \(url.path)  payload=0x\(String(format: "%08X", payload))")
    }
}
