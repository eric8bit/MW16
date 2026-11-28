#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MW16 Stage 10 —— 应用菜单（小窗，不全屏）
//
//  v9 的问题：要手动输入 bundle id，且设置面板是全屏窗口。
//  v10 改成：
//    - 点蓝色 MW 圆点 → 弹出「应用列表」小窗
//    - 列表直接从系统读取已安装应用，点一下直接开浮窗
//    - 菜单窗口 320x480，不是全屏，其他地方照常可点

#define S10_LOG @"/var/mobile/Media/mw16_stage10.log"

static NSMutableString *gOut = nil;
static NSMutableString *gFile = nil;
static UITextView *gTrace = nil;
static UIWindow *gMenuWin = nil;
static UIWindow *gDotWin = nil;
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
    if (gOut.length > 20000) [gOut deleteCharactersInRange:NSMakeRange(0, 8000)];
    NSLog(@"[MW16-S10] %@", s);
}

static void Flush(void) {
    NSString *s = gFile ?: @"";
    if (!s.length) return;
    @try { [s writeToFile:S10_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    @catch (NSException *e) {}
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

// ---------- 已安装应用 ----------

static NSArray *InstalledApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    Class wsC = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsC) { A(@"LSApplicationWorkspace 缺失"); return out; }

    id ws = nil;
    if ([wsC respondsToSelector:@selector(defaultWorkspace)])
        ws = ((id (*)(id, SEL))objc_msgSend)((id)wsC, @selector(defaultWorkspace));
    if (!ws) { A(@"defaultWorkspace 为 nil"); return out; }

    SEL sel = NSSelectorFromString(@"allInstalledApplications");
    if (![ws respondsToSelector:sel]) sel = NSSelectorFromString(@"allApplications");
    if (![ws respondsToSelector:sel]) { A(@"没有 allInstalledApplications"); return out; }

    id all = nil;
    @try { all = ((id (*)(id, SEL))objc_msgSend)(ws, sel); }
    @catch (NSException *e) { A(@"取应用列表异常 %@", e.reason); return out; }
    if (![all isKindOfClass:[NSArray class]]) { A(@"应用列表类型异常"); return out; }

    for (id p in all) {
        NSString *bid = nil, *name = nil;

        for (NSString *s in @[@"bundleIdentifier", @"applicationIdentifier"]) {
            SEL x = NSSelectorFromString(s);
            if (![p respondsToSelector:x]) continue;
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)(p, x);
                if ([v isKindOfClass:[NSString class]] && [v length]) { bid = v; break; }
            } @catch (NSException *e) {}
        }
        for (NSString *s in @[@"localizedName", @"displayName", @"itemName"]) {
            SEL x = NSSelectorFromString(s);
            if (![p respondsToSelector:x]) continue;
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)(p, x);
                if ([v isKindOfClass:[NSString class]] && [v length]) { name = v; break; }
            } @catch (NSException *e) {}
        }

        if (!bid.length) continue;
        if ([bid hasPrefix:@"com.apple."]) continue;   // 系统 App 不列
        [out addObject:@{@"bid": bid, @"name": (name.length ? name : bid)}];
    }

    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    A(@"读到 %lu 个应用", (unsigned long)out.count);
    return out;
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

// ---------- block target ----------

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

// ---------- 缩放 / 浮窗 ----------

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

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 26)];
    bar.backgroundColor = [UIColor colorWithWhite:0.26 alpha:1.0];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [panel addSubview:bar];

    NSMutableDictionary *ctx = [NSMutableDictionary dictionary];
    ctx[@"win"] = win;
    ctx[@"content"] = content;
    ctx[@"bid"] = bid ?: @"";
    ctx[@"scene"] = scene ?: [NSNull null];

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

    UIView *area = [[UIView alloc] initWithFrame:CGRectMake(0, 26, w, h - 26)];
    area.backgroundColor = [UIColor blackColor];
    area.clipsToBounds = YES;
    area.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [panel addSubview:area];
    [area addSubview:content];
    FitContent(area, content);

    __block CGPoint grab = CGPointZero;
    MWBlockTarget *panT = MakeTarget(^(UIPanGestureRecognizer *g) {
        CGPoint p = [g locationInView:nil];
        if (g.state == UIGestureRecognizerStateBegan) {
            grab = CGPointMake(p.x - win.frame.origin.x, p.y - win.frame.origin.y);
        } else if (g.state == UIGestureRecognizerStateChanged) {
            CGRect scr = [UIScreen mainScreen].bounds;
            CGFloat nx = MAX(0, MIN(p.x - grab.x, scr.size.width - win.frame.size.width));
            CGFloat ny = MAX(24, MIN(p.y - grab.y, scr.size.height - win.frame.size.height - 16));
            win.frame = CGRectMake(nx, ny, win.frame.size.width, win.frame.size.height);
        }
    });
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] init];
    [pan addTarget:panT action:@selector(fire:)];
    [bar addGestureRecognizer:pan];
    objc_setAssociatedObject(bar, "t", panT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat hs = 26;
    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(w - hs, h - hs, hs, hs)];
    handle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    handle.layer.cornerRadius = 6;
    handle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [panel addSubview:handle];

    __block CGRect startF = CGRectZero;
    __block CGPoint startP = CGPointZero;
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
    UIPanGestureRecognizer *rp = [[UIPanGestureRecognizer alloc] init];
    [rp addTarget:rpT action:@selector(fire:)];
    [handle addGestureRecognizer:rp];
    objc_setAssociatedObject(handle, "t", rpT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    win.hidden = NO;
    [gWindows addObject:ctx];
    A(@"浮窗 %lu 已开 %@ (%.0fx%.0f)", (unsigned long)gWindows.count, bid, w, h);
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

static void HideMenu(void) {
    if (gMenuWin) gMenuWin.hidden = YES;
}

static void StartOpen(NSString *bid) {
    if (!bid.length) return;
    HideMenu();
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
            if (cv) ShowFloating(cv, scene, bid);
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
        for (NSDictionary *d in [gWindows copy]) {
            NSString *bid = d[@"bid"];
            int pid = PidOf(bid);
            if (pid > 0 && !gAssertions[bid]) AcquireAssertion(bid);
            id sc = SceneForBundle(bid);
            if (sc) ForceForeground(sc);
        }
    });
    dispatch_resume(gKeep);
}

