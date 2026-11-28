#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MW16 Stage 6
//
//  v5 结论：
//    - 点击有反应  → 触摸链路本来就是通的，不用额外处理
//    - 保活失败    → 只改 scene 设置留不住「进程」，App 被系统挂起了
//    - 无法开第二个 → 面板关掉后没有入口
//
//  这一版：
//    1. 常驻的「MW」小圆点，随时可再开窗（修复 B）
//    2. 进程级保活：RBSAssertion 锁住 App 进程（不只改 scene）
//    3. 每 3 秒打印诊断：pid / scene / layers，看得出死在哪一步

#define S6_LOG @"/var/mobile/Media/mw16_stage7.log"

static NSMutableString *gOut = nil;
static UITextView *gTrace = nil;
static UIWindow *gPanelWin = nil;
static UIWindow *gButtonWin = nil;
static UIView *gButton = nil;
static dispatch_source_t gPoll = nil;
static dispatch_source_t gKeep = nil;
static int gPollCount = 0;

static NSMutableArray *gWindows = nil;      // 打开的浮窗
static NSMutableDictionary *gAssertions = nil;  // bid -> RBSAssertion

static void A(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gOut) gOut = [NSMutableString string];
    [gOut appendFormat:@"%@\n", s];
    NSLog(@"[MW16-S6] %@", s);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gTrace) {
            gTrace.text = gOut;
            [gTrace scrollRangeToVisible:NSMakeRange(gTrace.text.length, 0)];
        }
    });
}

static void Flush(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *old = [NSString stringWithContentsOfFile:S6_LOG encoding:NSUTF8StringEncoding error:nil];
            if (!old) old = @"";
            if (old.length > 40000) old = [old substringFromIndex:old.length - 20000];
            [[old stringByAppendingString:gOut ?: @""] writeToFile:S6_LOG atomically:YES
                                                          encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) {}
    });
}

static UIWindowScene *ActiveScene(void) {
    UIWindowScene *fb = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (!fb) fb = (UIWindowScene *)s;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
    }
    return fb;
}

static UIWindow *MakeWindow(CGFloat level, UIColor *bg) {
    UIWindowScene *ws = ActiveScene();
    UIWindow *w = ws ? [[UIWindow alloc] initWithWindowScene:ws]
                     : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.frame = [UIScreen mainScreen].bounds;
    w.windowLevel = level;
    w.backgroundColor = bg;
    return w;
}

