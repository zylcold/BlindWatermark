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
        // 纯色画面一个可用观测都没有。不能因为「非零 z 里没有小于 3 的」就报全部 bit 显著 ——
        // 那是把「没测到」当成「测得好」（历史 bug，已固化成断言）
        XCTAssertEqual(decoded.weakBits, 32, "没有观测的 bit 必须算证据不足")
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

// MARK: - 256 bit 推荐布局

final class WatermarkPayloadTests: XCTestCase {
    private let keyHex = "00112233445566778899aabbccddeeff"

    private func makeKey() throws -> SymmetricKey {
        try XCTUnwrap(SymmetricKey(hex: keyHex))
    }

    func testPackUnpackRoundTrip() throws {
        let payload = WatermarkPayload(
            uid: 0xDEAD_BEEF,
            timestamp: 1_765_000_000,
            build: 202609161722,
            pageClassName: "BHProfileViewController",
            note: "hotfix-3",
            app: 3,
            environment: 1,
            key: try makeKey()
        )
        XCTAssertEqual(payload.bytes.count, WatermarkPayload.byteCount)
        XCTAssertEqual(WatermarkPayload.byteCount, 64)
        XCTAssertEqual(WatermarkPayload.payloadBits, 512)
        let restored = try XCTUnwrap(WatermarkPayload(bytes: payload.bytes))
        XCTAssertEqual(restored, payload)
        XCTAssertTrue(restored.isValid(key: try makeKey()))
        XCTAssertEqual(restored.buildNumber, "202609161722", "build 必须原样 14 位十进制回环")
        XCTAssertEqual(restored.note, "hotfix-3")
        // note 现在是 22 字节
        let longNote = WatermarkPayload(uid: 1, timestamp: 1_760_000_000, build: 0,
                                        pageClassName: "BHProfileViewController",
                                        note: String(repeating: "x", count: 40), key: try makeKey())
        XCTAssertEqual(longNote.note?.count, WatermarkPayload.noteByteCount, "超长 note 截到 22 字节")
        XCTAssertEqual(restored.pageNameCode, "profile")
    }

    func testHexKeyRejectsGarbage() {
        XCTAssertNil(SymmetricKey(hex: "abc"))
        XCTAssertNil(SymmetricKey(hex: "zz"))
        XCTAssertNotNil(SymmetricKey(hex: "00ff"))
    }

    func testMACDetectsTampering() throws {
        let payload = WatermarkPayload(uid: 1, timestamp: 2, build: 202609161722, pageClassName: "BHProfileViewController", note: "n", app: 3, environment: 1, key: try makeKey())
        var tampered = payload
        tampered.uid = 99
        XCTAssertFalse(tampered.isValid(key: try makeKey()), "改了字段 mac 必须校验不过")
    }

    func testMACTamperOnAnySignedFieldIsCaught() throws {
        let base = WatermarkPayload(uid: 1, timestamp: 2, build: 202609161722, pageClassName: "BHProfileViewController", note: "n", app: 3, environment: 1, key: try makeKey())
        var cases: [WatermarkPayload] = []
        var a = base; a.uid = 9; cases.append(a)
        var b = base; b.timestamp = 9; cases.append(b)
        var e = base; e.build = 202601010101; cases.append(e)
        var c = base; c.pageCodeBytes[0] ^= 0x01; cases.append(c)
        var d = base; d.noteBytes[0] = 0x7A; cases.append(d)
        for tampered in cases {
            XCTAssertFalse(tampered.isValid(key: try makeKey()))
        }
        XCTAssertTrue(base.isValid(key: try makeKey()))
    }

