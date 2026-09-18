import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import BlindWatermarkCore

// 用法: bwdecode <截图路径> [--protocol v4|v5.2|auto] [--bits N] [--offset X,Y]
//                 [--auto-offset] [--plane luma|chroma] [--pilot none|pn|separated]
//                 [--scale N] [--layout] [--key <hex>] [--pages <json>] [--auto]
//   --bits    payload 有效位数，默认 512（layout v4），必须与打水印端一致
//   --offset  图案相位，截图被裁过时才需要（例如裁掉状态栏后 --offset 0,-N）
//   --auto-offset 已知平面 / 位数时自动求相位：穷举块网格相位与 tile 平移（rotation）。
//             裁剪自愈靠校验值裁决：有 --key 验 HMAC，没 --key 就验载荷自带的公开自检值。
//             两者都没有（校验值全 0）时退化为结构自检，**不保证解出正确载荷**，会打警告。
//             与 --offset 互斥；与 --auto 语义重叠，别一起用
//   --plane   水印压在哪一平面，默认 chroma，必须与打水印端一致
//   --layout  按 layout v4 解读字段（uid / 时间 / build / 页面短码 / note / 标签）
//   --key     服务端密钥（hex），配合 --layout 校验
//   --pages      页面注册表 JSON（字符串数组），把页面短码换成确定的类名
//   --dump-codes 只列出注册表里每个类名的短码，不进解码流程
//   --auto    截图被裁过 / 不确定平面时用：穷举 64 相位 × 双平面 × 512 tile 平移；
//             同样靠校验值裁决（密钥 → HMAC，无密钥 → 公开自检值）；
//             都没有则退结构自检并警告 —— 近似解会漏网，必须看弱 bit
//   --protocol v5.2  显式启用紧凑 207-bit + BCH(255,207) + 偶校验协议；默认仍为 v4
//   --pilot         v5.2 实验导频档（none 默认；pn / separated 仅用于实验测量）
//   --scale N       v5.2 已知等比缩放，例如 0.837；--auto 会搜索 0.50...1.50 粗网格并局部精搜

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

func warn(_ message: String) {
    FileHandle.standardError.write(("警告: " + message + "\n").data(using: .utf8)!)
}

func printV52Result(_ result: V52Codec.Decoded, layout: Bool, trim: String? = nil) -> Bool {
    guard let payload = result.payload, !result.ambiguous else {
        if result.ambiguous {
            warn("v5.2 找到多个不同的 CRC-valid payload，拒绝按首个结果裁决（候选 \(result.candidateCount) 个）")
        } else {
            warn("v5.2 未找到 BCH + CRC-valid payload（\(result.failureReason ?? "图像太小、相位或缩放不匹配")）")
        }
        return false
    }
    let hex = payload.bytes.map { String(format: "%02x", $0) }.joined()
    // 证据分档与 v4 同一把尺：v5.2 只有 CRC24（不是验签），观测不够就必须自己当守门人。
    let minimum = BlockCodec.minObservationsPerBit
    let verdict = result.hasSufficientEvidence
        ? String(format: "OK(每 bit 最少 %d 次观测)", result.minObservations)
        : String(format: "TOO_SMALL(每 bit 仅 %.1f 次观测、最少 %d 次，需要 ≥ %d：图太小或图案已被破坏)",
                 result.averageObservations, result.minObservations, minimum)
    print(String(
        format: "protocol=v5.2 payload=0x%@  plane=%@  pilot=%@  phase=(%d,%d)  scale=%.4f  correctedBits=%d  softRecovery=%@  pilotScore=%.3f  candidateCount=%d  minObs=%d  avgObs=%.1f  |z|中位=%.1f  %@%@",
        hex,
        result.plane.rawValue,
        result.sync.rawValue,
        result.offsetX,
        result.offsetY,
        result.estimatedScale,
        result.correctedBits,
        result.softRecoveryUsed ? "true" : "false",
        result.pilotScore,
        result.candidateCount,
        result.minObservations,
        result.averageObservations,
        result.medianAbsZ,
        verdict,
        trimField.map { "  \($0)" } ?? ""
    ))
    if !result.hasSufficientEvidence {
        let message = String(
            format: "每 bit 仅 %.1f 次观测（最少 %d 次，需要 ≥ %d）：图太小或图案已被破坏，载荷不可信",
            result.averageObservations, result.minObservations, minimum
        )
        guard layout else {
            warn(message + "，不要用 --layout 解读字段")
            return true
        }
        fail("图像太小 / 图案已被破坏，不解读字段：可用观测"
            + "每 bit 仅 \(String(format: "%.1f", result.averageObservations)) 次（最少 \(result.minObservations) 次，需要 ≥ \(minimum)）。"
            + "请让用户发原图并保证范围足够大（256 bit 码字实测需要约 1280 个 pair，整宽 1179 时约 150px 高）", code: 1)
    }
    guard layout else { return true }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    print(String(
        format: "uid=%u(0x%08X)  time=%@  page=%@  buildTime=%@  app=%u  note=%@  profile=%u  crcStatus=OK(完整性自检,未验签)",
        payload.uid,
        payload.uid,
        formatter.string(from: Date(timeIntervalSince1970: TimeInterval(payload.timestamp))),
        payload.pageNameCode,
        formatter.string(from: Date(timeIntervalSince1970: TimeInterval(payload.buildTime))),
        payload.app,
        payload.note.isEmpty ? "（空）" : payload.note,
        WatermarkPayloadV52.profile
    ))
    return true
}

