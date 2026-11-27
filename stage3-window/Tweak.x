#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MW16 Stage 3 —— 启动 App → 等 scene → 建图层容器 → 浮窗
//
//  v3 日志确认的事实：
//    - enumerateScenesWithBlock: 存在且可用
//    - 场景 id 形如 "sceneID:com.apple.xxx-default"
//  因此必须先把 App 跑起来，等它的 scene 出现且 layers>0，才可能出画面。

#define S3_LOG @"/var/mobile/Media/mw16_stage3.log"

static NSMutableString *gOut = nil;
static UITextView *gTrace = nil;
static UIWindow *gPanelWin = nil;
static UIWindow *gFloatWin = nil;

// ---------- 基础 ----------

static void A(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gOut) gOut = [NSMutableString string];
    [gOut appendFormat:@"%@\n", s];
    NSLog(@"[MW16-S3] %@", s);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gTrace) gTrace.text = gOut;
    });
}

static void FlushLog(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [gOut writeToFile:S3_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
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

static UIWindow *MakeWindow(CGFloat level) {
    UIWindowScene *ws = ActiveScene();
    UIWindow *w = ws ? [[UIWindow alloc] initWithWindowScene:ws]
                     : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.frame = [UIScreen mainScreen].bounds;
    w.windowLevel = level;
    w.backgroundColor = [UIColor clearColor];
    return w;
}

// ---------- 场景 ----------

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
        @try { ((void (*)(id, SEL, id))objc_msgSend)(mgr, sel, b); }
        @catch (NSException *e) {}
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

static int LayerCount(id scene) {
    if (!scene || ![scene respondsToSelector:@selector(layerManager)]) return -1;
    id lm = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(layerManager));
    if (!lm || ![lm respondsToSelector:@selector(layers)]) return -1;
    id layers = ((id (*)(id, SEL))objc_msgSend)(lm, @selector(layers));
    return [layers isKindOfClass:[NSArray class]] ? (int)[layers count] : -1;
}

// ---------- 容器 ----------

static UIView *BuildContainer(id scene, NSMutableString *r) {
    if (!scene) { [r appendString:@"scene=nil"]; return nil; }
    int n = LayerCount(scene);
    [r appendFormat:@"layers=%d ", n];
    if (n <= 0) { [r appendString:@"(无图层)"]; return nil; }

    id lm = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(layerManager));
    id layers = ((id (*)(id, SEL))objc_msgSend)(lm, @selector(layers));

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
        } @catch (NSException *e) {}
    }
    [r appendFormat:@"hostViews=%d", made];
    return (made > 0) ? cv : nil;
}

// ---------- 浮窗 ----------

@interface S3CloseBar : UIButton
@end

@implementation S3CloseBar
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor systemRedColor];
        self.layer.cornerRadius = CGRectGetHeight(frame) / 2.0;
        [self addTarget:self action:@selector(hideSelf) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)hideSelf {
    if (gFloatWin) { gFloatWin.hidden = YES; gFloatWin = nil; }
}
@end

static void CloseFloating(void) {
    if (gFloatWin) { gFloatWin.hidden = YES; gFloatWin = nil; }
}

static void ShowFloating(UIView *cv) {
    CloseFloating();

    UIWindow *host = MakeWindow(UIWindowLevelAlert + 800);
    host.backgroundColor = [UIColor clearColor];
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

    [bar addSubview:[[S3CloseBar alloc] initWithFrame:CGRectMake(8, 6, 52, 14)]];

    cv.frame = CGRectMake(0, 26, w, h - 26);
    cv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:cv];

    host.hidden = NO;
    gFloatWin = host;
    A(@"浮窗已显示 %.0fx%.0f", w, h);
}

// ---------- 启动 App ----------

