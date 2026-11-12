//
//  ACCore.m — IOHID 触摸注入 + 连点引擎
//

#import "ACCore.h"
#import "ACDebug.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/message.h>

#pragma mark - 私有 IOHID 接口
// 全部走 dlsym，编译期不依赖 PrivateFrameworks/IOKit，避免链接失败导致 tweak 整个加载不上。

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

enum {
    kACTransducerHand = 3,      // kIOHIDDigitizerTransducerTypeHand
    kACEventRange     = 1 << 0, // kIOHIDDigitizerEventRange
    kACEventTouch     = 1 << 1, // kIOHIDDigitizerEventTouch
};

/// IOHIDEventSystemClientType
/// iOS 15 起 IOHIDEventSystemClientCreate() 返回的 default client 已经不能派发事件：
/// 调用 IOHIDEventSystemClientDispatchEvent 不报错，但事件被静默丢弃。
/// 必须显式创建 Monitor / Administrator 类型的 client。
enum {
    kACClientTypeDefault       = 0,
    kACClientTypeMonitor       = 1,
    kACClientTypeAdministrator = 2,
};

typedef IOHIDEventSystemClientRef (*ACFnCreateClient)(CFAllocatorRef);
typedef IOHIDEventSystemClientRef (*ACFnCreateClientWithType)(CFAllocatorRef, int, CFDictionaryRef);
typedef void (*ACFnSchedule)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
typedef void (*ACFnDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*ACFnSetProperty)(IOHIDEventSystemClientRef, CFStringRef, CFTypeRef);
typedef IOHIDEventRef (*ACFnCreateEvent)(CFAllocatorRef, uint64_t, int,
                                         uint32_t, uint32_t, uint32_t, uint32_t,
                                         double, double, double, double, double,
                                         bool, bool, uint32_t);
typedef IOHIDEventRef (*ACFnCreateFinger)(CFAllocatorRef, uint64_t,
                                          uint32_t, uint32_t, uint32_t,
                                          double, double, double, double, double,
                                          bool, bool, uint32_t);
typedef void (*ACFnAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*ACFnSetInteger)(IOHIDEventRef, uint32_t, int64_t);

static IOHIDEventSystemClientRef sClient       = NULL;
static int                       sClientType   = -1;
static ACFnDispatch              sDispatch     = NULL;
static ACFnCreateEvent           sCreateEvent  = NULL;
static ACFnCreateFinger          sCreateFinger = NULL;
static ACFnAppend                sAppend       = NULL;
static ACFnSetInteger            sSetInteger   = NULL;

static ACInjectChannel sChannel      = ACInjectChannelNone;
static BOOL            sUserOverride = NO;   // 用户手动指定过通道后不再自动改

void ACBuzz(int times) {
    if (times <= 0) return;
    for (int i = 0; i < times; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.38 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        });
    }
}

BOOL ACIsSpringBoard(void) {
    static BOOL sb = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 这里会被 ctor 直接调用，绝对不能写日志 —— 碰文件系统会拖慢甚至搞崩
        // SpringBoard 启动，被 Dopamine 拉黑之后就再也注入不进来了。
        NSString *n = [NSProcessInfo processInfo].processName;
        NSString *b = [NSBundle mainBundle].bundleIdentifier;
        sb = [n isEqualToString:@"SpringBoard"] ||
             [b isEqualToString:@"com.apple.springboard"];
    });
    return sb;
}

