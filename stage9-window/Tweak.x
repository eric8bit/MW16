#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MW16 Stage 9 —— 小窗口架构（彻底解决触摸问题）
//
//  v7 的教训：用「铺满全屏的透明 UIWindow」承载圆点和浮窗，
//  即使把 root view 改成穿透的，只要有一处没穿透干净，整个主屏就废了。
//
//  v9 换思路：
//    - 圆点窗口只有 56x56，不在圆点上的触摸根本碰不到这个窗口
//    - 浮窗窗口跟浮窗一样大，窗口外就是桌面，天然可点
//    - 只有设置面板是全屏，不用时 hidden
//
//  这样完全不需要 hitTest 穿透，从架构上消灭问题。

#define S9_LOG @"/var/mobile/Media/mw16_stage9.log"

static NSMutableString *gOut = nil;
static NSMutableString *gFile = nil;
static UITextView *gTrace = nil;
static UIWindow *gPanelWin = nil;
static UIWindow *gDotWin = nil;
static UIView *gDotView = nil;
static dispatch_source_t gPoll = nil;
static dispatch_source_t gKeep = nil;
static int gPollCount = 0;

static NSMutableArray *gWindows = nil;
static NSMutableDictionary *gAssertions = nil;

static void A(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gOut) gOut = [NSMutableString string];
    if (!gFile) gFile = [NSMutableString string];
    [gOut appendFormat:@"%@\n", s];
    [gFile appendFormat:@"%@\n", s];
    if (gFile.length > 60000) [gFile deleteCharactersInRange:NSMakeRange(0, 20000)];
    if (gOut.length > 30000) [gOut deleteCharactersInRange:NSMakeRange(0, 10000)];
    NSLog(@"[MW16-S9] %@", s);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gTrace) return;
        gTrace.text = gOut;
        if (gTrace.text.length)
            [gTrace scrollRangeToVisible:NSMakeRange(gTrace.text.length - 1, 1)];
    });
}

static void Flush(void) {
    NSString *s = gFile ?: @"";
    if (!s.length) return;
    @try {
        [s writeToFile:S9_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}

static void FlushAsync(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ Flush(); });
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

static UIWindow *NewWindow(CGRect frame, CGFloat level) {
    UIWindowScene *ws = ActiveScene();
    UIWindow *w = ws ? [[UIWindow alloc] initWithWindowScene:ws]
                     : [[UIWindow alloc] initWithFrame:frame];
    w.frame = frame;
    w.windowLevel = level;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = [UIColor clearColor];
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
    NSMutableArray *o = [NSMutableArray array];
    SEL sel = NSSelectorFromString(@"enumerateScenesWithBlock:");
    if ([mgr respondsToSelector:sel]) {
        void (^b)(id) = ^(id s) { if (s) [o addObject:s]; };
        @try { ((void (*)(id, SEL, id))objc_msgSend)(mgr, sel, b); } @catch (NSException *e) {}
    }
    return o;
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
    for (id x in v) [m addObject:x];
    return m;
}

// ---------- pid / RBS ----------

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
    id pst = [app respondsToSelector:ps] ? ((id (*)(id, SEL))objc_msgSend)(app, ps) : nil;
    SEL pidSel = NSSelectorFromString(@"pid");
    if (pst && [pst respondsToSelector:pidSel])
        return ((int (*)(id, SEL))objc_msgSend)(pst, pidSel);
    if ([app respondsToSelector:pidSel])
        return ((int (*)(id, SEL))objc_msgSend)(app, pidSel);
    return 0;
}

static void ReportRBS(void) {
    A(@"RBS: target=%d attr=%d assertion=%d",
      NSClassFromString(@"RBSTarget") != nil,
      NSClassFromString(@"RBSLegacyAttribute") != nil,
      NSClassFromString(@"RBSAssertion") != nil);
}

