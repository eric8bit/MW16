#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

// MW16 Stage 3 v3
//
//  v2 的问题：要求你先手动打开 App，但等你回到桌面时 App 可能已被系统回收，
//  于是 scene for ... = NIL，什么都探不到。
//
//  v3 改成一键完成：自动启动 App → 轮询 scene → 抓到就立刻 dump。

#define S3_LOG @"/var/mobile/Media/mw16_stage3.log"

static NSMutableString *gOut = nil;
static UITextView *gTrace = nil;
static UIWindow *gPanelWin = nil;
static dispatch_source_t gPollTimer = nil;
static int gPollCount = 0;

static void A(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gOut) gOut = [NSMutableString string];
    [gOut appendFormat:@"%@\n", s];
    NSLog(@"[MW16-S3] %@", s);
    dispatch_async(dispatch_get_main_queue(), ^{ if (gTrace) gTrace.text = gOut; });
}

static void Flush(void) {
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

static void DumpSels(Class cls, const char *needle, int limit) {
    if (!cls) { A(@"  (class nil)"); return; }
    NSMutableArray *names = [NSMutableArray array];
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = sel_getName(method_getName(ms[i]));
            if (!needle || strstr(nm, needle)) {
                NSString *s = [NSString stringWithUTF8String:nm];
                if (s && ![names containsObject:s]) [names addObject:s];
            }
        }
        if (ms) free(ms);
    }
    if (!names.count) { A(@"  (无匹配 %s)", needle ? needle : "*"); return; }
    [names sortUsingSelector:@selector(compare:)];
    int i = 0;
    for (NSString *s in names) {
        if (i++ >= limit) { A(@"  ... 共 %lu 个", (unsigned long)names.count); break; }
        A(@"  -%@", s);
    }
}

static void DumpIvars(Class cls) {
    if (!cls) { A(@"  (class nil)"); return; }
    unsigned int n = 0;
    Ivar *ivs = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n; i++) A(@"  @%s", ivar_getName(ivs[i]));
    if (ivs) free(ivs);
    if (n == 0) A(@"  (无 ivar)");
}

static id GetIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return (__bridge id)(*(void **)((__bridge void *)obj + ivar_getOffset(iv)));
    }
    return nil;
}

static void DumpScene(id scene) {
    if (!scene) { A(@"scene = NIL"); return; }

    Class sc = object_getClass(scene);
    A(@"");
    A(@"scene class = %@", NSStringFromClass(sc));
    A(@"scene id    = %@", SceneID(scene) ?: @"?");
    A(@"");

    A(@"[A] FBScene 里含 layer 的方法：");
    DumpSels(sc, "layer", 25);
    A(@"  含 Layer：");
    DumpSels(sc, "Layer", 25);
    A(@"");

    A(@"[B] FBScene 的 ivar：");
    DumpIvars(sc);
    A(@"");

    A(@"[C] 关键 selector 存在性：");
    static const char *sels[] = {"layerManager", "_layerManager", "layerHost", "layers",
                                  "sceneLayerManager", "identifier"};
    for (int i = 0; i < 6; i++) {
        A(@"  %s = %d", sels[i], [scene respondsToSelector:NSSelectorFromString([NSString stringWithUTF8String:sels[i]])]);
    }
    A(@"");

    id lm = nil;
    if ([scene respondsToSelector:@selector(layerManager)]) {
        @try { lm = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(layerManager)); }
        @catch (NSException *e) { A(@"layerManager EXC %@", e.reason); }
    }
    if (!lm) lm = GetIvar(scene, "_layerManager");
    A(@"[D] layerManager = %@ (%@)", lm ? @"OK" : @"NIL", lm ? NSStringFromClass([lm class]) : @"-");

    if (lm) {
        Class lmc = object_getClass(lm);
        A(@"");
        A(@"[E] layerManager 含 layer 的方法：");
        DumpSels(lmc, "layer", 25);
        A(@"");
        A(@"[F] layerManager 的 ivar：");
        DumpIvars(lmc);
        A(@"");
        A(@"[G] 尝试读：");
        for (NSString *sel in @[@"layers", @"_layers", @"allLayers", @"sceneLayers"]) {
            SEL s = NSSelectorFromString(sel);
            if (![lm respondsToSelector:s]) { A(@"  %@ -> 不存在", sel); continue; }
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)(lm, s);
                A(@"  %@ -> %@ (%lu)", sel, v ? NSStringFromClass([v class]) : @"nil",
                  (unsigned long)([v respondsToSelector:@selector(count)] ? [v count] : 0));
            } @catch (NSException *e) { A(@"  %@ EXC %@", sel, e.reason); }
        }
        for (NSString *ivn in @[@"_layers", @"_layerMap", @"_layersByIdentifier"]) {
            id v = GetIvar(lm, [ivn UTF8String]);
            if (v) A(@"  ivar %@ -> %@ (%lu)", ivn, NSStringFromClass([v class]),
                     (unsigned long)([v respondsToSelector:@selector(count)] ? [v count] : 0));
        }
    }
    Flush();
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
    if (gPollTimer) { dispatch_source_cancel(gPollTimer); gPollTimer = nil; }
}

