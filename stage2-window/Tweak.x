#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
//  MW16 Stage 2 —— 单窗口试验版（屏幕上直接显示诊断信息）
//
//  原则：
//    1. %ctor 里只登记延时任务，加载期不做任何实事
//    2. 每一步结果画在屏幕上，不依赖日志文件
//    3. 任何一步失败只显示文字，不崩溃
// ---------------------------------------------------------------------------

#define S2_LOG @"/var/mobile/Media/mw16_stage2.log"

static NSMutableString *gTrace = nil;
static UILabel *gTraceLabel = nil;
static UIWindow *gPanelWin = nil;
static UIWindow *gFloatWin = nil;

static void S2Append(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[MW16-S2] %@", line);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gTrace) gTrace = [NSMutableString string];
        [gTrace appendFormat:@"%@\n", line];
        if (gTrace.length > 3000) [gTrace deleteCharactersInRange:NSMakeRange(0, 1500)];
        if (gTraceLabel) gTraceLabel.text = gTrace;
        @try {
            NSString *old = [NSString stringWithContentsOfFile:S2_LOG encoding:NSUTF8StringEncoding error:nil];
            if (!old) old = @"";
            [[old stringByAppendingFormat:@"%@  %@\n", [NSDate date], line]
              writeToFile:S2_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) {}
    });
}

static UIWindowScene *S2ActiveScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (!fallback) fallback = (UIWindowScene *)s;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
    }
    return fallback;
}

static UIWindow *S2MakeWindow(CGFloat level) {
    UIWindowScene *ws = S2ActiveScene();
    UIWindow *w = ws ? [[UIWindow alloc] initWithWindowScene:ws]
                     : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.frame = [UIScreen mainScreen].bounds;
    w.windowLevel = level;
    w.backgroundColor = [UIColor clearColor];
    return w;
}

#pragma mark - 场景枚举

static void S2CollectFrom(id mgr, NSMutableArray *out) {
    if (!mgr || ![mgr respondsToSelector:@selector(allScenes)]) return;
    id all = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(allScenes));
    if (![all isKindOfClass:[NSArray class]] && ![all isKindOfClass:[NSSet class]]) return;
    for (id sc in all) {
        if (![sc respondsToSelector:@selector(identifier)]) continue;
        NSString *sid = ((id (*)(id, SEL))objc_msgSend)(sc, @selector(identifier));
        if (sid.length && ![out containsObject:sid]) [out addObject:sid];
    }
}

static NSArray<NSString *> *S2AllSceneIDs(void) {
    NSMutableArray *out = [NSMutableArray array];
    Class fbMgr = NSClassFromString(@"FBSceneManager");
    if (fbMgr && [fbMgr respondsToSelector:@selector(sharedInstance)])
        S2CollectFrom(((id (*)(id, SEL))objc_msgSend)((id)fbMgr, @selector(sharedInstance)), out);
    Class mws = NSClassFromString(@"SBMainWorkspace");
    if (mws && [mws respondsToSelector:@selector(sharedInstance)]) {
        id ws = ((id (*)(id, SEL))objc_msgSend)((id)mws, @selector(sharedInstance));
        if ([ws respondsToSelector:@selector(sceneManager)])
            S2CollectFrom(((id (*)(id, SEL))objc_msgSend)(ws, @selector(sceneManager)), out);
    }
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

static id S2SceneForID(NSString *sid) {
    if (!sid.length) return nil;
    Class fbMgr = NSClassFromString(@"FBSceneManager");
    if (!fbMgr || ![fbMgr respondsToSelector:@selector(sharedInstance)]) return nil;
    id inst = ((id (*)(id, SEL))objc_msgSend)((id)fbMgr, @selector(sharedInstance));
    if (!inst) return nil;
    SEL sel = NSSelectorFromString(@"sceneWithIdentifier:");
    if ([inst respondsToSelector:sel]) {
        id sc = ((id (*)(id, SEL, id))objc_msgSend)(inst, sel, sid);
        if (sc) return sc;
    }
    if ([inst respondsToSelector:@selector(allScenes)]) {
        id all = ((id (*)(id, SEL))objc_msgSend)(inst, @selector(allScenes));
        for (id sc in all) {
            if (![sc respondsToSelector:@selector(identifier)]) continue;
            NSString *s = ((id (*)(id, SEL))objc_msgSend)(sc, @selector(identifier));
            if ([s isEqualToString:sid]) return sc;
        }
    }
    return nil;
}

#pragma mark - 建容器

static UIView *S2BuildContainer(id scene, NSMutableString *r) {
    if (!scene) { [r appendString:@"scene=nil"]; return nil; }
    if (![scene respondsToSelector:@selector(layerManager)]) { [r appendString:@"no layerManager"]; return nil; }

    id lm = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(layerManager));
    if (!lm) { [r appendString:@"layerManager=nil"]; return nil; }

    id layers = [lm respondsToSelector:@selector(layers)]
                 ? ((id (*)(id, SEL))objc_msgSend)(lm, @selector(layers)) : nil;
    NSUInteger n = [layers isKindOfClass:[NSArray class]] ? [layers count] : 0;
    [r appendFormat:@"layers=%lu ", (unsigned long)n];

    Class cc = NSClassFromString(@"_UISceneLayerHostContainerView");
    if (!cc) { [r appendString:@"no containerClass"]; return nil; }

    id container = nil;
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
    if (!container) { [r appendString:@"container=nil"]; return nil; }

    UIView *cv = (UIView *)container;
    if (CGRectIsEmpty(cv.frame)) cv.frame = CGRectMake(0, 0, 300, 500);

    if ([container respondsToSelector:@selector(_createHostViewForLayer:)] && n > 0) {
        NSUInteger made = 0;
        for (id layer in layers) {
            UIView *hv = ((id (*)(id, SEL, id))objc_msgSend)(container, @selector(_createHostViewForLayer:), layer);
            if (!hv) continue;
            hv.frame = cv.bounds;
            hv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [cv addSubview:hv];
            made++;
        }
        [r appendFormat:@"hostViews=%lu", (unsigned long)made];
    } else {
        [r appendString:@"hostViews=skip"];
    }
    return cv;
}

