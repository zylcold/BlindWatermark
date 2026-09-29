import XCTest
@testable import BlindWatermarkCore

final class StripWatermarkTests: XCTestCase {

    func testBitsLayoutGoldenVector() {
        // uid=124914474, minuteOffset=389398（2026-09-28 09:58 UTC）
        let bits = StripWatermark.bits(uid: 124914474, minuteOffset: 389_398)
        XCTAssertEqual(bits.count, 76)
        XCTAssertEqual(Array(bits.prefix(4)), [true, false, true, true], "同步标记 1011")
        var uid: UInt32 = 0
        for i in 0..<32 where bits[4 + i] { uid |= 1 << UInt32(31 - i) }
        XCTAssertEqual(uid, 124_914_474)
        var mins: UInt32 = 0
        for i in 0..<24 where bits[36 + i] { mins |= 1 << UInt32(23 - i) }
        XCTAssertEqual(mins, 389_398)
        XCTAssertEqual(StripWatermark.crc16(Array(bits[4..<60])), Array(bits[60..<76]), "CRC16 自洽")
    }

    func testCRC16CCITTFALSE() {
        // "123456789" CRC-16/CCITT-FALSE = 0x29B1
        let body = "123456789".data(using: .ascii)!.map { byte -> [Bool] in
            (0..<8).map { (byte >> UInt8(7 - $0)) & 1 == 1 }
        }.flatMap { $0 }
        let crc = StripWatermark.crc16(body)
        var v: UInt16 = 0
        for b in crc { v = UInt16(truncatingIfNeeded: (UInt32(v) << 1) | (b ? 1 : 0)) }
        XCTAssertEqual(v, 0x29B1)
    }

    func testRenderDecodeRoundtripTopAndBottom() {
        let bits = StripWatermark.bits(uid: 124_914_474, minuteOffset: 389_398)
        var image = RGBAImage(width: 1320, height: 2868)
        StripWatermark.render(into: &image, bits: bits, blockWidthPx: 16, stripHeightPx: 3, edge: .top)
        StripWatermark.render(into: &image, bits: bits, blockWidthPx: 16, stripHeightPx: 3, edge: .bottom)
        let decoded = StripWatermark.decode(image: image)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.uid, 124_914_474)
        XCTAssertEqual(decoded?.minuteOffset, 389_398)
        XCTAssertEqual(decoded?.fixedBits, 0)
    }

    func testDecodeOnlyBottomEdge() {
        // 顶部被裁掉（模拟 IM 裁切），底部条仍可解
        let bits = StripWatermark.bits(uid: 42, minuteOffset: 7)
        var image = RGBAImage(width: 1320, height: 2000)
        StripWatermark.render(into: &image, bits: bits, blockWidthPx: 16, stripHeightPx: 3, edge: .bottom)
        let decoded = StripWatermark.decode(image: image)
        XCTAssertEqual(decoded?.uid, 42)
        XCTAssertEqual(decoded?.minuteOffset, 7)
        XCTAssertEqual(decoded?.edge, .bottom)
    }

    func testSubpixelBlockWidthAfterScale() {
        // 0.969 缩放后块宽 ≈15.58：直接按 15.58 渲染验证亚像素网格命中
        let bits = StripWatermark.bits(uid: 987_654_321, minuteOffset: 123_456)
        var image = RGBAImage(width: 1279, height: 2781)
        StripWatermark.render(into: &image, bits: bits, blockWidthPx: 15.58, stripHeightPx: 3, edge: .top)
        let decoded = StripWatermark.decode(image: image)
        XCTAssertEqual(decoded?.uid, 987_654_321)
        XCTAssertEqual(decoded?.minuteOffset, 123_456)
        XCTAssertEqual(decoded?.edge, .top)
    }

    func testNoStripReturnsNil() {
        var image = RGBAImage(width: 1320, height: 2868)
        for i in 0..<image.pixels.count { image.pixels[i] = 200 }
        XCTAssertNil(StripWatermark.decode(image: image))
    }

    func testPayloadBridgeUsesMinuteTruncation() {
        let payload = WatermarkPayload(
            uid: 5, timestampOffset: 61, buildMinuteOffset: 1, pageCode: "abcdefgh", app: 11
        )
        // 61 秒向下取整为 1 分钟
        let bits = StripWatermark.bits(payload: payload!)
        var mins: UInt32 = 0
        for i in 0..<24 where bits[36 + i] { mins |= 1 << UInt32(23 - i) }
        XCTAssertEqual(mins, 1)
    }
}
