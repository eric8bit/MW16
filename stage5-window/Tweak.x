#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MW16 Stage 5
//
// Stage 4 已能完整显示 App 画面。这一版解决两件事：
//   1) 保活：把 App 的 scene 钉在前台，切到桌面后画面不黑
//   2) 触摸：在画面上叠一层透明视图，记录点按是否到达
//      （远程图层能否直接收触摸，需要实测才知道）

#define S5_LOG @"/var/mobile/Media/mw16_stage5.log"

static NSMutableString *gOut = nil;
static UITextView *gTrace = nil;
static UIWindow *gPanelWin = nil;
static dispatch_source_t gPoll = nil;
static int gPollCount = 0;

// 所有打开的窗口：{ window, content, scene, bundleID }
static NSMutableArray *gWindows = nil;

static void A(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gOut) gOut = [NSMutableString string];
    [gOut appendFormat:@"%@\n", s];
    NSLog(@"[MW16-S5] %@", s);
    dispatch_async(dispatch_get_main_queue(), ^{ if (gTrace) gTrace.text = gOut; });
}

static void Flush(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [gOut writeToFile:S5_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
        @catch (NSException *e) {}
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

// ---------- 保活：强制 scene 前台 ----------

// 当前所有受管 bundleID
static BOOL IsManaged(NSString *ident) {
    if (!ident.length || !gWindows.count) return NO;
    for (NSDictionary *d in gWindows) {
        NSString *bid = d[@"bid"];
        if (bid.length && [ident containsString:bid]) return YES;
    }
    return NO;
}

static void ForceForeground(id scene, BOOL fg) {
    if (!scene) return;
    @try {
        if (![scene respondsToSelector:@selector(settings)]) return;
        id st = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(settings));
        if (!st || ![st respondsToSelector:@selector(mutableCopy)]) return;
        id ms = ((id (*)(id, SEL))objc_msgSend)(st, @selector(mutableCopy));
        if (!ms) return;
        if ([ms respondsToSelector:@selector(setForeground:)])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(ms, @selector(setForeground:), fg);
        if ([ms respondsToSelector:@selector(setDeactivationReasons:)])
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(ms,
                @selector(setDeactivationReasons:), fg ? 0ULL : 2ULL);
        if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:)]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene,
                @selector(updateSettings:withTransitionContext:), ms, nil);
        }
    } @catch (NSException *e) {}
}

// ---------- 窗口 ----------

static void CloseFloating(NSDictionary *d) {
    if (!d) return;
    NSInteger idx = (NSInteger)[gWindows indexOfObject:d];
    if (idx != NSNotFound) [gWindows removeObjectAtIndex:(NSUInteger)idx];
    UIWindow *w = d[@"win"];
    w.hidden = YES;
}

@interface S5CloseBar : UIButton
@property (nonatomic, strong) NSDictionary *ctx;
@end
@implementation S5CloseBar
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor systemRedColor];
        self.layer.cornerRadius = CGRectGetHeight(f) / 2.0;
        [self addTarget:self action:@selector(hideSelf) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)hideSelf { CloseFloating(self.ctx); }
@end

static void Refit(UIView *win, UIView *content) {
    if (!win || !content) return;
    CGRect area = CGRectMake(0, 26, win.bounds.size.width, win.bounds.size.height - 26);
    if (area.size.width < 1 || area.size.height < 1) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    if (sb.size.width < 1 || sb.size.height < 1) return;
    CGFloat s = MIN(area.size.width / sb.size.width, area.size.height / sb.size.height);
    content.transform = CGAffineTransformIdentity;
    content.bounds = CGRectMake(0, 0, sb.size.width, sb.size.height);
    content.center = CGPointMake(CGRectGetMidX(area), CGRectGetMidY(area));
    content.transform = CGAffineTransformMakeScale(s, s);
    content.autoresizingMask = UIViewAutoresizingNone;
}

@interface S5Drag : NSObject
@property (nonatomic, weak) UIView *win;
@property (nonatomic, weak) UIView *content;
@property (nonatomic) CGPoint grab;
@end
@implementation S5Drag
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *win = self.win;
    if (!win || !win.superview) return;
    CGPoint p = [g locationInView:win.superview];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.grab = CGPointMake(p.x - win.center.x, p.y - win.center.y);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        win.center = CGPointMake(p.x - self.grab.x, p.y - self.grab.y);
    }
}
@end

