import BlindWatermarkCore
import Foundation
import ImageIO

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = "bwdecode <image> [--layout] [--scale 0.5...1.5] [--offset X,Y] [--plane chroma|luma] [--auto] [--protocol v6]"
var path: String?
var layout = false
var plane = WatermarkPlane.chroma
var scale: Double?
var offset: (Double, Double)?
let arguments = Array(CommandLine.arguments.dropFirst())
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
if let offset {
    decoded = V6Codec.decode(working, plane: plane, scale: scale ?? 1,
                             offsetX: offset.0, offsetY: offset.1, searchTile: true)
} else {
    decoded = V6Codec.decodeBest(working, scales: scale.map { [$0] }, plane: plane)
}
guard let result = decoded else { fail("NO(protocol=v6，无 BCH + CRC-valid 载荷)", code: 1) }
guard !result.ambiguous, let payload = result.payload else { fail("ambiguous(protocol=v6，多个不同载荷，拒绝解读)", code: 1) }
let verdict = result.hasSufficientEvidence ? "OK" : "TOO_SMALL(每 bit 最少 \(result.minObservations) 次，需要 ≥ 5)"
print(String(format: "protocol=v6 payload=0x%@ plane=%@ phase=(%.2f,%.2f) tileShift=(%d,%d) scale=%.6f correctedBits=%d softRecovery=%@ companionRecovery=%@ pilotScore=%.3f minObs=%d avgObs=%.1f |z|中位=%.1f %@%@",
             payload.bytes.map { String(format: "%02x", $0) }.joined(), plane.rawValue,
             result.offsetX, result.offsetY, result.tileShiftX, result.tileShiftY, result.estimatedScale,
             result.correctedBits, result.softRecoveryUsed ? "true" : "false",
             result.companionRecoveryUsed ? "true" : "false", result.pilotScore,
             result.minObservations, result.averageObservations, result.medianAbsZ, verdict,
             trim.outputField.map { " " + $0 } ?? ""))
if !result.hasSufficientEvidence {
    FileHandle.standardError.write(Data("观测不足，不解读字段，请使用范围更大的原图。\n".utf8))
    exit(layout ? 1 : 0)
}
if layout {
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    print("uid=\(payload.uid) time=\(formatter.string(from: Date(timeIntervalSince1970: Double(payload.timestamp)))) page=\(payload.pageNameCode) buildTime=\(formatter.string(from: Date(timeIntervalSince1970: Double(payload.buildTime)))) app=\(payload.app) note=\(payload.note.isEmpty ? "（空）" : payload.note) crcStatus=OK(完整性自检,未验签)")
}
