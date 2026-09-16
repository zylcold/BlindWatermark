#if canImport(UIKit)
import Foundation

/// 供 ObjC `+load` 通过 `NSClassFromString(@"LLBlindWatermarkBootstrap")` 找到的入口。
///
/// 不要改名，改名会静默失效（自动加载会退回手动 `Watermark.install`）。
@objc(LLBlindWatermarkBootstrap)
public final class BlindWatermarkBootstrap: NSObject {

    /// 由 ObjC 侧 `performSelector` 调用。
    @objc
    public static func installIfNeeded() {
        WatermarkState.shared.start()
    }
}

#endif
