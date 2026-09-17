import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import BlindWatermarkCore

// 用法: bwdecode <截图路径> [--bits N] [--offset X,Y] [--auto-offset] [--plane luma|chroma]
//                 [--layout] [--key <hex>] [--pages <json>] [--auto]
//   --bits    payload 有效位数，默认 256（推荐布局），必须与打水印端一致
//   --offset  图案相位，截图被裁过时才需要（例如裁掉状态栏后 --offset 0,-N）
//   --auto-offset 已知平面 / 位数时自动求相位：穷举块网格相位。
//             只有给了 --key 才额外穷举 tile 平移（rotation），用 MAC 裁决；
//             没给 --key 时只搜块网格相位、rotation 恒 0，只能按 |z| 中位选（置信度不可保证），
//             非整 tile 倍数的裁剪解不了。
//             与 --offset 互斥；与 --auto 语义重叠，别一起用
//   --plane   水印压在哪一平面，默认 chroma，必须与打水印端一致
//   --layout  按 256 bit 推荐布局解读字段（uid / 时间 / 页面 / 标签）
//   --key     服务端密钥（hex），配合 --layout 校验 mac
//   --pages      页面注册表 JSON（字符串数组），把页面短码换成确定的类名
//   --dump-codes 只列出注册表里每个类名的短码，不进解码流程
//   --auto    截图被裁过 / 不确定平面与位数时用：穷举 64 相位 × 双平面 × tile 旋转，
//             位数默认只有 256，只有显式给了 --bits 且 ≠256 才追加那一种；
//             给了 --key 用 MAC 裁决，没给就退回 medianAbsZ（不如 MAC 可靠）

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func warn(_ message: String) {
    FileHandle.standardError.write(("警告: " + message + "\n").data(using: .utf8)!)
}

/// MAC 裁决器：只对推荐布局有意义，位数不符时一律返回 false（宁可让它退回未校验结果，也不要假装验证过）。
func macValidator(_ key: SymmetricKey) -> (BlockCodec.Decoded) -> Bool {
    { decoded in
        guard decoded.payloadBits == WatermarkPayload.payloadBits,
              let fields = WatermarkPayload(bytes: decoded.payloadBytes) else { return false }
        return fields.isValid(key: key)
    }
}

var path: String?
var payloadBits = WatermarkPayload.payloadBits
var offsetX = 0
var offsetY = 0
var autoOffset = false
var explicitOffset = false
var plane: WatermarkPlane = .chroma
var showLayout = false
var key: SymmetricKey?
var pages: PageRegistry?
var auto = false
var dumpCodes = false

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
        explicitOffset = true
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
    case "--pages":
        index += 1
        guard index < arguments.count,
              let registry = PageRegistry(contentsOf: URL(fileURLWithPath: arguments[index])) else {
            fail("--pages 需要一个可读的 JSON 文件（顶层字符串数组）", code: 2)
        }
        pages = registry
    case "--auto":
        auto = true
    case "--dump-codes":
        dumpCodes = true
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

if autoOffset && explicitOffset {
    fail("--auto-offset 与 --offset 互斥：前者就是自动求后者，同时给无法判断以哪个为准", code: 2)
}
if autoOffset && auto {
    fail("--auto-offset 与 --auto 语义重叠：--auto 已经穷举相位 / 平面 / 位数，单独用 --auto 即可", code: 2)
}

if dumpCodes {
    guard let pages else {
        fail("--dump-codes 需要配合 --pages 使用", code: 2)
    }
    // 列宽取 codeLength + 1：短码最长 10 字符，`padding(toLength:)` 会把超出的截掉，
    // 列宽给 6 会把 darkmode 显示成 darkmo —— 表是给人/grep 看的，不能截
    print("code       类名")
    for entry in pages.codeTable {
        print("\(entry.code.padding(toLength: PageNameCodec.codeLength + 1, withPad: " ", startingAt: 0))\(entry.name)")
    }
    exit(0)
}

guard let path else {
    fail("用法: bwdecode <截图路径> [--bits N] [--offset X,Y] [--auto-offset] [--plane luma|chroma] [--layout] [--key <hex>] [--pages <json>] [--auto]", code: 2)
}

let url = URL(fileURLWithPath: path)
guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let image = RGBAImage(cgImage: cgImage)
else {
    fail("读不到图片: \(path)", code: 1)
}