    func testMACChangesWithKey() throws {
        let a = WatermarkPayload(uid: 1, timestamp: 2, build: 202609161722, pageClassName: "BHProfileViewController", note: "n", app: 3, environment: 1, key: try makeKey())
        let otherKey = try XCTUnwrap(SymmetricKey(hex: "ffeeddccbbaa99887766554433221100"))
        let b = WatermarkPayload(uid: 1, timestamp: 2, build: 202609161722, pageClassName: "BHProfileViewController", note: "n", app: 3, environment: 1, key: otherKey)
        XCTAssertNotEqual(a.mac, b.mac)
    }

    // MARK: - 公开自检值（无密钥部署）

    /// 自检载荷：没有密钥也能完成校验，但必须报成"未验签"
    func testSelfCheckValidatesWithoutKey() throws {
        let payload = WatermarkPayload.selfChecked(
            uid: 0x1234_5678,
            timestamp: 1_760_000_000,
            build: 202609161722,
            pageClassName: "BHProfileViewController",
            note: "hotfix-3",
            app: 1
        )
        XCTAssertEqual(payload.verification(key: nil), .selfChecked)
        XCTAssertEqual(payload.verification(key: try makeKey()), .selfChecked, "自检值不是 HMAC，换任何密钥都不该变成验签")
        XCTAssertFalse(payload.isValid(key: try makeKey()), "自检载荷不能冒充验签通过")
        XCTAssertTrue(payload.isPlausible)
    }

    /// `mac: []` 这种客户端自拼的载荷：必须报未签名，不能报 BAD（旧版会误报"密钥不符或被篡改"）
    func testUnsignedPayloadIsReportedAsUnsigned() throws {
        let payload = WatermarkPayload(uid: 7, timestamp: 1_760_000_000, build: 0, pageCodeBytes: PageNameCodec.encodeBytes("profile"), app: 0, environment: 0, noteBytes: [], mac: [])
        XCTAssertTrue(payload.isUnsigned)
        XCTAssertEqual(payload.verification(key: nil), .unsigned)
        XCTAssertEqual(payload.verification(key: try makeKey()), .unsigned)
        XCTAssertTrue(payload.isPlausible, "推荐布局下字段是自洽的")
    }

    /// 近似解（半块相位错位解出的那种东西）：自检值能拦，结构自检拦不住。
    /// 钉死这个差异 —— 它是 A 方案存在的全部理由，也是"结构自检只能当兵底"的依据。
    func testNearCopyAliasIsCaughtBySelfCheckOnly() throws {
        let payload = WatermarkPayload.selfChecked(
            uid: 0x1234_5678,
            timestamp: 1_760_000_000,
            build: 202609161722,
            pageClassName: "BHTextListViewController",
            note: "hotfix-3",
            app: 1
        )
        var alias = payload
        alias.uid ^= 0x0F  // 改 4 个 bit，结构字段一个不动
        XCTAssertEqual(alias.verification(key: nil), .failed, "自检值必须拦住近似解")
        XCTAssertTrue(alias.isPlausible, "结构自检看不出这个近似解")
    }

    /// 256 bit 载荷在推荐参数下的编解码回环：字段必须逐字节还原
    func test256BitRoundTripOnRealisticContent() throws {
        let payload = WatermarkPayload(
            uid: 0x0BAD_F00D,
            timestamp: 1_765_123_456,
            build: 202609161722,
            pageClassName: "BHProfileViewController",
            note: "hotfix-3",
            app: 3,
            key: try makeKey()
        )
        // helper 只收 UInt32，256 bit 直接铺字节版 tile
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
        let decoded = try XCTUnwrap(BlockCodec.decode(base, payloadBits: WatermarkPayload.payloadBits))
        XCTAssertEqual(decoded.payloadBytes, payload.bytes)
        XCTAssertEqual(decoded.weakBits, 0)
        let restored = try XCTUnwrap(WatermarkPayload(bytes: decoded.payloadBytes))
        XCTAssertEqual(restored.uid, payload.uid)
        XCTAssertEqual(restored.timestamp, payload.timestamp)
        XCTAssertEqual(restored.pageNameCode, payload.pageNameCode)
        XCTAssertEqual(restored.note, payload.note)
        XCTAssertEqual(restored.build, payload.build)
        XCTAssertEqual(restored.tag, payload.tag)
        XCTAssertEqual(restored.mac, payload.mac)
    }

