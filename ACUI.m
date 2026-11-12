//
//  ACUI.m — 悬浮球、设置面板、区域框选
//

#import "ACUI.h"
#import "ACCore.h"
#import "ACDebug.h"
#import <math.h>
#import <objc/message.h>

#define AC_ICON_SIZE 56.0
#define AC_PANEL_W   280.0
#define AC_PANEL_H   424.0
#define AC_SIDE      16.0

static const CGFloat kACWindowLevel    = 10000200.0;   // SpringBoard 下的悬浮球层
static const CGFloat kACSelectLevel    = 10000300.0;   // SpringBoard 下的框选遮罩层

/// 普通 App 里不需要（也不该）用 SpringBoard 那么夸张的层级，
/// Alert 之上一点点就能盖住 App 自己的所有弹出层。
static CGFloat ACIconLevel(void) {
    return ACIsSpringBoard() ? kACWindowLevel : (UIWindowLevelAlert + 1000.0);
}
static CGFloat ACSelectLevel(void) {
    return ACIsSpringBoard() ? kACSelectLevel : (UIWindowLevelAlert + 1100.0);
}

#pragma mark - 可穿透窗口

/// passesThroughTouches = YES 时只有真正命中了子控件才接手触摸，其余区域一律穿透给下层 App。
/// 框选遮罩窗必须置 NO，否则它自己也收不到手势。
@interface ACWindow : UIWindow
@property (nonatomic, assign) BOOL passesThroughTouches;
@end

@implementation ACWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.passesThroughTouches) {
        return [super hitTest:point withEvent:event];
    }
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self) return nil;
    if (self.rootViewController && v == self.rootViewController.view) return nil;
    return v;
}

@end

/// 拿一个能用来建窗的 UIWindowScene。三条路依次试，SpringBoard 上通常要走后两条。
static UIWindowScene *ACActiveScene(void) {
    UIApplication *app = [UIApplication sharedApplication];

    // 路 1：connectedScenes。普通 App 走这条就够了。
    UIWindowScene *any = nil;
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        if (!any) any = (UIWindowScene *)s;
    }
    if (any) return any;

    // 路 2：从宿主已有的窗口反查。SpringBoard 的 connectedScenes 经常是空集，
    //       但它自己的主屏窗口带着 scene，这条路才是 SpringBoard 上的正解。
    for (UIWindow *w in app.windows) {
        if (w.windowScene) return w.windowScene;
    }

    // 路 3：私有 API。前两条都空的时候，UIScreen 还知道当前前台是哪个 scene。
    SEL fg = NSSelectorFromString(@"_foregroundScene");
    if ([[UIScreen mainScreen] respondsToSelector:fg]) {
        id s = ((id (*)(id, SEL))objc_msgSend)([UIScreen mainScreen], fg);
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

/// 把窗口真正送上屏幕。
///
/// hidden = NO 只是"不隐藏"，窗口对象还躺在场外，没人把它画出来。
/// iOS 上没有 orderFrontRegardless（那是 macOS 的），公开 API 里最接近的是
/// makeKeyAndVisible —— 但它会把 key window 抢走，SpringBoard 里这么干会打断
/// 正在进行的文本输入。所以优先用私有的 _orderFrontWithoutMakingKey：只上屏不抢焦点。
static void ACShowWindow(UIWindow *w) {
    if (!w) return;
    w.hidden = NO;

    // 私有 _orderFrontWithoutMakingKey 在部分 iOS 16 版本上已经不响应，
    // respondsToSelector 能过但调用是空转 —— 那就白显示了。这里直接用公开 API：
    // 抢一次 key 把它顶上台面，再立刻把 key 还给原来的窗口。
    UIWindow *prev = [UIApplication sharedApplication].keyWindow;
    [w makeKeyAndVisible];
    if (prev && prev != w) [prev makeKeyWindow];
}

static ACWindow *ACMakeWindow(CGFloat level) {
    UIWindowScene *sc = ACActiveScene();
    ACWindow *w = sc ? [[ACWindow alloc] initWithWindowScene:sc]
                     : [[ACWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.frame = [UIScreen mainScreen].bounds;
    w.windowLevel = level;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = [UIColor clearColor];
    w.rootViewController.view.frame = w.bounds;   // 未 makeKeyAndVisible 时自己兜一下布局
    w.passesThroughTouches = YES;
    w.hidden = NO;
    [w layoutIfNeeded];

    // 少了这一句的典型症状：scene 有、frame 对、hidden=NO，屏幕上什么都没有。
    ACShowWindow(w);

    return w;
}

/// 自建窗口彻底没戏时的最后一条路：把内容直接挂到宿主已有的窗口上。
/// SpringBoard 里这个就是主屏窗口，App 里就是 App 自己的窗口。
static UIView *ACHostFallbackView(void) {
    UIWindow *best = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isHidden || w.alpha < 0.01) continue;
        if (w.bounds.size.width < 10) continue;
        if (!best || w.windowLevel > best.windowLevel) best = w;
    }
    if (!best) return nil;
    return best.rootViewController.view ?: best;
}

#pragma mark - 管理器

@interface ACManager () <UIGestureRecognizerDelegate>

@property (nonatomic, strong) ACWindow *win;
@property (nonatomic, strong) UIView   *icon;      // 悬浮球
@property (nonatomic, strong) UIView   *hostViewOverride;   // 兜底挂载时的父视图
@property (nonatomic, assign) BOOL      fellBack;

@property (nonatomic, strong) UIView   *panel;
@property (nonatomic, strong) UILabel  *statusLabel;
@property (nonatomic, strong) UILabel  *intervalLabel;
@property (nonatomic, strong) UILabel  *countLabel;
@property (nonatomic, strong) UILabel  *regionLabel;
@property (nonatomic, strong) UISlider *intervalSlider;
@property (nonatomic, strong) UISlider *countSlider;
@property (nonatomic, strong) UIButton *actionBtn;
@property (nonatomic, strong) UIButton *channelBtn;
@property (nonatomic, strong) UIView   *logView;
@property (nonatomic, strong) UILabel  *diagLabel;   // 底部自检行：宿主 / 窗口 / 通道

@property (nonatomic, strong) ACWindow *selWin;
@property (nonatomic, strong) UIView   *selRect;
@property (nonatomic, assign) CGPoint   selStart;

@property (nonatomic, assign) BOOL didSetup;
@property (nonatomic, strong) dispatch_source_t keeper;     // 窗口保活定时器

- (UIView *)hostView;
- (CGSize)screenSize;
- (void)startWindowKeeper;
- (NSString *)diagnosticLine;

@end

@implementation ACManager

+ (instancetype)shared {
    static ACManager *obj;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ obj = [[ACManager alloc] init]; });
    return obj;
}