#pragma mark - 浮窗

static void S2ShowFloating(UIView *cv, NSString *title) {
    UIWindow *host = S2MakeWindow(UIWindowLevelAlert + 800);
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
    win.layer.borderColor = [[UIColor colorWithWhite:1 alpha:0.25] CGColor];
    win.clipsToBounds = YES;
    [vc.view addSubview:win];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 26)];
    bar.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
    [win addSubview:bar];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(72, 0, w - 96, 26)];
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    lbl.textColor = [UIColor colorWithWhite:0.88 alpha:1];
    lbl.adjustsFontSizeToFitWidth = YES;
    [bar addSubview:lbl];

    cv.frame = CGRectMake(0, 26, w, h - 26);
    cv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:cv];

    host.hidden = NO;
    gFloatWin = host;
    S2Append(@"浮窗已创建 %.0f x %.0f", w, h);
}

#pragma mark - 面板

@interface S2Panel : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) UILabel *traceLabel;
@property (nonatomic, copy) NSArray<NSString *> *items;
@end

@implementation S2Panel

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat w = MIN(sb.size.width - 24, 384);
    CGFloat h = sb.size.height - 160;

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake((sb.size.width - w) / 2, 70, w, h)];
    box.backgroundColor = [UIColor secondarySystemBackgroundColor];
    box.layer.cornerRadius = 16;
    box.clipsToBounds = YES;
    [self.view addSubview:box];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, w - 80, 26)];
    title.text = @"MW16 Stage 2";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [box addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 46, 8, 36, 36);
    [close setTitle:@"X" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:close];

    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.frame = CGRectMake(16, 40, 90, 30);
    [refresh setTitle:@"刷新列表" forState:UIControlStateNormal];
    refresh.titleLabel.font = [UIFont systemFontOfSize:13];
    [refresh addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:refresh];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 74, w, h - 240) style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 40;
    [box addSubview:self.table];

    self.hint = [[UILabel alloc] initWithFrame:CGRectMake(16, h - 162, w - 32, 80)];
    self.hint.numberOfLines = 6;
    self.hint.font = [UIFont systemFontOfSize:11];
    self.hint.textColor = [UIColor secondaryLabelColor];
    self.hint.text = @"点一个场景试试";
    [box addSubview:self.hint];

    self.traceLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, h - 80, w - 32, 68)];
    self.traceLabel.numberOfLines = 8;
    self.traceLabel.font = [UIFont systemFontOfSize:9];
    self.traceLabel.textColor = [UIColor systemGreenColor];
    [box addSubview:self.traceLabel];
    gTraceLabel = self.traceLabel;

    [self reload];
}

- (void)dismiss { if (gPanelWin) gPanelWin.hidden = YES; }

- (void)reload {
    self.items = S2AllSceneIDs();
    [self.table reloadData];
    self.hint.text = [NSString stringWithFormat:@"共 %lu 个场景\n（下拉可再刷新）", (unsigned long)self.items.count];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.items.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"s2c";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    c.textLabel.text = self.items[ip.row];
    c.textLabel.font = [UIFont systemFontOfSize:11];
    c.textLabel.adjustsFontSizeToFitWidth = YES;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *sid = self.items[ip.row];
    NSMutableString *r = [NSMutableString string];
    [r appendFormat:@"%@: ", sid];
    id scene = S2SceneForID(sid);
    if (!scene) {
        [r appendString:@"scene=NIL"];
        self.hint.text = r;
        return;
    }
    UIView *cv = S2BuildContainer(scene, r);
    [r appendFormat:@" -> %@", cv ? @"OK" : @"NIL"];
    self.hint.text = r;
    S2Append(@"%@", r);
    if (cv) {
        S2ShowFloating(cv, sid);
        if (gPanelWin) gPanelWin.hidden = YES;
    }
}

@end

static void S2ShowPanel(void) {
    UIWindow *w = S2MakeWindow(UIWindowLevelAlert + 900);
    S2Panel *p = [S2Panel new];
    w.rootViewController = p;
    w.hidden = NO;
    gPanelWin = w;
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        S2Append(@"BOOT iOS %@", [[UIDevice currentDevice] systemVersion]);
        S2ShowPanel();
    });
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gPanelWin) S2ShowPanel();
    });
    %init;
}