    /// 给 MAC 校验器时，`findBestOffset` 必须返回一个能解出原载荷的相位。
    ///
    /// 平坦底色上「块对齐最好」的相位不止一个（错位相位把相邻块按同一比例线性混合，符号照样保住），
    /// 所以这里只断言解出来的东西 MAC 通过、字段原样 —— 这正是校验器存在的意义，不断言唯一相位。
    func testFindBestOffsetWithMACValidatorReturnsCorrectPhase() throws {
        let key = try makeKey()
        let payload = WatermarkPayload(
            uid: 0x0BAD_F00D,
            timestamp: 1_765_123_456,
            build: 202609161722,
            pageClassName: "BHProfileViewController",
            note: "hotfix-3",
            app: 3,
            key: key
        )
        var base = RGBAImage(width: 640, height: 900)
        base.fill((180, 180, 180, 255))
        base.blendTiled(BlockCodec.makeTile(payload: payload.bytes), dx: 3, dy: 5)

        // 真校验：MAC 通过就说明相位可用、载荷也是原样解回的，不是拿答案去比答案
        func validatesMAC(_ decoded: BlockCodec.Decoded) -> Bool {
            guard decoded.payloadBits == WatermarkPayload.payloadBits,
                  let fields = WatermarkPayload(bytes: decoded.payloadBytes) else { return false }
            return fields.isValid(key: key)
        }

        let best = BlockCodec.findBestOffset(in: base, validate: validatesMAC)
        XCTAssertTrue((0..<BlockCodec.blockSize).contains(best.offsetX))
        XCTAssertTrue((0..<BlockCodec.blockSize).contains(best.offsetY))

        let result = try XCTUnwrap(
            BlockCodec.decode(base, offsetX: best.offsetX, offsetY: best.offsetY)
        )
        XCTAssertTrue(validatesMAC(result), "选出的相位必须解出 MAC 通过的载荷")
        XCTAssertEqual(WatermarkPayload(bytes: result.payloadBytes), payload)
    }

    /// 校验器是**用来筛相位的**，不是摆设：只有 `oy == 5` 的相位通过时，
    /// 返回值必须落在 `oy == 5` 里，而不是裸 `medianAbsZ` argmax 的那一组。
    func testFindBestOffsetHonorsValidator() throws {
        let payload = WatermarkPayload(
            uid: 0x0BAD_F00D,
            timestamp: 1_765_123_456,
            build: 202609161722,
            pageClassName: "BHProfileViewController",
            note: "hotfix-3",
            app: 3,
            key: try makeKey()
        )
        var base = RGBAImage(width: 640, height: 900)
        base.fill((180, 180, 180, 255))
        base.blendTiled(BlockCodec.makeTile(payload: payload.bytes), dx: 3, dy: 5)

        // 前提：裸 argmax 选的不是 oy == 5。不成立这条测试就没意义，所以先断言前提。
        let unfiltered = BlockCodec.findBestOffset(in: base)
        XCTAssertNotEqual(unfiltered.offsetY, 5, "前提失效：裸 argmax 已经落在 oy == 5")

        let filtered = BlockCodec.findBestOffset(in: base, validate: { $0.offsetY == 5 })
        XCTAssertEqual(filtered.offsetY, 5)

        // 在通过校验的那一行里，仍是 |z| 中位最高的那个
        var rowBest = (offsetX: 0, offsetY: 5)
        var rowScore = -Double.infinity
        for ox in 0..<BlockCodec.blockSize {
            let decoded = try XCTUnwrap(BlockCodec.decode(base, offsetX: ox, offsetY: 5))
            if decoded.medianAbsZ > rowScore {
                rowScore = decoded.medianAbsZ
                rowBest = (ox, 5)
            }
        }
        XCTAssertEqual(filtered.offsetX, rowBest.offsetX)
    }

