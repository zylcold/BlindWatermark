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
        for row in y..<(y + h) {
            guard row >= 0, row < height else { continue }
            for col in x..<(x + w) {
                guard col >= 0, col < width else { continue }
                let i = (row * width + col) * 4
                pixels[i] = rgba.0
                pixels[i + 1] = rgba.1
                pixels[i + 2] = rgba.2
                pixels[i + 3] = rgba.3
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
    func featureBuffer(_ plane: WatermarkPlane) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let p = i * 4
            let r = Double(pixels[p])
            let g = Double(pixels[p + 1])
            let b = Double(pixels[p + 2])
            switch plane {
            case .luma:
                out[i] = r * 0.299 + g * 0.587 + b * 0.114
            case .chroma:
                // 蓝-黄对色通道。灰阶内容在这里恒为 0，所以文字/白底界面的内容噪声几乎消失。
                out[i] = b - (r + g) / 2
            }
        }
        return out
    }
}
