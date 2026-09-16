#if canImport(UIKit)
import UIKit

/// 每个 scene 一个覆盖全屏的水印窗口。
///
/// 不参与交互、不成为 key window，只贡献一层几乎不可见的亮度扰动。
/// 截图/录屏走 render server 合成，本窗口的像素必然被带进产物里 —— 不需要 hook 截屏 API。
final class WatermarkWindow: UIWindow {
    private let host = UIViewController()

    init(scene: UIWindowScene, pattern: UIImage) {
        super.init(windowScene: scene)
        // 盖住业务窗口与系统弹窗；alpha 极低，视觉无影响
        windowLevel = .alert + 1
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