    /// 不传 `validate` 时 `findBestOffset` 就是纯 `medianAbsZ` argmax（含同分先到先得的顺序），
    /// 只保证块对齐最好 —— 这正是它必须配校验器用的原因，也是这条性质不能丢的原因。
    func testFindBestOffsetWithoutValidatorIsPureArgmax() throws {
        let payload = WatermarkPayload(
            uid: 0x0BAD_F00D,
            timestamp: 1_765_123_456,
            build: 202609161722,
            pageClassName: "BHProfileViewController",
            note: "hotfix-3",
            app: 3,
            key: try makeKey()
        )
        var base = RGBAImage(width: 640, height: 900)
        base.fill((180, 180, 180, 255))
        base.blendTiled(BlockCodec.makeTile(payload: payload.bytes), dx: 3, dy: 5)

        var expected = (offsetX: 0, offsetY: 0)
        var bestScore = -Double.infinity
        for oy in 0..<BlockCodec.blockSize {
            for ox in 0..<BlockCodec.blockSize {
                let decoded = try XCTUnwrap(BlockCodec.decode(base, offsetX: ox, offsetY: oy))
                if decoded.medianAbsZ > bestScore {
                    bestScore = decoded.medianAbsZ
                    expected = (ox, oy)
                }
            }
        }

        let best = BlockCodec.findBestOffset(in: base)
        XCTAssertEqual(best.offsetX, expected.offsetX)
        XCTAssertEqual(best.offsetY, expected.offsetY)
    }
}

// MARK: - 自动探测与页面注册表

final class AutoDecodeTests: XCTestCase {
    private let keyHex = "00112233445566778899aabbccddeeff"

    private func key() throws -> SymmetricKey {
        try XCTUnwrap(SymmetricKey(hex: keyHex))
    }

    private func shot(payload: [UInt8], plane: WatermarkPlane, offset: (Int, Int)) -> RGBAImage {
        var base = RGBAImage(width: 640, height: 900)
        var seed: UInt64 = 11
        for y in 0..<base.height {
            for x in 0..<base.width {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let v = UInt8(190 + (seed >> 60) % 50)
                let i = (y * base.width + x) * 4
                base.pixels[i] = v
                base.pixels[i + 1] = v
                base.pixels[i + 2] = v
                base.pixels[i + 3] = 255
            }
        }
        base.blendTiled(BlockCodec.makeTile(payload: payload, plane: plane), dx: offset.0, dy: offset.1)
        return base
    }

    private func makePayload() throws -> WatermarkPayload {
        WatermarkPayload(uid: 0x1234_5678, timestamp: 1_760_000_000, build: 202609161722, pageClassName: "BHProfileViewController", note: "hotfix-3", app: 1, key: try key())
    }

    /// 裁剪 + 相位未知 + 平面未指定：MAC 裁决必须命中唯一正确解
    func testAutoFindsOffsetPlaneAndBits() throws {
        let payload = try makePayload()
        let image = shot(payload: payload.bytes, plane: .chroma, offset: (5, 3))
        let decoded = try XCTUnwrap(BlockCodec.decodeBest(
            image,
            payloadBitsCandidates: [WatermarkPayload.payloadBits, 32],
            planes: [.chroma, .luma],
            searchPhase: true,
            validate: { [secret = try key()] candidate in
                guard candidate.payloadBits == WatermarkPayload.payloadBits,
                      let fields = WatermarkPayload(bytes: candidate.payloadBytes) else { return false }
                return fields.isValid(key: secret)
            }
        ))
        XCTAssertEqual(decoded.payloadBytes, payload.bytes)
        XCTAssertEqual(decoded.plane, WatermarkPlane.chroma)
        // 相位可能命中与真值等价的退化解：tile 内 bit 索引按 4 行一组重复，
        // 组内错位照样解出同一份载荷。MAC 校验通过即为正确答案，不苛求命中原始偏移。
        let fields = try XCTUnwrap(WatermarkPayload(bytes: decoded.payloadBytes))
        XCTAssertTrue(fields.isValid(key: try key()))
    }