#pragma mark 建立

- (void)setup {
    [self setupAttempt:0];
}

/// 悬浮球和面板真正挂在哪。
/// 正常情况下是自建窗口的 rootViewController.view；自建窗口上不了屏时换成宿主的窗口。
- (UIView *)hostView {
    return self.hostViewOverride ?: self.win.rootViewController.view;
}

/// 布局基准尺寸。兜底模式下父视图是宿主的窗口，不能拿 self.win 的尺寸硬套。
- (CGSize)screenSize {
    CGSize s = self.hostView.bounds.size;
    if (s.width < 10 || s.height < 10) s = [UIScreen mainScreen].bounds.size;
    return s;
}

/// 宿主启动早期 connectedScenes 可能还是空的，拿不到 scene 就等一会儿再来。
/// 但最多等 8 秒 —— 等不到就得换路走，不能让用户对着空屏幕猜。
- (void)setupAttempt:(NSInteger)attempt {
    if (self.didSetup) return;

    UIWindowScene *scene = ACActiveScene();
    BOOL ready = (scene != nil);

    // App 可能被推送/后台任务唤醒加载我们，那种时候不能建窗
    if (ready && !ACIsSpringBoard()) {
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
            ready = NO;
        }
    }

    if (!ready && attempt < 20) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf setupAttempt:attempt + 1];
        });
        return;
    }

    self.didSetup = YES;

    ACRefreshInjectChannel();
    self.win = ACMakeWindow(ACIconLevel());

    ACDLog(@"window built: level=%.0f frame=%@ hidden=%d scene=%@ attempt=%ld",
           self.win.windowLevel, NSStringFromCGRect(self.win.frame),
           self.win.hidden,
           self.win.windowScene ? @"yes" : @"nil",
           (long)attempt);

    // 没有 windowScene 的 UIWindow 在 iOS 13+ 永远不会被画出来 —— 对象在、frame 对、
    // hidden=NO，屏幕上就是空的。这种情况不再干等，直接把内容挂到宿主现成的窗口上。
    if (!self.win.windowScene) {
        UIView *host = ACHostFallbackView();
        if (host) {
            self.hostViewOverride = host;
            self.fellBack = YES;
            self.win.hidden = YES;   // 万一它哪天又上屏了，别出现两个球
            ACDLog(@"!! 没有 windowScene，已改挂宿主窗口 %@", NSStringFromClass([host class]));
            ACBuzz(2);               // 一共 3 下：注入成功但窗口是兜底挂的
        } else {
            // 自建窗口和宿主窗口都拿不到，说明 SpringBoard 这会儿还没把窗口体系铺完。
            // 别放弃，1 秒后再来 —— 放弃就等于屏幕上什么都没有。
            ACDLog(@"!! 无 scene 也无宿主窗口，1 秒后重试（第 %ld 次）", (long)attempt);
            self.didSetup = NO;
            self.win = nil;

            if (attempt < 60) {
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [weakSelf setupAttempt:attempt + 1];
                });
            } else {
                ACBuzz(3);
                ACDLog(@"!! 放弃：60 次都没拿到任何可用窗口");
            }
            return;
        }
    } else {
        ACBuzz(2);   // 一共 2 下：注入成功、窗口是自建的
    }

    [self buildIcon];
    [self buildPanel];

    __weak typeof(self) weakSelf = self;
    [ACEngine shared].stateHandler = ^{
        __strong typeof(self) s = weakSelf;
        [s refreshUI];
    };

    // 注入到本进程时，悬浮窗自己也在事件路径上 —— 每次点击前让开一瞬。
    // 关键：恢复必须延迟到 up 事件也发完之后，否则 down 落到 App、up 落到浮窗，
    // App 收到的是一次没有抬起的按下，什么都不会触发。
    // 要注意的是"让开"的对象不是窗口，而是悬浮球实际挂着的那层视图 ——
    // 兜底模式下球挂在宿主窗口上，只关窗口的交互对它毫无作用，会自己点自己。
    [ACEngine shared].willTap = ^{
        __strong typeof(self) s = weakSelf;
        s.hostView.userInteractionEnabled = NO;
    };
    [ACEngine shared].didTap = ^{
        __strong typeof(self) s = weakSelf;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            s.hostView.userInteractionEnabled = YES;
        });
    };

    [self startWindowKeeper];
    [self refreshUI];
    ACDLog(@"setup done, channel=%@ fallback=%d",
           ACInjectChannelName(ACInjectActiveChannel()), self.fellBack);
}

