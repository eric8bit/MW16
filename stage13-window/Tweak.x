#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MW16 Stage 13
//  1. 拖动抖动：用「手势起始时的窗口原点 + 屏幕坐标」重算，避免坐标反馈
//  2. 秒出窗口：先弹占位窗，图层到了再填内容
//  3. 打开后台任务切换器时自动关闭所有浮窗
//  4. 场景识别增强 + 失败原因分类

#define S13_LOG @"/var/mobile/Media/mw16_stage13.log"

static NSMutableString *gOut = nil;
static NSMutableString *gFile = nil;
static id gLogLock = nil;
static UIWindow *gMenuWin = nil;
static UIWindow *gDotWin = nil;
static dispatch_source_t gPoll = nil;
static dispatch_source_t gKeep = nil;
static int gPollCount = 0;

static NSMutableArray *gWindows = nil;
static NSMutableDictionary *gAssertions = nil;
static NSMutableDictionary *gCache = nil;

static id LogLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLogLock = [NSObject new]; });
    return gLogLock;
}

static void A(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    @synchronized (LogLock()) {
        if (!gOut) gOut = [NSMutableString string];
        if (!gFile) gFile = [NSMutableString string];
        [gOut appendFormat:@"%@\n", s];
        [gFile appendFormat:@"%@\n", s];
        if (gFile.length > 60000) [gFile deleteCharactersInRange:NSMakeRange(0, 20000)];
        if (gOut.length > 20000) [gOut deleteCharactersInRange:NSMakeRange(0, 8000)];
    }
    NSLog(@"[MW16-S13] %@", s);
}

