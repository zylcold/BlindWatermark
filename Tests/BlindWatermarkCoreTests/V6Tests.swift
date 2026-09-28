import XCTest
import ImageIO
@testable import BlindWatermarkCore

final class V6Tests: XCTestCase {
    private let payload = WatermarkPayload(uid: 3735928559, timestampOffset: 23439179,
        buildMinuteOffset: 381210, pageCode: "secabout", app: 11)!

    private func shot(width: Int = 1242, height: Int = 2688) -> RGBAImage {
        var image = RGBAImage(width: width, height: height)
        image.fill((245, 245, 245, 255))
        image.blendTiled(V6Codec.makeTile(payload: payload))
        return image
    }

    func testGoldenPayloadAndBCH() throws {
        XCTAssertEqual(payload.bytes.map { String(format: "%02x", $0) }.joined(),
                       "f6eedbeabd745a16d0882e50bbbc36826c0140066fc77c18a80700")
        let word = V6BCH.encode(messageBytes: payload.bytes)
        XCTAssertEqual(word.map { String(format: "%02x", $0) }.joined(),
                       "f35516606e2084c0f65f6715ebd4a06fd1e5b9786cf706584579cacc15a1e9256ecc02d0f56fefbeadde4ba765018de802b5cb6b23c8160064f076cc87817a00")
        XCTAssertEqual(V6BCH.decode(codewordBytes: word)?.messageBytes, payload.bytes)
    }

    func testFortyErrorsAndIndependentParity() throws {
        let word = V6BCH.encode(messageBytes: payload.bytes)
        for count in [1, 6, 18, 40] {
            for seed in 0..<5 {
                var damaged = word
                for i in 0..<count {
                    let index = (i * 13 + seed * 37) % 511
                    damaged[index >> 3] ^= 1 << UInt8(index & 7)
                }
                damaged[63] ^= 0x80
                let result = try XCTUnwrap(V6BCH.decode(codewordBytes: damaged))
                XCTAssertEqual(result.messageBytes, payload.bytes)
                XCTAssertEqual(result.correctedBits, count + 1)
            }
        }
    }

    func testPayloadRejectsWrongVersionCRCReservedAndPadding() {
        for bit in [0, 50, 179, 203, 207, 210, 211, 215] {
            var bytes = payload.bytes
            bytes[bit >> 3] ^= 1 << UInt8(bit & 7)
            XCTAssertNil(WatermarkPayload(bytes: bytes), "bit=\(bit)")
        }
        XCTAssertNil(WatermarkPayload(uid: 1, timestampOffset: 0, buildMinuteOffset: 0,
                                     pageCode: "toolonggg", noteCode: ""))
        XCTAssertNil(WatermarkPayload(uid: 1, timestampOffset: 0, buildMinuteOffset: 0,
                                     pageCode: "ok", noteCode: "abcdefg"))
        XCTAssertEqual(PageNameCodec.code(for: "Module.BHUserProfileViewController"), "userprof")
        XCTAssertEqual(WatermarkPayload(uid: 1, timestampOffset: 0, buildMinuteOffset: 0,
                                       pageCode: "a_", noteCode: "x_")?.note, "x")
        XCTAssertNil(WatermarkPayload.decodeBase37(37 * 37, length: 2))
    }

    func testMaximumFieldsAndStrictCodeWidths() throws {
        let maximum = try XCTUnwrap(WatermarkPayload(uid: .max, timestampOffset: 0x7FFF_FFFF,
            buildMinuteOffset: 0xFF_FFFF, pageCode: "a_z09xyz", app: 9999, noteCode: "z9_a0b"))
        XCTAssertEqual(WatermarkPayload(bytes: maximum.bytes), maximum)
        XCTAssertEqual(V6BCH.decode(codewordBytes: V6BCH.encode(messageBytes: maximum.bytes))?.messageBytes, maximum.bytes)
        XCTAssertNil(WatermarkPayload(uid: 1, timestampOffset: 0, buildMinuteOffset: 0,
                                     pageCode: "ok", noteCode: "abcdef_"))
        XCTAssertNil(WatermarkPayload(uid: 1, timestampOffset: 0, buildMinuteOffset: 0,
                                     pageCode: "ok", app: 10000))
    }

    func testOffGridResizeAndZeroSignalObservation() throws {
        let source = shot()
        for scale in [0.837, 1.173] {
            let width = Int((Double(source.width) * scale).rounded())
            let height = Int((Double(source.height) * scale).rounded())
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .high
            context.draw(try XCTUnwrap(source.makeCGImage()), in: CGRect(x: 0, y: 0, width: width, height: height))
            let image = try XCTUnwrap(RGBAImage(cgImage: try XCTUnwrap(context.makeImage())))
            let result = try XCTUnwrap(V6Codec.decodeBest(image, scales: [scale]))
            XCTAssertEqual(result.payload, payload)
            XCTAssertTrue(result.hasSufficientEvidence)
        }
        // 数据 cell 的信号归零时面积仍存在，但 BCH/CRC 必须阻止“只凭计数”放行。
        var pilotOnly = shot()
        for y in 0..<pilotOnly.height {
            for x in 0..<pilotOnly.width where (x / V6Codec.cellWidth) % V6Codec.columns < V6Codec.dataColumns {
                let index = (y * pilotOnly.width + x) * 4
                pilotOnly.pixels[index] = 245
                pilotOnly.pixels[index + 1] = 245
                pilotOnly.pixels[index + 2] = 245
            }
        }
        XCTAssertNil(V6Codec.decode(pilotOnly))
    }