/// 载荷里的字段（只对推荐布局有意义；位数不符一律 nil）。
func fields(of decoded: BlockCodec.Decoded) -> WatermarkPayload? {
    guard decoded.payloadBits == WatermarkPayload.payloadBits else { return nil }
    return WatermarkPayload(bytes: decoded.payloadBytes)
}

/// 严格校验器：验签通过（有密钥）或公开自检值通过（未验签但能证明"解对了"）。
/// 位数不符时一律 false —— 宁可退回未校验结果，也不要假装验证过。
func validValidator(_ key: SymmetricKey?) -> (BlockCodec.Decoded) -> Bool {
    { decoded in
        guard let payload = fields(of: decoded) else { return false }
        switch payload.verification(key: key) {
        case .signed, .selfChecked: return true
        case .unsigned, .failed: return false
        }
    }
}

/// 兜底校验器：结构自检（不需要密钥、不依赖额外字段）。
/// **只减少错误，不消除错误** —— 半块相位错位解出的近似解结构字段根本没动，照样能过。
func structuralValidator(_ decoded: BlockCodec.Decoded) -> Bool {
    fields(of: decoded)?.isPlausible ?? false
}

/// 三档阶梯搜索：
/// 1. 严格校验器 + 常规相位（快）
/// 2. 严格校验器 + block 奇偶档（救"裁剪量是奇数个块"的横向裁剪）
/// 3. 结构自检兜底（载荷没带校验值时唯一能做到的，必须打警告）
///
/// 返回最终结果与它落在哪一档校验上。
func decodeLadder(
    _ image: RGBAImage,
    payloadBitsCandidates: [Int],
    planes: [WatermarkPlane],
    key: SymmetricKey?
) -> (result: BlockCodec.Decoded?, tier: WatermarkPayload.Verification?) {
    let strict = validValidator(key)
    for pairOffset in [false, true] {
        let candidate = BlockCodec.decodeBest(
            image,
            payloadBitsCandidates: payloadBitsCandidates,
            planes: planes,
            searchPhase: true,
            searchTile: true,
            searchPairOffset: pairOffset,
            validate: strict
        )
        if let tier = candidate.flatMap({ verificationTier($0, key: key) }), tier == .signed || tier == .selfChecked {
            return (candidate, tier)
        }
    }
    warn(noValidatorWarning)
    let fallback = BlockCodec.decodeBest(
        image,
        payloadBitsCandidates: payloadBitsCandidates,
        planes: planes,
        searchPhase: true,
        searchTile: true,
        validate: structuralValidator
    )
    return (fallback, fallback.flatMap { verificationTier($0, key: key) })
}

/// 载荷既没带 HMAC（或没有密钥）、也没带公开自检值时打给调用方看的警告。
let noValidatorWarning = "载荷没带可校验的校验值（mac 全 0 或仅有 HMAC 而没给 --key）："
    + "裁剪 / 相位搜索已退化为结构自检，近似解会漏网 —— 结论不保证正确，必须看 弱bit 与 校验 字段；"
    + "接入端填公开自检值（WatermarkPayload.selfChecked）或服务端 HMAC 才能真正保证"

