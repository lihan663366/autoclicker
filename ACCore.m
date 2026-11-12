//
//  ACCore.m — IOHID 触摸注入 + 连点引擎
//

#import "ACCore.h"
#import <dlfcn.h>
#import <mach/mach_time.h>

#pragma mark - 私有 IOHID 接口
// 全部走 dlsym，编译期不依赖 PrivateFrameworks/IOKit，避免链接失败导致 tweak 整个加载不上。

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

enum {
    kACTransducerHand = 3,      // kIOHIDDigitizerTransducerTypeHand
    kACEventRange     = 1 << 0, // kIOHIDDigitizerEventRange
    kACEventTouch     = 1 << 1, // kIOHIDDigitizerEventTouch
};

typedef IOHIDEventSystemClientRef (*ACFnCreateClient)(CFAllocatorRef);
typedef void (*ACFnSchedule)(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
typedef void (*ACFnDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*ACFnCreateEvent)(CFAllocatorRef, uint64_t, int,
                                         uint32_t, uint32_t, uint32_t, uint32_t,
                                         double, double, double, double, double,
                                         bool, bool, uint32_t);

static IOHIDEventSystemClientRef sClient      = NULL;
static ACFnDispatch              sDispatch    = NULL;
static ACFnCreateEvent           sCreateEvent = NULL;

static void ACEnsureClient(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) return;
        ACFnCreateClient createClient = (ACFnCreateClient)dlsym(h, "IOHIDEventSystemClientCreate");
        ACFnSchedule     schedule     = (ACFnSchedule)dlsym(h, "IOHIDEventSystemClientScheduleWithRunLoop");
        sDispatch    = (ACFnDispatch)dlsym(h, "IOHIDEventSystemClientDispatchEvent");
        sCreateEvent = (ACFnCreateEvent)dlsym(h, "IOHIDEventCreateDigitizerEvent");
        if (createClient) {
            sClient = createClient(kCFAllocatorDefault);
            if (sClient && schedule) {
                schedule(sClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
            }
        }
    });
}

static CGFloat ACScale(void) {
    static CGFloat s = 0;
    if (s <= 0) s = [UIScreen mainScreen].scale;
    return s > 0 ? s : 2.0;
}

#pragma mark - 注入

void ACInjectTap(CGPoint point) {
    ACEnsureClient();
    if (!sClient || !sDispatch || !sCreateEvent) return;

    // digitizer 事件使用物理像素坐标
    const CGFloat k = ACScale();
    double x = point.x * k;
    double y = point.y * k;

    IOHIDEventRef down = sCreateEvent(kCFAllocatorDefault, mach_absolute_time(),
                                      kACTransducerHand, 0, 1,
                                      kACEventRange | kACEventTouch, 0,
                                      x, y, 0.0, 1.0, 0.0,
                                      true, true, 0);
    if (!down) return;
    sDispatch(sClient, down);
    CFRelease(down);

    // 8ms 后再抬起，太快会被系统合并成一次无效触摸
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        IOHIDEventRef up = sCreateEvent(kCFAllocatorDefault, mach_absolute_time(),
                                        kACTransducerHand, 0, 1,
                                        0, 0,
                                        x, y, 0.0, 0.0, 0.0,
                                        false, false, 0);
        if (!up) return;
        sDispatch(sClient, up);
        CFRelease(up);
    });
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

    NSTimeInterval iv = _interval;
    if (iv < 0.02) iv = 0.02;
    if (iv > 5.0)  iv = 5.0;

    uint64_t intervalNs = (uint64_t)(iv * (double)NSEC_PER_SEC);
    uint64_t leewayNs   = (uint64_t)(2 * NSEC_PER_MSEC);

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)intervalNs),
                              intervalNs, leewayNs);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        __strong typeof(self) self_ = weakSelf;
        if (!self_ || !self_.running) return;

        CGPoint p = (self_.mode == ACTapModeRegion) ? ACRandomPointInRect(self_.region) : self_.point;
        dispatch_async(dispatch_get_main_queue(), ^{
            ACInjectTap(p);
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
