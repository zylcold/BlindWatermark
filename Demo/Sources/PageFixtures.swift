import UIKit

// 演示用的「受监控页面」占位类。
//
// 真实项目里这些类本来就存在，agent 拿到短码后 `grep -rin "class.*phot"` 就能定位。
// Demo 是 SwiftUI 写的、没有这些 VC，为了让「短码 → grep → 类名」这条链路
// 在这里也能端到端跑通，显式声明出同名类。
//
// 接入端只要把真正想监控的类名登记进 PageRegistry，接法与此无关。

final class BHPlainViewController: UIViewController {}
final class BHWhiteChatViewController: UIViewController {}
final class BHTextListViewController: UIViewController {}
final class BHPhotoGridViewController: UIViewController {}
final class BHDarkModeViewController: UIViewController {}
final class BHMixedFeedViewController: UIViewController {}