static void StartProbe(NSString *bid) {
    StopPoll();
    if (!gOut) gOut = [NSMutableString string];
    [gOut setString:@""];

    A(@"目标: %@", bid);
    A(@"正在启动 App ...");
    LaunchApp(bid);
    gPollCount = 0;

    gPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gPollTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 400 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gPollTimer, ^{
        gPollCount++;
        id scene = SceneForBundle(bid);

        if (gPollCount % 5 == 1) A(@"[%d] 找 scene ... %@", gPollCount, scene ? @"找到" : @"还没有");

        if (scene) {
            A(@"[%d] 拿到 scene，开始探测", gPollCount);
            StopPoll();
            DumpScene(scene);
            return;
        }
        if (gPollCount >= 50) {   // 20 秒
            StopPoll();
            A(@"超时 20s：还没看到 %@ 的 scene", bid);
            A(@"当前所有场景：");
            for (id s in AllScenes()) A(@"  %@", SceneID(s) ?: @"?");
            A(@"");
            A(@"可能原因：App 启动失败 / bundle id 不对 / 应用被系统拦截");
            Flush();
        }
    });
    dispatch_resume(gPollTimer);
}

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
    h.text = @"MW16 Stage3 · 图层探测";
    h.textColor = [UIColor whiteColor];
    h.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [self.view addSubview:h];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(sb.size.width - 52, 42, 40, 34);
    [x setTitle:@"X" forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    [x addTarget:self action:@selector(hidePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:x];

    self.field = [[UITextField alloc] initWithFrame:CGRectMake(12, 80, sb.size.width - 100, 34)];
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
    go.frame = CGRectMake(sb.size.width - 82, 80, 70, 34);
    [go setTitle:@"启动+探测" forState:UIControlStateNormal];
    go.backgroundColor = [UIColor systemBlueColor];
    [go setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont systemFontOfSize:12];
    go.layer.cornerRadius = 8;
    [go addTarget:self action:@selector(goTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:go];

    self.trace = [[UITextView alloc] initWithFrame:CGRectMake(0, 124, sb.size.width, sb.size.height - 142)];
    self.trace.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.trace.textColor = [UIColor colorWithRed:0.45 green:1.0 blue:0.55 alpha:1.0];
    self.trace.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    self.trace.editable = NO;
    [self.view addSubview:self.trace];
    gTrace = self.trace;

    if (!gOut) gOut = [NSMutableString string];
    A(@"点「启动+探测」：会自动打开 App 并等待它的 scene。");
}

- (void)hidePanel { if (gPanelWin) { gPanelWin.hidden = YES; gPanelWin = nil; } }

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self goTapped]; return YES; }

- (void)goTapped {
    NSString *bid = [self.field.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!bid.length) { A(@"先输入 bundle id"); return; }
    [self.field resignFirstResponder];
    StartProbe(bid);
}

@end

static void ShowPanel(void) {
    UIWindow *w = MakeWindow(UIWindowLevelAlert + 900);
    w.backgroundColor = [UIColor colorWithWhite:0 alpha:0.92];
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
