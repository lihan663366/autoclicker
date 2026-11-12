//
//  ACCore.h — 触摸注入 + 连点引擎
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ACTapMode) {
    ACTapModePoint  = 0,   // 固定单点
    ACTapModeRegion = 1,   // 区域内随机落点
};

/// 向系统注入一次点击（down + up）
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

+ (instancetype)shared;

- (void)start;
- (void)stop;
- (void)saveSettings;
- (void)loadSettings;

@end