/// SpringBoard 在锁屏、解锁、切换 App 时会把非系统窗口压到后面去，
/// 这里定期把窗口重新提到最前 —— 只是 orderFront，不抢 key window，不影响输入。
- (void)startWindowKeeper {
    if (self.keeper || self.fellBack) return;

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
    dispatch_source_set_timer(t,
                              dispatch_time(DISPATCH_TIME_NOW, 3ull * NSEC_PER_SEC),
                              3ull * NSEC_PER_SEC,
                              1ull * NSEC_PER_SEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        __strong typeof(self) s = weakSelf;
        if (!s.win || s.fellBack) return;
        ACShowWindow(s.win);
    });
    dispatch_resume(t);
    self.keeper = t;
}

#pragma mark 悬浮球

- (void)buildIcon {
    CGFloat s = AC_ICON_SIZE;
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(48, 180, s, s)];
    v.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.80];
    v.layer.cornerRadius = s / 2.0;
    v.layer.borderWidth = 1.2;
    v.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.38].CGColor;
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOpacity = 0.35;
    v.layer.shadowRadius = 6;
    v.layer.shadowOffset = CGSizeMake(0, 2);
    v.userInteractionEnabled = YES;

    UIImageView *iv = [[UIImageView alloc] initWithFrame:v.bounds];
    iv.contentMode = UIViewContentModeCenter;
    iv.tintColor = [UIColor whiteColor];
    iv.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:26
                                                            weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:@"hand.tap.fill" withConfiguration:cfg];
        if (img) iv.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    if (!iv.image) {
        UILabel *glyph = [[UILabel alloc] initWithFrame:v.bounds];
        glyph.text = @"◎";
        glyph.textColor = [UIColor whiteColor];
        glyph.font = [UIFont systemFontOfSize:26 weight:UIFontWeightSemibold];
        glyph.textAlignment = NSTextAlignmentCenter;
        [v addSubview:glyph];
    } else {
        [v addSubview:iv];
    }

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onIconPan:)];
    pan.delegate = self;
    [v addGestureRecognizer:pan];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)];
    [tap requireGestureRecognizerToFail:pan];
    [v addGestureRecognizer:tap];

    [self.hostView addSubview:v];
    self.icon = v;

    // 版本角标：装错包/装了旧包是最常见的"没效果"来源，一眼就能确认
    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(s - 26, -6, 32, 15)];
    badge.text = @"1.4";
    badge.textColor = [UIColor colorWithRed:1.0 green:0.42 blue:0.32 alpha:1.0];
    badge.font = [UIFont boldSystemFontOfSize:9.5];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.75];
    badge.layer.cornerRadius = 5;
    badge.layer.masksToBounds = YES;
    badge.userInteractionEnabled = NO;
    [v addSubview:badge];

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CGFloat x = [d doubleForKey:@"ac_icon_x"];
    CGFloat y = [d doubleForKey:@"ac_icon_y"];
    if (x > 1 && y > 1) v.center = CGPointMake(x, y);
}

