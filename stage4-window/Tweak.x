#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MW16 Stage 4 —— 真正把 App 画面放进浮窗
//
// Stage 3 探测确认的事实：
//   [scene layerManager]        -> FBSceneLayerManager   （存在）
//   [layerManager layers]       -> __NSFrozenOrderedSetM （有序集合，不是 NSArray！）
//
// 之前一直 layers=-1，就是因为代码里判断 `isKindOfClass:[NSArray class]`，
// 而它是 NSOrderedSet 的子类，检查不通过。API 本身一直是对的。

#define S4_LOG @"/var/mobile/Media/mw16_stage4.log"

static NSMutableString *gOut = nil;
static UITextView *gTrace = nil;
static UIWindow *gPanelWin = nil;
static UIWindow *gFloatWin = nil;
static dispatch_source_t gPoll = nil;
static int gPollCount = 0;

static void A(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gOut) gOut = [NSMutableString string];
    [gOut appendFormat:@"%@\n", s];
    NSLog(@"[MW16-S4] %@", s);
    dispatch_async(dispatch_get_main_queue(), ^{ if (gTrace) gTrace.text = gOut; });
}

static void Flush(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [gOut writeToFile:S4_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
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

// 关键修正：layers 返回的是 NSOrderedSet（或 NSArray），两者都能 for-in
static NSArray *LayerList(id scene) {
    if (!scene || ![scene respondsToSelector:@selector(layerManager)]) return nil;
    id lm = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(layerManager));
    if (!lm || ![lm respondsToSelector:@selector(layers)]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(lm, @selector(layers));
    if (!v) return nil;
    if ([v isKindOfClass:[NSArray class]]) return v;
    if ([v isKindOfClass:[NSSet class]]) return [(NSSet *)v allObjects];
    if ([v isKindOfClass:[NSOrderedSet class]]) return [(NSOrderedSet *)v array];
    // 兜底：任何支持 for-in 的集合
    if ([v respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        NSMutableArray *m = [NSMutableArray array];
        for (id o in v) [m addObject:o];
        return m;
    }
    return nil;
}

static void CloseFloating(void) {
    if (gFloatWin) { gFloatWin.hidden = YES; gFloatWin = nil; }
}

// 小关闭条，点一下关掉自己所在窗口
@interface S4CloseBar : UIButton
@end
@implementation S4CloseBar
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor systemRedColor];
        self.layer.cornerRadius = CGRectGetHeight(f) / 2.0;
        [self addTarget:self action:@selector(hideSelf) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)hideSelf { CloseFloating(); }
@end

// ---------- 缩放：内容按全屏渲染，必须整体缩放才能完整放进窗口 ----------

static void S5Refit(UIView *win, UIView *content) {
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

@interface S5Resize : NSObject
@property (nonatomic, weak) UIView *win;
@property (nonatomic, weak) UIView *content;
@property (nonatomic) CGRect startFrame;
@property (nonatomic) CGPoint startPoint;
@end

@implementation S5Resize
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
    CGFloat minW = 140.0, minH = 180.0;
    f.size.width = MAX(minW, MIN(self.startFrame.size.width + dx, sb.size.width - f.origin.x - 4));
    f.size.height = MAX(minH, MIN(self.startFrame.size.height + dy, sb.size.height - f.origin.y - 40));
    win.frame = f;

    S5Refit(win, self.content);
}
@end

static void ShowFloating(UIView *cv, NSString *title) {
    CloseFloating();

    UIWindow *host = MakeWindow(UIWindowLevelAlert + 800, [UIColor clearColor]);
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    host.rootViewController = vc;

    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat w = sb.size.width * 0.62;
    CGFloat h = w * 1.7;
    if (h > sb.size.height * 0.72) h = sb.size.height * 0.72;

    UIView *win = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width - w - 14, 96, w, h)];
    win.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    win.layer.cornerRadius = 12;
    win.layer.borderWidth = 1;
    win.layer.borderColor = [[UIColor colorWithWhite:1 alpha:0.3] CGColor];
    win.clipsToBounds = YES;
    [vc.view addSubview:win];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 26)];
    bar.backgroundColor = [UIColor colorWithWhite:0.24 alpha:1.0];
    [win addSubview:bar];

    [bar addSubview:[[S4CloseBar alloc] initWithFrame:CGRectMake(8, 6, 52, 14)]];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(68, 0, w - 76, 26)];
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:10];
    lbl.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    lbl.adjustsFontSizeToFitWidth = YES;
    [bar addSubview:lbl];

    [win addSubview:cv];

    // 内容按全屏尺寸渲染，等比缩放进窗口区域，保证完整可见
    S5Refit(win, cv);

    // 标题栏拖动
    S5Drag *drag = [S5Drag new];
    drag.win = win;
    drag.content = cv;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:drag action:@selector(pan:)];
    [bar addGestureRecognizer:pan];
    objc_setAssociatedObject(win, "s5drag", drag, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 右下角缩放手柄
    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(w - 26, h - 26, 22, 22)];
    handle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    handle.layer.cornerRadius = 5;
    handle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [win addSubview:handle];

    S5Resize *resize = [S5Resize new];
    resize.win = win;
    resize.content = cv;
    UIPanGestureRecognizer *rpan = [[UIPanGestureRecognizer alloc] initWithTarget:resize action:@selector(pan:)];
    [handle addGestureRecognizer:rpan];
    objc_setAssociatedObject(win, "s5resize", resize, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    host.hidden = NO;
    gFloatWin = host;
    A(@"浮窗已显示 %.0fx%.0f（内容等比缩放）", w, h);
}

