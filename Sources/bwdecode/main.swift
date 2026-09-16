import CoreGraphics
import Foundation
import ImageIO
import BlindWatermarkCore

// 用法: bwdecode <截图路径> [--bits N] [--offset X,Y] [--plane luma|chroma]
//   --bits    payload 有效位数，默认 32，需与打水印端一致
//   --offset  图案相位，截图被裁过时才需要（例如裁掉状态栏后 --offset 0,-N）
//   --plane   水印压在哪一平面，默认 chroma，需与打水印端一致

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

var path: String?
var payloadBits = 32
var offsetX = 0
var offsetY = 0
var plane: WatermarkPlane = .chroma

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
    case "--plane":
        index += 1
        guard index < arguments.count, let value = WatermarkPlane(rawValue: arguments[index]) else {
            fail("--plane 需要 luma 或 chroma", code: 2)
        }
        plane = value
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
    fail("用法: bwdecode <截图路径> [--bits N] [--offset X,Y] [--plane luma|chroma]", code: 2)
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
    offsetY: offsetY,
    plane: plane
) else {
    fail("解码失败: 图像太小", code: 1)
}

// 判读看「有几个 bit 证据不足」，不看最弱那一个：
// 真实界面里有文字边缘、与块网格对齐的版式，个别 bit 的 z 天然会塌，全局最小值太苛刻。
let total = result.payloadBits
let weak = result.weakBits
let verdict: String
if weak == 0 {
    verdict = "OK(全部 \(total) bit 显著)"
} else if weak <= total / 8 {
    verdict = "WEAK(\(weak)/\(total) bit 证据不足，结论谨慎)"
} else {
    verdict = "NO(画面中可能没有水印)"
}

print(String(
    format: "payload=0x%08X  高16位=0x%04X  低16位=0x%04X  payloadBits=%d  平面=%@  相位=(%d,%d)  signal=%.2f  |z|中位=%.1f  最弱=%.1f  弱bit=%d/%d  %@",
    result.payload,
    (result.payload >> 16) & 0xFFFF,
    result.payload & 0xFFFF,
    result.payloadBits,
    result.plane.rawValue,
    result.offsetX,
    result.offsetY,
    result.signal,
    result.medianAbsZ,
    result.confidence,
    weak,
    total,
    verdict
))
