#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <string.h>
#import <unistd.h>
#import <stdlib.h>

// ---------------------------------------------------------------------------
//  MW16 Probe — iOS 16.x / Relaxin(roothide)
//  只读取信息，不修改任何系统行为。
//  装好后 respring，然后：
//     tail -f /var/mobile/Library/Preferences/mw16_probe.log
//  或 Console.app 过滤 "MW16Probe"。
//  跑完后把日志整段发回来，据此确定最终实现。
// ---------------------------------------------------------------------------

#define PROBE_LOG_PATH @"/var/mobile/Library/Preferences/mw16_probe.log"

// SpringBoard 类声明（%hook 需要编译期可见）
@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end

static dispatch_queue_t gProbeQ = nil;
static NSMutableString *gProbeBuf = nil;

static void MWAppendLog(NSString *line) {
    if (!gProbeQ) gProbeQ = dispatch_queue_create("mw16.probe.log", DISPATCH_QUEUE_SERIAL);
    dispatch_async(gProbeQ, ^{
        if (!gProbeBuf) gProbeBuf = [NSMutableString string];
        [gProbeBuf appendString:line];
        [gProbeBuf appendString:@"\n"];
        [gProbeBuf writeToFile:PROBE_LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}

#define PLOG(fmt, ...) do { \
    NSString *__l = [NSString stringWithFormat:@"[MW16Probe] " fmt, ##__VA_ARGS__]; \
    NSLog(@"%@", __l); \
    MWAppendLog(__l); \
} while (0)

static id MWIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return (__bridge id)(*(void **)((__bridge void *)obj + ivar_getOffset(iv)));
    }
    return nil;
}

static void MWDumpSelectors(Class cls, const char *needle, const char *tag) {
    if (!cls) { PLOG("%s: CLASS MISSING", tag); return; }
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    int hits = 0;
    if (ms) {
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = sel_getName(method_getName(ms[i]));
            if (!needle || strstr(nm, needle)) {
                PLOG("%s -[%s %s]", tag, class_getName(cls), nm);
                hits++;
            }
        }
        free(ms);
    }
    if (!hits) PLOG("%s: no selector matching \"%s\" on %s", tag, needle ? needle : "*", class_getName(cls));
}

static void MWDumpIvars(Class cls, const char *tag) {
    if (!cls) { PLOG("%s: CLASS MISSING", tag); return; }
    unsigned int n = 0;
    Ivar *ivs = class_copyIvarList(cls, &n);
    if (!ivs) return;
    for (unsigned int i = 0; i < n; i++) {
        PLOG("%s ivar %s : %s", tag, ivar_getName(ivs[i]), ivar_getTypeEncoding(ivs[i]) ?: "?");
    }
    free(ivs);
}

// ---------------------------------------------------------------------------
// [1] 场景查找能力 —— 决定 mw_createWindowForApp 怎么写
// ---------------------------------------------------------------------------
static void MWProbeScenes(void) {
    PLOG("================ [1] scene APIs ================");

    Class fbsm = objc_getClass("FBSceneManager");
    PLOG("FBSceneManager: %s", fbsm ? "found" : "MISSING");
    if (fbsm) {
        MWDumpSelectors(fbsm, "scene", "FBSceneManager");
        MWDumpSelectors(fbsm, "shared", "FBSceneManager");
    }

    Class sbsm = objc_getClass("SBSceneManager");
    PLOG("SBSceneManager: %s", sbsm ? "found" : "MISSING");
    if (sbsm) {
        MWDumpSelectors(sbsm, "scene", "SBSceneManager");
        MWDumpSelectors(sbsm, "all", "SBSceneManager");
    }

    Class mws = objc_getClass("SBMainWorkspace");
    PLOG("SBMainWorkspace: %s", mws ? "found" : "MISSING");
    if (mws) MWDumpSelectors(mws, "scene", "SBMainWorkspace");

    // 直接试 sceneWithIdentifier:
    id mgr = nil;
    if (fbsm && [fbsm respondsToSelector:@selector(sharedInstance)])
        mgr = ((id (*)(id, SEL))objc_msgSend)((id)fbsm, @selector(sharedInstance));
    PLOG("FBSceneManager.sharedInstance = %@", mgr);
    if (mgr) {
        MWDumpIvars(object_getClass(mgr), "FBSceneManager.inst");
        if ([mgr respondsToSelector:@selector(allScenes)]) {
            id all = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(allScenes));
            PLOG("allScenes count = %lu", (unsigned long)[all count]);
            for (id s in all) {
                NSString *sid = nil;
                if ([s respondsToSelector:@selector(identifier)]) sid = [s identifier];
                PLOG("  scene identifier = %@  class = %@", sid, NSStringFromClass([s class]));
            }
        }
        PLOG("responds sceneWithIdentifier: = %d",
             [mgr respondsToSelector:NSSelectorFromString(@"sceneWithIdentifier:")]);
    }
}