/// 解码结果落在哪一档校验上，用来决定输出措辞。
func verificationTier(_ decoded: BlockCodec.Decoded, key: SymmetricKey?) -> WatermarkPayload.Verification? {
    fields(of: decoded)?.verification(key: key)
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
var protocolVersion = "v4"
var pilot: V52SyncMode = .none
var v52Scale: Double?
var bitsExplicit = false

var index = 1
let arguments = CommandLine.arguments
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--protocol":
        index += 1
        guard index < arguments.count else { fail("--protocol 需要 v4、v5.2 或 auto", code: 2) }
        let value = arguments[index].lowercased()
        guard ["v4", "4", "v5.2", "v52", "5.2", "auto"].contains(value) else {
            fail("--protocol 需要 v4、v5.2 或 auto", code: 2)
        }
        protocolVersion = value == "v4" || value == "4" ? "v4"
            : (value == "auto" ? "auto" : "v5.2")
    case "--v52":
        protocolVersion = "v5.2"
    case "--pilot":
        index += 1
        guard index < arguments.count, let value = V52SyncMode(rawValue: arguments[index]) else {
            fail("--pilot 需要 none、pn 或 separated", code: 2)
        }
        pilot = value
    case "--scale":
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]), value.isFinite, value > 0, value <= 4 else {
            fail("--scale 需要一个大于 0 的数，例如 0.837", code: 2)
        }
        v52Scale = value
    case "--bits":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]),
              (1...BlockCodec.maxPayloadBits).contains(value) else {
            fail("--bits 需要 1...\(BlockCodec.maxPayloadBits) 的整数", code: 2)
        }
        payloadBits = value
        bitsExplicit = true
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

// `--protocol auto` is itself an auto-detection request; set the shared flag
// before checking the mutually exclusive legacy geometry options.
if protocolVersion == "auto" { auto = true }

if autoOffset && explicitOffset {
    fail("--auto-offset 与 --offset 互斥：前者就是自动求后者，同时给无法判断以哪个为准", code: 2)
}
if autoOffset && auto {
    fail("--auto-offset 与 --auto 语义重叠：--auto 已经穷举相位 / 平面 / 位数，单独用 --auto 即可", code: 2)
}

// `--auto` keeps its historical v4 phase/plane search semantics. Protocol
// auto-detection is opt-in through the explicit `--protocol auto` spelling.
// `--protocol v5.2 --auto` still means v5.2-only geometry search.

if protocolVersion == "v5.2" {
    if bitsExplicit {
        fail("v5.2 的物理码字固定为 256 bit（信息字段 207 bit），不要传 v4 的 --bits", code: 2)
    }
    if key != nil { fail("v5.2 只有 CRC24，没有 v4 的 HMAC；请去掉 --key", code: 2) }
    // pilot 要从亮度通道叠调制，luma 平面已经把亮度通道拿去放数据了。
    if pilot != .none && plane == .luma {
        warn("--pilot \(pilot.rawValue) 在 --plane luma 下不会写入导频（luma 平面把亮度通道全部用于数据），"
            + "输出的 pilotScore 无意义；要测导频请用 --plane chroma")
    }
}

if protocolVersion == "v5.2" && pages != nil {
    fail("--pages 是 v4 的 15 字符注册表；v5.2 只输出 8 字符 compact page code，请去掉 --pages", code: 2)
}
if protocolVersion == "auto" && key != nil {
    warn("--protocol auto 带 --key 时，v5.2 分支仍只验证 CRC24（不使用 HMAC）；若需强制验签请显式 --protocol v4")
}
if protocolVersion == "auto" && bitsExplicit {
    warn("--protocol auto 的 v5.2 探测固定 256-bit 码字，忽略 --bits；v4 回退仍使用该参数")
}
if protocolVersion == "auto" && pages != nil {
    warn("--pages 仅用于 v4 回退；v5.2 输出 compact page code，不使用旧 15 字符注册表")
}

if dumpCodes {
    if protocolVersion == "v5.2" {
        fail("--dump-codes 当前只支持 v4 页面注册表；v5.2 请使用 compact page code 定位", code: 2)
    }
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
    fail("用法: bwdecode <截图路径> [--protocol v4|v5.2|auto] [--bits N] [--offset X,Y] [--auto-offset] [--plane luma|chroma] [--pilot none|pn|separated] [--scale N] [--layout] [--key <hex>] [--pages <json>] [--auto]", code: 2)
}

let url = URL(fileURLWithPath: path)
guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let image = RGBAImage(cgImage: cgImage)
else {
    fail("读不到图片: \(path)", code: 1)
}

// 黑边（IM 转发 / 图片查看器套的纯黑边框）会在交界列上制造量级大、方向固定的假差分，
// 按 tile 周期性反复砸同一批 bit，直接把 BCH 纠错预算用光。自动路径先裁掉它；
// 显式给了 --offset 的调用方自己掌握几何，不动它们的图。
let trimmed: (image: RGBAImage, trim: UniformBorderTrim) = explicitOffset
    ? (image, .none)
    : image.trimmingUniformDarkBorder()
let workingImage = trimmed.image
let trimField = trimmed.trim.outputField
if let trimField {
    warn("检测到黑边，已按内容区解码（\(trimField)，phase 相对裁剪后的图像 / black border trimmed")
}