static id SBAppFor(NSString *bid) {
    Class ac = NSClassFromString(@"SBApplicationController");
    if (!ac || ![ac respondsToSelector:@selector(sharedInstance)]) return nil;
    id ctrl = ((id (*)(id, SEL))objc_msgSend)((id)ac, @selector(sharedInstance));
    SEL sel = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (!ctrl || ![ctrl respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(ctrl, sel, bid);
}

static void LaunchApp(NSString *bid) {
    id app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if (app && [app respondsToSelector:sel]) {
        @try { ((void (*)(id, SEL, id, BOOL))objc_msgSend)(app, sel, bid, YES); }
        @catch (NSException *e) {}
    }
}

static void OpenBundle(NSString *bid) {
    if (!bid.length) return;

    id app = SBAppFor(bid);
    BOOL running = NO;
    if (app && [app respondsToSelector:@selector(isRunning)])
        running = ((BOOL (*)(id, SEL))objc_msgSend)(app, @selector(isRunning));

    A(@"== %@ ==", bid);
    A(@"app=%@ running=%d", app ? @"ok" : @"nil", running);

    LaunchApp(bid);
    FlushLog();

    __block int tries = 0;
    __block dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                             dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              500 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        tries++;
        id scene = SceneForBundle(bid);
        int lc = scene ? LayerCount(scene) : -1;

        if (tries % 4 == 1) A(@"[%d] scene=%@ layers=%d", tries, scene ? @"Y" : @"N", lc);

        if (scene && lc > 0) {
            dispatch_source_cancel(timer);
            NSMutableString *r = [NSMutableString string];
            UIView *cv = BuildContainer(scene, r);
            A(@"build: %@ -> %@", r, cv ? @"OK" : @"FAIL");
            if (cv) { ShowFloating(cv); if (gPanelWin) { gPanelWin.hidden = YES; } }
            FlushLog();
            return;
        }
        if (tries >= 24) {
            dispatch_source_cancel(timer);
            A(@"超时 12s：没等到 %@ 的图层", bid);
            FlushLog();
        }
    });
    dispatch_resume(timer);
}

// ---------- 面板 ----------

@interface S3Panel : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITextView *trace;
@end

@implementation S3Panel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];
    CGRect sb = [UIScreen mainScreen].bounds;

    UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(12, 46, sb.size.width - 90, 28)];
    h.text = @"MW16 Stage 3";
    h.textColor = [UIColor whiteColor];
    h.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [self.view addSubview:h];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(sb.size.width - 52, 42, 40, 34);
    [x setTitle:@"X" forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    [x addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:x];

    self.field = [[UITextField alloc] initWithFrame:CGRectMake(12, 80, sb.size.width - 100, 34)];
    self.field.placeholder = @"bundle id，例如 com.tencent.xin";
    self.field.borderStyle = UITextBorderStyleRoundedRect;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.delegate = self;
    self.field.textColor = [UIColor whiteColor];
    self.field.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    [self.view addSubview:self.field];

    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    go.frame = CGRectMake(sb.size.width - 82, 80, 70, 34);
    [go setTitle:@"打开" forState:UIControlStateNormal];
    go.backgroundColor = [UIColor systemBlueColor];
    [go setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    go.layer.cornerRadius = 8;
    [go addTarget:self action:@selector(goTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:go];

    UIButton *ls = [UIButton buttonWithType:UIButtonTypeSystem];
    ls.frame = CGRectMake(12, 120, 120, 28);
    [ls setTitle:@"列出当前场景" forState:UIControlStateNormal];
    ls.titleLabel.font = [UIFont systemFontOfSize:12];
    [ls addTarget:self action:@selector(listScenes) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:ls];

    self.trace = [[UITextView alloc] initWithFrame:CGRectMake(0, 152, sb.size.width, sb.size.height - 170)];
    self.trace.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.trace.textColor = [UIColor colorWithRed:0.45 green:1.0 blue:0.55 alpha:1.0];
    self.trace.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.trace.editable = NO;
    [self.view addSubview:self.trace];
    gTrace = self.trace;

    if (!gOut) gOut = [NSMutableString string];
    [gOut setString:@""];
    A(@"就绪：输入 bundle id 后点「打开」。");
}

- (void)hidePanel {
    if (gPanelWin) { gPanelWin.hidden = YES; gPanelWin = nil; }
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
    OpenBundle(bid);
}

- (void)listScenes {
    NSArray *all = AllScenes();
    A(@"--- 当前 %lu 个场景 ---", (unsigned long)all.count);
    for (id s in all) A(@"  %@  layers=%d", SceneID(s) ?: @"?", LayerCount(s));
    FlushLog();
}

@end

static void ShowPanel(void) {
    UIWindow *w = MakeWindow(UIWindowLevelAlert + 900);
    w.backgroundColor = [UIColor colorWithWhite:0 alpha:0.9];
    S3Panel *p = [S3Panel new];
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
