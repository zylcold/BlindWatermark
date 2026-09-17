import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import BlindWatermarkCore

// 用法: bwdecode <截图路径> [--bits N] [--offset X,Y] [--auto-offset] [--plane luma|chroma] [--layout] [--key <hex>]
//   --bits        payload 有效位数，默认 128（推荐布局），必须与打水印端一致
//   --offset      图案相位，截图被裁过时才需要（例如裁掉状态栏后 --offset 0,-N）
//   --auto-offset 自动搜索最优相位，穷举 blockSize×blockSize 种偏移取 |z| 中位最大的一组
//   --plane       水印压在哪一平面，默认 chroma，必须与打水印端一致
//   --layout      按 128 bit 推荐布局解读字段（uid / 时间 / 页面 / 标签）
//   --key         服务端密钥（hex），配合 --layout 校验 mac

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

var path: String?
var payloadBits = WatermarkPayload.payloadBits
var offsetX = 0
var offsetY = 0
var autoOffset = false
var plane: WatermarkPlane = .chroma
var showLayout = false
var key: SymmetricKey?

var index = 1
let arguments = CommandLine.arguments
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--bits":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]),
              (1...BlockCodec.maxPayloadBits).contains(value) else {
            fail("--bits 需要 1...\(BlockCodec.maxPayloadBits) 的整数", code: 2)
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
    case "--auto-offset":
        autoOffset = true
    case "--plane":
        index += 1
        guard index < arguments.count, let value = WatermarkPlane(rawValue: arguments[index]) else {
            fail("--plane 需要 luma 或 chroma", code: 2)
        }
        plane = value
    case "--layout":
        showLayout = true
    case "--key":
        index += 1
        guard index < arguments.count, let value = SymmetricKey(hex: arguments[index]) else {
            fail("--key 需要 hex 字符串，例如 00112233445566778899aabbccddeeff", code: 2)
        }
        key = value
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
    fail("用法: bwdecode <截图路径> [--bits N] [--offset X,Y] [--auto-offset] [--plane luma|chroma] [--layout] [--key <hex>]", code: 2)
}

let url = URL(fileURLWithPath: path)
guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let image = RGBAImage(cgImage: cgImage)
else {
    fail("读不到图片: \(path)", code: 1)
}

if autoOffset {
    let best = BlockCodec.findBestOffset(in: image, payloadBits: payloadBits, plane: plane)
    offsetX = best.offsetX
    offsetY = best.offsetY
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

let hex = result.payloadBytes.map { String(format: "%02x", $0) }.joined()

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
    format: "payload=0x%@  payloadBits=%d  平面=%@  相位=(%d,%d)  signal=%.2f  |z|中位=%.1f  最弱=%.1f  弱bit=%d/%d  %@",
    hex,
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

// 推荐布局的字段解读
if showLayout {
    guard result.payloadBits == WatermarkPayload.payloadBits,
          let fields = WatermarkPayload(bytes: result.payloadBytes) else {
        fail("--layout 需要 --bits \(WatermarkPayload.payloadBits) 且载荷为 \(WatermarkPayload.byteCount) 字节", code: 2)
    }
    let date = Date(timeIntervalSince1970: TimeInterval(fields.timestamp))
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    let magicLine = fields.hasMagic ? "magic=OK" : "magic=BAD(payloadBits 可能与编码端不一致)"
    let macLine: String
    if let key {
        macLine = fields.isValid(key: key) ? "mac=OK" : "mac=BAD(密钥不符或被篡改)"
    } else {
        macLine = "mac=未校验(需要 --key)"
    }
    print(String(
        format: "uid=%u(0x%08X)  time=%@  pageIndex=%u  appTag=%u(0x%03X)  %@  %@",
        fields.uid,
        fields.uid,
        formatter.string(from: date),
        fields.pageIndex,
        fields.appTag,
        fields.appTag,
        magicLine,
        macLine
    ))
    print("pageIndex 需查接入端的页面注册表才能还原类名")
}
