#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// MW16 Stage 2 v3
//  修正两点：
//   1) 上一版的关闭按钮把 @selector(dismissViewControllerAnimated:completion:) 当 action 用，
//      参数被当成 block 指针 → _Block_copy 崩溃。改成正常的窗口隐藏。
//   2) 场景枚举改用真实存在的 -enumerateScenesWithBlock:（探测已确认）。

#define S2_LOG @"/var/mobile/Media/mw16_stage2.log"

static NSMutableString *gOut = nil;
static UITextView *gTextView = nil;
static UIWindow *gPanelWin = nil;
static UIWindow *gFloatWin = nil;

static void A(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gOut) gOut = [NSMutableString string];
    [gOut appendFormat:@"%@\n", s];
    NSLog(@"[MW16-S2] %@", s);
}

static void Flush(NSString *path) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gTextView) gTextView.text = gOut ?: @"";
        @try { [gOut writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
        @catch (NSException *e) {}
    });
}

static UIView *BuildContainer(id scene, NSMutableString *r);
static void ShowFloating(UIView *cv);

    UIWindowScene *fallback = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (!fallback) fallback = (UIWindowScene *)s;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
    }
    return fallback;
}

static UIWindow *MakeWindow(CGFloat level) {
    UIWindowScene *ws = ActiveScene();
    UIWindow *w = ws ? [[UIWindow alloc] initWithWindowScene:ws]
                     : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.frame = [UIScreen mainScreen].bounds;
    w.windowLevel = level;
    w.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    return w;
}

#pragma mark - 场景枚举（用探测确认过的 API）

static id FBSceneManagerInst(void) {
    Class c = NSClassFromString(@"FBSceneManager");
    if (!c || ![c respondsToSelector:@selector(sharedInstance)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, @selector(sharedInstance));
}

static NSArray *AllScenes(void) {
    id mgr = FBSceneManagerInst();
    if (!mgr) return @[];

    NSMutableArray *out = [NSMutableArray array];

    // 1) -enumerateScenesWithBlock:（探测确认存在）
    SEL sel = NSSelectorFromString(@"enumerateScenesWithBlock:");
    if ([mgr respondsToSelector:sel]) {
        void (^blk)(id) = ^(id scene) {
            if (scene) [out addObject:scene];
        };
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(mgr, sel, blk);
        } @catch (NSException *e) {}
    }

    // 2) -scenesPassingTest:（兜底）
    if (out.count == 0) {
        SEL p = NSSelectorFromString(@"scenesPassingTest:");
        if ([mgr respondsToSelector:p]) {
            BOOL (^test)(id) = ^BOOL(id scene) { return scene != nil; };
            @try {
                id r = ((id (*)(id, SEL, id))objc_msgSend)(mgr, p, test);
                if ([r isKindOfClass:[NSSet class]] || [r isKindOfClass:[NSArray class]]) {
                    for (id s in r) [out addObject:s];
                }
            } @catch (NSException *e) {}
        }
    }

    // 3) ivar _workspace 里再找一次
    if (out.count == 0) {
        Ivar iv = class_getInstanceVariable(object_getClass(mgr), "_workspace");
        if (iv) {
            id ws = (__bridge id)(*(void **)((__bridge void *)mgr + ivar_getOffset(iv)));
            if (ws && [ws respondsToSelector:@selector(sceneManager)]) {
                id sm = ((id (*)(id, SEL))objc_msgSend)(ws, @selector(sceneManager));
                if (sm && [sm respondsToSelector:@selector(enumerateScenesWithBlock:)]) {
                    void (^b2)(id) = ^(id s) { if (s) [out addObject:s]; };
                    @try { ((void (*)(id, SEL, id))objc_msgSend)(sm, @selector(enumerateScenesWithBlock:), b2); }
                    @catch (NSException *e) {}
                }
            }
        }
    }

    return out;
}

static NSString *SceneID(id scene) {
    if (!scene) return nil;
    if ([scene respondsToSelector:@selector(identifier)]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(identifier));
        if ([v isKindOfClass:[NSString class]]) return v;
    }
    return nil;
}

#pragma mark - 建容器

static UIView *BuildContainer(id scene, NSMutableString *r) {
    if (!scene) { [r appendString:@"scene=nil"]; return nil; }

    // 先看有没有图层
    id lm = nil;
    if ([scene respondsToSelector:@selector(layerManager)])
        lm = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(layerManager));
    if (!lm) { [r appendString:@"no layerManager"]; return nil; }

    id layers = nil;
    if ([lm respondsToSelector:@selector(layers)])
        layers = ((id (*)(id, SEL))objc_msgSend)(lm, @selector(layers));
    NSUInteger n = [layers isKindOfClass:[NSArray class]] ? [layers count] : 0;
    [r appendFormat:@"layers=%lu ", (unsigned long)n];

    Class cc = NSClassFromString(@"_UISceneLayerHostContainerView");
    if (!cc) { [r appendString:@"no containerClass"]; return nil; }

    id container = nil;
    @try {
        if ([(id)cc instancesRespondToSelector:@selector(initWithScene:debugDescription:)]) {
            container = ((id (*)(id, SEL, id, id))objc_msgSend)(
                ((id (*)(id, SEL))objc_msgSend)((id)cc, @selector(alloc)),
                @selector(initWithScene:debugDescription:), scene, @"MW16-S2");
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
        [r appendFormat:@"init EXC %@", e.reason];
        return nil;
    }

    if (!container) { [r appendString:@"container=nil"]; return nil; }

    UIView *cv = (UIView *)container;
    if (CGRectIsEmpty(cv.frame)) cv.frame = CGRectMake(0, 0, 320, 560);

    if ([container respondsToSelector:@selector(_createHostViewForLayer:)] && n > 0) {
        NSUInteger made = 0;
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
        [r appendFormat:@"hostViews=%lu", (unsigned long)made];
    } else {
        [r appendString:@"hostViews=skip"];
    }

    return cv;
}

