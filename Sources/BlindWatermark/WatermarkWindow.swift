#if canImport(UIKit)
import UIKit

/// 每个 scene 一个覆盖全屏的水印窗口。
///
/// 不参与交互、不成为 key window，叠加一层低幅度色度载波；可见性需要在目标设备验收。
/// 截图/录屏走 render server 合成，可见窗口的像素随正常系统截图进入产物 —— 不需要 hook 截屏 API。
/// 「抗微信压缩」档在窗口顶部/底部再各画一条 1pt 的可见亮度条码，见 StripWatermark。
final class WatermarkWindow: UIWindow {
    private let host = UIViewController()
    private let stripLayerTop = CALayer()
    private let stripLayerBottom = CALayer()
    /// 条码开关由 WatermarkState.Config.strip 控制；关闭时不挂 layer。
    private var stripEnabled = false

    init(scene: UIWindowScene, pattern: UIImage, level: UIWindow.Level) {
        super.init(windowScene: scene)
        windowLevel = level
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false

        host.view.isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        rootViewController = host

        update(pattern: pattern)
        isHidden = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(pattern: UIImage) {
        host.view.backgroundColor = UIColor(patternImage: pattern)
        host.view.setNeedsDisplay()
    }

    /// 顶部/底部 1pt 条码。`image` 为该屏幕像素宽、1pt 高（scale 行）的亮度条位图。
    func updateStrips(top: UIImage?, bottom: UIImage?) {
        applyStrip(layer: stripLayerTop, image: top, yAxis: 0)
        if let bottom = bottom {
            let h = CGFloat(bottom.size.height * bottom.scale) / max(1, bottom.scale) // 1pt
            applyStrip(layer: stripLayerBottom, image: bottom, yAxis: bounds.height - h)
        } else {
            stripLayerBottom.removeFromSuperlayer()
        }
    }

    private func applyStrip(layer: CALayer, image: UIImage?, yAxis: CGFloat) {
        guard let image = image, stripEnabled else {
            layer.removeFromSuperlayer()
            return
        }
        layer.frame = CGRect(x: 0, y: yAxis, width: bounds.width, height: image.size.height)
        layer.contents = image.cgImage
        layer.contentsGravity = .resizeAspectFill
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        if layer.superlayer == nil {
            host.view.layer.addSublayer(layer)
        }
        layer.setNeedsDisplay()
    }

    func setStripEnabled(_ enabled: Bool) {
        stripEnabled = enabled
        if !enabled {
            stripLayerTop.removeFromSuperlayer()
            stripLayerBottom.removeFromSuperlayer()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 旋转/分屏后重新贴边
        stripLayerTop.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripLayerTop.frame.height)
        stripLayerBottom.frame = CGRect(x: 0, y: bounds.height - stripLayerBottom.frame.height,
                                        width: bounds.width, height: stripLayerBottom.frame.height)
    }
}

#endif