    /// 没有校验器时，裸穷举可能命中错误相位 —— 这是已知限制，
    /// 但至少不能崩、不能给出弱得离谱的结果
    func testAutoWithoutValidatorStillDecodes() throws {
        let payload = try makePayload()
        let image = shot(payload: payload.bytes, plane: .chroma, offset: (0, 0))
        let decoded = try XCTUnwrap(BlockCodec.decodeBest(image, searchPhase: false))
        XCTAssertEqual(decoded.payloadBytes, payload.bytes, "无裁剪 + 相位(0,0) 下不应依赖运气")
    }

    private func crop(_ image: RGBAImage, top: Int, left: Int) -> RGBAImage {
        var out = RGBAImage(width: image.width - left, height: image.height - top)
        for y in 0..<out.height {
            for x in 0..<out.width {
                let si = ((y + top) * image.width + (x + left)) * 4
                let di = (y * out.width + x) * 4
                for c in 0..<4 { out.pixels[di + c] = image.pixels[si + c] }
            }
        }
        return out
    }

    /// 裁剪是真实工单里最常见的形态（截掉状态栏、分享时裁边）。
    /// 裁掉非 256 整数倍会让图案 tile 原点平移，载荷表现为整体旋转；
    /// 相位搜索只修块对齐，必须靠 tile 旋转穷举 + MAC 才能救回来。
    func testAutoSurvivesNonTileAlignedCrop() throws {
        let payload = try makePayload()
        let full = shot(payload: payload.bytes, plane: .chroma, offset: (0, 0))
        let cropped = crop(full, top: 137, left: 0)

        let seconds = try key()
        let decoded = try XCTUnwrap(BlockCodec.decodeBest(
            cropped,
            searchPhase: true,
            searchTile: true,
            validate: { candidate in
                guard candidate.payloadBits == WatermarkPayload.payloadBits,
                      let fields = WatermarkPayload(bytes: candidate.payloadBytes) else { return false }
                return fields.isValid(key: seconds)
            }
        ))
        XCTAssertEqual(decoded.payloadBytes, payload.bytes)
        let fields = try XCTUnwrap(WatermarkPayload(bytes: decoded.payloadBytes))
        XCTAssertEqual(fields.uid, payload.uid)
        XCTAssertEqual(fields.pageNameCode, payload.pageNameCode)
    }

    /// 横向裁剪同样是真实的形态（分享时裁左右、拼图裁边）。
    /// 横向平移在 tile 右边界回卷到本行第 0 列，按线性索引加偏移会跨行（见 `BlockCodec.fold`），
    /// 只有 1/16 的观测错位 —— z 值照样漂亮、MAC 才看得出来，所以必须固化成回归测试。
    func testAutoSurvivesHorizontalCrop() throws {
        let payload = try makePayload()
        let full = shot(payload: payload.bytes, plane: .chroma, offset: (0, 0))
        let secret = try key()

        // 16 = 整个 pair；24 = 一个半 pair（块网格能对齐、配对跨了两个 pair）；
        // 40 = 两 pair 加一个块。三种都必须是 MAC 校验通过的正确载荷。
        for left in [16, 24, 40] {
            let cropped = crop(full, top: 0, left: left)
            let decoded = try XCTUnwrap(BlockCodec.decodeBest(
                cropped,
                searchPhase: true,
                searchTile: true,
                validate: { candidate in
                    guard candidate.payloadBits == WatermarkPayload.payloadBits,
                          let fields = WatermarkPayload(bytes: candidate.payloadBytes) else { return false }
                    return fields.isValid(key: secret)
                }
            ), "left=\(left) 应能靠 tile 平移搜出来")
            XCTAssertEqual(decoded.payloadBytes, payload.bytes, "left=\(left) 解出的载荷不对")
        }
    }