#pragma mark - 面板（关闭按钮用正规 target/action）

@interface S2Panel : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UITextView *trace;
@property (nonatomic, copy) NSArray *scenes;
@end

@implementation S2Panel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    CGRect sb = [UIScreen mainScreen].bounds;

    UILabel *hdr = [[UILabel alloc] initWithFrame:CGRectMake(12, 46, sb.size.width - 90, 28)];
    hdr.text = @"MW16 Stage 2";
    hdr.textColor = [UIColor whiteColor];
    hdr.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [self.view addSubview:hdr];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(sb.size.width - 52, 42, 40, 34);
    [x setTitle:@"X" forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    [x addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:x];

    UIButton *rf = [UIButton buttonWithType:UIButtonTypeSystem];
    rf.frame = CGRectMake(12, 76, 100, 30);
    [rf setTitle:@"刷新场景" forState:UIControlStateNormal];
    rf.titleLabel.font = [UIFont systemFontOfSize:13];
    [rf addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:rf];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 110, sb.size.width, sb.size.height * 0.45)
                                             style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 40;
    self.table.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    [self.view addSubview:self.table];

    self.trace = [[UITextView alloc] initWithFrame:CGRectMake(0, sb.size.height * 0.45 + 112,
                                                             sb.size.width, sb.size.height * 0.45)];
    self.trace.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.trace.textColor = [UIColor colorWithRed:0.45 green:1.0 blue:0.55 alpha:1.0];
    self.trace.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.trace.editable = NO;
    [self.view addSubview:self.trace];
    gTextView = self.trace;

    [self reload];
}

- (void)hidePanel {
    if (gPanelWin) { gPanelWin.hidden = YES; gPanelWin = nil; }
}

- (void)reload {
    self.scenes = AllScenes();
    [self.table reloadData];
    if (!gOut) gOut = [NSMutableString string];
    [gOut setString:@""];
    A(@"场景数 = %lu", (unsigned long)self.scenes.count);
    int i = 0;
    for (id s in self.scenes) {
        if (i++ >= 40) break;
        A(@"  %@", SceneID(s) ?: @"(no id)");
    }
    self.trace.text = gOut;
    Flush(S2_LOG);
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.scenes.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"s2v3";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    c.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
    c.textLabel.textColor = [UIColor whiteColor];
    c.textLabel.font = [UIFont systemFontOfSize:11];
    c.textLabel.text = SceneID(self.scenes[ip.row]) ?: @"(no id)";
    c.textLabel.adjustsFontSizeToFitWidth = YES;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    id scene = self.scenes[ip.row];
    NSMutableString *r = [NSMutableString string];
    [r appendFormat:@"%@: ", SceneID(scene) ?: @"?"];
    UIView *cv = BuildContainer(scene, r);
    [r appendFormat:@" -> %@", cv ? @"OK" : @"NIL"];
    if (gOut) [gOut appendFormat:@"%@\n", r];
    if (gTextView) gTextView.text = gOut;
    Flush(S2_LOG);
    if (cv) {
        ShowFloating(cv);
        [self hidePanel];
    }
}

@end

#pragma mark - 浮窗

static void ShowFloating(UIView *cv) {
    UIWindow *host = MakeWindow(UIWindowLevelAlert + 800);
    host.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    host.rootViewController = vc;

    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat w = sb.size.width * 0.62;
    CGFloat h = w * 1.7;
    if (h > sb.size.height * 0.72) h = sb.size.height * 0.72;

    UIView *win = [[UIView alloc] initWithFrame:CGRectMake(sb.size.width - w - 14, 90, w, h)];
    win.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    win.layer.cornerRadius = 12;
    win.layer.borderWidth = 1;
    win.layer.borderColor = [[UIColor colorWithWhite:1 alpha:0.3] CGColor];
    win.clipsToBounds = YES;
    [vc.view addSubview:win];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 26)];
    bar.backgroundColor = [UIColor colorWithWhite:0.24 alpha:1.0];
    [win addSubview:bar];

    cv.frame = CGRectMake(0, 26, w, h - 26);
    cv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:cv];

    host.hidden = NO;
    gFloatWin = host;
    A(@"浮窗已创建 %.0fx%.0f", w, h);
}

static void ShowPanel(void) {
    UIWindow *w = MakeWindow(UIWindowLevelAlert + 900);
    S2Panel *p = [S2Panel new];
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