- (void)onIconPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.panel.superview) {
        [self.panel removeFromSuperview];
    }

    UIView *v = self.icon;
    CGPoint t = [g translationInView:self.hostView];
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);

    CGSize screen = self.screenSize;
    CGFloat r = v.bounds.size.width / 2.0;
    c.x = MAX(r + 4, MIN(screen.width  - r - 4, c.x));
    c.y = MAX(r + 34, MIN(screen.height - r - 4, c.y));
    v.center = c;
    [g setTranslation:CGPointZero inView:self.hostView];

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setDouble:c.x forKey:@"ac_icon_x"];
        [d setDouble:c.y forKey:@"ac_icon_y"];
        [d synchronize];
    }
}

#pragma mark 面板

- (UILabel *)makeLabel:(NSString *)text size:(CGFloat)size
                 color:(UIColor *)color bold:(BOOL)bold {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.textColor = color;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.backgroundColor = [UIColor clearColor];
    return l;
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    b.layer.cornerRadius = 8;
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildPanel {
    UIView *p = [[UIView alloc] initWithFrame:CGRectMake(0, 0, AC_PANEL_W, AC_PANEL_H)];
    p.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.95];
    p.layer.cornerRadius = 18;
    p.layer.borderWidth = 1;
    p.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    p.layer.shadowColor = [UIColor blackColor].CGColor;
    p.layer.shadowOpacity = 0.45;
    p.layer.shadowRadius = 14;
    p.layer.shadowOffset = CGSizeMake(0, 6);
    p.hidden = NO;

    CGFloat innerW = AC_PANEL_W - AC_SIDE * 2;
    UIColor *dim = [UIColor colorWithWhite:0.62 alpha:1.0];

    // 标题
    UILabel *title = [self makeLabel:@"自动连点" size:17 color:[UIColor whiteColor] bold:YES];
    title.frame = CGRectMake(AC_SIDE, 16, 150, 22);
    [p addSubview:title];

    UIButton *close = [self makeButton:@"✕" action:@selector(closePanel)];
    close.frame = CGRectMake(AC_PANEL_W - AC_SIDE - 28, 14, 28, 28);
    close.layer.cornerRadius = 14;
    close.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    [p addSubview:close];

    // 状态
    self.statusLabel = [self makeLabel:@"已停止" size:12 color:dim bold:NO];
    self.statusLabel.frame = CGRectMake(AC_SIDE, 46, innerW, 18);
    [p addSubview:self.statusLabel];

    UIView *line1 = [[UIView alloc] initWithFrame:CGRectMake(AC_SIDE, 72, innerW, 0.5)];
    line1.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    [p addSubview:line1];

    // 间隔
    UILabel *t1 = [self makeLabel:@"点击间隔" size:13 color:[UIColor whiteColor] bold:NO];
    t1.frame = CGRectMake(AC_SIDE, 84, 120, 20);
    [p addSubview:t1];

    self.intervalLabel = [self makeLabel:@"0.20 秒" size:13 color:dim bold:NO];
    self.intervalLabel.textAlignment = NSTextAlignmentRight;
    self.intervalLabel.frame = CGRectMake(AC_PANEL_W - AC_SIDE - 120, 84, 120, 20);
    [p addSubview:self.intervalLabel];

    self.intervalSlider = [[UISlider alloc] initWithFrame:CGRectMake(AC_SIDE, 106, innerW, 28)];
    self.intervalSlider.minimumValue = 0.0;
    self.intervalSlider.maximumValue = 1.0;
    self.intervalSlider.minimumTrackTintColor = [UIColor colorWithRed:0.30 green:0.78 blue:0.98 alpha:1];
    [self.intervalSlider addTarget:self action:@selector(onIntervalChanged:)
                  forControlEvents:UIControlEventValueChanged];
    [p addSubview:self.intervalSlider];

    // 次数
    UILabel *t2 = [self makeLabel:@"点击次数" size:13 color:[UIColor whiteColor] bold:NO];
    t2.frame = CGRectMake(AC_SIDE, 144, 120, 20);
    [p addSubview:t2];

    self.countLabel = [self makeLabel:@"无限" size:13 color:dim bold:NO];
    self.countLabel.textAlignment = NSTextAlignmentRight;
    self.countLabel.frame = CGRectMake(AC_PANEL_W - AC_SIDE - 120, 144, 120, 20);
    [p addSubview:self.countLabel];

    self.countSlider = [[UISlider alloc] initWithFrame:CGRectMake(AC_SIDE, 166, innerW, 28)];
    self.countSlider.minimumValue = 0.0;
    self.countSlider.maximumValue = 1.0;
    self.countSlider.minimumTrackTintColor = [UIColor colorWithRed:0.30 green:0.78 blue:0.98 alpha:1];
    [self.countSlider addTarget:self action:@selector(onCountChanged:)
               forControlEvents:UIControlEventValueChanged];
    [p addSubview:self.countSlider];

    // 区域
    UILabel *t3 = [self makeLabel:@"点击位置" size:13 color:[UIColor whiteColor] bold:NO];
    t3.frame = CGRectMake(AC_SIDE, 204, 120, 20);
    [p addSubview:t3];

    self.regionLabel = [self makeLabel:@"点 (200, 400)" size:13 color:dim bold:NO];
    self.regionLabel.textAlignment = NSTextAlignmentRight;
    self.regionLabel.frame = CGRectMake(AC_PANEL_W - AC_SIDE - 150, 204, 150, 20);
    [p addSubview:self.regionLabel];

    CGFloat bw = (innerW - 10) / 2.0;
    UIButton *pick = [self makeButton:@"选 点" action:@selector(beginPickPoint)];
    pick.frame = CGRectMake(AC_SIDE, 230, bw, 32);
    [p addSubview:pick];

    UIButton *box = [self makeButton:@"框选区域" action:@selector(beginPickRegion)];
    box.frame = CGRectMake(AC_SIDE + bw + 10, 230, bw, 32);
    [p addSubview:box];

    UIButton *clear = [self makeButton:@"清除区域（回到单点）" action:@selector(clearRegion)];
    clear.frame = CGRectMake(AC_SIDE, 270, innerW, 30);
    clear.titleLabel.font = [UIFont systemFontOfSize:12.5];
    clear.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    [p addSubview:clear];

    UIView *line2 = [[UIView alloc] initWithFrame:CGRectMake(AC_SIDE, 312, innerW, 0.5)];
    line2.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    [p addSubview:line2];

    // 注入通道切换 + 日志。两条注入路在不同系统版本上有效性不一样，
    // 自动选错时让用户自己试一次最快。
    CGFloat hw = (innerW - 10) / 2.0;
    UIButton *chBtn = [self makeButton:@"通道" action:@selector(onSwitchChannel)];
    chBtn.frame = CGRectMake(AC_SIDE, 320, hw, 32);
    chBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    chBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    chBtn.titleLabel.minimumScaleFactor = 0.75;
    [p addSubview:chBtn];
    self.channelBtn = chBtn;

    UIButton *logBtn = [self makeButton:@"查看日志" action:@selector(showLog)];
    logBtn.frame = CGRectMake(AC_SIDE + hw + 10, 320, hw, 32);
    logBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    logBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    [p addSubview:logBtn];

    // 主按钮
    UIButton *act = [self makeButton:@"开 始" action:@selector(onAction)];
    act.frame = CGRectMake(AC_SIDE, 362, innerW, 44);
    act.layer.cornerRadius = 12;
    act.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    act.backgroundColor = [UIColor colorWithRed:0.18 green:0.68 blue:0.36 alpha:1.0];
    [p addSubview:act];
    self.actionBtn = act;

    // 自检行：装上没反应时，截这一张图就能定位卡在哪一层
    self.diagLabel = [self makeLabel:@"·" size:9.5
                               color:[UIColor colorWithWhite:0.45 alpha:1.0] bold:NO];
    self.diagLabel.frame = CGRectMake(AC_SIDE, AC_PANEL_H - 18, innerW, 12);
    self.diagLabel.textAlignment = NSTextAlignmentCenter;
    self.diagLabel.adjustsFontSizeToFitWidth = YES;
    self.diagLabel.minimumScaleFactor = 0.7;
    [p addSubview:self.diagLabel];

    self.panel = p;
}