    /// 无密钥 + 裁剪：载荷只要带了公开自检值，就不需要密钥也能完成裁剪自愈。
    /// 旧的"无 key 只能按 |z| 中位猜"在这批用例上实测 0/20 正确 —— 钉住新行为。
    func testAutoSurvivesCropWithoutKeyWhenSelfChecked() throws {
        let payload = WatermarkPayload.selfChecked(
            uid: 0x1234_5678,
            timestamp: 1_760_000_000,
            build: 202609161722,
            pageClassName: "BHTextListViewController",
            note: "hotfix-3",
            app: 1
        )
        let full = shot(payload: payload.bytes, plane: .chroma, offset: (0, 0))
        // 严格校验器：验签或自检值通过。跟 CLI 里的 validValidator 同语义
        let validate: (BlockCodec.Decoded) -> Bool = { decoded in
            guard decoded.payloadBits == WatermarkPayload.payloadBits,
                  let fields = WatermarkPayload(bytes: decoded.payloadBytes) else { return false }
            switch fields.verification(key: nil) {
            case .signed, .selfChecked: return true
            case .unsigned, .failed: return false
            }
        }
        for (left, top) in [(0, 137), (0, 400), (8, 0), (16, 0), (24, 0), (40, 0), (16, 400)] {
            let decoded = try XCTUnwrap(BlockCodec.decodeBest(
                crop(full, top: top, left: left),
                planes: [.chroma],
                searchPhase: true,
                searchTile: true,
                validate: validate
            ), "left=\(left) top=\(top) 应能靠自检值解出来")
            XCTAssertEqual(decoded.payloadBytes, payload.bytes, "left=\(left) top=\(top) 解出的载荷不对")
        }
    }

    /// 横向裁剪量是**奇数个块**时，解码端默认配的是跨两个 pattern pair 的块对，
    /// 读出来是相邻两 bit 的和（只有两位相同时才留下观测）—— 信号弱一截。
    /// 多搜一档 block 奇偶（`searchPairOffset`）后重新读到真正的 pair，|z| 回到和偶数块裁剪一样。
    /// 真实截图（文字页裁 40px）上卡的就是这条：实测带上奇偶档后 20/20 个裁剪用例全对。
    func testPairOffsetRecoversOddBlockCrops() throws {
        let payload = WatermarkPayload.selfChecked(
            uid: 0x1234_5678,
            timestamp: 1_760_000_000,
            build: 202609161722,
            pageClassName: "BHTextListViewController",
            note: "hotfix-3",
            app: 1
        )
        let full = shot(payload: payload.bytes, plane: .chroma, offset: (0, 0))
        let validate: (BlockCodec.Decoded) -> Bool = { decoded in
            guard decoded.payloadBits == WatermarkPayload.payloadBits,
                  let fields = WatermarkPayload(bytes: decoded.payloadBytes) else { return false }
            switch fields.verification(key: nil) {
            case .signed, .selfChecked: return true
            case .unsigned, .failed: return false
            }
        }

        // 偶数块裁剪（16px）作为基准：这是"配对了"的 |z|
        let aligned = try XCTUnwrap(BlockCodec.decodeBest(
            crop(full, top: 0, left: 16), planes: [.chroma], searchPhase: true, validate: validate
        ))

        for left in [8, 24, 40] {  // 奇数个块 = 半对错位
            let plain = try XCTUnwrap(BlockCodec.decodeBest(
                crop(full, top: 0, left: left), planes: [.chroma], searchPhase: true, validate: validate
            ))
            let parity = try XCTUnwrap(BlockCodec.decodeBest(
                crop(full, top: 0, left: left), planes: [.chroma], searchPhase: true,
                searchPairOffset: true, validate: validate
            ))
            XCTAssertEqual(plain.payloadBytes, payload.bytes, "left=\(left) 常规搜索也要能解对")
            XCTAssertEqual(parity.payloadBytes, payload.bytes, "left=\(left) 奇偶档解出的载荷不对")
            XCTAssertGreaterThan(parity.medianAbsZ, plain.medianAbsZ, "left=\(left) 奇偶档应读到真正的 pair")
            XCTAssertEqual(parity.medianAbsZ, aligned.medianAbsZ, accuracy: 0.1,
                           "left=\(left) 奇偶档的 |z| 应与偶数块裁剪持平")
        }
    }