static void ACEnsureSymbols(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) {
            ACDLog(@"!! dlopen IOKit failed: %s", dlerror());
            return;
        }

        ACFnCreateClient          createPlain = (ACFnCreateClient)dlsym(h, "IOHIDEventSystemClientCreate");
        ACFnCreateClientWithType  createTyped = (ACFnCreateClientWithType)dlsym(h, "IOHIDEventSystemClientCreateWithType");
        ACFnSchedule              schedule    = (ACFnSchedule)dlsym(h, "IOHIDEventSystemClientScheduleWithRunLoop");
        ACFnSetProperty           setProp     = (ACFnSetProperty)dlsym(h, "IOHIDEventSystemClientSetProperty");

        sDispatch     = (ACFnDispatch)dlsym(h, "IOHIDEventSystemClientDispatchEvent");
        sCreateEvent  = (ACFnCreateEvent)dlsym(h, "IOHIDEventCreateDigitizerEvent");
        sCreateFinger = (ACFnCreateFinger)dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
        sAppend       = (ACFnAppend)dlsym(h, "IOHIDEventAppendEvent");
        sSetInteger   = (ACFnSetInteger)dlsym(h, "IOHIDEventSetIntegerValue");

        ACDLog(@"symbols: dispatch=%d createEvent=%d createFinger=%d append=%d typedCreate=%d",
               sDispatch != NULL, sCreateEvent != NULL, sCreateFinger != NULL,
               sAppend != NULL, createTyped != NULL);

        // iOS 15+ 必须用带 type 的创建函数，Monitor 类型才能派发
        if (createTyped) {
            for (int t = kACClientTypeMonitor; t >= kACClientTypeDefault; t--) {
                IOHIDEventSystemClientRef c = createTyped(kCFAllocatorDefault, t, NULL);
                if (!c) continue;
                if (schedule) schedule(c, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
                // 只订阅 digitizer 页，某些系统上不设会收不到/发不出
                if (setProp) setProp(c, CFSTR("PrimaryUsagePage"), (__bridge CFTypeRef)@(0x0D));
                sClient = c;
                sClientType = t;
                ACDLog(@"client created with type=%d", t);
                break;
            }
        }
        if (!sClient && createPlain) {
            sClient = createPlain(kCFAllocatorDefault);
            if (sClient && schedule) schedule(sClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
            sClientType = kACClientTypeDefault;
            ACDLog(@"client created with legacy IOHIDEventSystemClientCreate (type=0)");
        }
        if (!sClient) ACDLog(@"!! 所有 client 创建失败");
    });
}

static CGFloat ACScale(void) {
    static CGFloat s = 0;
    if (s <= 0) s = [UIScreen mainScreen].scale;
    return s > 0 ? s : 2.0;
}

#pragma mark - 通道探测

NSString *ACInjectChannelName(ACInjectChannel ch) {
    switch (ch) {
        case ACInjectChannelDispatch: return @"HID 派发";
        case ACInjectChannelEnqueue:  return @"事件队列";
        default:                      return @"不可用";
    }
}

ACInjectChannel ACInjectActiveChannel(void) {
    if (sChannel == ACInjectChannelNone) ACRefreshInjectChannel();
    return sChannel;
}

/// 用户在面板上手动切换通道。两条路在不同系统版本上有效性不一样，
/// 自动猜错的时候让用户自己试一次最快。
void ACSetInjectChannel(ACInjectChannel ch) {
    sUserOverride = YES;
    sChannel = ch;
    ACDLog(@"channel overridden by user -> %@", ACInjectChannelName(ch));
}

BOOL ACIsChannelOverridden(void) { return sUserOverride; }

ACInjectChannel ACRefreshInjectChannel(void) {
    ACEnsureSymbols();

    BOOL canDispatch = (sClient && sDispatch && sCreateEvent);
    BOOL canEnqueue  = [[UIApplication sharedApplication]
                           respondsToSelector:NSSelectorFromString(@"_enqueueHIDEvent:")]
                       && sCreateEvent != NULL;

    if (sUserOverride) {
        ACDLog(@"channel kept (user override) = %@", ACInjectChannelName(sChannel));
        return sChannel;
    }

    if (ACIsSpringBoard()) {
        // SpringBoard 有 HID entitlement，派发能把点击送到任意 App。
        // 但如果 client 是 legacy default 类型，派发在 iOS 15+ 会静默失效 —— 此时用事件队列，
        // SpringBoard 的 _enqueueHIDEvent: 就是系统事件入口，同样会转发给前台 App。
        if (canDispatch && sClientType != kACClientTypeDefault) {
            sChannel = ACInjectChannelDispatch;
        } else if (canEnqueue) {
            sChannel = ACInjectChannelEnqueue;
        } else if (canDispatch) {
            sChannel = ACInjectChannelDispatch;
        } else {
            sChannel = ACInjectChannelNone;
        }
    } else {
        // App 进程没有 HID entitlement，派发调用会静默失败。
        // 这里绝不能退到 dispatch，否则界面显示"正常"但一次都点不动。
        sChannel = canEnqueue ? ACInjectChannelEnqueue : ACInjectChannelNone;
    }

    ACDLog(@"channel = %@ (canDispatch=%d clientType=%d canEnqueue=%d)",
           ACInjectChannelName(sChannel), canDispatch, sClientType, canEnqueue);
    return sChannel;
}

#pragma mark - 事件构造

