#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

// MW16 Stage 2 v2 —— 私有 API 探测（只读，不改任何东西）
// 目的：把 FBSceneManager / SBMainWorkspace / SBSceneManager 的真实
//       方法名和 ivar 名打到屏幕上，据此修正场景枚举逻辑。

#define S2_LOG @"/var/mobile/Media/mw16_stage2.log"

static NSMutableString *gOut = nil;
static UITextView *gTextView = nil;
static UIWindow *gPanelWin = nil;

static void A(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!gOut) gOut = [NSMutableString string];
    [gOut appendFormat:@"%@\n", s];
    NSLog(@"[MW16-S2] %@", s);
}

static BOOL HasSel(id obj, NSString *name) {
    return obj && [obj respondsToSelector:NSSelectorFromString(name)];
}

// 打印类（含父类）里匹配 needle 的方法名
static void DumpMethods(Class cls, const char *needle, int limit) {
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
    if (!names.count) { A(@"  (no match %s)", needle ? needle : "*"); return; }
    [names sortUsingSelector:@selector(compare:)];
    int shown = 0;
    for (NSString *s in names) {
        if (shown >= limit) { A(@"  ... +%lu more", (unsigned long)(names.count - shown)); break; }
        A(@"  -%@", s);
        shown++;
    }
}

static void DumpIvars(Class cls) {
    if (!cls) { A(@"  (class nil)"); return; }
    NSMutableArray *names = [NSMutableArray array];
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = ivar_getName(ivs[i]);
            if (nm) {
                NSString *s = [NSString stringWithUTF8String:nm];
                if (s && ![names containsObject:s]) [names addObject:s];
            }
        }
        if (ivs) free(ivs);
    }
    if (!names.count) { A(@"  (no ivars)"); return; }
    int shown = 0;
    for (NSString *s in names) {
        if (shown >= 40) { A(@"  ... +%lu more", (unsigned long)(names.count - shown)); break; }
        A(@"  @%@", s);
        shown++;
    }
}

static id CallCls(Class cls, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!cls || ![(id)cls respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, s);
}

static id CallObj(id obj, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, s);
}

static void CountColl(NSString *label, id v) {
    if (!v) { A(@"%@ = nil", label); return; }
    if ([v isKindOfClass:[NSArray class]]) { A(@"%@ = NSArray(%lu)", label, (unsigned long)[(NSArray *)v count]); return; }
    if ([v isKindOfClass:[NSSet class]]) { A(@"%@ = NSSet(%lu)", label, (unsigned long)[(NSSet *)v count]); return; }
    if ([v isKindOfClass:[NSDictionary class]]) { A(@"%@ = NSDict(%lu)", label, (unsigned long)[(NSDictionary *)v count]); return; }
    A(@"%@ = %@", label, NSStringFromClass([v class]));
}

static void RunDump(void) {
    if (!gOut) gOut = [NSMutableString string];
    [gOut setString:@""];

    A(@"iOS %@  %@", [[UIDevice currentDevice] systemVersion], [[UIDevice currentDevice] model]);
    A(@"");

    // ---- 1. FBSceneManager ----
    Class fb = NSClassFromString(@"FBSceneManager");
    A(@"[1] FBSceneManager = %@", fb ? @"YES" : @"NO");
    if (fb) {
        DumpMethods(fb, "scene", 14);
        DumpMethods(fb, "Scene", 10);
    }
    A(@"");

    // ---- 2. SBMainWorkspace ----
    Class mws = NSClassFromString(@"SBMainWorkspace");
    A(@"[2] SBMainWorkspace = %@", mws ? @"YES" : @"NO");
    if (mws) DumpMethods(mws, "cene", 14);
    A(@"");

    // ---- 3. SBSceneManager ----
    Class sbs = NSClassFromString(@"SBSceneManager");
    A(@"[3] SBSceneManager = %@", sbs ? @"YES" : @"NO");
    if (sbs) DumpMethods(sbs, "cene", 18);
    A(@"");

    // ---- 4. 实例探测 ----
    A(@"[4] instances");
    id fbInst = CallCls(fb, @"sharedInstance");
    A(@"FBSceneManager.shared = %@", fbInst ? NSStringFromClass([fbInst class]) : @"nil");
    if (fbInst) {
        CountColl(@"  .allScenes", CallObj(fbInst, @"allScenes"));
        CountColl(@"  .scenes", CallObj(fbInst, @"scenes"));
        CountColl(@"  .scenesByID", CallObj(fbInst, @"scenesByID"));
        A(@"  --- ivars ---");
        DumpIvars(object_getClass(fbInst));
    }
    A(@"");

    id wsInst = CallCls(mws, @"sharedInstance");
    A(@"SBMainWorkspace.shared = %@", wsInst ? @"ok" : @"nil");
    if (wsInst) {
        id sm = CallObj(wsInst, @"sceneManager");
        A(@"  .sceneManager = %@ (%@)", sm ? @"ok" : @"nil", sm ? NSStringFromClass([sm class]) : @"-");
        if (sm) {
            A(@"  --- ivars of sceneManager ---");
            DumpIvars(object_getClass(sm));
        }
    }
    A(@"");

    // ---- 5. 顶层尝试 ----
    A(@"[5] final tries");
    NSArray *cands = @[@"allScenes", @"scenes", @"_allScenes", @"scenesByID", @"_scenesByID"];
    for (NSString *c in cands) {
        CountColl([NSString stringWithFormat:@"fb.%@", c], CallObj(fbInst, c));
    }
    if (wsInst) {
        id sm = CallObj(wsInst, @"sceneManager");
        for (NSString *c in cands) {
            CountColl([NSString stringWithFormat:@"sm.%@", c], CallObj(sm, c));
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (gTextView) {
            gTextView.text = gOut;
        }
        @try {
            [gOut writeToFile:S2_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) {}
    });
}

static void ShowPanel(void) {
    UIWindowScene *ws = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (!ws) ws = (UIWindowScene *)s;
        if (s.activationState == UISceneActivationStateForegroundActive) { ws = (UIWindowScene *)s; break; }
    }
    UIWindow *w = ws ? [[UIWindow alloc] initWithWindowScene:ws]
                     : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.frame = [UIScreen mainScreen].bounds;
    w.windowLevel = UIWindowLevelAlert + 900;
    w.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    w.rootViewController = vc;

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(8, 50, w.bounds.size.width - 16, w.bounds.size.height - 120)];
    tv.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    tv.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
    tv.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    tv.editable = NO;
    tv.text = @"扫描中...";
    [vc.view addSubview:tv];
    gTextView = tv;

    UILabel *hdr = [[UILabel alloc] initWithFrame:CGRectMake(12, 14, w.bounds.size.width - 24, 30)];
    hdr.text = @"MW16 Stage2 · API 探测";
    hdr.textColor = [UIColor whiteColor];
    hdr.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [vc.view addSubview:hdr];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(w.bounds.size.width - 56, 10, 44, 34);
    [btn setTitle:@"X" forState:UIControlStateNormal];
    [btn addTarget:vc action:@selector(dismissViewControllerAnimated:completion:) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:btn];

    w.hidden = NO;
    gPanelWin = w;

    RunDump();
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ShowPanel(); });
}
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ if (!gPanelWin) ShowPanel(); });
    %init;
}