    /// 只搜相位不搜旋转，裁过的图必然解错 —— 固化这个失败模式，防止有人把旋转搜索删掉
    func testPhaseSearchAloneIsNotEnoughAfterCrop() throws {
        let payload = try makePayload()
        let full = shot(payload: payload.bytes, plane: .chroma, offset: (0, 0))
        let cropped = crop(full, top: 137, left: 0)
        let decoded = try XCTUnwrap(BlockCodec.decodeBest(
            cropped,
            searchPhase: true,
            searchTile: false,
            validate: { _ in false }
        ))
        XCTAssertNotEqual(decoded.payloadBytes, payload.bytes, "不搜旋转时本来就会解错；能解对说明测试构造失效了")
    }

    func testPageRegistryMatchesByCode() throws {
        var registry = PageRegistry(names: [])
        registry.register("BHLoginViewController")
        registry.register("BHChatListViewController")
        registry.register("BHProfileViewController")
        registry.register("BHLoginViewController")
        XCTAssertEqual(registry.names.count, 3, "重复登记必须幂等")

        XCTAssertEqual(registry.matches(code: PageNameCodec.code(for: "BHProfileViewController")), ["BHProfileViewController"])
        XCTAssertTrue(registry.matches(code: "zzzz").isEmpty)

        let data = try XCTUnwrap(registry.jsonData)
        let restored = try XCTUnwrap(PageRegistry(data: data))
        XCTAssertEqual(restored, registry)
    }

    /// 注册表按类名归一化匹配，因此换版本不会像索引方案那样整体错位
    func testRegistrySurvivesVersionDrift() throws {
        let old = PageRegistry(names: ["BHProfileViewController", "BHOrderViewController"])
        let new = PageRegistry(names: ["BHOrderViewController", "BHProfileViewController", "BHNewFeatureViewController"])
        let code = PageNameCodec.code(for: "BHProfileViewController")
        XCTAssertEqual(old.matches(code: code), new.matches(code: code))
    }

    func testPageRegistryRejectsGarbage() {
        XCTAssertNil(PageRegistry(data: Data("[1,2,3]".utf8)))
        XCTAssertNil(PageRegistry(data: Data("{}".utf8)))
    }
}

// MARK: - 类名短码

final class PageNameCodecTests: XCTestCase {
    func testStripsRedundantSuffixAndPrefix() {
        XCTAssertEqual(PageNameCodec.code(for: "BHProfileViewController"), "profile")
        XCTAssertEqual(PageNameCodec.code(for: "BHChatListViewController"), "chatlist")
        XCTAssertEqual(PageNameCodec.code(for: "BHLiveRoomViewController"), "liveroom")
        XCTAssertEqual(PageNameCodec.code(for: "BHLoginViewController"), "login")
        XCTAssertEqual(PageNameCodec.code(for: "JYOrderDetailViewController"), "orderdetail")
    }

