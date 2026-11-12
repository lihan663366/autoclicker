//
//  Tweak.xm — 注入 SpringBoard，加载悬浮球
//
//  注入目标由 AutoClicker.plist 决定（默认 com.apple.springboard）。
//  想只在某个 App 里生效，把 plist 的 Bundles 换成该 App 的 bundle id 即可，代码无需改动。
//

#import "ACUI.h"

%ctor {
    if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) return;

    // 等 SpringBoard 的窗口体系就绪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[ACManager shared] setup];
    });
}
