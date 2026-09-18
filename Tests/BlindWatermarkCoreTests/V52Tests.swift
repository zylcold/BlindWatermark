import Foundation
import XCTest
@testable import BlindWatermarkCore

final class V52Tests: XCTestCase {
    private let payload = WatermarkPayloadV52(
        uid: 0x1234_5678,
        timestampOffset: 1_234_567,
        buildMinuteOffset: 89_012,
        pageCode: "profile",
        app: 42,
        noteCode: "hotfix"
    )!

    func testPayloadAndBCHGoldenVectors() throws {
        let payloadBytes = payload.bytes
        XCTAssertEqual(
            payloadBytes.map { String(format: "%02x", $0) }.joined(),
            "8167452371682d01a0dd0a50ffa86faf4a0520236ff49078f702"
        )
        let codeword = V52BCH.encode(messageBytes: payloadBytes)
        XCTAssertEqual(
            codeword.map { String(format: "%02x", $0) }.joined(),
            "dbf79d8bb6998167452371682d01a0dd0a50ffa86faf4a0520236ff49078f782"
        )
        let restored = try XCTUnwrap(V52BCH.decode(codewordBytes: codeword))
        XCTAssertEqual(restored.messageBytes, payloadBytes)
        XCTAssertEqual(restored.correctedBits, 0)
        XCTAssertEqual(try XCTUnwrap(WatermarkPayloadV52(bytes: restored.messageBytes)), payload)
    }

    func testBCHCorrectsZeroThroughSixErrorsAndRejectsSeven() throws {
        var seed: UInt64 = 0xD1B5_4A32_91E7_0C5D
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed
        }
        for errorCount in 0...6 {
            var message = [UInt8](repeating: 0, count: V52BCH.messageByteCount)
            for index in message.indices { message[index] = UInt8(truncatingIfNeeded: next() >> 17) }
            message[message.count - 1] &= 0x7F // only 207 information bits are meaningful
            let codeword = V52BCH.encode(messageBytes: message)
            var damaged = codeword
            var positions = Set<Int>()
            while positions.count < errorCount { positions.insert(Int(next() % 256)) }
            for position in positions { damaged[position >> 3] ^= 1 << UInt8(position & 7) }
            let decoded = try XCTUnwrap(V52BCH.decode(codewordBytes: damaged), "errors=\(errorCount)")
            XCTAssertEqual(decoded.messageBytes, message)
            XCTAssertEqual(decoded.correctedBits, errorCount)
        }

