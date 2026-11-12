//
//  ACCore.h — 触摸注入 + 连点引擎
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ACTapMode) {
    ACTapModePoint  = 0,   // 固定单点
    ACTapModeRegion = 1,   // 区域内随机落点
};

/// 注入通道。SpringBoard 和普通 App 的权限模型不一样，可用通道也不同。
typedef NS_ENUM(NSInteger, ACInjectChannel) {
    ACInjectChannelNone      = 0,   // 完全没有可用通道
    ACInjectChannelDispatch  = 1,   // IOHIDEventSystemClientDispatchEvent（仅 SpringBoard）
    ACInjectChannelEnqueue   = 2,   // -[UIApplication _enqueueHIDEvent:]（App 内可用，无需 entitlement）
};

/// 用震动次数编码状态，不依赖任何界面、日志、文件权限。
///   1 下 = dylib 已注入
///   2 下 = 窗口已建成
///   3 下 = 注入成功但窗口建不出来（走了兜底或彻底失败）
void ACBuzz(int times);

/// 当前宿主是不是 SpringBoard（决定窗口层级、建窗时机、注入通道）
BOOL ACIsSpringBoard(void);

/// 重新探测注入通道（进程启动后调一次即可）
ACInjectChannel ACRefreshInjectChannel(void);

/// 当前生效的通道
ACInjectChannel ACInjectActiveChannel(void);

/// 手动指定通道（面板上的切换按钮用）。指定后自动探测不再覆盖它。
void ACSetInjectChannel(ACInjectChannel ch);

/// 开关：面板上的切换按钮用
BOOL ACIsChannelOverridden(void);

/// 通道名，用于界面上显示
NSString *ACInjectChannelName(ACInjectChannel ch);

/// 向当前进程注入一次点击（down + up）
void ACInjectTap(CGPoint point);

/// 区域内随机取点；矩形为空时返回其中心
CGPoint ACRandomPointInRect(CGRect rect);

@interface ACEngine : NSObject

@property (nonatomic, assign) CGPoint     point;      // 单点模式落点（屏幕坐标系）
@property (nonatomic, assign) CGRect      region;     // 区域模式矩形（屏幕坐标系）
@property (nonatomic, assign) ACTapMode   mode;
@property (nonatomic, assign) NSTimeInterval interval;  // 点击间隔，0.02 ~ 5.0 秒
@property (nonatomic, assign) NSInteger   maxTaps;    // 0 = 无限

@property (nonatomic, assign, readonly) BOOL      running;
@property (nonatomic, assign, readonly) NSInteger tapCount;

/// 状态变化回调（已派发到主线程）
@property (nonatomic, copy) void (^stateHandler)(void);

/// 每次注入前 / 后调用（主线程）。注入到自己的进程时，
/// 悬浮窗本身就在事件路径上，必须先让开，否则点到的是自己。
@property (nonatomic, copy) void (^willTap)(void);
@property (nonatomic, copy) void (^didTap)(void);

+ (instancetype)shared;

- (void)start;
- (void)stop;
- (void)saveSettings;
- (void)loadSettings;

@end