static void AcquireAssertion(NSString *bid) {
    if (!bid.length) return;
    if (!gAssertions) gAssertions = [NSMutableDictionary dictionary];
    if (gAssertions[bid]) return;
    Class tgtC = NSClassFromString(@"RBSTarget");
    Class attrC = NSClassFromString(@"RBSLegacyAttribute");
    Class asrtC = NSClassFromString(@"RBSAssertion");
    if (!tgtC || !attrC || !asrtC) return;

    int pid = PidOf(bid);
    if (pid <= 0) return;

    @try {
        id target = ((id (*)(id, SEL, int))objc_msgSend)((id)tgtC, @selector(targetWithPid:), pid);
        id attr = ((id (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)((id)attrC,
                    @selector(attributeWithReason:flags:), (NSUInteger)7, (NSUInteger)0x0B);
        id asrt = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
                    ((id (*)(id, SEL))objc_msgSend)((id)asrtC, @selector(alloc)),
                    @selector(initWithExplanation:target:attributes:),
                    @"MW16 keep alive", target, @[attr]);
        NSError *err = nil;
        BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(asrt, @selector(acquireWithError:), &err);
        if (ok) {
            gAssertions[bid] = asrt;
            A(@"[%@] RBS 断言成功 pid=%d", bid, pid);
        } else {
            A(@"[%@] RBS 失败 pid=%d err=%@", bid, pid, err.localizedDescription ?: @"?");
        }
    } @catch (NSException *e) {
        A(@"[%@] RBS 异常 %@", bid, e.reason);
    }
}

static void ReleaseAssertion(NSString *bid) {
    if (!bid.length) return;
    id a = gAssertions[bid];
    if (!a) return;
    SEL inv = NSSelectorFromString(@"invalidate");
    if ([a respondsToSelector:inv])
        @try { ((void (*)(id, SEL))objc_msgSend)(a, inv); } @catch (NSException *e) {}
    [gAssertions removeObjectForKey:bid];
    A(@"[%@] RBS 已释放", bid);
}

static void ForceForeground(id scene) {
    if (!scene) return;
    @try {
        SEL stSel = NSSelectorFromString(@"settings");
        if (![scene respondsToSelector:stSel]) return;
        id st = ((id (*)(id, SEL))objc_msgSend)(scene, stSel);
        if (!st || ![st respondsToSelector:@selector(mutableCopy)]) return;
        id ms = ((id (*)(id, SEL))objc_msgSend)(st, @selector(mutableCopy));
        if (!ms) return;
        SEL fg = NSSelectorFromString(@"setForeground:");
        if ([ms respondsToSelector:fg]) ((void (*)(id, SEL, BOOL))objc_msgSend)(ms, fg, YES);
        SEL dr = NSSelectorFromString(@"setDeactivationReasons:");
        if ([ms respondsToSelector:dr])
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(ms, dr, 0ULL);
        SEL up = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if ([scene respondsToSelector:up])
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, up, ms, nil);
    } @catch (NSException *e) {}
}

// ---------- 手势辅助（block 型 target，避免 @selector 传 block 参数） ----------

@interface MWBlockTarget : NSObject
@property (nonatomic, copy) void (^handler)(id sender);
@end

@implementation MWBlockTarget
- (void)fire:(id)sender { if (self.handler) self.handler(sender); }
@end

static MWBlockTarget *MakeTarget(void (^handler)(id)) {
    MWBlockTarget *t = [MWBlockTarget new];
    t.handler = handler;
    return t;
}

// ---------- 内容等比缩放 ----------

static void FitContent(UIView *host, UIView *content) {
    if (!host || !content) return;
    CGFloat bw = host.bounds.size.width;
    CGFloat bh = host.bounds.size.height;
    if (bw < 1 || bh < 1) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    if (sb.size.width < 1 || sb.size.height < 1) return;
    CGFloat k = MIN(bw / sb.size.width, bh / sb.size.height);
    content.transform = CGAffineTransformIdentity;
    content.bounds = CGRectMake(0, 0, sb.size.width, sb.size.height);
    content.center = CGPointMake(bw / 2.0, bh / 2.0);
    content.transform = CGAffineTransformMakeScale(k, k);
}

// ---------- 浮窗 ----------

static void CloseOne(NSDictionary *ctx) {
    if (!ctx) return;
    [gWindows removeObject:ctx];
    UIWindow *w = ctx[@"win"];
    w.hidden = YES;
    NSString *bid = ctx[@"bid"];
    BOOL still = NO;
    for (NSDictionary *d in gWindows) {
        if ([d[@"bid"] isEqualToString:bid]) { still = YES; break; }
    }
    if (!still) ReleaseAssertion(bid);
    A(@"关闭浮窗 %@（剩 %lu）", bid, (unsigned long)gWindows.count);
    FlushAsync();
}

static UIView *BuildContainer(id scene, NSMutableString *r) {
    NSArray *layers = LayerList(scene);
    [r appendFormat:@"layers=%lu ", (unsigned long)layers.count];
    if (!layers.count) { [r appendString:@"(空)"]; return nil; }

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
            UIView *hv = ((id (*)(id, SEL, id))objc_msgSend)(container,
                            @selector(_createHostViewForLayer:), layer);
            if (!hv) continue;
            hv.frame = cv.bounds;
            hv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [cv addSubview:hv];
            made++;
        } @catch (NSException *e) {}
    }
    [r appendFormat:@"hostViews=%d", made];
    return made > 0 ? cv : nil;
}

