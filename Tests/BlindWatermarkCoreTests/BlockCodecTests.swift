import CoreGraphics
import CryptoKit
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
        plane: WatermarkPlane = .chroma,
        offset: (Int, Int) = (0, 0),
        drawBase: (inout RGBAImage) -> Void
    ) -> RGBAImage {
        var base = RGBAImage(width: width, height: height)
        drawBase(&base)
        let tile = BlockCodec.makeTile(payload: payload, payloadBits: payloadBits, alpha: delta, plane: plane)
        base.blendTiled(tile, dx: offset.0, dy: offset.1)
        return base
    }

    /// 亮度平面的块均值极差，用来量化「有没有可见的亮度网格」
    private func lumaSpread(_ image: RGBAImage) -> Double {
        spread(image.featureBuffer(.luma))
    }

    private func chromaSpread(_ image: RGBAImage) -> Double {
        spread(image.featureBuffer(.chroma))
    }

    private func spread(_ feature: [Double]) -> Double {
        var means: [Double] = []
        let width = 512
        var y = 0
        while y + 8 <= 512 {
            var x = 0
            while x + 8 <= 512 {
                var sum = 0.0
                for row in 0..<8 {
                    for col in 0..<8 { sum += feature[(y + row) * width + x + col] }
                }
                means.append(sum / 64)
                x += 8
            }
            y += 8
        }
        guard let low = means.min(), let high = means.max() else { return 0 }
        return high - low
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
        let decoded = try XCTUnwrap(BlockCodec.decode(image, payloadBits: 32))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertGreaterThan(decoded.signal, 2.0)
        XCTAssertGreaterThan(decoded.confidence, 30)
    }

    func testBlackBackground() throws {
        let payload: UInt32 = 0x1234_ABCD
        let image = makeScreenshot(payload: payload) { $0.fill((0, 0, 0, 255)) }
        let decoded = try XCTUnwrap(BlockCodec.decode(image, payloadBits: 32))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertGreaterThan(decoded.signal, 2.0)
        XCTAssertGreaterThan(decoded.confidence, 30)
    }

    func testMidGrayBackground() throws {
        let payload: UInt32 = 0x0F0F_0F0F
        let image = makeScreenshot(payload: payload) { $0.fill((128, 128, 128, 255)) }
        let decoded = try XCTUnwrap(BlockCodec.decode(image, payloadBits: 32))
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
        let decoded = try XCTUnwrap(BlockCodec.decode(image, payloadBits: 32))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertGreaterThan(decoded.confidence, 2, "内容噪声下 z 值仍应明显为正")
    }

    // MARK: - 鲁棒性

    func testSurvivesJPEGQuality80() throws {
        let payload: UInt32 = 0x5A5A_0001
        let image = makeScreenshot(payload: payload) { $0.fill((240, 240, 240, 255)) }
        let compressed = try jpegRoundTrip(image, quality: 0.8)
        let decoded = try XCTUnwrap(BlockCodec.decode(compressed, payloadBits: 32))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertGreaterThan(decoded.confidence, 30)
    }

    func testSurvivesJPEGQuality60() throws {
        let payload: UInt32 = 0x5A5A_0002
        let image = makeScreenshot(payload: payload) { $0.fill((200, 200, 200, 255)) }
        let compressed = try jpegRoundTrip(image, quality: 0.6)
        let decoded = try XCTUnwrap(BlockCodec.decode(compressed, payloadBits: 32))
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
        let decoded = try XCTUnwrap(BlockCodec.decode(cropped, payloadBits: 32))
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
        let decoded = try XCTUnwrap(BlockCodec.decode(image, payloadBits: 32))
        XCTAssertEqual(decoded.payload, payload)
    }

    func testImageWithoutWatermarkHasLowConfidence() throws {
        // 不贴 tile，纯底图
        var plain = RGBAImage(width: 640, height: 900)
        plain.fill((255, 255, 255, 255))
        let decoded = try XCTUnwrap(BlockCodec.decode(plain, payloadBits: 32))
        XCTAssertLessThan(decoded.confidence, 2, "无水印画面不应给出高置信度")
    }

    /// 容量与余量都建立在这组几何常数上，钉住它，改块大小/ tile 大小会立刻炸出来。
    func testTileGeometryContract() {
        XCTAssertEqual(BlockCodec.blockSize, 8)
        XCTAssertEqual(BlockCodec.tileSize, 256)
        // (256/8/2) 个 pair 列 × (256/8) 个块行
        XCTAssertEqual(BlockCodec.pairsPerTile, 512)
        // iPhone 16 截图 1179x2556：(1179/8/2) × (2556/8) = 23287 个 pair
        // payloadBits = 32 → 每 bit 727 次观测；16 → 1455 次
    }

    // MARK: - 平面选择

    /// chroma 的卖点就是「亮度一个像素都没动」，也就是肉眼看不到亮度网格。
    /// 这里直接把不变量测出来：色度平面铺满了，亮度平面的块均值极差仍然是 0。
    func testChromaPreservesLumaOnFlatBackground() throws {
        let payload: UInt32 = 0xC0FF_EE01
        var base = RGBAImage(width: 512, height: 512)
        base.fill((250, 250, 250, 255))
        base.blendTiled(BlockCodec.makeTile(payload: payload, alpha: 8, plane: .chroma))

        XCTAssertLessThan(lumaSpread(base), 0.3, "chroma 模式几乎不改动亮度（预乘取整的残差）")
        XCTAssertGreaterThan(chromaSpread(base), 5, "色度平面应该确实被写入了")
    }

    func testLumaPlaneDoesChangeLuma() throws {
        var base = RGBAImage(width: 512, height: 512)
        base.fill((250, 250, 250, 255))
        base.blendTiled(BlockCodec.makeTile(payload: 0x1234_5678, alpha: 6, plane: .luma))

        XCTAssertGreaterThan(lumaSpread(base), 4, "luma 模式必然会留下亮度网格")
    }

    func testLumaPlaneStillDecodes() throws {
        let payload: UInt32 = 0x0BAD_F00D
        let image = makeScreenshot(payload: payload, plane: .luma) { $0.fill((255, 255, 255, 255)) }
        let decoded = try XCTUnwrap(BlockCodec.decode(image, payloadBits: 32, plane: .luma))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertGreaterThan(decoded.confidence, 30)
    }

    /// 彩色内容（照片）在色度平面上的噪声最大，这是 chroma 模式的坏情况。
    /// `chromaScale` 是色度结构的最小尺度：32px 接近真实照片，8px 是刻意与水印同频的对抗样本。
    private func colorfulScreenshot(payload: UInt32, chromaScale: Int) -> RGBAImage {
        makeScreenshot(payload: payload) { base in
            let width = base.width
            let gridW = width / chromaScale + 2
            let gridH = base.height / chromaScale + 2
            var noise = [Double](repeating: 0, count: gridW * gridH * 3)
            var seed: UInt64 = 0x2545_F491_4F6C_DD1D
            for i in 0..<noise.count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                noise[i] = Double(seed >> 33) / Double(UInt64.max >> 33)
            }
            for y in 0..<base.height {
                for x in 0..<width {
                    let gx = Double(x) / Double(chromaScale)
                    let gy = Double(y) / Double(chromaScale)
                    let x0 = Int(gx), y0 = Int(gy)
                    let fx = gx - Double(x0), fy = gy - Double(y0)
                    func sample(_ c: Int, _ xx: Int, _ yy: Int) -> Double {
                        noise[(min(yy, gridH - 1) * gridW + min(xx, gridW - 1)) * 3 + c]
                    }
                    let i = (y * width + x) * 4
                    for c in 0..<3 {
                        let top = sample(c, x0, y0) * (1 - fx) + sample(c, x0 + 1, y0) * fx
                        let bottom = sample(c, x0, y0 + 1) * (1 - fx) + sample(c, x0 + 1, y0 + 1) * fx
                        base.pixels[i + c] = UInt8(clamping: Int((top * (1 - fy) + bottom * fy) * 255))
                    }
                    base.pixels[i + 3] = 255
                }
            }
        }
    }

    func testChromaOnRealisticColorContent() throws {
        let payload: UInt32 = 0xCAFE_BABE
        let image = colorfulScreenshot(payload: payload, chromaScale: 32)
        let decoded = try XCTUnwrap(BlockCodec.decode(image, payloadBits: 32))
        XCTAssertEqual(decoded.payload, payload)
    }

    /// 对抗样本：色度结构恰好是 8px —— 和水印同一个空间频率。
    /// chroma 模式在这里必然退化，但**绝不能静默解错**：要么解不出原 payload，要么置信度低到会被判成 NO。
    func testChromaNeverSilentlyWrongOnAdversarialColorTexture() throws {
        let payload: UInt32 = 0xCAFE_BABE
        let image = colorfulScreenshot(payload: payload, chromaScale: 8)
        let decoded = try XCTUnwrap(BlockCodec.decode(image, payloadBits: 32))
        let silentlyWrong = decoded.payload != payload && decoded.confidence >= 3
        XCTAssertFalse(silentlyWrong, "解错了却给出高置信度（信心=\(decoded.confidence)）")
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

// MARK: - 128 bit 推荐布局

final class WatermarkPayloadTests: XCTestCase {
    private let keyHex = "00112233445566778899aabbccddeeff"

    private func makeKey() throws -> SymmetricKey {
        try XCTUnwrap(SymmetricKey(hex: keyHex))
    }

    func testPackUnpackRoundTrip() throws {
        let payload = WatermarkPayload(
            uid: 0xDEAD_BEEF,
            timestamp: 1_765_000_000,
            pageIndex: 5,
            tag: 1,
            key: try makeKey()
        )
        XCTAssertEqual(payload.bytes.count, WatermarkPayload.byteCount)
        let restored = try XCTUnwrap(WatermarkPayload(bytes: payload.bytes))
        XCTAssertEqual(restored, payload)
        XCTAssertTrue(restored.isValid(key: try makeKey()))
    }

    func testHexKeyRejectsGarbage() {
        XCTAssertNil(SymmetricKey(hex: "abc"))
        XCTAssertNil(SymmetricKey(hex: "zz"))
        XCTAssertNotNil(SymmetricKey(hex: "00ff"))
    }

    func testMACDetectsTampering() throws {
        let payload = WatermarkPayload(uid: 1, timestamp: 2, pageIndex: 3, tag: 4, key: try makeKey())
        var tampered = payload
        tampered.uid = 99
        XCTAssertFalse(tampered.isValid(key: try makeKey()), "改了字段 mac 必须校验不过")
    }

    func testMACChangesWithKey() throws {
        let a = WatermarkPayload(uid: 1, timestamp: 2, pageIndex: 3, tag: 4, key: try makeKey())
        let otherKey = try XCTUnwrap(SymmetricKey(hex: "ffeeddccbbaa99887766554433221100"))
        let b = WatermarkPayload(uid: 1, timestamp: 2, pageIndex: 3, tag: 4, key: otherKey)
        XCTAssertNotEqual(a.mac, b.mac)
    }

    /// 128 bit 载荷在推荐参数下的编解码回环：字段必须逐字节还原
    func test128BitRoundTripOnRealisticContent() throws {
        let payload = WatermarkPayload(
            uid: 0x0BAD_F00D,
            timestamp: 1_765_123_456,
            pageIndex: 3,
            tag: 7,
            key: try makeKey()
        )
        // helper 只收 UInt32，128 bit 直接铺字节版 tile
        var base = RGBAImage(width: 640, height: 900)
        var seed: UInt64 = 7
        for y in 0..<base.height {
            for x in 0..<base.width {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let v = UInt8(180 + (seed >> 60) % 60)
                let i = (y * base.width + x) * 4
                base.pixels[i] = v
                base.pixels[i + 1] = v
                base.pixels[i + 2] = v
                base.pixels[i + 3] = 255
            }
        }
        base.blendTiled(BlockCodec.makeTile(payload: payload.bytes))
        let decoded = try XCTUnwrap(BlockCodec.decode(base, payloadBits: 128))
        XCTAssertEqual(decoded.payloadBytes, payload.bytes)
        XCTAssertEqual(decoded.weakBits, 0)
        let restored = try XCTUnwrap(WatermarkPayload(bytes: decoded.payloadBytes))
        XCTAssertEqual(restored.uid, payload.uid)
        XCTAssertEqual(restored.timestamp, payload.timestamp)
        XCTAssertEqual(restored.pageIndex, payload.pageIndex)
        XCTAssertEqual(restored.tag, payload.tag)
        XCTAssertEqual(restored.mac, payload.mac)
    }

    // MARK: - magic 自检

    func testMagicEmbeddedByAppTagInit() {
        let p = WatermarkPayload(uid: 1, timestamp: 2, pageIndex: 3, appTag: 5, mac: 0)
        XCTAssertTrue(p.hasMagic, "appTag 构造应自动嵌入 magic")
        XCTAssertEqual(p.appTag, 5)
        XCTAssertEqual(p.tag >> 12, WatermarkPayload.magic)
    }

    func testMagicAbsentOnRawTagInit() {
        let p = WatermarkPayload(uid: 1, timestamp: 2, pageIndex: 3, tag: 4, mac: 0)
        XCTAssertFalse(p.hasMagic, "原始 tag: 构造不嵌入 magic，hasMagic 应为 false")
    }

    func testMagicRoundTripEncodeDecodeChroma() throws {
        let payload = WatermarkPayload(uid: 0xDEAD_BEEF, timestamp: 12345, pageIndex: 7, appTag: 3, mac: 0)
        XCTAssertTrue(payload.hasMagic)
        var base = RGBAImage(width: 640, height: 900)
        base.fill((200, 200, 200, 255))
        base.blendTiled(BlockCodec.makeTile(payload: payload.bytes))
        let decoded = try XCTUnwrap(BlockCodec.decode(base, payloadBits: 128))
        let restored = try XCTUnwrap(WatermarkPayload(bytes: decoded.payloadBytes))
        XCTAssertTrue(restored.hasMagic, "解码还原的载荷 magic 应通过")
        XCTAssertEqual(restored.uid, payload.uid)
        XCTAssertEqual(restored.appTag, payload.appTag)
        XCTAssertEqual(decoded.weakBits, 0)
    }

    func testFindBestOffsetReturnsCorrectPhase() throws {
        let payload: UInt32 = 0xCAFE_BABE
        // 用非零相位编码，auto-offset 应能找回
        let ox = 3, oy = 5
        var base = RGBAImage(width: 640, height: 900)
        base.fill((180, 180, 180, 255))
        let tile = BlockCodec.makeTile(payload: payload, payloadBits: 32)
        base.blendTiled(tile, dx: ox, dy: oy)
        let best = BlockCodec.findBestOffset(in: base, payloadBits: 32)
        let result = try XCTUnwrap(
            BlockCodec.decode(base, payloadBits: 32, offsetX: best.offsetX, offsetY: best.offsetY)
        )
        XCTAssertEqual(result.payload, payload, "auto-offset 找到最优相位后应能正确解码")
    }
}
