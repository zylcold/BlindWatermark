#if canImport(UIKit)
import UIKit

/// 每个 scene 一个覆盖全屏的水印窗口。
///
/// 不参与交互、不成为 key window，叠加一层低幅度色度载波；可见性需要在目标设备验收。
/// 截图/录屏走 render server 合成，可见窗口的像素随正常系统截图进入产物 —— 不需要 hook 截屏 API。
final class WatermarkWindow: UIWindow {
    private let host = UIViewController()

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

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

#endif
