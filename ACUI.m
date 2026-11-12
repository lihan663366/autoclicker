//
//  ACUI.m — 悬浮球、设置面板、区域框选
//

#import "ACUI.h"
#import "ACCore.h"
#import <math.h>

#define AC_ICON_SIZE 56.0
#define AC_PANEL_W   280.0
#define AC_PANEL_H   384.0
#define AC_SIDE      16.0

static const CGFloat kACWindowLevel    = 10000200.0;   // 悬浮球层
static const CGFloat kACSelectLevel    = 10000300.0;   // 框选遮罩层

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

static UIWindowScene *ACActiveScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindowScene *fallback = nil;
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        if (!fallback) fallback = (UIWindowScene *)s;
    }
    if (fallback) return fallback;

    // 兜底：SpringBoard 某些版本 connectedScenes 为空，从已有窗口反查 scene
    for (UIWindow *w in app.windows) {
        if (w.windowScene) return w.windowScene;
    }
    return nil;
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
    return w;
}

#pragma mark - 管理器

@interface ACManager () <UIGestureRecognizerDelegate>

@property (nonatomic, strong) ACWindow *win;
@property (nonatomic, strong) UIView   *icon;      // 悬浮球

@property (nonatomic, strong) UIView   *panel;
@property (nonatomic, strong) UILabel  *statusLabel;
@property (nonatomic, strong) UILabel  *intervalLabel;
@property (nonatomic, strong) UILabel  *countLabel;
@property (nonatomic, strong) UILabel  *regionLabel;
@property (nonatomic, strong) UISlider *intervalSlider;
@property (nonatomic, strong) UISlider *countSlider;
@property (nonatomic, strong) UIButton *actionBtn;

@property (nonatomic, strong) ACWindow *selWin;
@property (nonatomic, strong) UIView   *selRect;
@property (nonatomic, assign) CGPoint   selStart;

@property (nonatomic, assign) BOOL didSetup;

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

/// SpringBoard 启动早期 connectedScenes 可能还是空的，拿不到 scene 就等一会儿再来
- (void)setupAttempt:(NSInteger)attempt {
    if (self.didSetup) return;

    if (!ACActiveScene() && attempt < 12) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf setupAttempt:attempt + 1];
        });
        return;
    }

    self.didSetup = YES;

    self.win = ACMakeWindow(kACWindowLevel);

    [self buildIcon];
    [self buildPanel];

    __weak typeof(self) weakSelf = self;
    [ACEngine shared].stateHandler = ^{
        __strong typeof(self) s = weakSelf;
        [s refreshUI];
    };
    [self refreshUI];
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

    [self.win.rootViewController.view addSubview:v];
    self.icon = v;

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
    CGPoint t = [g translationInView:self.win];
    CGPoint c = CGPointMake(v.center.x + t.x, v.center.y + t.y);

    CGSize screen = self.win.bounds.size;
    CGFloat r = v.bounds.size.width / 2.0;
    c.x = MAX(r + 4, MIN(screen.width  - r - 4, c.x));
    c.y = MAX(r + 34, MIN(screen.height - r - 4, c.y));
    v.center = c;
    [g setTranslation:CGPointZero inView:self.win];

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

    UIView *line2 = [[UIView alloc] initWithFrame:CGRectMake(AC_SIDE, 314, innerW, 0.5)];
    line2.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    [p addSubview:line2];

    // 主按钮
    UIButton *act = [self makeButton:@"开 始" action:@selector(onAction)];
    act.frame = CGRectMake(AC_SIDE, 328, innerW, 44);
    act.layer.cornerRadius = 12;
    act.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    act.backgroundColor = [UIColor colorWithRed:0.18 green:0.68 blue:0.36 alpha:1.0];
    [p addSubview:act];
    self.actionBtn = act;

    self.panel = p;
}

- (void)layoutPanel {
    if (!self.panel.superview) return;

    CGSize screen = self.win.bounds.size;
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
    [self.win.rootViewController.view addSubview:self.panel];
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
    if (e.running) [e stop];
    else            [e start];
    [self refreshUI];
}

- (void)clearRegion {
    [ACEngine shared].region = CGRectZero;
    [ACEngine shared].mode = ACTapModePoint;
    [[ACEngine shared] saveSettings];
    [self refreshUI];
}

#pragma mark 刷新

- (void)refreshUI {
    ACEngine *e = [ACEngine shared];

    if (e.running) {
        self.statusLabel.text = [NSString stringWithFormat:@"运行中 · 已点击 %ld 次", (long)e.tapCount];
        self.statusLabel.textColor = [UIColor colorWithRed:0.34 green:0.86 blue:0.46 alpha:1];
        [self.actionBtn setTitle:@"停 止" forState:UIControlStateNormal];
        self.actionBtn.backgroundColor = [UIColor colorWithRed:0.80 green:0.24 blue:0.24 alpha:1.0];
    } else {
        self.statusLabel.text = @"已停止";
        self.statusLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
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

    ACWindow *w = ACMakeWindow(kACSelectLevel);
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
