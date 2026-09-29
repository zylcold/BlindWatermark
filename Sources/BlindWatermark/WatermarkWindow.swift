#if canImport(UIKit)
import UIKit

/// 每个 scene 一个覆盖全屏的水印窗口。
///
/// 不参与交互、不成为 key window，叠加一层低幅度色度载波；可见性需要在目标设备验收。
/// 截图/录屏走 render server 合成，可见窗口的像素随正常系统截图进入产物 —— 不需要 hook 截屏 API。
/// 「抗微信压缩」档在窗口顶部/底部再各画一条 1pt 的可见亮度条码，见 StripWatermark。
final class WatermarkWindow: UIWindow {
    private let host = UIViewController()
    private let stripTop = UIView()
    private let stripBottom = UIView()
    private var stripEnabled = false
    /// 条码位图（1pt 高、整屏宽，按屏幕 scale 生成）。旋转/换宽后由 refreshStrips 重新生成。
    private var stripImage: UIImage?

    init(scene: UIWindowScene, pattern: UIImage, level: UIWindow.Level) {
        super.init(windowScene: scene)
        windowLevel = level
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false

        host.view.isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        rootViewController = host

        for strip in [stripTop, stripBottom] {
            strip.isUserInteractionEnabled = false
            strip.isHidden = true
        }
        host.view.addSubview(stripTop)
        host.view.addSubview(stripBottom)

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
    /// 用 `UIColor(patternImage:)` 而不是 CALayer.contents：后者在本工程实测不合成（backgroundColor 可见但 contents 不画）。
    func updateStrips(top: UIImage?, bottom: UIImage?) {
        stripImage = top
        if stripEnabled, let stripImage {
            for strip in [stripTop, stripBottom] {
                strip.backgroundColor = UIColor(patternImage: stripImage)
                strip.isHidden = false
            }
        } else {
            for strip in [stripTop, stripBottom] {
                strip.backgroundColor = nil
                strip.isHidden = true
            }
        }
        layoutStrips()
    }

    private func layoutStrips() {
        guard stripEnabled, stripImage != nil else { return }
        let width = stripImage?.size.width ?? bounds.width
        stripTop.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        stripBottom.frame = CGRect(x: 0, y: bounds.height - 1, width: width, height: 1)
    }

    func setStripEnabled(_ enabled: Bool) {
        stripEnabled = enabled
        if !enabled {
            for strip in [stripTop, stripBottom] {
                strip.backgroundColor = nil
                strip.isHidden = true
            }
        } else if stripImage != nil {
            updateStrips(top: stripImage, bottom: stripImage)
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutStrips()
    }
}

#endif
