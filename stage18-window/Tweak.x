#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MW16 Stage 13
//  1. 拖动抖动：用「手势起始时的窗口原点 + 屏幕坐标」重算，避免坐标反馈
//  2. 秒出窗口：先弹占位窗，图层到了再填内容
//  3. 打开后台任务切换器时自动关闭所有浮窗
//  4. 场景识别增强 + 失败原因分类

#define S13_LOG @"/var/mobile/Media/mw16_stage18.log"

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


// ===== 手柄专用手势识别器 =====
//
// 为什么不用 UIPan + UILongPress 组合：
//   UIKit 默认「一个手势识别成功后，其它识别器会被取消」。
//   UILongPress 一触发，正在跟踪的 UIPan 立刻收到 Cancelled，
//   于是手指还在屏幕上，拖动却已经失效 —— 只能抬手再按一次。
//   这正是「长按震完还得重新拖」的原因。
//
// 改成单个识别器，自己计时：
//   按下 → 若 0.4s 内位移 < 6pt → 进入缩放模式（震一次），继续拖就是缩放
//   按下 → 若 0.4s 内位移 > 6pt → 进入移动模式，继续拖就是移动
//   快速抬起且没动 → 自身失败，让双击识别器接手（关闭浮窗）
@interface MWHandleGesture : UIGestureRecognizer
@property (nonatomic, assign) BOOL scalingMode;
@property (nonatomic, copy) void (^onBegan)(BOOL scaling, CGPoint finger);
@property (nonatomic, copy) void (^onMove)(CGPoint finger);
@end

@implementation MWHandleGesture {
    CGPoint _startFinger;
    BOOL _decided;
}

// 取固定参照系下的手指坐标（不能用窗口自身坐标系，窗口在动）
- (CGPoint)refPoint {
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
    return [self locationInView:ref ?: self.view];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    _startFinger = [self refPoint];
    _decided = NO;
    self.scalingMode = NO;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MWHandleGesture *s = weakSelf;
        if (!s) return;
        // 还停在「按下未决」且没变成移动 → 判定为长按缩放
        if (s.state != UIGestureRecognizerStatePossible) return;
        if (s->_decided) return;

        s->_decided = YES;
        s.scalingMode = YES;

        UIImpactFeedbackGenerator *haptic =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [haptic prepare];
        [haptic impactOccurred];

        if (s.onBegan) s.onBegan(YES, [s refPoint]);
        s.state = UIGestureRecognizerStateBegan;
        s.state = UIGestureRecognizerStateChanged;
    });
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    CGPoint p = [self refPoint];

    if (!_decided) {
        CGFloat dx = p.x - _startFinger.x;
        CGFloat dy = p.y - _startFinger.y;
        if (sqrt(dx * dx + dy * dy) > 6.0) {
            _decided = YES;
            self.scalingMode = NO;
            if (self.onBegan) self.onBegan(NO, p);
            self.state = UIGestureRecognizerStateBegan;
            self.state = UIGestureRecognizerStateChanged;
        }
    }

    if (self.state == UIGestureRecognizerStateChanged && self.onMove) {
        self.onMove(p);
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateEnded;
    } else {
        // 没动就抬手 → 主动失败，让双击识别器判定关闭
        self.state = UIGestureRecognizerStateFailed;
    }
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateCancelled;
    } else {
        self.state = UIGestureRecognizerStateFailed;
    }
    [super touchesCancelled:touches withEvent:event];
}

- (void)reset {
    [super reset];
    _decided = NO;
    self.scalingMode = NO;
}

@end