- (void)layoutPanel {
    if (!self.panel.superview) return;

    CGSize screen = self.screenSize;
    CGFloat w = AC_PANEL_W;
    CGFloat h = AC_PANEL_H;

    CGFloat x = self.icon.center.x - w / 2.0;
    CGFloat y = self.icon.center.y + 42;
    if (y + h > screen.height - 24) y = self.icon.center.y - h - 42;

    x = MAX(10, MIN(screen.width  - w - 10, x));
    y = MAX(52, MIN(screen.height - h - 16, y));

    self.panel.frame = CGRectMake(x, y, w, h);
}

- (void)togglePanel {
    if (self.panel.superview) {
        [self.panel removeFromSuperview];
        return;
    }
    [self.hostView addSubview:self.panel];
    [self layoutPanel];
    [self refreshUI];
}

- (void)closePanel {
    [self.panel removeFromSuperview];
}

#pragma mark 面板交互

- (double)sliderValueForInterval:(NSTimeInterval)v {
    v = MAX(0.02, MIN(5.0, v));
    return log(v / 0.02) / log(250.0);
}

- (NSTimeInterval)intervalForSliderValue:(double)s {
    return 0.02 * pow(250.0, MAX(0.0, MIN(1.0, s)));
}

- (void)onIntervalChanged:(UISlider *)s {
    NSTimeInterval v = [self intervalForSliderValue:s.value];
    [ACEngine shared].interval = v;
    [[ACEngine shared] saveSettings];
    self.intervalLabel.text = [NSString stringWithFormat:@"%.2f 秒", v];
}