static void Flush(void) {
    NSString *s = nil;
    @synchronized (LogLock()) { s = [gFile copy] ?: @""; }
    if (!s.length) return;
    @try { [s writeToFile:S13_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
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

static NSString *SceneBundleID(id s) {
    if (!s) return nil;
    SEL cp = NSSelectorFromString(@"clientProcess");
    if ([s respondsToSelector:cp]) {
        id p = ((id (*)(id, SEL))objc_msgSend)(s, cp);
        SEL bi = NSSelectorFromString(@"bundleIdentifier");
        if (p && [p respondsToSelector:bi]) {
            id b = ((id (*)(id, SEL))objc_msgSend)(p, bi);
            if ([b isKindOfClass:[NSString class]] && [b length]) return b;
        }
    }
    SEL st = NSSelectorFromString(@"settings");
    if ([s respondsToSelector:st]) {
        id stv = ((id (*)(id, SEL))objc_msgSend)(s, st);
        SEL ai = NSSelectorFromString(@"applicationIdentifier");
        if (stv && [stv respondsToSelector:ai]) {
            id b = ((id (*)(id, SEL))objc_msgSend)(stv, ai);
            if ([b isKindOfClass:[NSString class]] && [b length]) return b;
        }
    }
    NSString *sid = SceneID(s);
    if (sid) {
        NSArray *comp = [sid componentsSeparatedByString:@":"];
        if (comp.count >= 3) {
            NSString *tail = comp.lastObject;
            if ([tail hasSuffix:@"-default"]) tail = [tail substringToIndex:tail.length - 8];
            if ([tail containsString:@"."]) return tail;
        }
    }
    return nil;
}

static id SceneForBundle(NSString *bid) {
    if (!bid.length) return nil;
    NSArray *all = AllScenes();
    for (id s in all) {
        NSString *b = SceneBundleID(s);
        if (b && [b isEqualToString:bid]) return s;
    }
    for (id s in all) {
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
        BOOL sys = [bid hasPrefix:@"com.apple."];
        [out addObject:@{@"bid": bid, @"name": (name.length ? name : bid), @"sys": @(sys)}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL sa = [a[@"sys"] boolValue], sb = [b[@"sys"] boolValue];
        if (sa != sb) return sa ? NSOrderedDescending : NSOrderedAscending;
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    A(@"读到 %lu 个应用", (unsigned long)out.count);
    return out;
}

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
        if (ok) { gAssertions[bid] = asrt; A(@"[%@] RBS 成功 pid=%d", bid, pid); }
        else { A(@"[%@] RBS 失败 pid=%d %@", bid, pid, err.localizedDescription ?: @"?"); }
    } @catch (NSException *e) { A(@"[%@] RBS 异常 %@", bid, e.reason); }
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

// 取「屏幕固定坐标系」下的触摸点。
// 关键：locationInView:nil 返回的是窗口自己的坐标系，
// 而浮窗本身在被拖动 —— 坐标系跟着动，位移会被抵消，
// 于是窗口在「跟随 → 复位」之间来回跳，表现就是抖动。
// 这里改为换算到 SpringBoard 那个不会移动的窗口，坐标就稳定了。
static CGPoint ScreenPoint(id sender) {
    UIGestureRecognizer *g = (UIGestureRecognizer *)sender;
    UIWindow *ref = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w || w.hidden) continue;
        if (w == gDotWin || w == gMenuWin) continue;
        BOOL ours = NO;
        for (NSDictionary *d in [gCache allValues]) {
            if (d[@"win"] == w) { ours = YES; break; }
        }
        if (ours) continue;
        ref = w;
        break;
    }
    if (ref) return [g locationInView:ref];
    return [g locationInView:nil];
}

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
    A(@"关闭浮窗 %@（剩 %lu）", ctx[@"bid"], (unsigned long)gWindows.count);
    FlushAsync();
}

static void CloseAll(void) {
    if (!gWindows.count) return;
    NSArray *snapshot = [gWindows copy];
    for (NSDictionary *d in snapshot) {
        UIWindow *w = d[@"win"];
        w.hidden = YES;
    }
    NSUInteger n = gWindows.count;
    [gWindows removeAllObjects];
    A(@"关闭全部浮窗（%lu 个）", (unsigned long)n);
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
    NSMutableString *dbg = [NSMutableString string];
    for (id layer in layers) {
        @try {
            UIView *hv = ((id (*)(id, SEL, id))objc_msgSend)(container,
                            @selector(_createHostViewForLayer:), layer);
            if (!hv) { [dbg appendFormat:@"[%@nil] ", NSStringFromClass([layer class])]; continue; }
            hv.frame = cv.bounds;
            hv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [cv addSubview:hv];
            made++;
        } @catch (NSException *e) { [dbg appendFormat:@"[EXC] "]; }
    }
    if (made == 0 && dbg.length) [r appendFormat:@" %@", dbg];
    [r appendFormat:@"hostViews=%d", made];
    return made > 0 ? cv : nil;
}

// 建占位浮窗（不含内容）
static NSMutableDictionary *CreateFloatingShell(NSString *bid) {
    CGRect sb = [UIScreen mainScreen].bounds;
    NSInteger n = (NSInteger)gWindows.count;
    CGFloat aspect = sb.size.height / sb.size.width;
    CGFloat h = sb.size.height * 0.58;
    CGFloat w = h / aspect;
    if (w > sb.size.width * 0.72) { w = sb.size.width * 0.72; h = w * aspect; }
    CGFloat x = sb.size.width - w - 12 - (CGFloat)(n % 3) * 24;
    CGFloat y = 90 + (CGFloat)(n % 3) * 32;
    if (x < 4) x = 4;

    UIWindow *win = NewWindow(CGRectMake(x, y, w, h), UIWindowLevelAlert + 800);
    UIView *root = win.rootViewController.view;
    root.frame = win.bounds;

    CGFloat shellPad = 6.0;
    UIView *panel = [[UIView alloc] initWithFrame:root.bounds];
    panel.backgroundColor = [UIColor colorWithWhite:0.86 alpha:0.98];
    panel.layer.cornerRadius = 26;
    panel.layer.borderWidth = 2.0;
    panel.layer.borderColor = [[UIColor colorWithWhite:0.72 alpha:1.0] CGColor];
    panel.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.layer.shadowOpacity = 0.28;
    panel.layer.shadowRadius = 14;
    panel.layer.shadowOffset = CGSizeMake(0, 6);
    panel.clipsToBounds = NO;
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:panel];

    UIView *screen = [[UIView alloc] initWithFrame:CGRectMake(shellPad, shellPad,
                                                             w - shellPad * 2, h - shellPad * 2)];
    screen.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    screen.layer.cornerRadius = 20;
    screen.clipsToBounds = YES;
    screen.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [panel addSubview:screen];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 30)];
    bar.backgroundColor = [UIColor clearColor];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [panel addSubview:bar];

    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake((w - 46) / 2.0, 11, 46, 5)];
    pill.backgroundColor = [UIColor colorWithWhite:0.35 alpha:0.55];
    pill.layer.cornerRadius = 2.5;
    pill.userInteractionEnabled = NO;
    pill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [bar addSubview:pill];

    NSMutableDictionary *ctx = [NSMutableDictionary dictionary];
    ctx[@"win"] = win;
    ctx[@"bid"] = bid ?: @"";
    ctx[@"panel"] = panel;
    ctx[@"screen"] = screen;
    ctx[@"bar"] = bar;
    ctx[@"pill"] = pill;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - shellPad - 30, shellPad + 8, 26, 26);
    close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    close.layer.cornerRadius = 13;
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    MWBlockTarget *closeT = MakeTarget(^(id sender) { CloseOne(ctx); });
    [close addTarget:closeT action:@selector(fire:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(close, "t", closeT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [panel addSubview:close];
    ctx[@"close"] = close;

    // 拖动：用「按下瞬间的窗口原点 + 屏幕坐标」重算，避免坐标反馈抖动
    __block CGRect dragStart = CGRectZero;
    __block CGPoint fingerStart = CGPointZero;
    MWBlockTarget *panT = MakeTarget(^(id sender) {
        UIPanGestureRecognizer *g = (UIPanGestureRecognizer *)sender;
        CGPoint finger = ScreenPoint(sender);
        if (g.state == UIGestureRecognizerStateBegan) {
            dragStart = win.frame;
            fingerStart = finger;
            return;
        }
        if (g.state != UIGestureRecognizerStateChanged) return;
        CGRect scr = [UIScreen mainScreen].bounds;
        CGFloat nx = dragStart.origin.x + (finger.x - fingerStart.x);
        CGFloat ny = dragStart.origin.y + (finger.y - fingerStart.y);
        nx = MAX(0, MIN(nx, scr.size.width - dragStart.size.width));
        ny = MAX(24, MIN(ny, scr.size.height - dragStart.size.height - 16));
        win.frame = CGRectMake(nx, ny, dragStart.size.width, dragStart.size.height);
    });
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] init];
    [pan addTarget:panT action:@selector(fire:)];
    [bar addGestureRecognizer:pan];
    objc_setAssociatedObject(bar, "t", panT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat hs = 30;
    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(w - hs - 4, h - hs - 4, hs, hs)];
    handle.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
    handle.layer.cornerRadius = hs / 2.0;
    handle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [panel addSubview:handle];
    ctx[@"handle"] = handle;

    UIImageView *hArrow = [[UIImageView alloc] initWithFrame:CGRectMake(9, 9, 12, 12)];
    hArrow.image = [UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"];
    hArrow.tintColor = [UIColor colorWithWhite:1 alpha:0.85];
    hArrow.userInteractionEnabled = NO;
    [handle addSubview:hArrow];

    __block CGRect rsStart = CGRectZero;
    __block CGPoint rsFinger = CGPointZero;
    MWBlockTarget *rpT = MakeTarget(^(id sender) {
        UIPanGestureRecognizer *g = (UIPanGestureRecognizer *)sender;
        CGPoint finger = ScreenPoint(sender);
        if (g.state == UIGestureRecognizerStateBegan) {
            rsStart = win.frame;
            rsFinger = finger;
            return;
        }
        if (g.state != UIGestureRecognizerStateChanged) return;
        CGRect scr = [UIScreen mainScreen].bounds;
        CGFloat scrAspect = scr.size.height / scr.size.width;
        CGFloat maxW = MIN(scr.size.width - rsStart.origin.x,
                           (scr.size.height - rsStart.origin.y - 24) / scrAspect);
        CGFloat nw = MAX(140, MIN(rsStart.size.width + (finger.x - rsFinger.x), maxW));
        CGFloat nh = nw * scrAspect;
        win.frame = CGRectMake(rsStart.origin.x, rsStart.origin.y, nw, nh);
        panel.frame = CGRectMake(0, 0, nw, nh);
        screen.frame = CGRectMake(6, 6, nw - 12, nh - 12);
        bar.frame = CGRectMake(0, 0, nw, 30);
        pill.frame = CGRectMake((nw - 46) / 2.0, 11, 46, 5);
        close.frame = CGRectMake(nw - 6 - 30, 14, 26, 26);
        handle.frame = CGRectMake(nw - hs - 4, nh - hs - 4, hs, hs);
        UIView *ct = ctx[@"content"];
        if (ct) FitContent(screen, ct);
    });
    UIPanGestureRecognizer *rp = [[UIPanGestureRecognizer alloc] init];
    [rp addTarget:rpT action:@selector(fire:)];
    [handle addGestureRecognizer:rp];
    objc_setAssociatedObject(handle, "t", rpT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 占位提示
    UILabel *ph = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w - 12, 40)];
    ph.text = @"正在启动...";
    ph.textAlignment = NSTextAlignmentCenter;
    ph.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    ph.font = [UIFont systemFontOfSize:12];
    ph.center = CGPointMake((w - 12) / 2.0, (h - 12) / 2.0);
    ph.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                          UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [screen addSubview:ph];
    ctx[@"placeholder"] = ph;

    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    sp.color = [UIColor colorWithWhite:0.75 alpha:1.0];
    sp.center = CGPointMake((w - 12) / 2.0, (h - 12) / 2.0 - 34);
    sp.autoresizingMask = ph.autoresizingMask;
    [sp startAnimating];
    [screen addSubview:sp];
    ctx[@"spinner"] = sp;

    win.hidden = NO;
    [gWindows addObject:ctx];
    if (!gCache) gCache = [NSMutableDictionary dictionary];
    gCache[bid] = ctx;
    A(@"占位浮窗 %@ (%.0fx%.0f)", bid, w, h);
    return ctx;
}