static void FitContent(UIView *host, UIView *content) {
    if (!host || !content) return;
    CGFloat bw = host.bounds.size.width;
    CGFloat bh = host.bounds.size.height;
    if (bw < 1 || bh < 1) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    if (sb.size.width < 1 || sb.size.height < 1) return;
    // 填充式缩放：比例不一致就裁掉，绝不留黑边（黑边是之前最碍眼的问题）。
    CGFloat k = MAX(bw / sb.size.width, bh / sb.size.height);

    content.transform = CGAffineTransformIdentity;
    content.bounds = CGRectMake(0, 0, sb.size.width, sb.size.height);

    CGFloat sh = sb.size.height * k;
    CGFloat cy = bh / 2.0;
    // 内容比窗口高时底部对齐 —— App 的底部标签栏比顶部状态条重要
    if (sh > bh) cy = bh - sh / 2.0;
    content.center = CGPointMake(bw / 2.0, cy);
    content.transform = CGAffineTransformMakeScale(k, k);
}

// 彻底销毁浮窗：从窗口层级移除，并清掉缓存。
// 只 hidden 是不够的 —— 进后台切换器时窗口留在层级里，
// 就会留下一块黑屏，看起来"没关掉"。
static void DestroyOne(NSDictionary *ctx) {
    if (!ctx) return;
    UIWindow *w = ctx[@"win"];
    NSString *bid = ctx[@"bid"];
    @try {
        w.hidden = YES;
        w.rootViewController = nil;
        w.windowLevel = UIWindowLevelNormal - 1;
    } @catch (NSException *e) {}
    [gWindows removeObject:ctx];
    if (bid.length && gCache[bid] == ctx) [gCache removeObjectForKey:bid];
    ReleaseAssertion(bid);
}

static void CloseOne(NSDictionary *ctx) {
    if (!ctx) return;
    NSString *bid = ctx[@"bid"];
    DestroyOne(ctx);
    A(@"关闭浮窗 %@（剩 %lu）", bid, (unsigned long)gWindows.count);
    FlushAsync();
}

static void CloseAll(void) {
    if (!gWindows.count) return;
    NSArray *snapshot = [gWindows copy];
    [gWindows removeAllObjects];
    for (NSDictionary *d in snapshot) {
        UIWindow *w = d[@"win"];
        NSString *bid = d[@"bid"];
        @try {
            w.hidden = YES;
            w.rootViewController = nil;
        } @catch (NSException *e) {}
        if (bid.length && gCache[bid] == d) [gCache removeObjectForKey:bid];
        ReleaseAssertion(bid);
    }
    A(@"销毁全部浮窗（%lu 个）", (unsigned long)snapshot.count);
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

// 手柄视图：只让「弧线本身」接收触摸。
//
// 为什么需要它：
//   用户实测反馈「触发点在白色弧和浮窗右下角之间的空白处」。
//   原因是手柄视图是一个 76×76 的正方形，弧只是里面的四条边之一段，
//   正方形里绝大部分是空白，而 UIView 默认整块都能接收触摸。
//   → 重写 pointInside，把触摸限制在弧线周围 ±18pt 的环带里。
@interface MWHandleHitView : UIView
@property (nonatomic, assign) CGPoint arcCenterInView;
@property (nonatomic, assign) CGFloat arcRadius;
@end

@implementation MWHandleHitView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat dx = point.x - _arcCenterInView.x;
    CGFloat dy = point.y - _arcCenterInView.y;
    CGFloat d = sqrt(dx * dx + dy * dy);

    // 1) 必须在第一象限（正右 → 正下），也就是弧所在的那 90°
    if (dx < 0 || dy < 0) return NO;

    // 2) 离弧线中心不能超过 16pt（弧线本身 4pt，加一点手指容差）
    if (fabs(d - _arcRadius) > 16.0) return NO;

    return YES;
}
@end

