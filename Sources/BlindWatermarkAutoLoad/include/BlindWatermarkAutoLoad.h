#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 自动加载开关。
///
/// 本目标存在的唯一目的是提供一个 `+load`，让宿主**零代码**挂载水印层。
/// 但静态库的 `+load` 所在目标文件必须有符号引用才会被链接进来，
/// 因此 Swift 侧需要在启动路径上调用一次本函数（见 `WatermarkState.start()`）。
FOUNDATION_EXPORT void LLBlindWatermarkAutoLoadEnable(void);

NS_ASSUME_NONNULL_END