- (void)onCountChanged:(UISlider *)s {
    NSInteger taps = (NSInteger)llround(s.value * 500.0);
    if (taps < 5) taps = 0;
    [ACEngine shared].maxTaps = taps;
    [[ACEngine shared] saveSettings];
    self.countLabel.text = (taps == 0) ? @"无限"
                                       : [NSString stringWithFormat:@"%ld 次", (long)taps];
}

- (void)onAction {
    ACEngine *e = [ACEngine shared];

    if (e.running) {
        [e stop];
        [self refreshUI];
        return;
    }

    if (ACInjectActiveChannel() == ACInjectChannelNone) {
        self.statusLabel.text = @"注入通道不可用，无法点击";
        self.statusLabel.textColor = [UIColor colorWithRed:0.95 green:0.42 blue:0.34 alpha:1];
        return;
    }

    [e start];

    // 面板本身会挡住落点，开跑就收起
    [self closePanel];
    [self refreshUI];
}

- (void)clearRegion {
    [ACEngine shared].region = CGRectZero;
    [ACEngine shared].mode = ACTapModePoint;
    [[ACEngine shared] saveSettings];
    [self refreshUI];
}

#pragma mark 通道 / 日志

/// 三条通道轮换：派发 → 队列 → 不可用 → 派发。
/// 用户点一次就能试出这台设备上哪条真的能点。
- (void)onSwitchChannel {
    ACInjectChannel cur = ACInjectActiveChannel();
    ACInjectChannel next;
    switch (cur) {
        case ACInjectChannelDispatch: next = ACInjectChannelEnqueue;  break;
        case ACInjectChannelEnqueue:  next = ACInjectChannelNone;     break;
        default:                      next = ACInjectChannelDispatch; break;
    }
    ACSetInjectChannel(next);
    ACDLog(@"用户切换通道: %@ -> %@", ACInjectChannelName(cur), ACInjectChannelName(next));
    [self refreshUI];
}