static id FBSceneMgr(void) {
    Class c = NSClassFromString(@"FBSceneManager");
    if (!c || ![c respondsToSelector:@selector(sharedInstance)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, @selector(sharedInstance));
}

static NSArray *AllScenes(void) {
    id mgr = FBSceneMgr();
    if (!mgr) return @[];
    NSMutableArray *out = [NSMutableArray array];
    SEL sel = NSSelectorFromString(@"enumerateScenesWithBlock:");
    if ([mgr respondsToSelector:sel]) {
        void (^b)(id) = ^(id s) { if (s) [out addObject:s]; };
        @try { ((void (*)(id, SEL, id))objc_msgSend)(mgr, sel, b); } @catch (NSException *e) {}
    }
    return out;
}

static NSString *SceneID(id s) {
    if (!s || ![s respondsToSelector:@selector(identifier)]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(s, @selector(identifier));
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static id SceneForBundle(NSString *bid) {
    if (!bid.length) return nil;
    for (id s in AllScenes()) {
        NSString *sid = SceneID(s);
        if (sid && [sid containsString:bid]) return s;
    }
    return nil;
}

static NSArray *LayerList(id scene) {
    if (!scene || ![scene respondsToSelector:@selector(layerManager)]) return nil;
    id lm = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(layerManager));
    if (!lm || ![lm respondsToSelector:@selector(layers)]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(lm, @selector(layers));
    if (!v) return nil;
    if ([v isKindOfClass:[NSArray class]]) return v;
    if ([v isKindOfClass:[NSOrderedSet class]]) return [(NSOrderedSet *)v array];
    if ([v isKindOfClass:[NSSet class]]) return [(NSSet *)v allObjects];
    NSMutableArray *m = [NSMutableArray array];
    for (id o in v) [m addObject:o];
    return m;
}

// ---------- 进程号 ----------

static id SBApp(NSString *bid) {
    Class ac = NSClassFromString(@"SBApplicationController");
    if (!ac || ![ac respondsToSelector:@selector(sharedInstance)]) return nil;
    id ctrl = ((id (*)(id, SEL))objc_msgSend)((id)ac, @selector(sharedInstance));
    SEL sel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (!ctrl || ![ctrl respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(ctrl, sel, bid);
}

static int PidOf(NSString *bid) {
    id app = SBApp(bid);
    if (!app) return 0;

    SEL ps = NSSelectorFromString(@"processState");
    id pstate = [app respondsToSelector:ps] ? ((id (*)(id, SEL))objc_msgSend)(app, ps) : nil;
    SEL pidSel = NSSelectorFromString(@"pid");
    if (pstate && [pstate respondsToSelector:pidSel]) {
        return ((int (*)(id, SEL))objc_msgSend)(pstate, pidSel);
    }
    if ([app respondsToSelector:pidSel]) {
        return ((int (*)(id, SEL))objc_msgSend)(app, pidSel);
    }
    return 0;
}

// ---------- 进程级保活 ----------

// 返回: 1=成功 0=失败 -1=类缺失
static int AcquireAssertion(NSString *bid) {
    if (!bid.length) return -2;
    if (gAssertions[bid]) return 1;

    Class tgtC = NSClassFromString(@"RBSTarget");
    Class attrC = NSClassFromString(@"RBSLegacyAttribute");
    Class asrtC = NSClassFromString(@"RBSAssertion");
    if (!tgtC || !attrC || !asrtC) {
        A(@"RBS 类缺失 target=%d attr=%d assertion=%d",
          tgtC != nil, attrC != nil, asrtC != nil);
        return -1;
    }

    int pid = PidOf(bid);
    if (pid <= 0) { A(@"[%@] 拿不到 pid，暂不能断言", bid); return 0; }

    @try {
        id target = ((id (*)(id, SEL, int))objc_msgSend)((id)tgtC,
                        @selector(targetWithPid:), pid);
        NSUInteger flags = (1 << 0) | (1 << 1) | (1 << 3);   // suspend/throttle/priority
        id attr = ((id (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)((id)attrC,
                        @selector(attributeWithReason:flags:), (NSUInteger)7, flags);
        id asrt = ((id (*)(id, SEL, NSString *, id, NSArray *))objc_msgSend)(
                        ((id (*)(id, SEL))objc_msgSend)((id)asrtC, @selector(alloc)),
                        @selector(initWithExplanation:target:attributes:),
                        @"MW16 keep alive", target, @[attr]);
        NSError *err = nil;
        BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(asrt,
                        @selector(acquireWithError:), &err);
        if (ok) {
            if (!gAssertions) gAssertions = [NSMutableDictionary dictionary];
            gAssertions[bid] = asrt;
            A(@"[%@] RBS 断言成功 pid=%d", bid, pid);
            return 1;
        }
        A(@"[%@] RBS 断言失败 pid=%d err=%@", bid, pid, err.localizedDescription ?: @"?");
        return 0;
    } @catch (NSException *e) {
        A(@"[%@] RBS 异常 %@", bid, e.reason);
        return 0;
    }
}

static void ReleaseAssertion(NSString *bid) {
    id a = gAssertions[bid];
    if (!a) return;
    SEL inv = NSSelectorFromString(@"invalidate");
    if ([a respondsToSelector:inv]) @try { ((void (*)(id, SEL))objc_msgSend)(a, inv); } @catch (NSException *e) {}
    [gAssertions removeObjectForKey:bid];
    A(@"[%@] RBS 断言已释放", bid);
}

// ---------- 场景保活 ----------

static void ForceForeground(id scene) {
    if (!scene) return;
    @try {
        SEL stSel = NSSelectorFromString(@"settings");
        if (![scene respondsToSelector:stSel]) return;
        id st = ((id (*)(id, SEL))objc_msgSend)(scene, stSel);
        if (!st || ![st respondsToSelector:@selector(mutableCopy)]) return;
        id ms = ((id (*)(id, SEL))objc_msgSend)(st, @selector(mutableCopy));
        if (!ms) return;

        SEL fgSel = NSSelectorFromString(@"setForeground:");
        if ([ms respondsToSelector:fgSel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(ms, fgSel, YES);

        SEL drSel = NSSelectorFromString(@"setDeactivationReasons:");
        if ([ms respondsToSelector:drSel])
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(ms, drSel, 0ULL);

        SEL up2 = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if ([scene respondsToSelector:up2]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, up2, ms, nil);
            return;
        }
        SEL up3 = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        if ([scene respondsToSelector:up3])
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, up3, ms, nil, nil);
    } @catch (NSException *e) {}
}

static void CloseWindow(NSDictionary *d) {
    if (!d) return;
    NSString *bid = d[@"bid"];
    [gWindows removeObject:d];
    UIWindow *w = d[@"win"];
    w.hidden = YES;

    BOOL stillOpen = NO;
    for (NSDictionary *o in gWindows) {
        if ([o[@"bid"] isEqualToString:bid]) { stillOpen = YES; break; }
    }
    if (!stillOpen) ReleaseAssertion(bid);
    A(@"关闭窗口 %@（剩 %lu 个）", bid, (unsigned long)gWindows.count);
}

static void ShowPanel(void);

// ---------- 触摸穿透 ----------
//
//  问题：全屏 UIWindow 的 root view 是普通 UIView，会吃掉整个屏幕的触摸，
//  导致主屏、浮窗外的区域全部点不动。
//
//  修法：root view 只把触摸交给真正命中的子视图，其余返回 nil，
//  事件继续往下传给 SpringBoard。

@interface MWPassthroughView : UIView
@end

@implementation MWPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *v in [self.subviews reverseObjectEnumerator]) {
        if (v.hidden || v.alpha < 0.01) continue;
        CGPoint p = [self convertPoint:point toView:v];
        UIView *hit = [v hitTest:p withEvent:event];
        if (hit) return hit;
    }
    return nil;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return NO; }
@end

@interface MWPassVC : UIViewController
@end

@implementation MWPassVC
- (void)loadView {
    MWPassthroughView *v = [[MWPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.backgroundColor = [UIColor clearColor];
    self.view = v;
}
@end

// ---------- 常驻小圆点 ----------

@interface S6Dot : UIView
@end

@implementation S6Dot
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor colorWithRed:0.15 green:0.5 blue:0.95 alpha:0.95];
        self.layer.cornerRadius = CGRectGetWidth(f) / 2.0;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.35;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 3);

        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.text = @"MW";
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightHeavy];
        l.userInteractionEnabled = NO;
        [self addSubview:l];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                action:@selector(tap)]];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                action:@selector(pan:)]];
    }
    return self;
}