// 浮窗窗口 = 浮窗大小，窗口外天然可点桌面
static void ShowFloating(UIView *content, id scene, NSString *bid) {
    CGRect sb = [UIScreen mainScreen].bounds;
    NSInteger n = (NSInteger)gWindows.count;

    CGFloat w = sb.size.width * 0.60;
    CGFloat h = w * 1.70;
    if (h > sb.size.height * 0.62) h = sb.size.height * 0.62;
    CGFloat x = sb.size.width - w - 12 - (CGFloat)(n % 3) * 24;
    CGFloat y = 90 + (CGFloat)(n % 3) * 32;
    if (x < 4) x = 4;

    UIWindow *win = NewWindow(CGRectMake(x, y, w, h), UIWindowLevelAlert + 800);
    UIView *root = win.rootViewController.view;
    root.frame = win.bounds;

    UIView *panel = [[UIView alloc] initWithFrame:root.bounds];
    panel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    panel.layer.cornerRadius = 12;
    panel.layer.borderWidth = 1;
    panel.layer.borderColor = [[UIColor colorWithWhite:1 alpha:0.30] CGColor];
    panel.clipsToBounds = YES;
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:panel];

    // 标题栏
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 26)];
    bar.backgroundColor = [UIColor colorWithWhite:0.26 alpha:1.0];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [panel addSubview:bar];

    NSMutableDictionary *ctx = [NSMutableDictionary dictionary];
    ctx[@"win"] = win;
    ctx[@"content"] = content;
    ctx[@"bid"] = bid ?: @"";
    ctx[@"scene"] = scene ?: [NSNull null];

    // 关闭按钮
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(8, 6, 52, 14);
    close.backgroundColor = [UIColor systemRedColor];
    close.layer.cornerRadius = 7;
    MWBlockTarget *closeT = MakeTarget(^(id sender) { CloseOne(ctx); });
    [close addTarget:closeT action:@selector(fire:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(close, "t", closeT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [bar addSubview:close];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(68, 0, w - 76, 26)];
    lbl.text = bid;
    lbl.font = [UIFont systemFontOfSize:10];
    lbl.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    lbl.adjustsFontSizeToFitWidth = YES;
    [bar addSubview:lbl];

    // 内容区
    UIView *area = [[UIView alloc] initWithFrame:CGRectMake(0, 26, w, h - 26)];
    area.backgroundColor = [UIColor blackColor];
    area.clipsToBounds = YES;
    area.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [panel addSubview:area];
    [area addSubview:content];
    FitContent(area, content);

    // 拖动：标题栏
    __block CGPoint grab = CGPointZero;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] init];
    [bar addGestureRecognizer:pan];
    MWBlockTarget *panT = MakeTarget(^(UIPanGestureRecognizer *g) {
        CGPoint p = [g locationInView:nil];
        if (g.state == UIGestureRecognizerStateBegan) {
            grab = CGPointMake(p.x - win.frame.origin.x, p.y - win.frame.origin.y);
        } else if (g.state == UIGestureRecognizerStateChanged) {
            CGFloat nx = p.x - grab.x;
            CGFloat ny = p.y - grab.y;
            CGRect scr = [UIScreen mainScreen].bounds;
            nx = MAX(0, MIN(nx, scr.size.width - win.frame.size.width));
            ny = MAX(24, MIN(ny, scr.size.height - win.frame.size.height - 16));
            win.frame = CGRectMake(nx, ny, win.frame.size.width, win.frame.size.height);
        }
    });
    [pan addTarget:panT action:@selector(fire:)];
    objc_setAssociatedObject(bar, "t", panT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 缩放：右下角手柄
    CGFloat hs = 26;
    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(w - hs, h - hs, hs, hs)];
    handle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    handle.layer.cornerRadius = 6;
    handle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [panel addSubview:handle];

    __block CGRect startF = CGRectZero;
    __block CGPoint startP = CGPointZero;
    UIPanGestureRecognizer *rp = [[UIPanGestureRecognizer alloc] init];
    [handle addGestureRecognizer:rp];
    MWBlockTarget *rpT = MakeTarget(^(UIPanGestureRecognizer *g) {
        CGPoint p = [g locationInView:nil];
        if (g.state == UIGestureRecognizerStateBegan) {
            startF = win.frame;
            startP = p;
            return;
        }
        if (g.state != UIGestureRecognizerStateChanged) return;
        CGRect scr = [UIScreen mainScreen].bounds;
        CGFloat nw = MAX(160, MIN(startF.size.width + (p.x - startP.x), scr.size.width - startF.origin.x));
        CGFloat nh = MAX(220, MIN(startF.size.height + (p.y - startP.y), scr.size.height - startF.origin.y - 24));
        win.frame = CGRectMake(startF.origin.x, startF.origin.y, nw, nh);
        panel.frame = CGRectMake(0, 0, nw, nh);
        bar.frame = CGRectMake(0, 0, nw, 26);
        lbl.frame = CGRectMake(68, 0, nw - 76, 26);
        area.frame = CGRectMake(0, 26, nw, nh - 26);
        handle.frame = CGRectMake(nw - hs, nh - hs, hs, hs);
        FitContent(area, content);
    });
    [rp addTarget:rpT action:@selector(fire:)];
    objc_setAssociatedObject(handle, "t", rpT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    win.hidden = NO;
    [gWindows addObject:ctx];
    A(@"浮窗 %lu 已开 %@ (%.0fx%.0f) 位置(%.0f,%.0f)",
      (unsigned long)gWindows.count, bid, w, h, x, y);
}

