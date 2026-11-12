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

#import "ACUI.h"
#import "ACCore.h"
#import "ACDebug.h"

%ctor {
    ACDLog(@"=========== AutoClicker 1.2.0 loaded ===========");
    ACDLog(@"bundle=%@ executable=%@",
           [NSBundle mainBundle].bundleIdentifier ?: @"?",
           [NSBundle mainBundle].executablePath ?: @"?");

    BOOL isSB = ACIsSpringBoard();
    ACRefreshInjectChannel();

    // SpringBoard 要等它把窗口体系铺完；App 进程 scene 就绪快得多
    NSTimeInterval delay = isSB ? 3.0 : 0.35;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[ACManager shared] setup];
    });
}