- (void)tap { ShowPanel(); }

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *host = self.superview;
    if (!host) return;
    CGPoint d = [g translationInView:host];
    CGPoint c = self.center;
    c.x += d.x; c.y += d.y;
    CGFloat r = CGRectGetWidth(self.bounds) / 2.0;
    c.x = MAX(r + 4, MIN(c.x, CGRectGetWidth(host.bounds) - r - 4));
    c.y = MAX(r + 30, MIN(c.y, CGRectGetHeight(host.bounds) - r - 30));
    self.center = c;
    [g setTranslation:CGPointZero inView:host];
}
@end

static void EnsureDot(void) {
    if (gButtonWin) { gButtonWin.hidden = NO; return; }

    UIWindow *w = MakeWindow(UIWindowLevelAlert + 850, [UIColor clearColor]);
    MWPassVC *vc = [MWPassVC new];
    w.rootViewController = vc;

    CGRect sb = [UIScreen mainScreen].bounds;
    S6Dot *dot = [[S6Dot alloc] initWithFrame:CGRectMake(sb.size.width - 62,
                                                        sb.size.height * 0.42, 44, 44)];
    [vc.view addSubview:dot];

    w.hidden = NO;
    gButtonWin = w;
    gButton = dot;
}

// ---------- 浮窗 ----------

static void Refit(UIView *win, UIView *content) {
    if (!win || !content) return;
    CGRect area = CGRectMake(0, 26, win.bounds.size.width, win.bounds.size.height - 26);
    if (area.size.width < 1 || area.size.height < 1) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat s = MIN(area.size.width / sb.size.width, area.size.height / sb.size.height);
    content.transform = CGAffineTransformIdentity;
    content.bounds = CGRectMake(0, 0, sb.size.width, sb.size.height);
    content.center = CGPointMake(CGRectGetMidX(area), CGRectGetMidY(area));
    content.transform = CGAffineTransformMakeScale(s, s);
}