static void AttachContent(NSString *bid, UIView *content, id scene) {
    if (!gCache) return;
    NSMutableDictionary *ctx = gCache[bid];
    if (!ctx) return;
    UIView *screen = ctx[@"screen"];
    UILabel *ph = ctx[@"placeholder"];
    UIActivityIndicatorView *sp = ctx[@"spinner"];
    [ph removeFromSuperview];
    [sp stopAnimating];
    [sp removeFromSuperview];
    ctx[@"content"] = content;
    if (scene && scene != [NSNull null]) ctx[@"scene"] = scene;
    [screen addSubview:content];
    FitContent(screen, content);
    UIWindow *w = ctx[@"win"];
    w.hidden = NO;
    if (![gWindows containsObject:ctx]) [gWindows addObject:ctx];
    A(@"内容已填入 %@", bid);
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
    StopPoll();
    if (!gCache) gCache = [NSMutableDictionary dictionary];

    // 已开过：直接显示
    NSMutableDictionary *hits = gCache[bid];
    if (hits) {
        UIWindow *ww = hits[@"win"];
        ww.hidden = NO;
        if (![gWindows containsObject:hits]) [gWindows addObject:hits];
        id sc = SceneForBundle(bid);
        if (sc) ForceForeground(sc);
        if (PidOf(bid) > 0) AcquireAssertion(bid);
        HideMenu();
        A(@"秒开（复用缓存）%@", bid);
        FlushAsync();
        return;
    }

    @synchronized (LogLock()) {
        if (!gOut) gOut = [NSMutableString string];
        if (!gFile) gFile = [NSMutableString string];
        [gOut setString:@""];
        [gFile setString:@""];
    }
    gPollCount = 0;
    A(@"打开 %@", bid);
    Flush();

    // 立刻弹占位窗，消除「点了没反应」的等待感
    CreateFloatingShell(bid);
    HideMenu();

    gPoll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gPoll, dispatch_time(DISPATCH_TIME_NOW, 0),
                              150 * NSEC_PER_MSEC, 30 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gPoll, ^{
        gPollCount++;
        id scene = SceneForBundle(bid);
        NSArray *ls = scene ? LayerList(scene) : nil;
        int pid = PidOf(bid);
        if (pid > 0) AcquireAssertion(bid);
        if (scene) ForceForeground(scene);

        if (gPollCount % 20 == 1) {
            A(@"[%d] scene=%@ layers=%lu pid=%d", gPollCount, scene ? @"Y" : @"N",
              (unsigned long)ls.count, pid);
        }

        if (scene && ls.count > 0) {
            StopPoll();
            NSMutableString *r = [NSMutableString string];
            UIView *cv = BuildContainer(scene, r);
            A(@"build: %@ -> %@", r, cv ? @"OK" : @"FAIL");
            if (cv) AttachContent(bid, cv, scene);
            Flush();
            return;
        }

        if (gPollCount >= 200) {
            StopPoll();
            A(@"超时 30s：%@", scene ? @"scene 在但无图层（App 未渲染）" : @"找不到该 App 的 scene");
            if (!scene) {
                NSMutableString *ids = [NSMutableString string];
                for (id s in AllScenes()) {
                    NSString *b = SceneBundleID(s);
                    if (b) [ids appendFormat:@"%@ ", b];
                }
                A(@"当前场景 App: %@", ids.length ? ids : @"(无)");
            }
            NSMutableDictionary *c2 = gCache[bid];
            if (c2) {
                UILabel *ph = c2[@"placeholder"];
                ph.text = @"启动失败";
                UIActivityIndicatorView *sp2 = c2[@"spinner"];
                [sp2 stopAnimating];
                [sp2 removeFromSuperview];
            }
            Flush();
        }
    });
    dispatch_resume(gPoll);

    dispatch_async(dispatch_get_main_queue(), ^{ LaunchApp(bid); });
}

