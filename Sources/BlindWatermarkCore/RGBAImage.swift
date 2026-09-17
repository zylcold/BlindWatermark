import Accelerate
import CoreGraphics
import Foundation

/// 简单 RGBA8 位图，像素为**预乘 alpha**。编码端、解码端、测试共用。
public struct RGBAImage {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    public init?(cgImage: CGImage) {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        self.init(width: w, height: h)
        let ok = self.pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { return nil }
    }

    public func makeCGImage() -> CGImage? {
        // CGBitmapContextCreateImage 会拷贝像素，闭包外使用安全
        var buffer = pixels
        return buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    public mutating func fill(_ rgba: (UInt8, UInt8, UInt8, UInt8)) {
        fillRect(x: 0, y: 0, width: width, height: height, rgba: rgba)
    }

    public mutating func fillRect(x: Int, y: Int, width w: Int, height h: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) {
        let colStart = max(0, x)
        let colEnd = min(width, x + w)
        let rowStart = max(0, y)
        let rowEnd = min(height, y + h)
        guard colEnd > colStart, rowEnd > rowStart else { return }
        // 把 4 字节像素合成一个 UInt32，用 memset_pattern4 按行批量填充，比逐像素写快约 8x
        var pattern = UInt32(rgba.0) | UInt32(rgba.1) << 8 | UInt32(rgba.2) << 16 | UInt32(rgba.3) << 24
        let fillBytes = (colEnd - colStart) * 4
        pixels.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            for row in rowStart..<rowEnd {
                let dst = base.advanced(by: (row * width + colStart) * 4)
                memset_pattern4(dst, &pattern, fillBytes)
            }
        }
    }

    /// 预乘 alpha 的 source-over 合成，复刻 CoreAnimation 的绘制模型。
    /// 用于离线验证：把水印 tile 贴到任意底图上再解码。
    public mutating func blend(_ top: RGBAImage, dx: Int, dy: Int) {
        for y in 0..<top.height {
            let ty = y + dy
            guard ty >= 0, ty < height else { continue }
            for x in 0..<top.width {
                let tx = x + dx
                guard tx >= 0, tx < width else { continue }
                let si = (y * top.width + x) * 4
                let a = Int(top.pixels[si + 3])
                guard a > 0 else { continue }
                let di = (ty * width + tx) * 4
                let inv = 255 - a
                for c in 0..<3 {
                    pixels[di + c] = UInt8(min(255, Int(top.pixels[si + c]) + Int(pixels[di + c]) * inv / 255))
                }
                pixels[di + 3] = UInt8(min(255, a + Int(pixels[di + 3]) * inv / 255))
            }
        }
    }

    /// 按 tile 平铺合成，等价于 `UIColor(patternImage:)` 的铺法。
    /// 离线验证必须用这个：只贴一张 tile 的话，绝大多数 pair 上没有水印，观测统计完全不对。
    public mutating func blendTiled(_ top: RGBAImage, dx: Int = 0, dy: Int = 0) {
        guard top.width > 0, top.height > 0 else { return }
        var y = dy - top.height
        while y < height {
            var x = dx - top.width
            while x < width {
                blend(top, dx: x, dy: y)
                x += top.width
            }
            y += top.height
        }
    }

    /// 解码用的特征平面。逐像素标量，量纲与像素值一致。
    ///
    /// 使用 Accelerate/vDSP 向量化，相较纯 Swift 循环约快 4–8x。
    func featureBuffer(_ plane: WatermarkPlane) -> [Double] {
        let n = width * height
        guard n > 0 else { return [] }

        // 用 vDSP_vfltu8 把交错 RGBA 的各通道以步长 4 直接解交织到独立 Float 数组
        var r = [Float](repeating: 0, count: n)
        var g = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        pixels.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            vDSP_vfltu8(p,     4, &r, 1, vDSP_Length(n))
            vDSP_vfltu8(p + 1, 4, &g, 1, vDSP_Length(n))
            vDSP_vfltu8(p + 2, 4, &b, 1, vDSP_Length(n))
        }

        var result = [Float](repeating: 0, count: n)
        var tmp    = [Float](repeating: 0, count: n)
        switch plane {
        case .luma:
            // result = r * 0.299 + g * 0.587 + b * 0.114
            var wr: Float = 0.299
            var wg: Float = 0.587
            var wb: Float = 0.114
            vDSP_vsmul(r, 1, &wr, &result, 1, vDSP_Length(n))   // result = r * 0.299
            vDSP_vsma(g, 1, &wg, result, 1, &tmp, 1, vDSP_Length(n)) // tmp = g * 0.587 + result
            vDSP_vsma(b, 1, &wb, tmp, 1, &result, 1, vDSP_Length(n)) // result = b * 0.114 + tmp
        case .chroma:
            // result = b - (r + g) / 2
            vDSP_vadd(r, 1, g, 1, &tmp, 1, vDSP_Length(n))      // tmp = r + g
            var half: Float = 0.5
            vDSP_vsmul(tmp, 1, &half, &tmp, 1, vDSP_Length(n))  // tmp = (r + g) / 2
            // vDSP_vsub(B, IB, A, IA, C, IC, N) → C = A - B
            vDSP_vsub(tmp, 1, b, 1, &result, 1, vDSP_Length(n)) // result = b - tmp
        }

        // Float → Double
        var out = [Double](repeating: 0, count: n)
        vDSP_vspdp(result, 1, &out, 1, vDSP_Length(n))
        return out
    }
}