@interface S6Drag : NSObject
@property (nonatomic, weak) UIView *win;
@property (nonatomic, weak) UIView *content;
@property (nonatomic) CGPoint grab;
@end
@implementation S6Drag
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *win = self.win;
    if (!win || !win.superview) return;
    CGPoint p = [g locationInView:win.superview];
    if (g.state == UIGestureRecognizerStateBegan)
        self.grab = CGPointMake(p.x - win.center.x, p.y - win.center.y);
    else if (g.state == UIGestureRecognizerStateChanged)
        win.center = CGPointMake(p.x - self.grab.x, p.y - self.grab.y);
}
@end

@interface S6Resize : NSObject
@property (nonatomic, weak) UIView *win;
@property (nonatomic, weak) UIView *content;
@property (nonatomic) CGRect startFrame;
@property (nonatomic) CGPoint startPoint;
@end
@implementation S6Resize
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *win = self.win;
    if (!win || !win.superview) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.startFrame = win.frame;
        self.startPoint = [g locationInView:win.superview];
        return;
    }
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGPoint p = [g locationInView:win.superview];
    CGFloat dx = p.x - self.startPoint.x;
    CGFloat dy = p.y - self.startPoint.y;
    CGRect f = self.startFrame;
    CGRect sb = [UIScreen mainScreen].bounds;
    f.size.width = MAX(150.0, MIN(self.startFrame.size.width + dx, sb.size.width - f.origin.x - 4));
    f.size.height = MAX(200.0, MIN(self.startFrame.size.height + dy, sb.size.height - f.origin.y - 40));
    win.frame = f;
    Refit(win, self.content);
}
@end

@interface S6CloseBar : UIButton
@property (nonatomic, strong) NSDictionary *ctx;
@end
@implementation S6CloseBar
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor systemRedColor];
        self.layer.cornerRadius = CGRectGetHeight(f) / 2.0;
        [self addTarget:self action:@selector(hideSelf) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)hideSelf { CloseWindow(self.ctx); }
@end

static void ShowFloating(UIView *content, id scene, NSString *bid) {
    UIWindow *host = MakeWindow(UIWindowLevelAlert + 800, [UIColor clearColor]);
    MWPassVC *vc = [MWPassVC new];
    host.rootViewController = vc;

    CGRect sb = [UIScreen mainScreen].bounds;
    NSInteger n = (NSInteger)gWindows.count;
    CGFloat w = sb.size.width * 0.58;
    CGFloat h = w * 1.7;
    if (h > sb.size.height * 0.62) h = sb.size.height * 0.62;
    CGFloat ox = 12 + (CGFloat)(n % 4) * 22;
    CGFloat oy = 80 + (CGFloat)(n % 4) * 30;

    UIView *win = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width - w - ox, oy, w, h)];
    win.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    win.layer.cornerRadius = 12;
    win.layer.borderWidth = 1;
    win.layer.borderColor = [[UIColor colorWithWhite:1 alpha:0.3] CGColor];
    win.clipsToBounds = YES;
    [vc.view addSubview:win];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 26)];
    bar.backgroundColor = [UIColor colorWithWhite:0.24 alpha:1.0];
    [win addSubview:bar];

    NSMutableDictionary *ctx = [NSMutableDictionary dictionary];
    ctx[@"win"] = host;
    ctx[@"content"] = content;
    ctx[@"scene"] = scene ?: [NSNull null];
    ctx[@"bid"] = bid ?: @"";

    S6CloseBar *cb = [[S6CloseBar alloc] initWithFrame:CGRectMake(8, 6, 52, 14)];
    cb.ctx = ctx;
    [bar addSubview:cb];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(68, 0, w - 76, 26)];
    lbl.text = bid;
    lbl.font = [UIFont systemFontOfSize:10];
    lbl.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    lbl.adjustsFontSizeToFitWidth = YES;
    [bar addSubview:lbl];

    [win addSubview:content];
    Refit(win, content);

    S6Drag *drag = [S6Drag new];
    drag.win = win;
    drag.content = content;
    [bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:drag action:@selector(pan:)]];
    objc_setAssociatedObject(win, "s6drag", drag, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(w - 26, h - 26, 22, 22)];
    handle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    handle.layer.cornerRadius = 5;
    handle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [win addSubview:handle];

    S6Resize *rz = [S6Resize new];
    rz.win = win;
    rz.content = content;
    [handle addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:rz action:@selector(pan:)]];
    objc_setAssociatedObject(win, "s6resize", rz, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    host.hidden = NO;
    [gWindows addObject:ctx];
    A(@"窗口 %lu 已开 %@ (%.0fx%.0f)", (unsigned long)gWindows.count, bid, w, h);
}