// v5.2 is opt-in. In `auto` mode it gets one protocol-aware chance before the
// historical v4 ladder; a CRC-valid v5.2 result wins and an ambiguous result is
// refused instead of being reinterpreted as v4.
if protocolVersion == "v5.2" || protocolVersion == "auto" {
    let explicitV52 = protocolVersion == "v5.2"
    let scales = v52Scale.map { [$0] } ?? (auto ? V52Codec.defaultScales : [1.0])
    let v52Result: V52Codec.Decoded?
    if explicitV52 && !auto && !autoOffset {
        v52Result = V52Codec.decode(
            workingImage,
            plane: plane,
            sync: pilot,
            scale: v52Scale ?? 1.0,
            offsetX: offsetX,
            offsetY: offsetY,
            searchTile: false
        )
    } else {
        let searchTile = explicitV52 ? (auto || autoOffset) : true
        let planes: [WatermarkPlane] = explicitV52 ? [plane] : [.chroma, .luma]
        var fast: V52Codec.Decoded?
        if auto, v52Scale == nil {
            // 粗定位：比例尺先给 1 个平面 + ±10% 的 5 档候选，省掉 21 档粗网格 × 2 平面。
            if let hint = ScaleRuler.estimate(workingImage, planes: planes),
               hint.confidence >= ScaleRuler.minConfidence {
                warn(String(
                    format: "比例尺粗定位：%@ scale≈%.3f（置信 %.2f）→ 只在候选附近精搜 / scale ruler hint",
                    hint.plane.rawValue, hint.scale, hint.confidence
                ))
                fast = V52Codec.decodeBest(
                    workingImage,
                    scales: ScaleRuler.candidateScales(for: hint),
                    planes: [hint.plane],
                    syncModes: [pilot],
                    searchPhase: true,
                    searchTile: searchTile
                )
                // ambiguous 不值得信，交给完整网格重搜
                if let candidate = fast, !candidate.isSuccess { fast = nil }
            }
        }
        v52Result = fast ?? V52Codec.decodeBest(
            workingImage,
            scales: scales,
            planes: planes,
            syncModes: [pilot],
            searchPhase: true,
            searchTile: searchTile
        )
    }
    if let v52Result {
        if printV52Result(v52Result, layout: showLayout, trim: trimField) { exit(0) }
        fail("v5.2 解码未形成唯一的 BCH + CRC-valid 结果", code: 1)
    } else if explicitV52 {
        fail("v5.2 解码失败：未找到 BCH + CRC-valid 结果，请检查 --plane/--pilot/--scale/--offset", code: 1)
    }
}