// 后台任务切换器是否可见
static BOOL SwitcherVisible(void) {
    for (NSString *cn in @[@"SBMainSwitcherControllerCoordinator", @"SBMainSwitcherViewController"]) {
        Class c = NSClassFromString(cn);
        if (!c) continue;
        id inst = nil;
        for (NSString *sn in @[@"sharedInstance", @"sharedInstanceIfExists", @"sharedController"]) {
            SEL s = NSSelectorFromString(sn);
            if ([c respondsToSelector:s]) {
                @try { inst = ((id (*)(id, SEL))objc_msgSend)((id)c, s); } @catch (NSException *e) {}
                if (inst) break;
            }
        }
        if (!inst) continue;
        for (NSString *sn in @[@"isAppSwitcherVisible", @"_isAppSwitcherVisible",
                               @"isSwitcherVisible", @"isPresentingAppSwitcher"]) {
            SEL s = NSSelectorFromString(sn);
            if ([inst respondsToSelector:s]) {
                @try {
                    BOOL v = ((BOOL (*)(id, SEL))objc_msgSend)(inst, s);
                    if (v) return YES;
                } @catch (NSException *e) {}
            }
        }
    }
    return NO;
}

static void StartKeepAlive(void) {
    if (gKeep) return;
    gKeep = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gKeep, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gKeep, ^{
        // 打开后台任务切换器 -> 关掉所有浮窗
        static BOOL wasVisible = NO;
        BOOL vis = SwitcherVisible();
        if (vis && !wasVisible && gWindows.count) {
            A(@"检测到后台任务切换器，关闭浮窗");
            CloseAll();
        }
        wasVisible = vis;

        if (!gWindows.count) return;
        for (NSDictionary *d in [gWindows copy]) {
            NSString *bid = d[@"bid"];
            int pid = PidOf(bid);
            if (pid > 0 && !gAssertions[bid]) AcquireAssertion(bid);
        }
    });
    dispatch_resume(gKeep);
}