static void ShowFloating(UIView *content, id scene, NSString *bid) {
    UIWindow *host = MakeWindow(UIWindowLevelAlert + 800, [UIColor clearColor]);
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    host.rootViewController = vc;

    CGRect sb = [UIScreen mainScreen].bounds;
    NSInteger n = (NSInteger)gWindows.count;
    CGFloat w = sb.size.width * 0.6;
    CGFloat h = w * 1.7;
    if (h > sb.size.height * 0.66) h = sb.size.height * 0.66;
    CGFloat ox = 14 + (CGFloat)(n % 3) * 26;
    CGFloat oy = 90 + (CGFloat)(n % 3) * 34;

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

    S5CloseBar *cb = [[S5CloseBar alloc] initWithFrame:CGRectMake(8, 6, 52, 14)];
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

    S5Drag *drag = [S5Drag new];
    drag.win = win;
    drag.content = content;
    [bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:drag action:@selector(pan:)]];
    objc_setAssociatedObject(win, "s5drag", drag, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    host.hidden = NO;
    [gWindows addObject:ctx];
    A(@"窗口 %ld 已开：%@ %.0fx%.0f", (long)gWindows.count, bid, w, h);
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
    if (app && [app respondsToSelector:sel]) {
        @try { ((void (*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, bid, YES); }
        @catch (NSException *e) {}
    }
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

    gPoll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gPoll, dispatch_time(DISPATCH_TIME_NOW, 0), 400 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gPoll, ^{
        gPollCount++;
        id scene = SceneForBundle(bid);
        NSArray *ls = scene ? LayerList(scene) : nil;

        if (gPollCount % 5 == 1) {
            A(@"[%d] scene=%@ layers=%lu", gPollCount, scene ? @"Y" : @"N", (unsigned long)ls.count);
        }

        if (scene && ls.count > 0) {
            StopPoll();
            NSMutableString *r = [NSMutableString string];
            UIView *cv = BuildContainer(scene, r);
            A(@"build: %@ -> %@", r, cv ? @"OK" : @"FAIL");
            if (cv) {
                ShowFloating(cv, scene, bid);
                if (gPanelWin) gPanelWin.hidden = YES;
            }
            Flush();
            return;
        }

        if (gPollCount >= 60) {
            StopPoll();
            A(@"超时：24 秒没拿到图层");
            Flush();
        }
    });
    dispatch_resume(gPoll);
}

// ---------- 保活定时器 ----------

static void StartKeepAlive(void) {
    static dispatch_source_t t = nil;
    if (t) return;
    t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        if (!gWindows.count) return;
        for (NSDictionary *d in [gWindows copy]) {
            id sc = d[@"scene"];
            if (sc && sc != [NSNull null]) ForceForeground(sc, YES);
        }
    });
    dispatch_resume(t);
}

// ---------- 面板 ----------

@interface S5Panel : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITextView *trace;
@end

@implementation S5Panel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    CGRect sb = [UIScreen mainScreen].bounds;

    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(12, 46, sb.size.width - 90, 28)];
    h.text = @"MW16 Stage 5";
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

    self.trace = [[UITextView alloc] initWithFrame:CGRectMake(0, 124, sb.size.width, sb.size.height - 142)];
    self.trace.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.trace.textColor = [UIColor colorWithRed:0.45 green:1.0 blue:0.55 alpha:1.0];
    self.trace.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.trace.editable = NO;
    [self.view addSubview:self.trace];
    gTrace = self.trace;

    if (!gOut) gOut = [NSMutableString string];
    A(@"开窗后：切到桌面看画面是否还在（保活）；点画面看是否记录触摸。");
}

- (void)hidePanel { if (gPanelWin) { gPanelWin.hidden = YES; gPanelWin = nil; } }

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
    UIWindow *w = MakeWindow(UIWindowLevelAlert + 900, [UIColor colorWithWhite:0 alpha:0.92]);
    S5Panel *p = [S5Panel new];
    w.rootViewController = p;
    w.hidden = NO;
    gPanelWin = w;
}

// 全局：把 scene 的失活原因清掉（仅限受管 App）
%hook UIMutableApplicationSceneSettings
- (void)setDeactivationReasons:(unsigned long long)reasons {
    if (reasons != 0 && gWindows.count) {
        NSString *ident = nil;
        Ivar iv = class_getInstanceVariable(object_getClass(self), "_sceneIdentifier");
        if (iv) ident = (__bridge id)(*(void **)((__bridge void *)self + ivar_getOffset(iv)));
        if (!ident) {
            iv = class_getInstanceVariable(object_getClass(self), "_identifier");
            if (iv) ident = (__bridge id)(*(void **)((__bridge void *)self + ivar_getOffset(iv)));
        }
        if (ident && IsManaged(ident)) { %orig(0); return; }
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
        StartKeepAlive();
        ShowPanel();
    });
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gWindows) gWindows = [NSMutableArray array];
        if (!gPanelWin) ShowPanel();
    });
    %init;
}
