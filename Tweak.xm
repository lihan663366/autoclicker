//
//  Tweak.xm — 悬浮球入口
//
//  注入目标由 AutoClicker.plist 的 Bundles 决定，而该文件由 Makefile 根据
//  BUNDLE_ID 生成：
//
//      make package BUNDLE_ID=com.apple.springboard   # 全局生效（默认）
//      make package BUNDLE_ID=com.tencent.xin         # 只注入微信
//      make package BUNDLE_ID=com.a,com.b             # 多个 App
//
//  两种宿主的差异：
//
//    SpringBoard —— 有 HID entitlement，优先走 IOHIDEventSystemClientDispatchEvent，
//                   点击可以送到任意 App，但只能盖在 SpringBoard 层。
//    普通 App   —— 没有 HID entitlement，走 -[UIApplication _enqueueHIDEvent:]，
//                   事件只在本进程内生效，窗口也挂在 App 自己的 scene 上。
//
//  所以"注入 App"不是换个 bundle id 就完事，注入通道也得跟着换 —— 下面运行时探测。
//

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <unistd.h>
#import "ACUI.h"
#import "ACCore.h"
#import "ACDebug.h"

%ctor {
    @autoreleasepool {
        // ── 这里只做最轻的事 ────────────────────────────────────────────────
        //
        // ctor 跑在 dyld 装载 dylib 的瞬间，宿主（SpringBoard）还没启动完。
        // 在这个阶段创建 NSDateFormatter、开文件句柄、读 NSUserDefaults，
        // 都有可能把 SpringBoard 打崩；而 Dopamine 对"加载时崩溃"的 tweak
        // 有一套自动拉黑机制 —— 一旦被拉黑，之后不管怎么重装都不会再注入。
        // 表现就是"包装上了、什么都没发生、日志文件都不存在"。
        //
        // 所以：判断宿主 → 排两个延迟任务 → 立刻返回。
        BOOL isSB = ACIsSpringBoard();

        // 1.2 秒后：写日志 + 震动。
        // 震动是"注入成功"的物理证据，不依赖界面、不依赖文件权限、不依赖用户会看日志。
        //   震动了但没浮窗  → 注入没问题，是窗口/显示层的问题
        //   完全没震动      → 根本没注入，去查 Dopamine 的注入开关和安装位置
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ACDLog(@"=========== AutoClicker 1.4.1 loaded ===========");
            ACDLog(@"pid=%d host=%@ bundle=%@",
                   (int)getpid(),
                   isSB ? @"SpringBoard" : @"App",
                   [NSBundle mainBundle].bundleIdentifier ?: @"?");
            ACBuzz(1);   // 第 1 下：dylib 确实被注入了
        });

        // SpringBoard 要把窗口体系铺完才有 scene；App 进程快得多
        NSTimeInterval delay = isSB ? 2.0 : 0.35;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[ACManager shared] setup];
        });
    }
}