    func testHandlesPlainAndExoticNames() {
        // 名字就是后缀时会被剥成空，于是退而剥短一档的 "Controller"，剩 "View"
        XCTAssertEqual(PageNameCodec.code(for: "ViewController"), "view")
        XCTAssertEqual(PageNameCodec.code(for: "VC"), "vc", "剥到空则保留原名")
        XCTAssertEqual(PageNameCodec.code(for: "Module.BHProfileViewController"), "profile", "模块前缀要丢掉")
        XCTAssertEqual(PageNameCodec.code(for: "BHUser_Profile_VC"), "userprofile", "下划线不参与短码")
        XCTAssertEqual(PageNameCodec.code(for: ""), "")
    }

    func testShortNamePads() {
        XCTAssertEqual(PageNameCodec.decodeBytes(PageNameCodec.encodeBytes("ab")), "ab")
        XCTAssertEqual(PageNameCodec.code(for: "BHVC"), "bh")
    }

    /// 120 bit / 20 字符：短码 → 15 字节 → 短码必须逐字符回环
    func testEncodeDecodeRoundTrip() {
        for name in ["BHProfileViewController", "BHChatListViewController", "JYOrderDetailViewController",
                     "ABC", "ViewController", "x", ""] {
            let code = PageNameCodec.code(for: name)
            let bytes = PageNameCodec.encodeBytes(code)
            XCTAssertEqual(bytes.count, 12, "15 字符 × 6 bit = 90 bit，字段 12 字节")
            XCTAssertEqual(PageNameCodec.decodeBytes(bytes), code, name)
            XCTAssertTrue(PageNameCodec.validateBytes(bytes), "\(name) 的短码必须全部落在 37 符号表内")
        }
    }

    /// 15 字符：大多数类名剥完冗余词缀后正好装得下，agent 可以直接按短码找到类
    func testLongNamesFitFifteenCharacters() {
        XCTAssertEqual(PageNameCodec.code(for: "BHUserProfileEditViewController"), "userprofileedit")
        XCTAssertEqual(PageNameCodec.code(for: "BHUserProfileEditViewController").count, 15)
    }

    /// 15 字符只用 90 bit，字段有 96 bit —— 填充位必须为 0，结构自检会查（白拿 6 bit 判别力）
    func testValidateBytesRejectsNonZeroPadding() {
        var bytes = PageNameCodec.encodeBytes(PageNameCodec.code(for: "BHProfileViewController"))
        XCTAssertTrue(PageNameCodec.validateBytes(bytes))
        bytes[11] |= 0x40
        XCTAssertFalse(PageNameCodec.validateBytes(bytes), "未使用区被置 1 必须拒绝")
    }

    /// 37 符号表以外的 6-bit 值必须被结构自检拒掉（这是自检的判别力来源之一）
    func testValidateBytesRejectsOutOfAlphabet() {
        var bytes = PageNameCodec.encodeBytes(PageNameCodec.code(for: "BHProfileViewController"))
        bytes[0] = 0x3F  // 63 > 36，非法
        XCTAssertFalse(PageNameCodec.validateBytes(bytes))
    }

    /// 4 字符时 1000 个页面撞名概率 23%（生日问题），扩到 10 字符后这批名字必须互不相同
    func testCommonNamesDoNotCollide() {
        let names = [
            "BHProfileViewController", "BHChatListViewController", "BHLiveRoomViewController",
            "BHLoginViewController", "BHOrderViewController", "BHPayCenterViewController",
            "BHUserDetailViewController", "BHSearchViewController", "BHMatchViewController",
            "BHSettingsViewController", "BHFeedbackViewController", "BHPhotoGridViewController",
            "BHDarkModeViewController", "BHMixedFeedViewController", "BHTextListViewController",
            "BHWhiteChatViewController", "BHPlainViewController",
        ]
        let codes = names.map { PageNameCodec.code(for: $0) }
        XCTAssertEqual(Set(codes).count, names.count, "这批名字不应互撞：\(codes)")
    }

    func testGrepHintCarriesCode() {
        XCTAssertTrue(PageNameCodec.grepHint(forCode: "chatlist").contains("chatlist"))
    }
}