// ---------- 应用菜单（小窗） ----------

@interface MWMenu : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *apps;
@property (nonatomic, strong) UILabel *hint;
@end

@implementation MWMenu

- (void)viewDidLoad {
    [super viewDidLoad];

    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat w = MIN(320.0, sb.size.width - 24);
    CGFloat h = MIN(480.0, sb.size.height - 120);

    self.view.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.view.frame = CGRectMake(0, 0, w, h);
    self.view.layer.cornerRadius = 14;
    self.view.clipsToBounds = YES;

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 40)];
    bar.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    [self.view addSubview:bar];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, w - 120, 40)];
    title.text = @"选择应用";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [bar addSubview:title];

    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.frame = CGRectMake(w - 92, 6, 40, 28);
    [refresh setTitle:@"刷新" forState:UIControlStateNormal];
    refresh.titleLabel.font = [UIFont systemFontOfSize:12];
    MWBlockTarget *rt = MakeTarget(^(id s) { [self reloadApps]; });
    [refresh addTarget:rt action:@selector(fire:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(refresh, "t", rt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [bar addSubview:refresh];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 46, 6, 38, 28);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    MWBlockTarget *ct = MakeTarget(^(id s) { HideMenu(); });
    [close addTarget:ct action:@selector(fire:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(close, "t", ct, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [bar addSubview:close];

    self.hint = [[UILabel alloc] initWithFrame:CGRectMake(12, h - 30, w - 24, 22)];
    self.hint.text = @"点应用名即可开浮窗";
    self.hint.font = [UIFont systemFontOfSize:11];
    self.hint.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    [self.view addSubview:self.hint];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 40, w, h - 74)
                                              style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    self.table.separatorColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    self.table.rowHeight = 46;
    if ([self.table respondsToSelector:@selector(setIndicatorStyle:)])
        self.table.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [self.view addSubview:self.table];

    self.apps = @[];
    [self reloadApps];
}

- (void)reloadApps {
    NSArray *list = InstalledApps();
    self.apps = list ?: @[];
    [self.table reloadData];
    self.hint.text = [NSString stringWithFormat:@"共 %lu 个应用 · 点名字开浮窗",
                      (unsigned long)self.apps.count];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"mwapp";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cid];
        cell.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        cell.textLabel.font = [UIFont systemFontOfSize:14];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:9];
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
        cell.selectedBackgroundView = sel;
    }

    if ((NSUInteger)indexPath.row >= self.apps.count) return cell;
    NSDictionary *d = self.apps[indexPath.row];
    cell.textLabel.text = d[@"name"];
    cell.detailTextLabel.text = d[@"bid"];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tv deselectRowAtIndexPath:indexPath animated:NO];
    if ((NSUInteger)indexPath.row >= self.apps.count) return;
    NSString *bid = self.apps[indexPath.row][@"bid"];
    if (!bid.length) return;
    StartOpen(bid);
}

@end

static void ShowMenu(void) {
    if (gMenuWin) { gMenuWin.hidden = NO; return; }

    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat w = MIN(320.0, sb.size.width - 24);
    CGFloat h = MIN(480.0, sb.size.height - 120);
    CGFloat x = (sb.size.width - w) / 2.0;
    CGFloat y = MAX(70.0, (sb.size.height - h) / 2.0 - 30);

    UIWindow *win = NewWindow(CGRectMake(x, y, w, h), UIWindowLevelAlert + 880);
    win.backgroundColor = [UIColor clearColor];
    MWMenu *m = [MWMenu new];
    win.rootViewController = m;
    win.hidden = NO;
    gMenuWin = win;
    A(@"菜单已打开 (%.0fx%.0f)", w, h);
}

static void ToggleMenu(void) {
    if (gMenuWin && !gMenuWin.hidden) { HideMenu(); return; }
    ShowMenu();
}

// ---------- 圆点 ----------

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

    MWBlockTarget *tapT = MakeTarget(^(id sender) { ToggleMenu(); });
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] init];
    [tap addTarget:tapT action:@selector(fire:)];
    [dot addGestureRecognizer:tap];
    objc_setAssociatedObject(dot, "tap", tapT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
