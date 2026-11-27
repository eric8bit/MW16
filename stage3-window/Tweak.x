#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

// MW16 Stage 3 v2 —— 为什么 layers=-1
//
//  v1 现象：scene=Y（场景确实出现了），但 layers 一直是 -1。
//  -1 表示 LayerCount() 里某一步 respondsToSelector 失败：
//    要么 FBScene 没有 layerManager，要么 layerManager 没有 layers，
//    要么 layers 不是 NSArray。
//  这一版直接把真实的方法名/ivar 名打出来。

#define S3_LOG @"/var/mobile/Media/mw16_stage3.log"

static NSMutableString *gOut = nil;
static UITextView *gTrace = nil;
static UIWindow *gPanelWin = nil;

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

// ---------- 方法/变量转储 ----------

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

// 从一个对象里按名字取 ivar（沿继承链）
static id GetIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return (__bridge id)(*(void **)((__bridge void *)obj + ivar_getOffset(iv)));
    }
    return nil;
}

static void DumpSceneLayers(NSString *bid) {
    [gOut setString:@""];
    A(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    A(@"");

    id scene = SceneForBundle(bid);
    A(@"scene for %@ = %@", bid, scene ? @"FOUND" : @"NIL");
    if (!scene) { Flush(); return; }

    Class sc = object_getClass(scene);
    A(@"scene class = %@", NSStringFromClass(sc));
    A(@"");

    A(@"[A] FBScene 里含 layer 的方法：");
    DumpSels(sc, "layer", 20);
    A(@"    Layer");
    DumpSels(sc, "Layer", 20);
    A(@"");

    A(@"[B] FBScene 的 ivar：");
    DumpIvars(sc);
    A(@"");

    // 尝试几种取 layerManager 的写法
    A(@"[C] respondsToSelector 检查：");
    A(@"  layerManager      = %d", [scene respondsToSelector:@selector(layerManager)]);
    A(@"  _layerManager     = %d", [scene respondsToSelector:NSSelectorFromString(@"_layerManager")]);
    A(@"  layerHost         = %d", [scene respondsToSelector:NSSelectorFromString(@"layerHost")]);
    A(@"");

    id lm = nil;
    if ([scene respondsToSelector:@selector(layerManager)]) {
        @try { lm = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(layerManager)); }
        @catch (NSException *e) { A(@"layerManager EXC %@", e.reason); }
    }
    if (!lm) lm = GetIvar(scene, "_layerManager");
    A(@"layerManager 实例 = %@ (%@)", lm ? @"OK" : @"NIL", lm ? NSStringFromClass([lm class]) : @"-");

    if (lm) {
        Class lmc = object_getClass(lm);
        A(@"");
        A(@"[D] layerManager 里含 layer 的方法：");
        DumpSels(lmc, "layer", 25);
        A(@"");
        A(@"[E] layerManager 的 ivar：");
        DumpIvars(lmc);
        A(@"");

        A(@"[F] 尝试读图层：");
        A(@"  responds layers   = %d", [lm respondsToSelector:@selector(layers)]);
        A(@"  responds _layers  = %d", [lm respondsToSelector:NSSelectorFromString(@"_layers")]);

        for (NSString *sel in @[@"layers", @"_layers", @"allLayers"]) {
            SEL s = NSSelectorFromString(sel);
            if (![lm respondsToSelector:s]) { A(@"  %@ -> 不存在", sel); continue; }
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)(lm, s);
                A(@"  %@ -> %@ (%lu)", sel, v ? NSStringFromClass([v class]) : @"nil",
                  (unsigned long)([v respondsToSelector:@selector(count)] ? [v count] : 0));
            } @catch (NSException *e) { A(@"  %@ EXC %@", sel, e.reason); }
        }

        // 从 ivar 里翻
        for (NSString *ivn in @[@"_layers", @"_layerMap", @"_layersByIdentifier"]) {
            id v = GetIvar(lm, [ivn UTF8String]);
            if (v) A(@"  ivar %@ -> %@ (%lu)", ivn, NSStringFromClass([v class]),
                     (unsigned long)([v respondsToSelector:@selector(count)] ? [v count] : 0));
        }
    }

    Flush();
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
    h.text = @"MW16 Stage 3 · 图层探测";
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
    [go setTitle:@"探测" forState:UIControlStateNormal];
    go.backgroundColor = [UIColor systemBlueColor];
    [go setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
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
    A(@"输入 bundle id 后点「探测」。");
    A(@"注意：目标 App 需要先在后台跑着（先手动打开它再回来）。");
}

- (void)hidePanel { if (gPanelWin) { gPanelWin.hidden = YES; gPanelWin = nil; } }

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self goTapped]; return YES; }

- (void)goTapped {
    NSString *bid = [self.field.text stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!bid.length) { A(@"先输入 bundle id"); return; }
    [self.field resignFirstResponder];
    if (!gOut) gOut = [NSMutableString string];
    DumpSceneLayers(bid);
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