/// 构造一次完整的手指事件。坐标单位是物理像素，与 IOHID 层一致。
static IOHIDEventRef ACMakeHand(CGPoint point, BOOL down) {
    if (!sCreateEvent) return NULL;

    const CGFloat k = ACScale();
    double x  = point.x * k;
    double y  = point.y * k;
    uint64_t ts = mach_absolute_time();

    uint32_t mask = down ? (kACEventRange | kACEventTouch) : 0;
    double   press = down ? 1.0 : 0.0;

    IOHIDEventRef hand = sCreateEvent(kCFAllocatorDefault, ts, kACTransducerHand,
                                      0, 1, mask, 0,
                                      x, y, 0.0, press, 0.0,
                                      (bool)down, (bool)down, 0);
    if (!hand) return NULL;

    // 挂一根手指进去，UIKit 的事件识别依赖 finger 子事件才会认成真实触摸
    if (sCreateFinger && sAppend) {
        IOHIDEventRef finger = sCreateFinger(kCFAllocatorDefault, ts, 0, 1, mask,
                                             x, y, 0.0, press, 0.0,
                                             (bool)down, (bool)down, 0);
        if (finger) {
            sAppend(hand, finger, 0);
            CFRelease(finger);
        }
    }
    return hand;
}

#pragma mark - 注入实现

/// 系统级派发：需要带 HID entitlement 的进程 + 非 default 类型的 client
static void ACInjectViaDispatch(CGPoint point) {
    if (!sClient || !sDispatch || !sCreateEvent) {
        ACDLog(@"!! dispatch 通道符号缺失，跳过");
        return;
    }

    IOHIDEventRef down = ACMakeHand(point, YES);
    if (!down) { ACDLog(@"!! 构造 down 事件失败"); return; }
    sDispatch(sClient, down);
    CFRelease(down);

    // 8ms 后再抬起，太快会被系统合并成一次无效触摸
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        IOHIDEventRef up = ACMakeHand(point, NO);
        if (!up) return;
        sDispatch(sClient, up);
        CFRelease(up);
    });
}

/// 事件队列：私有方法 -[UIApplication _enqueueHIDEvent:]，把事件直接塞进本进程的
/// UIKit 事件流。不需要任何 entitlement，这是 App 内注入唯一稳定的通道。
static void ACInjectViaEnqueue(CGPoint point) {
    UIApplication *app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"_enqueueHIDEvent:");
    if (![app respondsToSelector:sel]) {
        ACDLog(@"!! UIApplication 没有 _enqueueHIDEvent:");
        return;
    }

    typedef void (*ACFnSend)(id, SEL, id);
    ACFnSend send = (ACFnSend)objc_msgSend;

    // 事件交给 UIKit 后不能立刻释放：不同系统版本对 _enqueueHIDEvent: 内部持有
    // 的时机不一致，立刻 CFRelease 有 use-after-free 的风险。延迟 1 秒回收。
    IOHIDEventRef down = ACMakeHand(point, YES);
    if (!down) { ACDLog(@"!! 构造 down 事件失败"); return; }
    send(app, sel, (__bridge id)down);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ CFRelease(down); });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        IOHIDEventRef up = ACMakeHand(point, NO);
        if (!up) return;
        send([UIApplication sharedApplication], sel, (__bridge id)up);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ CFRelease(up); });
    });
}

static NSInteger sTapLogBudget = 8;   // 只记录前几次点击，避免日志刷爆

void ACInjectTap(CGPoint point) {
    if (sChannel == ACInjectChannelNone) ACRefreshInjectChannel();

    if (sTapLogBudget > 0) {
        sTapLogBudget--;
        ACDLog(@"tap (%.1f, %.1f) via %@ scale=%.1f",
               point.x, point.y, ACInjectChannelName(sChannel), ACScale());
    }

    switch (sChannel) {
        case ACInjectChannelDispatch: ACInjectViaDispatch(point); break;
        case ACInjectChannelEnqueue:  ACInjectViaEnqueue(point);  break;
        default: break;
    }
}

CGPoint ACRandomPointInRect(CGRect rect) {
    if (CGRectIsEmpty(rect) || rect.size.width <= 1 || rect.size.height <= 1) {
        return CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    }
    CGFloat rx = (CGFloat)arc4random_uniform(10001) / 10000.0f;
    CGFloat ry = (CGFloat)arc4random_uniform(10001) / 10000.0f;
    return CGPointMake(rect.origin.x + rx * rect.size.width,
                       rect.origin.y + ry * rect.size.height);
}

#pragma mark - 引擎

@interface ACEngine ()
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) dispatch_queue_t  queue;
@end

@implementation ACEngine

