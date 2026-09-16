import CoreGraphics
import Foundation
import ImageIO
import BlindWatermarkCore

// 用法: bwdecode <截图路径> [--bits N] [--offset X,Y]
//   --bits    payload 有效位数，默认 32，需与打水印端一致
//   --offset  图案相位，截图被裁过时才需要（例如裁掉状态栏后 --offset 0,-N）

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

var path: String?
var payloadBits = 32
var offsetX = 0
var offsetY = 0

var index = 1
let arguments = CommandLine.arguments
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--bits":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]), (1...32).contains(value) else {
            fail("--bits 需要 1...32 的整数", code: 2)
        }
        payloadBits = value
    case "--offset":
        index += 1
        let parts = index < arguments.count ? arguments[index].split(separator: ",") : []
        guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else {
            fail("--offset 需要 X,Y 形式，例如 --offset 0,-130", code: 2)
        }
        offsetX = x
        offsetY = y
    default:
        if path == nil, !argument.hasPrefix("--") {
            path = argument
        } else {
            fail("无法识别的参数: \(argument)", code: 2)
        }
    }
    index += 1
}

guard let path else {
    fail("用法: bwdecode <截图路径> [--bits N] [--offset X,Y]", code: 2)
}

let url = URL(fileURLWithPath: path)
guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let image = RGBAImage(cgImage: cgImage)
else {
    fail("读不到图片: \(path)", code: 1)
}

guard let result = BlockCodec.decode(
    image,
    payloadBits: payloadBits,
    offsetX: offsetX,
    offsetY: offsetY
) else {
    fail("解码失败: 图像太小", code: 1)
}

// confidence 是各 bit |z| 的最小值，即最弱那个 bit 的显著度。|z| >= 3 才算每 bit 可靠
let verdict: String
if result.confidence >= 3 {
    verdict = "OK"
} else if result.confidence >= 1.5 {
    verdict = "WEAK(画面内容复杂或被压缩，结果可能不可靠)"
} else {
    verdict = "NO(画面中可能没有水印)"
}

print(String(
    format: "payload=0x%08X  高16位=0x%04X  低16位=0x%04X  payloadBits=%d  相位=(%d,%d)  signal=%.2f  confidence=%.1f  %@",
    result.payload,
    (result.payload >> 16) & 0xFFFF,
    result.payload & 0xFFFF,
    result.payloadBits,
    result.offsetX,
    result.offsetY,
    result.signal,
    result.confidence,
    verdict
))