// 建占位浮窗（不含内容）
static NSMutableDictionary *CreateFloatingShell(NSString *bid) {
    CGRect sb = [UIScreen mainScreen].bounds;
    NSInteger n = (NSInteger)gWindows.count;

    // 内容尺寸（真正显示 App 画面的那块）
    //
    // 上一版用的是屏幕原始比例 2.165（844/390），窗口 273×591 ——
    // 那就是把整块手机屏幕缩小 70%，看起来像一根竖长条，不是"小窗"。
    // 现在把宽高比压到 1.80 并把宽度放到屏宽的 76%：
    //   296 × 533，横向更饱满，纵向不再顶满屏幕。
    //
    // 代价：比例变了就必须裁掉 App 画面的一部分（FitContent 用的是填充式缩放，
    // 不会有黑边，但会裁切）。裁切统一从顶部裁、底部对齐 ——
    // App 的底部标签栏比顶部状态栏有用。
    const CGFloat kAspect = 1.80;
    CGFloat cw = sb.size.width * 0.76;
    CGFloat ch = cw * kAspect;
    if (ch > sb.size.height * 0.70) { ch = sb.size.height * 0.70; cw = ch / kAspect; }

    // 窗口比内容多留一圈，给弧线手柄腾地方（否则会被裁掉）
    // 弧只凸出内容右下角 4pt + 半个线宽，窗口不需要再留 30pt 的空隙
    CGFloat gap = 10.0;
    CGFloat w = cw + gap;
    CGFloat h = ch + gap;

    CGFloat x = sb.size.width - w - 8 - (CGFloat)(n % 3) * 24;
    CGFloat y = 90 + (CGFloat)(n % 3) * 32;
    if (x < 4) x = 4;

    UIWindow *win = NewWindow(CGRectMake(x, y, w, h), UIWindowLevelAlert + 800);
    UIView *root = win.rootViewController.view;
    root.frame = win.bounds;

    // panel 覆盖整个窗口，且不裁切 —— 弧线要画到内容外面去
    UIView *panel = [[UIView alloc] initWithFrame:root.bounds];
    panel.backgroundColor = [UIColor clearColor];
    panel.clipsToBounds = NO;
    panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root addSubview:panel];

    // 内容区：只占左上角 cw × ch
    UIView *screen = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, ch)];
    screen.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    screen.layer.cornerRadius = 22;
    screen.clipsToBounds = YES;
    [panel addSubview:screen];

    // 顶部拖拽区（透明）
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, 30)];
    bar.backgroundColor = [UIColor clearColor];
    [panel addSubview:bar];

    NSMutableDictionary *ctx = [NSMutableDictionary dictionary];
    ctx[@"win"] = win;
    ctx[@"bid"] = bid ?: @"";
    ctx[@"panel"] = panel;
    ctx[@"screen"] = screen;
    ctx[@"bar"] = bar;
    ctx[@"cw"] = @(cw);
    ctx[@"ch"] = @(ch);
    ctx[@"gap"] = @(gap);

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

    // ===== 右下角弧形手柄 =====
    //
    // 三种手势：
    //   双击        → 关闭浮窗
    //   拖动        → 移动浮窗
    //   长按后拖动  → 缩放浮窗（保持手机比例），长按时震动一次
    //
    // 内容圆角是 22。把弧的圆心放在「圆角的圆心」上，
    // 半径比 22 大 4pt，于是弧线就是一条紧贴着圆角、始终等距 4pt 的装饰线。
    //   0° 端点 = (cw+4, ch-22)   90° 端点 = (cw-22, ch+4)
    //   45° 中点 = (cw-3.6, ch-3.6)
    // 整条弧都咬着拐角走，不再悬在窗口外面。
    const CGFloat cornerR = 22;
    const CGFloat arcR = 26;
    const CGFloat pad = 6;
    const CGFloat hs = 2 * (arcR + pad);           // 手柄视图边长（正方形，与弧同中心）
    CGPoint arcC = CGPointMake(cw - cornerR, ch - cornerR);   // panel 坐标系
    CGRect hRect = CGRectMake(arcC.x - hs / 2.0, arcC.y - hs / 2.0, hs, hs);

    MWHandleHitView *handle = [[MWHandleHitView alloc] initWithFrame:hRect];
    handle.arcCenterInView = CGPointMake(hs / 2.0, hs / 2.0);
    handle.arcRadius = arcR;
    handle.backgroundColor = [UIColor clearColor];
    handle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [panel addSubview:handle];       // 加在 screen 之后 → 位于内容之上
    ctx[@"handle"] = handle;

    // 画弧：圆心在「内容右下圆角的圆心」，半径 26 > 圆角 22，
    // 于是这条弧始终贴着圆角外侧 4pt，从正右扫到正下。
    CGPoint cc = CGPointMake(hs / 2.0, hs / 2.0);   // 手柄视图内的中心

    @try {
        // iPadOS 台前调度那种手柄：
        //   一条等宽的 90° 圆弧，从「正右」扫到「正下」，
        //   两端圆头，白色 + 深色描边衬托，紧紧包住内容的右下圆角。
        UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:cc
                                                            radius:arcR
                                                        startAngle:0
                                                          endAngle:M_PI_2
                                                         clockwise:YES];

        // 先画一层略粗的暗色底，保证在浅色画面上也看得清
        CAShapeLayer *halo = [CAShapeLayer layer];
        halo.path = ring.CGPath;
        halo.fillColor = [UIColor clearColor].CGColor;
        halo.strokeColor = [UIColor colorWithWhite:0.0 alpha:0.40].CGColor;
        halo.lineWidth = 5.5;
        halo.lineCap = kCALineCapRound;
        [handle.layer addSublayer:halo];

        // 主弧：等宽白线
        CAShapeLayer *ringLayer = [CAShapeLayer layer];
        ringLayer.path = ring.CGPath;
        ringLayer.fillColor = [UIColor clearColor].CGColor;
        ringLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.98].CGColor;
        ringLayer.lineWidth = 4.0;
        ringLayer.lineCap = kCALineCapRound;
        [handle.layer addSublayer:ringLayer];
        ringLayer.name = @"ring";
        ctx[@"ring"] = ringLayer;
        ctx[@"halo"] = halo;
    } @catch (NSException *e) {
        // 兜底：绘图失败时至少给一个可见白点
        handle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.55];
        handle.layer.cornerRadius = hs / 2.0;
    }

    // 单个识别器同时承担「移动 / 长按缩放」，不会互相抢触摸
    __block CGRect gStart = CGRectZero;
    __block CGPoint gFinger = CGPointZero;
    __block BOOL gScaling = NO;

    MWHandleGesture *hg = [[MWHandleGesture alloc] init];
    hg.onBegan = ^(BOOL scaling, CGPoint finger) {
        gStart = win.frame;
        gFinger = finger;
        gScaling = scaling;
        A(scaling ? @"缩放模式（长按已触发）" : @"移动模式");
    };
    hg.onMove = ^(CGPoint finger) {
        CGRect scr = [UIScreen mainScreen].bounds;

        if (!gScaling) {
            CGFloat nx = gStart.origin.x + (finger.x - gFinger.x);
            CGFloat ny = gStart.origin.y + (finger.y - gFinger.y);
            nx = MAX(-4, MIN(nx, scr.size.width - gStart.size.width));
            ny = MAX(4, MIN(ny, scr.size.height - gStart.size.height + 4));
            win.frame = CGRectMake(nx, ny, gStart.size.width, gStart.size.height);
            return;
        }

        // 缩放同样保持 2.0 的宽高比，和初始形状一致
        CGFloat maxW = MIN(scr.size.width - gStart.origin.x - 8,
                           (scr.size.height - gStart.origin.y - 60) / kAspect);
        CGFloat minW = 180;
        CGFloat nw = MAX(minW, MIN(gStart.size.width + (finger.x - gFinger.x), maxW));
        CGFloat nh = nw * kAspect;
        CGFloat nCw = MAX(100, nw - gap);
        CGFloat nCh = MAX(100, nh - gap);

        win.frame = CGRectMake(gStart.origin.x, gStart.origin.y, nw, nh);
        panel.frame = CGRectMake(0, 0, nw, nh);
        screen.frame = CGRectMake(0, 0, nCw, nCh);
        bar.frame = CGRectMake(0, 0, nCw, 30);
        handle.frame = CGRectMake(nCw - cornerR - hs / 2.0,
                                  nCh - cornerR - hs / 2.0, hs, hs);
        ctx[@"cw"] = @(nCw);
        ctx[@"ch"] = @(nCh);
        UIView *ct = ctx[@"content"];
        if (ct) FitContent(screen, ct);
    };
    [handle addGestureRecognizer:hg];
    objc_setAssociatedObject(handle, "hg", hg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 双击：关闭浮窗。它排在自定义手势之后，靠"没动就失败"让位。
    MWBlockTarget *doubleT = MakeTarget(^(id sender) { CloseOne(ctx); });
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] init];
    doubleTap.numberOfTapsRequired = 2;
    [doubleTap addTarget:doubleT action:@selector(fire:)];
    [handle addGestureRecognizer:doubleTap];
    objc_setAssociatedObject(handle, "dbl", doubleT, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [doubleTap requireGestureRecognizerToFail:hg];

    // 占位提示
    UILabel *ph = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w - 12, 40)];
    ph.text = @"正在启动...";
    ph.textAlignment = NSTextAlignmentCenter;
    ph.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    ph.font = [UIFont systemFontOfSize:12];
    ph.center = CGPointMake(cw / 2.0, ch / 2.0);   // 居中在内容区，不是整窗
    ph.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                          UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [screen addSubview:ph];
    ctx[@"placeholder"] = ph;

    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    sp.color = [UIColor colorWithWhite:0.75 alpha:1.0];
    sp.center = CGPointMake(cw / 2.0, ch / 2.0 - 34);
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
// 判断「后台任务切换器是否打开」。
//
// 上一版查 SBMainSwitcherControllerCoordinator 的各种 isXxxVisible 方法，
// 实测全部返回 NO（日志里一条相关记录都没有），那条路不通。
//
// 换成查 SpringBoard 的主窗口结构：切换器打开时，
// 图标列表（SBIconController 的 contentView）会被移出层级或隐藏。
// 这是"看得见的结果"，比查私有布尔值可靠。
static BOOL SwitcherVisible(void) {
    // 主屏图标视图
    Class iconC = NSClassFromString(@"SBIconController");
    if (!iconC) return NO;
    id shared = nil;
    SEL si = NSSelectorFromString(@"sharedInstance");
    if ([iconC respondsToSelector:si]) {
        @try { shared = ((id (*)(id, SEL))objc_msgSend)((id)iconC, si); } @catch (NSException *e) {}
    }
    if (!shared) return NO;

    UIView *iconView = nil;
    for (NSString *sn in @[@"contentView", @"iconsView", @"iconView"]) {
        SEL s = NSSelectorFromString(sn);
        if (![shared respondsToSelector:s]) continue;
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(shared, s);
            if ([v isKindOfClass:[UIView class]]) { iconView = (UIView *)v; break; }
        } @catch (NSException *e) {}
    }
    if (!iconView) return NO;

    // 图标视图在屏幕上的可见面积
    UIWindow *win = iconView.window;
    if (!win) return YES;              // 已经不在任何窗口上 → 被切换器顶掉了
    if (win.hidden || win.alpha < 0.01) return YES;

    CGRect f = [iconView convertRect:iconView.bounds toView:nil];
    CGRect sb = [UIScreen mainScreen].bounds;
    CGRect inter = CGRectIntersection(f, sb);
    if (CGRectIsNull(inter) || CGRectIsEmpty(inter)) return YES;

    CGFloat ratio = (inter.size.width * inter.size.height) /
                    MAX(1.0, sb.size.width * sb.size.height);
    // 正常桌面时图标铺满约 60%+，切换器打开后会明显缩小
    return ratio < 0.18;
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
