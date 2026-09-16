import UIKit

/// 程序生成的「照片」：多倍频值噪声 + 随机矩形边缘。
/// 目的是造出接近真实照片的高频细节与硬边缘，用来压测水印在这些内容上还剩多少信噪比。
/// 不引资源文件，保持 Demo 自重为零。
enum NoiseImage {
    static let shared: UIImage = make(size: 384)

    private static func make(size: Int) -> UIImage {
        var pixels = [UInt8](repeating: 255, count: size * size * 4)

        // 三个倍频叠加，越细的倍频权重越低
        let octaves: [(grid: Int, weight: Double)] = [(12, 0.55), (24, 0.30), (48, 0.15)]
        var field = [Double](repeating: 0, count: size * size)
        for (grid, weight) in octaves {
            var lattice = [Double](repeating: 0, count: grid * grid)
            for i in 0..<lattice.count { lattice[i] = Double.random(in: 0...1) }
            for y in 0..<size {
                let gy = Double(y) / Double(size) * Double(grid - 1)
                let y0 = Int(gy)
                let y1 = min(y0 + 1, grid - 1)
                let fy = gy - Double(y0)
                for x in 0..<size {
                    let gx = Double(x) / Double(size) * Double(grid - 1)
                    let x0 = Int(gx)
                    let x1 = min(x0 + 1, grid - 1)
                    let fx = gx - Double(x0)
                    let top = lattice[y0 * grid + x0] * (1 - fx) + lattice[y0 * grid + x1] * fx
                    let bottom = lattice[y1 * grid + x0] * (1 - fx) + lattice[y1 * grid + x1] * fx
                    field[y * size + x] += (top * (1 - fy) + bottom * fy) * weight
                }
            }
        }

        // 随机色偏 + 硬边缘矩形，模拟照片里的物体边界
        let tint = (Double.random(in: 0.75...1.15), Double.random(in: 0.75...1.1), Double.random(in: 0.8...1.2))
        var rectangles: [(x: Int, y: Int, w: Int, h: Int, value: Double)] = []
        for _ in 0..<14 {
            rectangles.append((
                Int.random(in: -size / 4..<size),
                Int.random(in: -size / 4..<size),
                Int.random(in: size / 12..<size / 3),
                Int.random(in: size / 12..<size / 3),
                Double.random(in: 0...1)
            ))
        }

        for y in 0..<size {
            for x in 0..<size {
                var value = field[y * size + x]
                for rect in rectangles where x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h {
                    value = rect.value
                }
                let i = (y * size + x) * 4
                pixels[i] = UInt8(clamping: Int(value * tint.0 * 255))
                pixels[i + 1] = UInt8(clamping: Int(value * tint.1 * 255))
                pixels[i + 2] = UInt8(clamping: Int(value * tint.2 * 255))
                pixels[i + 3] = 255
            }
        }

        let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let cgImage = context?.makeImage() else {
            return UIImage()
        }
        return UIImage(cgImage: cgImage)
    }
}