static UIView *BuildContainer(id scene, NSMutableString *r) {
    NSArray *layers = LayerList(scene);
    [r appendFormat:@"layers=%lu ", (unsigned long)layers.count];
    if (layers.count == 0) { [r appendString:@"(集合为空)"]; return nil; }

    Class cc = NSClassFromString(@"_UISceneLayerHostContainerView");
    if (!cc) { [r appendString:@"no containerClass"]; return nil; }

    id container = nil;
    @try {
        if ([(id)cc instancesRespondToSelector:@selector(initWithScene:debugDescription:)]) {
            container = ((id (*)(id, SEL, id, id))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)((id)cc, @selector(alloc)),
                @selector(initWithScene:debugDescription:), scene, @"MW16");
            [r appendString:@"init=dbg "];
        } else if ([(id)cc instancesRespondToSelector:@selector(initWithScene:)]) {
            container = ((id (*)(id, SEL, id))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)((id)cc, @selector(alloc)),
                @selector(initWithScene:), scene);
            [r appendString:@"init=basic "];
        } else {
            [r appendString:@"init=NONE"];
            return nil;
        }
    } @catch (NSException *e) {
        [r appendFormat:@"EXC:%@", e.reason];
        return nil;
    }
    if (!container) { [r appendString:@"container=nil"]; return nil; }

    UIView *cv = (UIView *)container;
    if (CGRectIsEmpty(cv.frame)) cv.frame = CGRectMake(0, 0, 320, 560);

    if (![container respondsToSelector:@selector(_createHostViewForLayer:)]) {
        [r appendString:@"no _createHostViewForLayer"];
        return nil;
    }

    int made = 0;
    for (id layer in layers) {
        @try {
            UIView *hv = ((id (*)(id, SEL, id))objc_msgSend)(container, @selector(_createHostViewForLayer:), layer);
            if (!hv) continue;
            hv.frame = cv.bounds;
            hv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [cv addSubview:hv];
            made++;
        } @catch (NSException *e) {
            [r appendFormat:@"(hv EXC %@) ", e.reason];
        }
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
    CloseFloating();
    if (!gOut) gOut = [NSMutableString string];
    [gOut setString:@""];
    gPollCount = 0;

    A(@"目标: %@", bid);
    A(@"启动中 ...");
    LaunchApp(bid);

    gPoll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gPoll, dispatch_time(DISPATCH_TIME_NOW, 0), 400 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gPoll, ^{
        gPollCount++;
        id scene = SceneForBundle(bid);

        if (gPollCount % 5 == 1) {
            NSArray *ls = scene ? LayerList(scene) : nil;
            A(@"[%d] scene=%@ layers=%lu", gPollCount, scene ? @"Y" : @"N",
              (unsigned long)ls.count);
        }

        if (scene) {
            NSArray *ls = LayerList(scene);
            if (ls.count > 0) {
                StopPoll();
                A(@"[%d] 有图层了，建容器", gPollCount);
                NSMutableString *r = [NSMutableString string];
                UIView *cv = BuildContainer(scene, r);
                A(@"build: %@ -> %@", r, cv ? @"OK" : @"FAIL");

                if (cv) {
                    ShowFloating(cv, bid);
                    if (gPanelWin) { gPanelWin.hidden = YES; }
                } else {
                    A(@"容器建立失败，原因见上");
                }
                Flush();
                return;
            }
        }

        if (gPollCount >= 60) {   // 24 秒
            StopPoll();
            A(@"超时：24 秒内没拿到可用的图层");
            A(@"当前所有场景：");
            for (id s in AllScenes()) {
                A(@"  %@ layers=%lu", SceneID(s) ?: @"?", (unsigned long)LayerList(s).count);
            }
            Flush();
        }
    });
    dispatch_resume(gPoll);
}

@interface S4Panel : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITextView *trace;
@end

@implementation S4Panel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    CGRect sb = [UIScreen mainScreen].bounds;

    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(12, 46, sb.size.width - 90, 28)];
    h.text = @"MW16 Stage 4";
    h.textColor = [UIColor whiteColor];
    h.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [self.view addSubview:h];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(sb.size.width - 52, 42, 40, 34);
    [x setTitle:@"X" forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    [x addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:x];

    self.field = [[UITextField alloc] initWithFrame:CGRectMake(12, 80, sb.size.width - 110, 34)];
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
    go.frame = CGRectMake(sb.size.width - 92, 80, 80, 34);
    [go setTitle:@"开浮窗" forState:UIControlStateNormal];
    go.backgroundColor = [UIColor systemBlueColor];
    [go setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont systemFontOfSize:13];
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
    A(@"输入 bundle id 点「开浮窗」，会自动启动并等待图层。");
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
    S4Panel *p = [S4Panel new];
    w.rootViewController = p;
    w.hidden = NO;
    gPanelWin = w;
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ShowPanel(); });
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ if (!gPanelWin) ShowPanel(); });
    %init;
}