static void LaunchApp(NSString *bid) {
    id app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if (app && [app respondsToSelector:sel])
        @try { ((void (*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, bid, YES); }
        @catch (NSException *e) {}
}

static void EnsureDot(void);
static void ShowPanel(void);

static void StopPoll(void) {
    if (gPoll) { dispatch_source_cancel(gPoll); gPoll = nil; }
}

static void StartOpen(NSString *bid) {
    StopPoll();
    if (!gOut) gOut = [NSMutableString string];
    if (!gFile) gFile = [NSMutableString string];
    [gOut setString:@""];
    [gFile setString:@""];
    gPollCount = 0;
    A(@"打开 %@", bid);
    Flush();

    LaunchApp(bid);

    gPoll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gPoll, dispatch_time(DISPATCH_TIME_NOW, 0),
                              400 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gPoll, ^{
        gPollCount++;
        id scene = SceneForBundle(bid);
        NSArray *ls = scene ? LayerList(scene) : nil;
        int pid = PidOf(bid);
        if (pid > 0) AcquireAssertion(bid);

        if (gPollCount % 5 == 1) {
            A(@"[%d] scene=%@ layers=%lu pid=%d rbs=%d", gPollCount, scene ? @"Y" : @"N",
              (unsigned long)ls.count, pid, gAssertions[bid] ? 1 : 0);
        }

        if (scene && ls.count > 0) {
            StopPoll();
            NSMutableString *r = [NSMutableString string];
            UIView *cv = BuildContainer(scene, r);
            A(@"build: %@ -> %@", r, cv ? @"OK" : @"FAIL");
            if (cv) {
                ShowFloating(cv, scene, bid);
                if (gPanelWin) gPanelWin.hidden = YES;
                EnsureDot();
            }
            Flush();
            return;
        }

        if (gPollCount >= 60) {
            StopPoll();
            A(@"超时 24s：没拿到图层");
            Flush();
        }
    });
    dispatch_resume(gPoll);
}

// ---------- 保活 ----------

static void StartKeepAlive(void) {
    if (gKeep) return;
    gKeep = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gKeep, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              3 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gKeep, ^{
        if (!gWindows.count) return;
        NSMutableString *line = [NSMutableString string];
        for (NSDictionary *d in [gWindows copy]) {
            NSString *bid = d[@"bid"];
            int pid = PidOf(bid);
            id sc = SceneForBundle(bid);
            NSArray *ls = sc ? LayerList(sc) : nil;
            [line appendFormat:@"%@ pid=%d layers=%lu rbs=%d | ",
                bid, pid, (unsigned long)ls.count, gAssertions[bid] ? 1 : 0];
            if (pid > 0 && !gAssertions[bid]) AcquireAssertion(bid);
            if (sc) ForceForeground(sc);
        }
        if (line.length) {
            A(@"[keep] %@", line);
            static int tick = 0;
            if (++tick % 2 == 0) FlushAsync();
        }
    });
    dispatch_resume(gKeep);
}

// ---------- 面板 ----------

static void ShowPanel(void);

@interface MWPanel : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITextView *trace;
@end