@interface MWMenu : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *apps;
@property (nonatomic, strong) UILabel *hint;
@end

@implementation MWMenu

- (void)viewDidLoad {
    [super viewDidLoad];
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat w = MIN(320.0, sb.size.width - 10 - 76);
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

    __weak typeof(self) weakSelf = self;
    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.frame = CGRectMake(w - 92, 6, 40, 28);
    [refresh setTitle:@"刷新" forState:UIControlStateNormal];
    refresh.titleLabel.font = [UIFont systemFontOfSize:12];
    MWBlockTarget *rt = MakeTarget(^(id s) {
        __strong typeof(weakSelf) ss = weakSelf;
        [ss reloadApps];
    });
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
    self.hint.text = @"正在读取应用列表...";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *list = InstalledApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2) return;
            s2.apps = list ?: @[];
            [s2.table reloadData];
            s2.hint.text = [NSString stringWithFormat:@"共 %lu 个应用 · 点名字开浮窗",
                               (unsigned long)s2.apps.count];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"mwapp";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
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
    BOOL sys = [d[@"sys"] boolValue];
    cell.textLabel.text = sys ? [NSString stringWithFormat:@"%@（系统）", d[@"name"]] : d[@"name"];
    cell.detailTextLabel.text = d[@"bid"];
    cell.textLabel.textColor = sys ? [UIColor colorWithWhite:0.65 alpha:1.0] : UIColor.whiteColor;
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
    if (gMenuWin) {
        gMenuWin.hidden = NO;
        UIViewController *vc = gMenuWin.rootViewController;
        if (vc && [vc respondsToSelector:@selector(reloadApps)]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(vc, @selector(reloadApps)); }
            @catch (NSException *e) {}
        }
        return;
    }
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat w = MIN(320.0, sb.size.width - 10 - 76);
    CGFloat h = MIN(480.0, sb.size.height - 120);
    UIWindow *win = NewWindow(CGRectMake(10, MAX(70.0, (sb.size.height - h) / 2.0 - 30), w, h),
                              UIWindowLevelAlert + 880);
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

    __block CGRect dragStart = CGRectZero;
    __block CGPoint fingerStart = CGPointZero;
    MWBlockTarget *panT = MakeTarget(^(id sender) {
        UIPanGestureRecognizer *g = (UIPanGestureRecognizer *)sender;
        CGPoint finger = ScreenPoint(sender);
        if (g.state == UIGestureRecognizerStateBegan) {
            dragStart = w.frame;
            fingerStart = finger;
            return;
        }
        if (g.state != UIGestureRecognizerStateChanged) return;
        CGRect scr = [UIScreen mainScreen].bounds;
        CGFloat nx = dragStart.origin.x + (finger.x - fingerStart.x);
        CGFloat ny = dragStart.origin.y + (finger.y - fingerStart.y);
        nx = MAX(0, MIN(nx, scr.size.width - side));
        ny = MAX(24, MIN(ny, scr.size.height - side - 16));
        w.frame = CGRectMake(nx, ny, side, side);
    });
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] init];
    [pan addTarget:panT action:@selector(fire:)];
    [dot addGestureRecognizer:pan];
    objc_setAssociatedObject(dot, "pan", panT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    w.hidden = NO;
    gDotWin = w;
    A(@"圆点已就位");
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
    });
    %init;
}