- (void)showLog {
    if (self.logView) {
        [self.logView removeFromSuperview];
        self.logView = nil;
        return;
    }
    if (self.panel.superview) [self.panel removeFromSuperview];

    CGRect screen = CGRectMake(0, 0, self.screenSize.width, self.screenSize.height);
    UIView *host = [[UIView alloc] initWithFrame:screen];
    host.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.86];

    CGFloat pad = 14;
    CGFloat w = screen.size.width - pad * 2;

    UILabel *t = [self makeLabel:@"运行日志（点任意处关闭）" size:13
                           color:[UIColor whiteColor] bold:YES];
    t.frame = CGRectMake(pad + 4, 48, w, 20);
    [host addSubview:t];

    UITextView *tv = [[UITextView alloc] initWithFrame:
                        CGRectMake(pad, 74, w, screen.size.height - 74 - 60)];
    tv.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    tv.textColor = [UIColor colorWithWhite:0.90 alpha:1.0];
    tv.font = [UIFont fontWithName:@"Menlo" size:10.5] ?: [UIFont systemFontOfSize:10.5];
    tv.editable = NO;
    tv.layer.cornerRadius = 8;
    tv.text = ACDLogTail(200);
    [host addSubview:tv];

    UILabel *path = [self makeLabel:[NSString stringWithFormat:@"文件：%@", ACDLogPath() ?: @"不可写"]
                               size:10 color:[UIColor colorWithWhite:0.55 alpha:1] bold:NO];
    path.frame = CGRectMake(pad + 4, screen.size.height - 46, w - 8, 32);
    path.numberOfLines = 2;
    [host addSubview:path];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(hideLog)];
    [host addGestureRecognizer:tap];
    // 文本要能滚动，别被手势吃掉
    tap.cancelsTouchesInView = NO;

    [self.hostView addSubview:host];
    self.logView = host;
}

- (void)hideLog {
    [self.logView removeFromSuperview];
    self.logView = nil;
}

#pragma mark 刷新

- (NSString *)diagnosticLine {
    NSString *host = ACIsSpringBoard() ? @"SB" : @"App";
    NSString *win  = self.fellBack ? @"挂宿主窗" : (self.win.windowScene ? @"自建窗" : @"无窗");
    return [NSString stringWithFormat:@"%@ %d · %@ · %@",
            host, (int)getpid(), win,
            ACInjectChannelName(ACInjectActiveChannel())];
}

- (void)refreshUI {
    ACEngine *e = [ACEngine shared];

    ACInjectChannel ch = ACInjectActiveChannel();
    NSString *chName = ACInjectChannelName(ch);

    if (ch == ACInjectChannelNone) {
        // 通道不通时点多少次都不会有反应，必须让用户一眼看到
        self.statusLabel.text = @"注入通道不可用 · 点击无效";
        self.statusLabel.textColor = [UIColor colorWithRed:0.95 green:0.42 blue:0.34 alpha:1];
    } else if (e.running) {
        self.statusLabel.text = [NSString stringWithFormat:@"运行中 · 已点击 %ld 次 · %@",
                                 (long)e.tapCount, chName];
        self.statusLabel.textColor = [UIColor colorWithRed:0.34 green:0.86 blue:0.46 alpha:1];
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"已停止 · 注入通道：%@", chName];
        self.statusLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    }

    if (e.running) {
        [self.actionBtn setTitle:@"停 止" forState:UIControlStateNormal];
        self.actionBtn.backgroundColor = [UIColor colorWithRed:0.80 green:0.24 blue:0.24 alpha:1.0];
    } else {
        [self.actionBtn setTitle:@"开 始" forState:UIControlStateNormal];
        self.actionBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.68 blue:0.36 alpha:1.0];
    }

    self.intervalLabel.text = [NSString stringWithFormat:@"%.2f 秒", e.interval];
    self.intervalSlider.value = [self sliderValueForInterval:e.interval];

    NSInteger taps = e.maxTaps;
    self.countLabel.text = (taps <= 0) ? @"无限"
                                       : [NSString stringWithFormat:@"%ld 次", (long)taps];
    self.countSlider.value = MIN(1.0, MAX(0.0, (double)taps / 500.0));

    if (e.mode == ACTapModeRegion && !CGRectIsEmpty(e.region)) {
        self.regionLabel.text = [NSString stringWithFormat:@"区域 %.0f × %.0f",
                                 e.region.size.width, e.region.size.height];
    } else {
        self.regionLabel.text = [NSString stringWithFormat:@"点 (%.0f, %.0f)", e.point.x, e.point.y];
    }

    [self.channelBtn setTitle:[NSString stringWithFormat:@"通道：%@", chName]
                     forState:UIControlStateNormal];
    self.channelBtn.backgroundColor = (ch == ACInjectChannelNone)
        ? [UIColor colorWithRed:0.55 green:0.20 blue:0.18 alpha:1.0]
        : [UIColor colorWithWhite:1.0 alpha:0.14];

    self.diagLabel.text = [self diagnosticLine];
}