let result: BlockCodec.Decoded?
if auto {
    let validator: ((BlockCodec.Decoded) -> Bool)?
    if let key {
        validator = macValidator(key)
    } else {
        // 没有 MAC 可用时用时间戳合理性做弱校验：Unix 秒落在 2015...2100 之间
        validator = { decoded in
            guard decoded.payloadBits == WatermarkPayload.payloadBits,
                  let fields = WatermarkPayload(bytes: decoded.payloadBytes) else { return false }
            return (1_420_070_400...4_102_444_800).contains(fields.timestamp)
        }
    }
    var payloadBitsCandidates = [WatermarkPayload.payloadBits]
    if payloadBits != WatermarkPayload.payloadBits {
        payloadBitsCandidates.append(payloadBits)
    }
    result = BlockCodec.decodeBest(
        image,
        payloadBitsCandidates: payloadBitsCandidates,
        planes: [.chroma, .luma],
        searchPhase: true,
        validate: validator
    )
} else {
    if autoOffset {
        // 相位与 tile 平移都不确定：块网格相位靠 medianAbsZ 排序，tile 平移只能靠校验器裁决
        // （错位 / 错旋转同样能给出很干净的自洽载荷，裸穷举不叫搜索，叫猜）。
        var phaseValidator: ((BlockCodec.Decoded) -> Bool)?
        if let key {
            phaseValidator = macValidator(key)
            if payloadBits != WatermarkPayload.payloadBits {
                warn("MAC 只覆盖 \(WatermarkPayload.payloadBits) bit 推荐布局，--bits \(payloadBits) 下相位无法校验")
            }
        } else {
            phaseValidator = nil
            warn("--auto-offset 没给 --key：只搜块网格相位，tile 旋转不搜（等价 rotation 恒 0），"
                + "只能按 |z| 中位裁决，不保证解出正确载荷；非整 tile 倍数的裁剪（平移）解不了。"
                + "要覆盖裁剪平移必须给 --key。判读请看 弱bit，配合 --layout 检查字段是否合理")
        }
        result = BlockCodec.decodeBest(
            image,
            payloadBitsCandidates: [payloadBits],
            planes: [plane],
            searchPhase: true,
            searchTile: true,
            validate: phaseValidator
        )
    } else {
        result = BlockCodec.decode(
            image,
            payloadBits: payloadBits,
            offsetX: offsetX,
            offsetY: offsetY,
            plane: plane
        )
    }
}
guard let result else {
    fail("解码失败: 图像太小，或 --auto 没找到可信的候选", code: 1)
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
    let macLine: String
    if let key {
        macLine = fields.isValid(key: key) ? "mac=OK" : "mac=BAD(密钥不符或被篡改)"
    } else {
        macLine = "mac=未校验(需要 --key)"
    }
    // 新旧布局的 mac 覆盖范围相同（都是前 12 字节），所以旧截图 mac 照样通过，
    // 但 page/tag 字段边界变了 —— 靠 layout 版本位显式提示，别让 agent 误读。
    if fields.layoutVersion != WatermarkPayload.layoutVersion {
        print("注意: 这张截图是 layout=v\(fields.layoutVersion)，当前布局是 v\(WatermarkPayload.layoutVersion)，"
            + "page/tag 字段边界不同，下面的解读可能是错的")
    }
    let code = fields.pageNameCode
    let pageLine: String
    if let pages {
        let hits = pages.matches(code: code)
        switch hits.count {
        case 1:
            pageLine = "page=\(code) → \(hits[0])"
        case 0:
            pageLine = "page=\(code)（注册表无命中，换版本或没登记；\(PageNameCodec.grepHint(forCode: code))）"
        default:
            pageLine = "page=\(code) → \(hits.count) 个候选: \(hits.joined(separator: ", "))"
        }
    } else {
        pageLine = "page=\(code)（无注册表，直接 \(PageNameCodec.grepHint(forCode: code))）"
    }
    print(String(
        format: "uid=%u(0x%08X)  time=%@  %@  layout=v%u app=%u env=%u  %@",
        fields.uid,
        fields.uid,
        formatter.string(from: date),
        pageLine,
        fields.layoutVersion,
        fields.app,
        fields.environment,
        macLine
    ))
}