    func testPremultipliedConstantAlphaAndInterleaver() {
        let tile = V6Codec.makeTile(payload: payload)
        XCTAssertEqual(Set((0..<512).map(V6Codec.codeIndex)).count, 512)
        XCTAssertEqual(Set((512..<1024).map(V6Codec.codeIndex)).count, 512)
        XCTAssertEqual(V6Codec.pilotBits.filter { $0 }.count, 32)
        for i in stride(from: 0, to: tile.pixels.count, by: 4) {
            XCTAssertEqual(tile.pixels[i + 3], 4)
            XCTAssertLessThanOrEqual(tile.pixels[i], tile.pixels[i + 3])
            XCTAssertLessThanOrEqual(tile.pixels[i + 1], tile.pixels[i + 3])
            XCTAssertLessThanOrEqual(tile.pixels[i + 2], tile.pixels[i + 3])
        }
    }

    func testJPEGAndCropping() throws {
        let source = shot()
        for quality in [0.8, 0.6] {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(source.makeCGImage()),
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let reader = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
            let image = try XCTUnwrap(RGBAImage(cgImage: try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))))
            let result = try XCTUnwrap(V6Codec.decode(image))
            XCTAssertEqual(result.payload, payload)
            XCTAssertTrue(result.hasSufficientEvidence)
        }
        let cg = try XCTUnwrap(source.makeCGImage()?.cropping(to: CGRect(x: 13, y: 117, width: 1206, height: 1542)))
        let image = try XCTUnwrap(RGBAImage(cgImage: cg))
        let result = try XCTUnwrap(V6Codec.decodeBest(image, scales: [1]))
        XCTAssertEqual(result.payload, payload)
        XCTAssertTrue(result.hasSufficientEvidence)
    }

    func testInsufficientEvidenceAndNegativeOffsets() throws {
        let small = shot(width: V6Codec.tileWidth, height: V6Codec.tileHeight)
        let decoded = try XCTUnwrap(V6Codec.decode(small))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertFalse(decoded.hasSufficientEvidence)
        XCTAssertNil(V6Codec.decode(small, offsetX: -1))
        XCTAssertNil(V6Codec.decode(small, scale: .nan))
        var plain = RGBAImage(width: 640, height: 900)
        plain.fill((255, 255, 255, 255))
        XCTAssertNil(V6Codec.decodeBest(plain, scales: [1]))
    }

    func testScaleBoundariesAndPaddingEvidence() throws {
        let small = shot(width: V6Codec.tileWidth, height: V6Codec.tileHeight)
        for scale in [0, -1, Double.nan, .infinity, 1e-320, 0.499, 1.501] {
            XCTAssertNil(V6Codec.decode(small, scale: scale))
        }
        for color: UInt8 in [0, 40, 245, 255] {
            var framed = RGBAImage(width: 1632, height: 1536)
            framed.fill((color, color, color, 255))
            for row in 0..<small.height {
                let destination = ((row + 512) * framed.width + 544) * 4
                let source = row * small.width * 4
                framed.pixels.replaceSubrange(destination..<(destination + small.width * 4),
                    with: small.pixels[source..<(source + small.width * 4)])
            }
            let result = try XCTUnwrap(V6Codec.decode(framed, searchTile: true))
            XCTAssertEqual(result.payload, payload)
            XCTAssertEqual(result.minObservations, 2)
            XCTAssertFalse(result.hasSufficientEvidence)
        }
    }

    func testChaseRanksIndividualCandidates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("docs/samples/v6-photo-chase-ranking.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(RGBAImage(cgImage: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))))
        let result = try XCTUnwrap(V6Codec.decodeBest(image, scales: [1]))
        XCTAssertEqual(result.payload?.bytes.map { String(format: "%02x", $0) }.joined(),
                       "f6eedbeaadad4616b0852fa0fbf9b17f2a0040066fc75428010700")
        XCTAssertTrue(result.softRecoveryUsed)
        XCTAssertEqual(result.correctedBits, 42)
        XCTAssertTrue(result.hasSufficientEvidence)
    }

    func testAmbiguousCandidatesAreRejected() throws {
        let ctx = V6Codec.Context(stats: .init(), scale: 1, x: 0, y: 0, shifts: [])
        let other = WatermarkPayload(uid: 1, timestampOffset: 0, buildMinuteOffset: 0, pageCode: "other")!
        func candidate(_ p: WatermarkPayload) -> V6Codec.Candidate {
            .init(payload: p, correctedBits: 0, soft: false, context: ctx, shiftX: 0, shiftY: 0,
                  pilot: 1, minObs: 20, avgObs: 20, medianZ: 30)
        }
        let result = try XCTUnwrap(V6Codec.adjudicate([candidate(payload), candidate(other)]))
        XCTAssertTrue(result.ambiguous)
        XCTAssertNil(result.payload)
        XCTAssertEqual(V6Codec.adjudicate([candidate(payload), candidate(payload)])?.candidateCount, 1)
    }
}
