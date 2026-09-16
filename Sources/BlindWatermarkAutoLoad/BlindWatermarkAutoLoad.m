#import "BlindWatermarkAutoLoad.h"
#import <TargetConditionals.h>

void LLBlindWatermarkAutoLoadEnable(void) {}

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>

/// 宿主不写任何代码时，靠 +load 注册系统通知，等 App 起来后再去调用 Swift 侧挂载。
/// +load 阶段 Swift 运行时尚未就绪，所以这里只注册观察者，不做任何符号查找。
@interface LLBlindWatermarkAutoLoader : NSObject
@end

@implementation LLBlindWatermarkAutoLoader

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        // 冷启动：App 激活时挂载
        [nc addObserver:self
               selector:@selector(ll_handleActivation)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
        // 运行中新窗口出现（多 scene / 分屏）时补挂
        [nc addObserver:self
               selector:@selector(ll_handleActivation)
                   name:UIWindowDidBecomeVisibleNotification
                 object:nil];
    });
}

+ (void)ll_handleActivation {
    [self ll_bootstrapSwiftSide];
}

/// 通过 ObjC 运行时按名字找 Swift 类，避免 ObjC 目标反向依赖 Swift 目标（SPM 不支持循环）。
+ (void)ll_bootstrapSwiftSide {
    Class bootstrap = NSClassFromString(@"LLBlindWatermarkBootstrap");
    if (bootstrap == Nil) { return; }
    SEL selector = NSSelectorFromString(@"installIfNeeded");
    if (![bootstrap respondsToSelector:selector]) { return; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [bootstrap performSelector:selector];
#pragma clang diagnostic pop
}

@end

#endif