static UIView *BuildContainer(id scene, NSMutableString *r) {
    NSArray *layers = LayerList(scene);
    [r appendFormat:@"layers=%lu ", (unsigned long)layers.count];
    if (layers.count == 0) { [r appendString:@"(空)"]; return nil; }

    Class cc = NSClassFromString(@"_UISceneLayerHostContainerView");
    if (!cc) { [r appendString:@"no class"]; return nil; }

    id container = nil;
    @try {
        if ([(id)cc instancesRespondToSelector:@selector(initWithScene:debugDescription:)]) {
            container = ((id (*)(id, SEL, id, id))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)((id)cc, @selector(alloc)),
                @selector(initWithScene:debugDescription:), scene, @"MW16");
        } else if ([(id)cc instancesRespondToSelector:@selector(initWithScene:)]) {
            container = ((id (*)(id, SEL, id))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)((id)cc, @selector(alloc)),
                @selector(initWithScene:), scene);
        }
    } @catch (NSException *e) { [r appendFormat:@"EXC:%@", e.reason]; return nil; }
    if (!container) { [r appendString:@"nil"]; return nil; }

    UIView *cv = (UIView *)container;
    if (CGRectIsEmpty(cv.frame)) cv.frame = CGRectMake(0, 0, 320, 560);
    cv.userInteractionEnabled = YES;

    int made = 0;
    for (id layer in layers) {
        @try {
            UIView *hv = ((id (*)(id, SEL, id))objc_msgSend)(container, @selector(_createHostViewForLayer:), layer);
            if (!hv) continue;
            hv.frame = cv.bounds;
            hv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [cv addSubview:hv];
            made++;
        } @catch (NSException *e) {}
    }
    [r appendFormat:@"hostViews=%d", made];
    return (made > 0) ? cv : nil;
}

static void LaunchApp(NSString *bid) {
    id app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if (app && [app respondsToSelector:sel])
        @try { ((void (*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, bid, YES); }
        @catch (NSException *e) {}
}

static void StopPoll(void) {
    if (gPoll) { dispatch_source_cancel(gPoll); gPoll = nil; }
}

static void StartOpen(NSString *bid) {
    StopPoll();
    if (!gOut) gOut = [NSMutableString string];
    [gOut setString:@""];
    gPollCount = 0;
    A(@"打开 %@", bid);

    LaunchApp(bid);
    AcquireAssertion(bid);

    gPoll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gPoll, dispatch_time(DISPATCH_TIME_NOW, 0), 400 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gPoll, ^{
        gPollCount++;
        id scene = SceneForBundle(bid);
        NSArray *ls = scene ? LayerList(scene) : nil;

        if (gPollCount % 5 == 1) {
            A(@"[%d] scene=%@ layers=%lu pid=%d", gPollCount, scene ? @"Y" : @"N",
              (unsigned long)ls.count, PidOf(bid));
        }

        if (scene && ls.count > 0) {
            StopPoll();
            NSMutableString *r = [NSMutableString string];
            UIView *cv = BuildContainer(scene, r);
            A(@"build: %@ -> %@", r, cv ? @"OK" : @"FAIL");
            if (cv) {
                ShowFloating(cv, scene, bid);
                if (gPanelWin) { gPanelWin.hidden = YES; }
                EnsureDot();
            }
            Flush();
            return;
        }
        if (gPollCount >= 60) {
            StopPoll();
            A(@"超时 24s");
            Flush();
        }
    });
    dispatch_resume(gPoll);
}

// ---------- 保活循环（带诊断） ----------

static void StartKeepAlive(void) {
    if (gKeep) return;
    gKeep = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gKeep, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              3 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gKeep, ^{
        if (!gWindows.count) return;
        NSMutableString *line = [NSMutableString string];
        for (NSDictionary *d in [gWindows copy]) {
            NSString *bid = d[@"bid"];
            id sc = d[@"scene"];
            if (!sc || sc == [NSNull null]) continue;

            int pid = PidOf(bid);
            NSArray *ls = LayerList(sc);
            BOOL hasAssert = (gAssertions[bid] != nil);

            [line appendFormat:@"%@ pid=%d layers=%lu rbs=%d | ",
                bid, pid, (unsigned long)ls.count, hasAssert ? 1 : 0];

            // 场景前台 + 若断言丢了再补一次
            ForceForeground(sc);
            if (!hasAssert && pid > 0) AcquireAssertion(bid);
        }
        if (line.length) A(@"[keep] %@", line);
    });
    dispatch_resume(gKeep);
}