// ---------------------------------------------------------------------------
// [2] 图层宿主视图 —— 决定画面能不能挂出来（最关键）
// ---------------------------------------------------------------------------
static void MWProbeLayerHost(void) {
    PLOG("================ [2] layer host ================");
    Class c = objc_getClass("_UISceneLayerHostContainerView");
    PLOG("_UISceneLayerHostContainerView: %s", c ? "found" : "MISSING");
    if (c) {
        MWDumpSelectors(c, "init", "_UISceneLayerHostContainerView");
        MWDumpSelectors(c, "layer", "_UISceneLayerHostContainerView");
        MWDumpSelectors(c, "scene", "_UISceneLayerHostContainerView");
        MWDumpIvars(c, "_UISceneLayerHostContainerView");
    }
    Class k = objc_getClass("_UIKeyboardLayerHostView");
    PLOG("_UIKeyboardLayerHostView: %s", k ? "found" : "MISSING");
    Class e = objc_getClass("_UIExternalSceneLayerHostView");
    PLOG("_UIExternalSceneLayerHostView: %s", e ? "found" : "MISSING");
}

// ---------------------------------------------------------------------------
// [3] Medusa / Scale Mode 判定挂在哪
// ---------------------------------------------------------------------------
static void MWProbeMedusa(void) {
    PLOG("================ [3] medusa ================");
    const char *classes[] = { "SBApplication", "SBApplicationInfo", "SBApplicationController" };
    for (int i = 0; i < 3; i++) {
        Class c = objc_getClass(classes[i]);
        PLOG("%s: %s", classes[i], c ? "found" : "MISSING");
        if (c) {
            MWDumpSelectors(c, "Medusa", classes[i]);
            MWDumpSelectors(c, "medusa", classes[i]);
            MWDumpSelectors(c, "Split", classes[i]);
        }
    }
}

// ---------------------------------------------------------------------------
// [4] SpringBoard 的 window / windowScene 结构
// ---------------------------------------------------------------------------
static void MWProbeWindows(void) {
    PLOG("================ [4] windows ================");
    UIApplication *app = [UIApplication sharedApplication];
    PLOG("connectedScenes count = %lu", (unsigned long)app.connectedScenes.count);
    for (UIScene *s in app.connectedScenes) {
        PLOG("scene %@  class=%@ state=%ld", s, NSStringFromClass([s class]), (long)s.activationState);
        if ([s isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                PLOG("   window %@ class=%@ level=%f hidden=%d", w, NSStringFromClass([w class]),
                     (double)w.windowLevel, (int)w.hidden);
            }
        }
    }
    Class hw = objc_getClass("SBHomeScreenWindow");
    PLOG("SBHomeScreenWindow: %s", hw ? "found" : "MISSING");
}

// ---------------------------------------------------------------------------
// [5] RBS 断言自测 —— 决定“保活”走哪条路
// ---------------------------------------------------------------------------
static void MWProbeRBS(void) {
    PLOG("================ [5] RBS assertion ================");
    Class targetC = objc_getClass("RBSTarget");
    Class attrC   = objc_getClass("RBSLegacyAttribute");
    Class asrtC   = objc_getClass("RBSAssertion");
    PLOG("RBSTarget=%d RBSLegacyAttribute=%d RBSAssertion=%d",
         targetC != nil, attrC != nil, asrtC != nil);
    if (!targetC || !attrC || !asrtC) return;

    @try {
        id target = ((id (*)(id, SEL))objc_msgSend)((id)targetC, @selector(currentProcess));
        // 0x0D = PreventTaskSuspend | PreventTaskThrottleDown | WantsForegroundResourcePriority
        id attr = ((id (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(
            attrC, @selector(attributeWithReason:flags:), (NSUInteger)7, (NSUInteger)0x0D);
        PLOG("target=%@ attr=%@", target, attr);

        id asrt = ((id (*)(id, SEL, NSString *, id, NSArray *))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)asrtC, @selector(alloc)), @selector(initWithExplanation:target:attributes:),
            @"MW16 probe", target, @[attr]);
        NSError *err = nil;
        BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(asrt, @selector(acquireWithError:), &err);
        PLOG("acquireWithError = %d  error = %@", ok, err);
        if (ok && [asrt respondsToSelector:@selector(invalidate)]) {
            ((void (*)(id, SEL))objc_msgSend)(asrt, @selector(invalidate));
        }
    } @catch (NSException *e) {
        PLOG("RBS exception: %@", e);
    }
}

// ---------------------------------------------------------------------------
// [6] 运行时环境
// ---------------------------------------------------------------------------
static void MWProbeEnv(void) {
    PLOG("================ [6] env ================");
    PLOG("iOS = %@", [[UIDevice currentDevice] systemVersion]);
    BOOL hasVarJb = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
    PLOG("jailbreak type guess: %s", hasVarJb ? "rootless/roothide" : "rootful");
    PLOG("roothide jbroot env = %s", getenv("JBROOT") ?: "(null)");
    PLOG("pid = %d", getpid());
}

static void MWRunProbe(void) {
    PLOG("######## MW16 probe start ########");
    MWProbeEnv();
    MWProbeScenes();
    MWProbeLayerHost();
    MWProbeMedusa();
    MWProbeWindows();
    MWProbeRBS();
    PLOG("######## MW16 probe end ########");
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MWRunProbe();
    });
}
%end

%ctor {
    @autoreleasepool {
        gProbeQ = dispatch_queue_create("mw16.probe.log", DISPATCH_QUEUE_SERIAL);
        gProbeBuf = [NSMutableString string];
        [gProbeBuf appendString:[NSString stringWithFormat:@"\n===== MW16 probe %@ =====\n", [NSDate date]]];
    }
    %init;   // 自定义 %ctor 必须手动初始化，否则 hook 不生效
}