#pragma mark 选点 / 框选

- (void)beginPickPoint {
    [self presentSelection:NO];
}

- (void)beginPickRegion {
    [self presentSelection:YES];
}

- (void)presentSelection:(BOOL)regionMode {
    if (self.selWin) return;

    if (self.panel.superview) [self.panel removeFromSuperview];

    ACWindow *w = ACMakeWindow(ACSelectLevel());
    w.passesThroughTouches = NO;          // 遮罩必须吃触摸，否则手势收不到
    w.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
    w.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.selWin = w;

    UIView *host = w.rootViewController.view;
    CGFloat sw = w.bounds.size.width;

    UILabel *hint = [self makeLabel:(regionMode ? @"拖动框选点击区域"
                                                : @"点击要连点的位置")
                              size:14 color:[UIColor whiteColor] bold:NO];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.frame = CGRectMake(0, 0, sw, 22);
    hint.center = CGPointMake(sw / 2.0, 86);
    [host addSubview:hint];

    UIButton *cancel = [self makeButton:@"取消" action:@selector(onSelectCancelTap)];
    cancel.frame = CGRectMake(sw - 76, 62, 60, 32);
    [host addSubview:cancel];

    if (regionMode) {
        UIView *r = [[UIView alloc] initWithFrame:CGRectZero];
        r.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
        r.layer.borderColor = [UIColor colorWithRed:0.32 green:0.86 blue:0.52 alpha:1].CGColor;
        r.layer.borderWidth = 1.5;
        r.userInteractionEnabled = NO;
        r.hidden = YES;
        [host addSubview:r];
        self.selRect = r;

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onSelectPan:)];
        [host addGestureRecognizer:pan];

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onSelectCancel:)];
        [host addGestureRecognizer:tap];
    } else {
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onSelectTap:)];
        [host addGestureRecognizer:tap];
    }
}

- (void)onSelectCancel:(UITapGestureRecognizer *)g {
    [self dismissSelection];
}

- (void)onSelectCancelTap {
    [self dismissSelection];
}

- (void)onSelectTap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.selWin];
    [self dismissSelection];

    [ACEngine shared].point = p;
    [ACEngine shared].mode  = ACTapModePoint;
    [[ACEngine shared] saveSettings];
    [self refreshUI];
}

- (void)onSelectPan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.selWin];

    if (g.state == UIGestureRecognizerStateBegan) {
        self.selStart = p;
        self.selRect.hidden = NO;
        self.selRect.frame = CGRectMake(p.x, p.y, 0, 0);

    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat x = MIN(p.x, self.selStart.x);
        CGFloat y = MIN(p.y, self.selStart.y);
        CGFloat w = fabs(p.x - self.selStart.x);
        CGFloat h = fabs(p.y - self.selStart.y);
        self.selRect.frame = CGRectMake(x, y, w, h);

    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        CGRect r = self.selRect.frame;
        [self dismissSelection];

        if (r.size.width < 24 || r.size.height < 24) return;

        [ACEngine shared].region = r;
        [ACEngine shared].mode   = ACTapModeRegion;
        [[ACEngine shared] saveSettings];
        [self refreshUI];
    }
}

- (void)dismissSelection {
    self.selRect = nil;
    self.selWin.hidden = YES;
    self.selWin = nil;
}

#pragma mark UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

@end