@implementation MWPanel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    CGRect sb = [UIScreen mainScreen].bounds;

    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(14, 54, sb.size.width - 80, 30)];
    h.text = @"MW16 Stage 9";
    h.textColor = UIColor.whiteColor;
    h.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [self.view addSubview:h];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(sb.size.width - 56, 50, 44, 36);
    [x setTitle:@"X" forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    [x addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:x];

    self.field = [[UITextField alloc] initWithFrame:CGRectMake(14, 96, sb.size.width - 128, 38)];
    self.field.placeholder = @"bundle id";
    self.field.borderStyle = UITextBorderStyleRoundedRect;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.delegate = self;
    self.field.textColor = UIColor.whiteColor;
    self.field.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    self.field.text = @"tv.danmaku.bilianime";
    [self.view addSubview:self.field];

    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    go.frame = CGRectMake(sb.size.width - 106, 96, 92, 38);
    [go setTitle:@"开浮窗" forState:UIControlStateNormal];
    go.backgroundColor = [UIColor systemBlueColor];
    [go setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont systemFontOfSize:14];
    go.layer.cornerRadius = 9;
    [go addTarget:self action:@selector(goTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:go];

    self.trace = [[UITextView alloc] initWithFrame:CGRectMake(0, 146, sb.size.width, sb.size.height - 170)];
    self.trace.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.trace.textColor = [UIColor colorWithRed:0.45 green:1.0 blue:0.55 alpha:1.0];
    self.trace.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.trace.editable = NO;
    [self.view addSubview:self.trace];
    gTrace = self.trace;
    if (gOut) self.trace.text = gOut;

    A(@"点「开浮窗」。浮窗外的主屏应该完全正常。");
}

- (void)hidePanel {
    FlushAsync();
    if (gPanelWin) { gPanelWin.hidden = YES; }
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    [self goTapped];
    return YES;
}

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
    CGRect sb = [UIScreen mainScreen].bounds;
    UIWindow *w = NewWindow(sb, UIWindowLevelAlert + 900);
    w.backgroundColor = [UIColor colorWithWhite:0 alpha:0.95];
    MWPanel *p = [MWPanel new];
    w.rootViewController = p;
    w.hidden = NO;
    gPanelWin = w;
}

static void EnsureDot(void) {
    if (gDotWin) { gDotWin.hidden = NO; return; }

    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat side = 56;
    CGFloat x = sb.size.width - side - 14;
    CGFloat y = sb.size.height * 0.56;

    UIWindow *w = NewWindow(CGRectMake(x, y, side, side), UIWindowLevelAlert + 850);
    UIView *root = w.rootViewController.view;
    root.frame = w.bounds;

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, side, side)];
    dot.backgroundColor = [UIColor colorWithRed:0.15 green:0.5 blue:0.95 alpha:0.95];
    dot.layer.cornerRadius = side / 2.0;
    dot.userInteractionEnabled = YES;
    [root addSubview:dot];

    UILabel *l = [[UILabel alloc] initWithFrame:dot.bounds];
    l.text = @"MW";
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
    l.userInteractionEnabled = NO;
    [dot addSubview:l];

    // 点一下 -> 打开面板
    MWBlockTarget *tapT = MakeTarget(^(id sender) { ShowPanel(); });
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] init];
    [tap addTarget:tapT action:@selector(fire:)];
    [dot addGestureRecognizer:tap];
    objc_setAssociatedObject(dot, "tap", tapT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 拖动 -> 移动圆点窗口
    __block CGPoint grab = CGPointZero;
    MWBlockTarget *panT = MakeTarget(^(UIPanGestureRecognizer *g) {
        CGPoint p = [g locationInView:nil];
        if (g.state == UIGestureRecognizerStateBegan) {
            grab = CGPointMake(p.x - w.frame.origin.x, p.y - w.frame.origin.y);
        } else if (g.state == UIGestureRecognizerStateChanged) {
            CGRect scr = [UIScreen mainScreen].bounds;
            CGFloat nx = MAX(0, MIN(p.x - grab.x, scr.size.width - side));
            CGFloat ny = MAX(24, MIN(p.y - grab.y, scr.size.height - side - 16));
            w.frame = CGRectMake(nx, ny, side, side);
        }
    });
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] init];
    [pan addTarget:panT action:@selector(fire:)];
    [dot addGestureRecognizer:pan];
    objc_setAssociatedObject(dot, "pan", panT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    w.hidden = NO;
    gDotWin = w;
    gDotView = dot;
    A(@"圆点已就位 (%.0f,%.0f)", x, y);
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
        ReportRBS();
        StartKeepAlive();
        EnsureDot();
    });
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gWindows) gWindows = [NSMutableArray array];
        if (!gAssertions) gAssertions = [NSMutableDictionary dictionary];
        ReportRBS();
        StartKeepAlive();
        EnsureDot();
    });
    %init;
}
