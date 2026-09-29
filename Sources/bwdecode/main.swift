import BlindWatermarkCore
import Foundation
import ImageIO

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
bwdecode <image> [--layout] [--scale 0.5...1.5] [--offset X,Y] [--plane chroma|luma] [--auto] [--protocol v6] [--strip] [--strip-only] [--json]
bwdecode expect --uid <uint32> (--timestamp <unix-seconds> | --minute-offset <uint>) [--build YYYYMMDDHHMM] [--page <class>] [--app 0...9999] [--note <a-z0-9_ <=6>]
"""

// MARK: - expect 子命令：写入端期望值 → JSON（字段名与 --json 一致，供编码端对账）

func runExpect(_ args: [String]) -> Never {
    func arg(_ i: Int) -> String { i + 1 < args.count ? args[i + 1] : "" }
    var uid: UInt32?
    var timestamp: UInt64?
    var minuteOffset: UInt32?
    var build: String?
    var page: String?
    var app: UInt16?
    var note: String?
    var i = 0
    while i < args.count {
        defer { i += 1 }
        switch args[i] {
        case "--uid": uid = UInt32(arg(i)); i += 1
        case "--timestamp": timestamp = UInt64(arg(i)); i += 1
        case "--minute-offset": minuteOffset = UInt32(arg(i)); i += 1
        case "--build": build = arg(i); i += 1
        case "--page": page = arg(i); i += 1
        case "--app": app = UInt16(arg(i)); i += 1
        case "--note": note = arg(i); i += 1
        default: fail("expect 不支持的参数: \(args[i])")
        }
    }
    guard let uid else { fail("expect 需要 --uid") }
    guard (timestamp != nil) != (minuteOffset != nil) else { fail("expect 需要 --timestamp 或 --minute-offset 二选一") }

    // JSON 只回原始数据（写入什么回什么），不做时区转换或格式化。
    // 解码侧 --json 输出的是展示格式（UTC 字符串）；对账时比较原始值。
    var json: [String: Any] = ["uid": uid]
    if let ts = timestamp {
        json["timestamp"] = ts
        json["stripMinuteOffset"] = UInt32(max(0, (Int64(ts) - Int64(WatermarkPayload.timestampEpoch)) / 60))
    } else if let m = minuteOffset {
        json["stripMinuteOffset"] = m
        json["timestamp"] = WatermarkPayload.timestampEpoch + UInt64(m) * 60
    }

    // CFBundleVersion 原样回传：接入端把它按 UTC 解析成分钟偏移写入，
    // 期望值工具只负责回显写入值本身，不做二次解释。
    if let build, !build.isEmpty {
        guard build.count == 12, build.allSatisfy(\.isNumber) else { fail("--build 需要 12 位数字 YYYYMMDDHHMM") }
        json["build"] = build
    }

    if let page, !page.isEmpty {
        guard let payload = WatermarkPayload(uid: uid, timestampOffset: 0, buildMinuteOffset: 0,
                                             pageClassName: page, app: app ?? 0, note: note ?? "") else {
            fail("page/note 不合法（page 归一化后 ≤8 字符，note 仅 [a-z0-9_] ≤6 字符）")
        }
        json["page"] = payload.pageNameCode
    }
    if let app { json["app"] = app }
    if let note, !note.isEmpty { json["note"] = note }

    print(toJSON(json))
    exit(0)
}

func toJSON(_ dict: [String: Any]) -> String {
    var out = "{"
    var first = true
    func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
        if !first { out += "," }
        first = false
        switch v {
        case let s as String: out += esc(k) + ":" + esc(s)
        case let n as Int: out += esc(k) + ":\(n)"
        case let n as UInt32: out += esc(k) + ":\(n)"
        case let n as UInt64: out += esc(k) + ":\(n)"
        case let n as UInt16: out += esc(k) + ":\(n)"
        case let b as Bool: out += esc(k) + ":\(b)"
        default: out += esc(k) + ":null"
        }
    }
    return out + "}"
}

// MARK: - 图片解码

var path: String?
var layout = false
var wantStrip = false
var stripOnly = false
var wantJson = false
var plane = WatermarkPlane.chroma
var scale: Double?
var offset: (Double, Double)?
let arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, first == "expect" {
    runExpect(Array(arguments.dropFirst()))
}
var index = 0
func next() -> String {
    index += 1
    guard index < arguments.count else { fail("参数缺少值") }
    return arguments[index]
}
while index < arguments.count {
    switch arguments[index] {
    case "--help", "-h":
        print(usage)
        exit(0)
    case "--layout": layout = true
    case "--strip": wantStrip = true
    case "--strip-only": wantStrip = true; stripOnly = true
    case "--json": wantJson = true
    case "--auto": break // v6 默认搜索几何；保留这个明确的开关，不做跨协议回退。
    case "--protocol": guard next() == "v6" else { fail("只支持 v6；历史截图请使用旧版本工具") }
    case "--plane":
        guard let value = WatermarkPlane(rawValue: next()) else { fail("--plane 需要 chroma 或 luma") }
        plane = value
    case "--scale":
        guard let value = Double(next()), value.isFinite, (0.5...1.5).contains(value) else { fail("--scale 需要 0.5...1.5") }
        scale = value
    case "--offset":
        let parts = next().split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]),
              x.isFinite, y.isFinite, x >= 0, y >= 0 else { fail("--offset 需要非负 X,Y") }
        offset = (x, y)
    default:
        guard path == nil, !arguments[index].hasPrefix("-") else { fail("不支持的参数: \(arguments[index])") }
        path = arguments[index]
    }
    index += 1
}
guard let path else { fail(usage) }
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil), let image = RGBAImage(cgImage: cg) else { fail("无法读取图片", code: 1) }
let working: RGBAImage
let trim: UniformBorderTrim
if offset == nil {
    (working, trim) = image.trimmingUniformDarkBorder()
} else {
    working = image
    trim = .none
}
let decoded: V6Codec.Decoded?
if stripOnly {
    // 只解条码时跳过 v6 几何搜索（未知比例全档穷举是分钟级）
    decoded = nil
} else if let offset {
    decoded = V6Codec.decode(working, plane: plane, scale: scale ?? 1,
                             offsetX: offset.0, offsetY: offset.1, searchTile: true)
} else {
    decoded = V6Codec.decodeBest(working, scales: scale.map { [$0] }, plane: plane)
}

// 条码层用未裁边图：条码在画面最顶/最底，黑边裁剪可能把条一起裁掉。
let stripDecoded = (wantStrip || wantJson) ? StripWatermark.decode(image: image) : nil

var json: [String: Any] = [:]

if let result = decoded, !result.ambiguous, let payload = result.payload {
    let verdict = result.hasSufficientEvidence ? "OK" : "TOO_SMALL(每 bit 最少 \(result.minObservations) 次，需要 ≥ 5)"
    print(String(format: "protocol=v6 payload=0x%@ plane=%@ phase=(%.2f,%.2f) tileShift=(%d,%d) scale=%.6f correctedBits=%d softRecovery=%@ companionRecovery=%@ pilotScore=%.3f minObs=%d avgObs=%.1f |z|中位=%.1f %@%@",
                 payload.bytes.map { String(format: "%02x", $0) }.joined(), plane.rawValue,
                 result.offsetX, result.offsetY, result.tileShiftX, result.tileShiftY, result.estimatedScale,
                 result.correctedBits, result.softRecoveryUsed ? "true" : "false",
                 result.companionRecoveryUsed ? "true" : "false", result.pilotScore,
                 result.minObservations, result.averageObservations, result.medianAbsZ, verdict,
                 trim.outputField.map { " " + $0 } ?? ""))
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    if result.hasSufficientEvidence {
        json["v6"] = [
            "uid": payload.uid,
            "time": formatter.string(from: Date(timeIntervalSince1970: Double(payload.timestamp))),
            "buildTime": formatter.string(from: Date(timeIntervalSince1970: Double(payload.buildTime))),
            "page": payload.pageNameCode,
            "app": payload.app,
            "note": payload.note.isEmpty ? "" : payload.note,
            "correctedBits": result.correctedBits,
            "companionRecovery": result.companionRecoveryUsed,
            "minObs": result.minObservations,
        ] as [String: Any]
        if layout {
            print("uid=\(payload.uid) time=\(formatter.string(from: Date(timeIntervalSince1970: Double(payload.timestamp)))) page=\(payload.pageNameCode) buildTime=\(formatter.string(from: Date(timeIntervalSince1970: Double(payload.buildTime)))) app=\(payload.app) note=\(payload.note.isEmpty ? "（空）" : payload.note) crcStatus=OK(完整性自检,未验签)")
        }
    } else {
        // TOO_SMALL：观测不足不解读字段；stderr 警告，退出码契约见尾部
        FileHandle.standardError.write(Data("观测不足，不解读字段，请使用范围更大的原图。\n".utf8))
    }
} else if decoded == nil {
    json["v6"] = "NO"
} else {
    json["v6"] = "ambiguous"
}

if wantStrip || wantJson {
    if let s = stripDecoded {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        let minute = WatermarkPayload.timestampEpoch + UInt64(s.minuteOffset) * 60
        print("strip=OK edge=\(s.edge.rawValue) uid=\(s.uid) time=\(formatter.string(from: Date(timeIntervalSince1970: Double(minute)))) fixedBits=\(s.fixedBits) crcStatus=OK(完整性自检,未验签)")
        json["strip"] = [
            "uid": s.uid,
            "time": formatter.string(from: Date(timeIntervalSince1970: Double(minute))),
            "fixedBits": s.fixedBits,
            "edge": s.edge.rawValue,
        ] as [String: Any]
    } else if wantStrip {
        print("strip=NO")
        json["strip"] = "NO"
    }
}

if wantJson {
    print(toJSON(json))
}

if decoded == nil, stripDecoded == nil {
    fail("NO(protocol=v6 与 strip 均无有效载荷)", code: 1)
}
if let result = decoded, (result.ambiguous || result.payload == nil), stripDecoded == nil {
    fail("ambiguous(protocol=v6，多个不同载荷，拒绝解读)", code: 1)
}
if let result = decoded, !result.ambiguous, result.payload != nil, !result.hasSufficientEvidence {
    // v6 TOO_SMALL 的历史契约：带 --layout exit 1，否则 0；strip 有解不改变它
    exit(layout ? 1 : 0)
}