+ (instancetype)shared {
    static ACEngine *obj;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ obj = [[ACEngine alloc] init]; });
    return obj;
}

- (instancetype)init {
    if (self = [super init]) {
        _interval = 0.20;
        _maxTaps  = 0;
        _mode     = ACTapModePoint;
        _point    = CGPointMake(200, 400);
        _region   = CGRectZero;
        _running  = NO;
        _tapCount = 0;
        _queue = dispatch_queue_create("com.acme.autoclicker.tap", DISPATCH_QUEUE_SERIAL);
        [self loadSettings];
    }
    return self;
}

- (void)start {
    if (_running) return;

    if (_mode == ACTapModeRegion && (CGRectIsEmpty(_region) || _region.size.width < 4 || _region.size.height < 4)) {
        _mode = ACTapModePoint;   // 区域无效，退回单点
    }

    _tapCount = 0;
    _running  = YES;
    sTapLogBudget = 8;

    NSTimeInterval iv = _interval;
    if (iv < 0.02) iv = 0.02;
    if (iv > 5.0)  iv = 5.0;

    uint64_t intervalNs = (uint64_t)(iv * (double)NSEC_PER_SEC);
    uint64_t leewayNs   = (uint64_t)(2 * NSEC_PER_MSEC);

    ACDLog(@"engine start: interval=%.3fs max=%ld mode=%ld point=(%.1f,%.1f) region=(%.1f,%.1f,%.1f,%.1f) channel=%@",
           iv, (long)_maxTaps, (long)_mode, _point.x, _point.y,
           _region.origin.x, _region.origin.y, _region.size.width, _region.size.height,
           ACInjectChannelName(ACInjectActiveChannel()));

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNs),
                              intervalNs, leewayNs);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        __strong typeof(self) self_ = weakSelf;
        if (!self_ || !self_.running) return;

        CGPoint p = (self_.mode == ACTapModeRegion) ? ACRandomPointInRect(self_.region) : self_.point;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strong = weakSelf;
            if (strong.willTap) strong.willTap();
            ACInjectTap(p);
            if (strong.didTap) strong.didTap();
        });

        BOOL shouldStop = NO;
        @synchronized (self_) {
            self_->_tapCount += 1;
            if (self_.maxTaps > 0 && self_->_tapCount >= self_.maxTaps) shouldStop = YES;
        }
        if (shouldStop) [self_ stop];
    });

    self.timer = t;
    dispatch_resume(t);

    [self saveSettings];
    [self notify];
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
    ACDLog(@"engine stop: total=%ld", (long)_tapCount);
    [self saveSettings];
    [self notify];
}

- (void)notify {
    void (^h)(void) = self.stateHandler;
    if (!h) return;
    if ([NSThread isMainThread]) h();
    else dispatch_async(dispatch_get_main_queue(), h);
}

#pragma mark - 持久化

- (void)saveSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:self.interval forKey:@"ac_interval"];
    [d setInteger:self.maxTaps forKey:@"ac_maxTaps"];
    [d setInteger:self.mode    forKey:@"ac_mode"];
    [d setDouble:self.point.x  forKey:@"ac_point_x"];
    [d setDouble:self.point.y  forKey:@"ac_point_y"];
    [d setDouble:self.region.origin.x    forKey:@"ac_region_x"];
    [d setDouble:self.region.origin.y    forKey:@"ac_region_y"];
    [d setDouble:self.region.size.width  forKey:@"ac_region_w"];
    [d setDouble:self.region.size.height forKey:@"ac_region_h"];
    [d synchronize];
}

- (void)loadSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:@"ac_interval"]) self.interval = [d doubleForKey:@"ac_interval"];
    if ([d objectForKey:@"ac_maxTaps"])  self.maxTaps  = [d integerForKey:@"ac_maxTaps"];
    if ([d objectForKey:@"ac_mode"])     self.mode     = (ACTapMode)[d integerForKey:@"ac_mode"];

    if ([d objectForKey:@"ac_point_x"]) {
        self.point = CGPointMake([d doubleForKey:@"ac_point_x"], [d doubleForKey:@"ac_point_y"]);
    }
    if ([d objectForKey:@"ac_region_w"]) {
        self.region = CGRectMake([d doubleForKey:@"ac_region_x"], [d doubleForKey:@"ac_region_y"],
                                 [d doubleForKey:@"ac_region_w"], [d doubleForKey:@"ac_region_h"]);
    }
    if (self.interval < 0.02 || self.interval > 5.0) self.interval = 0.20;
}

@end
