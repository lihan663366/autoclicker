//
//  ACUI.h — 悬浮球 / 设置面板 / 区域框选
//

#import <UIKit/UIKit.h>

@interface ACManager : NSObject

+ (instancetype)shared;

/// 在 SpringBoard 里建立悬浮窗，只执行一次
- (void)setup;

@end