// ---------- 面板 ----------

@interface S6Panel : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITextView *trace;
@end

@implementation S6Panel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    CGRect sb = [UIScreen mainScreen].bounds;

    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(12, 46, sb.size.width - 90, 28)];
    h.text = @"MW16 Stage 7";
    h.textColor = [UIColor whiteColor];
    h.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [self.view addSubview:h];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(sb.size.width - 52, 42, 40, 34);
    [x setTitle:@"X" forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    [x addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:x];

    self.field = [[UITextField alloc] initWithFrame:CGRectMake(12, 80, sb.size.width - 116, 34)];
    self.field.placeholder = @"bundle id";
    self.field.borderStyle = UITextBorderStyleRoundedRect;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.delegate = self;
    self.field.textColor = [UIColor whiteColor];
    self.field.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    self.field.text = @"tv.danmaku.bilianime";
    [self.view addSubview:self.field];

    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    go.frame = CGRectMake(sb.size.width - 98, 80, 86, 34);
    [go setTitle:@"开新窗口" forState:UIControlStateNormal];
    go.backgroundColor = [UIColor systemBlueColor];
    [go setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont systemFontOfSize:12];
    go.layer.cornerRadius = 8;
    [go addTarget:self action:@selector(goTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:go];

    UIButton *clr = [UIButton buttonWithType:UIButtonTypeSystem];
    clr.frame = CGRectMake(12, 118, 110, 26);
    [clr setTitle:@"清空诊断" forState:UIControlStateNormal];
    clr.titleLabel.font = [UIFont systemFontOfSize:12];
    [clr addTarget:self action:@selector(clear) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:clr];

    self.trace = [[UITextView alloc] initWithFrame:CGRectMake(0, 150, sb.size.width, sb.size.height - 168)];
    self.trace.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.trace.textColor = [UIColor colorWithRed:0.45 green:1.0 blue:0.55 alpha:1.0];
    self.trace.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.trace.editable = NO;
    [self.view addSubview:self.trace];
    gTrace = self.trace;

    if (!gOut) gOut = [NSMutableString string];
    A(@"开窗后按 Home，看下面 [keep] 行的 layers 变化：");
    A(@"  layers 变 0 = 图层被摘掉；pid 变 0 = 进程没了");
}

- (void)hidePanel { if (gPanelWin) { gPanelWin.hidden = YES; gPanelWin = nil; } }

- (void)clear {
    if (gOut) [gOut setString:@""];
    if (gTrace) gTrace.text = @"";
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self goTapped]; return YES; }

- (void)goTapped {
    NSString *bid = [self.field.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!bid.length) { A(@"先输入 bundle id"); return; }
    [self.field resignFirstResponder];
    StartOpen(bid);
}

@end

static void ShowPanel(void) {
    if (gPanelWin) { gPanelWin.hidden = NO; return; }
    UIWindow *w = MakeWindow(UIWindowLevelAlert + 900, [UIColor colorWithWhite:0 alpha:0.94]);
    S6Panel *p = [S6Panel new];
    w.rootViewController = p;
    w.hidden = NO;
    gPanelWin = w;
}

%hook UIMutableApplicationSceneSettings
- (void)setDeactivationReasons:(unsigned long long)reasons {
    if (reasons != 0 && gWindows.count) {
        NSString *ident = nil;
        for (NSString *nm in @[@"_sceneIdentifier", @"_identifier"]) {
            Ivar iv = class_getInstanceVariable(object_getClass(self), [nm UTF8String]);
            if (iv) {
                id v = (__bridge id)(*(void **)((__bridge void *)self + ivar_getOffset(iv)));
                if ([v isKindOfClass:[NSString class]]) { ident = v; break; }
            }
        }
        if (ident) {
            for (NSDictionary *d in gWindows) {
                NSString *bid = d[@"bid"];
                if (bid.length && [ident containsString:bid]) { %orig(0); return; }
            }
        }
    }
    %orig;
}
%end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gWindows) gWindows = [NSMutableArray array];
        if (!gAssertions) gAssertions = [NSMutableDictionary dictionary];
        StartKeepAlive();
        EnsureDot();
        ShowPanel();
    });
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gWindows) gWindows = [NSMutableArray array];
        if (!gAssertions) gAssertions = [NSMutableDictionary dictionary];
        StartKeepAlive();
        EnsureDot();
        if (!gPanelWin) ShowPanel();
    });
    %init;
}
