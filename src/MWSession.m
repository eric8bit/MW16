#import "MWSession.h"
#import "MWSceneBridge.h"
#import "MWWindowView.h"
#import "MWWindowHost.h"
#import "MWPrefs.h"

#define S_LOG(fmt, ...) NSLog(@"[MW16.session] " fmt, ##__VA_ARGS__)

static NSMutableArray<MWSession *> *gSessions = nil;
static NSMutableArray<MWSession *> *gAll(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSessions = [NSMutableArray array]; });
    return gSessions;
}

// --- 供 hook 查询：这个 bundle/scene 是否要保持前台 ---
BOOL MWSessionShouldKeepBundle(NSString *bundleID) {
    if (!bundleID.length) return NO;
    for (MWSession *s in gAll()) {
        if (s.invalidated) continue;
        if ([bundleID isEqualToString:s.bundleID] || [bundleID hasPrefix:s.bundleID]) return YES;
    }
    return NO;
}

BOOL MWSessionShouldKeepScene(NSString *sceneID) {
    if (!sceneID.length) return NO;
    for (MWSession *s in gAll()) {
        if (s.invalidated) continue;
        if ([sceneID isEqualToString:s.scene.identifier] || [sceneID hasPrefix:s.bundleID]) return YES;
    }
    return NO;
}

BOOL MWSessionHasAny(void) {
    for (MWSession *s in gAll()) if (!s.invalidated) return YES;
    return NO;
}

@interface MWSession ()
@property (nonatomic, copy, readwrite) NSString *bundleID;
@property (nonatomic, strong, readwrite) FBScene *scene;
@property (nonatomic, strong) dispatch_source_t keepAlive;
@end

@implementation MWSession

+ (instancetype)sessionForBundleID:(NSString *)bundleID {
    for (MWSession *s in gAll()) {
        if (!s.invalidated && [s.bundleID isEqualToString:bundleID]) return s;
    }
    return nil;
}

+ (NSArray<MWSession *> *)allSessions { return [gAll() copy]; }

+ (MWSession *)sessionForWindowView:(MWWindowView *)view {
    for (MWSession *s in gAll()) if (s.windowView == view) return s;
    return nil;
}

+ (instancetype)sessionForBundleIDCreating:(NSString *)bundleID {
    MWSession *s = [self sessionForBundleID:bundleID];
    if (s) return s;
    s = [MWSession new];
    s.bundleID = bundleID;
    [gAll() addObject:s];
    return s;
}

- (BOOL)start {
    if (self.invalidated) return NO;
    if (self.windowView) return YES;

    self.scene = [MWSceneBridge sceneForBundleID:self.bundleID];
    if (!self.scene) {
        S_LOG(@"start failed: no scene for %@", self.bundleID);
        [self invalidate];   // 别把失败的 session 留在列表里，否则保活 hook 会一直放行
        return NO;
    }

    [self pushForeground:YES];

    UIView *container = [MWSceneBridge hostContainerForScene:self.scene];
    if (!container) {
        S_LOG(@"start failed: no container for %@", self.bundleID);
        [self invalidate];
        return NO;
    }

    MWWindowHost *host = [MWWindowHost shared];
    [host attach];

    MWWindowView *wv = [[MWWindowView alloc] initWithContentView:container
                                                      identifier:self.bundleID
                                                           scene:self.scene];
    self.windowView = wv;
    [host attachWindowView:wv];

    [self acquireAssertion];
    [self startKeepAlive];

    // 首帧：立刻铺一次图层。等 _setLayers: 回调可能延迟或不来，
    // 不主动刷一次的话窗口会先黑着。
    [wv refreshLayers];

    S_LOG(@"window started for %@", self.bundleID);
    return YES;
}

- (void)pushForeground:(BOOL)fg {
    [MWSceneBridge setScene:self.scene foreground:fg];
}

- (void)acquireAssertion {
    Class targetC = NSClassFromString(@"RBSTarget");
    Class attrC   = NSClassFromString(@"RBSLegacyAttribute");
    Class asrtC   = NSClassFromString(@"RBSAssertion");
    if (!targetC || !attrC || !asrtC) return;

    int pid = 0;
    Class ctrlC = NSClassFromString(@"SBApplicationController");
    id ctrl = [(id)ctrlC respondsToSelector:@selector(sharedInstance)]
                ? ((id (*)(id, SEL))objc_msgSend)((id)ctrlC, @selector(sharedInstance)) : nil;
    SBApplication *app = [ctrl respondsToSelector:@selector(applicationWithBundleIdentifier:)]
                ? ((id (*)(id, SEL, id))objc_msgSend)(ctrl, @selector(applicationWithBundleIdentifier:), self.bundleID)
                : nil;
    id ps = [app respondsToSelector:@selector(processState)] ? [app processState] : nil;
    if (ps && [ps respondsToSelector:NSSelectorFromString(@"pid")]) {
        pid = ((int (*)(id, SEL))objc_msgSend)(ps, NSSelectorFromString(@"pid"));
    }
    if (pid <= 0) { S_LOG(@"no pid for %@", self.bundleID); return; }

    @try {
        id target = ((id (*)(id, SEL, int))objc_msgSend)((id)targetC, @selector(targetWithPid:), pid);
        NSUInteger flags = BKSProcessAssertionPreventTaskSuspend |
                           BKSProcessAssertionPreventTaskThrottleDown |
                           BKSProcessAssertionWantsForegroundPriority;
        id attr = ((id (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)((id)attrC,
            @selector(attributeWithReason:flags:), (NSUInteger)BKSProcessAssertionReasonBackgroundUI, flags);
        id asrt = ((id (*)(id, SEL, NSString *, id, NSArray *))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)asrtC, @selector(alloc)),
            @selector(initWithExplanation:target:attributes:), @"MW16 keep alive", target, @[attr]);
        NSError *err = nil;
        BOOL ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(asrt, @selector(acquireWithError:), &err);
        if (ok) {
            self.processAssertion = asrt;   // strong hold，别让 ARC 回收
            S_LOG(@"assertion OK pid=%d", pid);
        } else {
            S_LOG(@"assertion FAILED pid=%d err=%@", pid, err);
        }
    } @catch (NSException *e) { S_LOG(@"assertion ex %@", e); }
}

- (void)startKeepAlive {
    [self stopKeepAlive];
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);   // 2s，比原版 1s 轻一半
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        typeof(self) s = weakSelf;
        if (!s || s.invalidated) return;
        [s pushForeground:YES];
    });
    dispatch_resume(t);
    self.keepAlive = t;
}

- (void)stopKeepAlive {
    if (self.keepAlive) {
        dispatch_source_cancel(self.keepAlive);
        self.keepAlive = nil;
    }
}

- (void)invalidate {
    if (self.invalidated) return;
    self.invalidated = YES;
    S_LOG(@"invalidate %@", self.bundleID);

    [self stopKeepAlive];

    if (self.processAssertion && [self.processAssertion respondsToSelector:@selector(invalidate)])
        [(id)self.processAssertion invalidate];
    self.processAssertion = nil;

    // 关键：撤销前台白名单，否则 App 会被永久钉在前台
    [self pushForeground:NO];

    [self.windowView removeFromSuperview];
    self.windowView = nil;
    self.scene = nil;

    [gAll() removeObject:self];
}

@end