        var sevenMessage = [UInt8](repeating: 0xA5, count: V52BCH.messageByteCount)
        sevenMessage[sevenMessage.count - 1] &= 0x7F // bit 207 is protocol padding
        var seven = V52BCH.encode(messageBytes: sevenMessage)
        for position in 0..<7 { seven[position >> 3] ^= 1 << UInt8(position & 7) }
        XCTAssertNil(V52BCH.decode(codewordBytes: seven), "t=6 不保证 7 bit，不能未经校验报成功")
    }

    func testPayloadRejectsPaddingReservedAndCRCTampering() throws {
        var padding = payload.bytes
        padding[padding.count - 1] |= 0x80
        XCTAssertNil(WatermarkPayloadV52(bytes: padding))

        var reserved = payload.bytes
        reserved[25] |= 1 << 6 // bit 206, the high reserved bit
        XCTAssertNil(WatermarkPayloadV52(bytes: reserved))

        var crc = payload.bytes
        crc[0] ^= 1
        XCTAssertNil(WatermarkPayloadV52(bytes: crc))
        XCTAssertNil(WatermarkPayloadV52.encodeBase37("a_", length: 0))
        XCTAssertEqual(WatermarkPayloadV52.decodeBase37(
            try XCTUnwrap(WatermarkPayloadV52.encodeBase37("a_", length: 8)), length: 8
        ), "a")
    }

    func testV52RoundTripWithPremultipliedChromaAndOddCropPhase() throws {
        var image = RGBAImage(width: 640, height: 900)
        image.fill((200, 200, 200, 255))
        image.blendTiled(V52Codec.makeTile(payload: payload, alpha: 8, plane: .chroma), dx: 3, dy: 5)
        let decoded = try XCTUnwrap(V52Codec.decode(
            image,
            plane: .chroma,
            sync: .none,
            scale: 1,
            offsetX: 3,
            offsetY: 5,
            searchTile: true
        ))
        XCTAssertTrue(decoded.isSuccess)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.correctedBits, 0)
        XCTAssertEqual(decoded.candidateCount, 1)
    }

    func testV52ExplicitResizeAndNegativeSample() throws {
        var source = RGBAImage(width: 640, height: 900)
        source.fill((200, 200, 200, 255))
        source.blendTiled(V52Codec.makeTile(payload: payload, alpha: 8, plane: .chroma), dx: 0, dy: 0)
        let scale = 0.837
        let width = Int(Double(source.width) * scale)
        let height = Int(Double(source.height) * scale)
        var resized = RGBAImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let sourceX = min(source.width - 1, Int(Double(x) / scale))
                let sourceY = min(source.height - 1, Int(Double(y) / scale))
                let sourceIndex = (sourceY * source.width + sourceX) * 4
                let destinationIndex = (y * width + x) * 4
                for channel in 0..<4 { resized.pixels[destinationIndex + channel] = source.pixels[sourceIndex + channel] }
            }
        }
        let decoded = try XCTUnwrap(V52Codec.decode(
            resized, plane: .chroma, sync: .none, scale: scale,
            offsetX: 0, offsetY: 0, searchTile: true
        ))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.estimatedScale, scale, accuracy: 0.000_001)

        var plain = RGBAImage(width: 640, height: 900)
        plain.fill((200, 200, 200, 255))
        XCTAssertNil(V52Codec.decode(plain, plane: .chroma, sync: .none, scale: 1, searchTile: true))
    }

    func testDecodeBestFindsUnlistedScalesAndOddBlockCrop() throws {
        func makeSource() -> RGBAImage {
            var image = RGBAImage(width: 640, height: 900)
            image.fill((200, 200, 200, 255))
            image.blendTiled(V52Codec.makeTile(payload: payload, alpha: 8, plane: .chroma), dx: 0, dy: 0)
            return image
        }
        func resize(_ input: RGBAImage, _ scale: Double) -> RGBAImage {
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

        // Neither ratio is in the supplied coarse grids. The search gets only
        // neighboring coarse values and must refine from the image evidence.
        for (scale, coarse) in [(0.837, [0.80, 0.85, 0.90]), (1.173, [1.15, 1.20, 1.25])] {
            let decoded = try XCTUnwrap(V52Codec.decodeBest(
                resize(makeSource(), scale),
                scales: coarse,
                planes: [.chroma],
                syncModes: [.none],
                searchPhase: false,
                searchTile: true,
                maxContexts: 4
            ), "scale=\(scale)")
            XCTAssertEqual(decoded.payload, payload)
            XCTAssertEqual(decoded.estimatedScale, scale, accuracy: 0.002)
        }

        let source = makeSource()
        let left = 9 // deliberately not a whole pair or tile
        let top = 13
        var cropped = RGBAImage(width: source.width - left, height: source.height - top)
        for y in 0..<cropped.height {
            for x in 0..<cropped.width {
                let sourceIndex = ((y + top) * source.width + x + left) * 4
                let destinationIndex = (y * cropped.width + x) * 4
                for channel in 0..<4 { cropped.pixels[destinationIndex + channel] = source.pixels[sourceIndex + channel] }
            }
        }
        let cropDecoded = try XCTUnwrap(V52Codec.decodeBest(
            cropped, scales: [1.0], planes: [.chroma], syncModes: [.none],
            searchPhase: true, searchTile: true, maxContexts: 4
        ))
        XCTAssertEqual(cropDecoded.payload, payload)
    }

    /// 小图能解出自洽的 CRC-valid 载荷，但观测不足时必须被标出来 —— CLI 靠这个标记拒绝解读字段。
    func testV52SmallImageIsMarkedInsufficient() throws {
        var image = RGBAImage(width: 320, height: 320)
        image.fill((200, 200, 200, 255))
        image.blendTiled(V52Codec.makeTile(payload: payload, alpha: 8, plane: .chroma), dx: 0, dy: 0)
        let decoded = try XCTUnwrap(V52Codec.decode(
            image, plane: .chroma, sync: .none, scale: 1, offsetX: 0, offsetY: 0, searchTile: true
        ))
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertLessThan(decoded.minObservations, BlockCodec.minObservationsPerBit)
        XCTAssertFalse(decoded.hasSufficientEvidence)

        var fullScreen = RGBAImage(width: 1179, height: 2556)
        fullScreen.fill((200, 200, 200, 255))
        fullScreen.blendTiled(V52Codec.makeTile(payload: payload, alpha: 8, plane: .chroma), dx: 0, dy: 0)
        let full = try XCTUnwrap(V52Codec.decode(
            fullScreen, plane: .chroma, sync: .none, scale: 1, offsetX: 0, offsetY: 0, searchTile: false
        ))
        XCTAssertTrue(full.hasSufficientEvidence, "整屏最少 \(full.minObservations) 次/bit")
    }

    /// 两个不同的 CRC-valid 载荷同时出现 → 一律 ambiguous，不按 score 挑第一个。
    func testV52AdjudicateRefusesTwoDistinctPayloads() throws {
        let other = try XCTUnwrap(WatermarkPayloadV52(
            uid: 0xDEAD_BEEF, timestampOffset: 7, buildMinuteOffset: 3,
            pageCode: "other", app: 1, noteCode: "x"
        ))
        func candidate(_ payload: WatermarkPayloadV52, score: Double) -> V52Codec.Candidate {
            V52Codec.Candidate(
                payload: payload,
                codewordBytes: V52BCH.encode(messageBytes: payload.bytes),
                correctedBits: 0,
                softRecoveryUsed: false,
                plane: .chroma,
                sync: .none,
                scale: 1,
                offsetX: 0,
                offsetY: 0,
                pilotScore: 0,
                medianAbsZ: 5,
                minObservations: 20,
                averageObservations: 20,
                score: score
            )
        }

        let single = try XCTUnwrap(V52Codec.adjudicate([candidate(payload, score: 1)]))
        XCTAssertEqual(single.payload, payload)
        XCTAssertFalse(single.ambiguous)

        let ambiguous = try XCTUnwrap(V52Codec.adjudicate([
            candidate(payload, score: 1), candidate(other, score: 9),
        ]))
        XCTAssertTrue(ambiguous.ambiguous)
        XCTAssertNil(ambiguous.payload)
        XCTAssertFalse(ambiguous.isSuccess)
        XCTAssertEqual(ambiguous.candidateCount, 2)
        XCTAssertEqual(ambiguous.failureReason, "multiple distinct CRC-valid payloads")
    }

    /// PN 序列跨语言契约：`tools/bwdecode.py` 的 `_v52_pn_bit` 用同一串 golden vector 钉住。
    func testV52PNSequenceGoldenVector() {
        let expected = "1011111010000010101000111101010111010011010110110000101100011000"
        XCTAssertEqual((0..<64).map { V52Codec.pnBit($0) ? "1" : "0" }.joined(), expected)
    }

    /// 负相位必须拒绝：积分图会把越界矩形夹到边界，多出垃圾观测（与 Python 端一致）。
    func testV52NegativeOffsetIsRejected() {
        var image = RGBAImage(width: 640, height: 900)
        image.fill((200, 200, 200, 255))
        image.blendTiled(V52Codec.makeTile(payload: payload, alpha: 8, plane: .chroma), dx: 3, dy: 5)
        XCTAssertNil(V52Codec.decode(image, plane: .chroma, sync: .none, scale: 1,
                                     offsetX: 3, offsetY: -1, searchTile: false))
        XCTAssertNil(V52Codec.decode(image, plane: .chroma, sync: .none, scale: 1,
                                     offsetX: -1, offsetY: 5, searchTile: false))
    }
}