let result: BlockCodec.Decoded?
/// 结果最终落在哪一档校验上（决定输出措辞）。nil = 不是推荐布局，无法解读字段。
var tier: WatermarkPayload.Verification?
if auto {
    var payloadBitsCandidates = [WatermarkPayload.payloadBits]
    if payloadBits != WatermarkPayload.payloadBits {
        payloadBitsCandidates.append(payloadBits)
    }
    (result, tier) = decodeLadder(workingImage, payloadBitsCandidates: payloadBitsCandidates, planes: [.chroma, .luma], key: key)
} else {
    if autoOffset {
        // 相位与 tile 平移都不确定：块网格相位靠 medianAbsZ 排序，平移只能靠校验值裁决
        // （错位平移同样能给出很干净的自洽载荷，裸穷举不叫搜索，叫猜）。
        if payloadBits != WatermarkPayload.payloadBits {
            warn("HMAC 与公开自检值都只覆盖 \(WatermarkPayload.payloadBits) bit 推荐布局，"
                + "--bits \(payloadBits) 下相位与平移无法校验")
        }
        (result, tier) = decodeLadder(workingImage, payloadBitsCandidates: [payloadBits], planes: [plane], key: key)
    } else {
        result = BlockCodec.decode(
            workingImage,
            payloadBits: payloadBits,
            offsetX: offsetX,
            offsetY: offsetY,
            plane: plane
        )
        tier = result.flatMap { verificationTier($0, key: key) }
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
let validated = tier == .signed || tier == .selfChecked
// 没有校验值时，观测太少的图会解出一份「看着正常的垃圾」——必须自己当守门人。
let insufficient = !validated && !result.hasSufficientEvidence
let verdict: String
if insufficient {
    verdict = String(
        format: "TOO_SMALL(每 bit 仅 %.1f 次观测、最少 %d 次，需要 ≥ %d：图太小或图案已被破坏)",
        result.averageObservations,
        result.minObservations,
        BlockCodec.minObservationsPerBit
    )
} else if weak == 0 {
    verdict = "OK(全部 \(total) bit 显著)"
} else if weak <= total / 8 {
    verdict = "WEAK(\(weak)/\(total) bit 证据不足，结论谨慎)"
} else {
    verdict = "NO(画面中可能没有水印)"
}

print(String(
    format: "payload=0x%@  payloadBits=%d  平面=%@  相位=(%d,%d)  signal=%.2f  |z|中位=%.1f  最弱=%.1f  弱bit=%d/%d  %@%@",
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
    verdict,
    trimField.map { "  \($0)" } ?? ""
))

// 推荐布局的字段解读
if showLayout {
    guard result.payloadBits == WatermarkPayload.payloadBits,
          let payload = WatermarkPayload(bytes: result.payloadBytes) else {
        fail("--layout 需要 --bits \(WatermarkPayload.payloadBits) 且载荷为 \(WatermarkPayload.byteCount) 字节", code: 2)
    }
    // 没有校验值 + 观测不足：拒绝给字段。宁可报「图太小」，也不要输出一份看着正常的垃圾。
    if insufficient {
        fail(String(
            format: "图像太小 / 图案已被破坏，不解读字段：可用观测每 bit 仅 %.1f 次（最少 %d 次，需要 ≥ %d）。"
                + "请让用户发原图，并保证范围足够大（512 bit 载荷实测需要约 2700 个 pair，"
                + "整宽 1179 时约 300px 高，整屏最稳）",
            result.averageObservations,
            result.minObservations,
            BlockCodec.minObservationsPerBit
        ), code: 1)
    }
    let date = Date(timeIntervalSince1970: TimeInterval(payload.timestamp))
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    // 校验分档必须如实写：自检值通过只证明"解对了"，不证明"没被伪造"。
    let checkLine: String
    switch payload.verification(key: key) {
    case .signed:
        checkLine = "mac=OK(验签)"
    case .selfChecked:
        checkLine = "mac=OK(自检,未验签)"
    case .unsigned:
        checkLine = payload.isPlausible
            ? "mac=未签名(字段自洽,退结构自检)"
            : "mac=未签名(字段不自洽,谨慎)"
    case .failed:
        // 没给密钥时无法区分"服务端 HMAC"与"真的坏了"，按未校验报，不吓人
        checkLine = key == nil ? "mac=未校验(需要 --key)" : "mac=BAD(密钥不符或载荷被改)"
    }
    let code = payload.pageNameCode
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
    // build 原样打 12 位十进制（外部传入的构建号）
    let buildLine: String
    if payload.build == 0 {
        buildLine = "build=未填"
    } else {
        buildLine = "build=\(payload.buildNumber)"
    }
    let noteLine = payload.note.map { $0.isEmpty ? "note=（空）" : "note=\($0)" } ?? "note=（非法 UTF-8）"
    // 格式串的转换符数量必须与参数一一对应 —— 个数对不上会直接 SIGSEGV
    print(String(
        format: "uid=%u(0x%08X)  time=%@  %@  %@  %@  layout=v%u app=%u env=%u  %@",
        payload.uid,
        payload.uid,
        formatter.string(from: date),
        pageLine,
        buildLine,
        noteLine,
        WatermarkPayload.layoutVersion,
        payload.app,
        payload.environment,
        checkLine
    ))
    if payload.build != 0 {
        print(buildClockLine(payload.build))
    }
} else if insufficient {
    warn(String(
        format: "每 bit 仅 %.1f 次观测（最少 %d 次，需要 ≥ %d）：图太小或图案已被破坏，"
            + "载荷不可信，不要用 --layout 解读字段",
        result.averageObservations,
        result.minObservations,
        BlockCodec.minObservationsPerBit
    ))
} else if let payload = fields(of: result), payload.isUnsigned {
    // 没开 --layout 也要提醒：无校验值的载荷在裁剪场景下不可信
    warn(noValidatorWarning)
}

/// build 号是外部传入的 12 位十进制（YYYYMMDDHHMM，如 202609161722），这里渲染成可读时间。
/// 语义上它就是构建方当地的墙上时间，不做时区换算，直接按数字拆。
func buildClockLine(_ build: UInt64) -> String {
    let digits = String(format: "%012llu", build)
    guard digits.count == 12 else { return "build 时间: 非法（不是 12 位十进制）" }
    func slice(_ offset: Int) -> String { String(digits.dropFirst(offset).prefix(2)) }
    return "build 时间: \(digits.prefix(4))-\(slice(4))-\(slice(6)) \(slice(8)):\(slice(10))（构建方当地墙上时间）"
}
