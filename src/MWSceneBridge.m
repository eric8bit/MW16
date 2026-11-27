#import "MWSceneBridge.h"
#import "MWHeaders16.h"

#define MWB_LOG(fmt, ...) NSLog(@"[MW16.bridge] " fmt, ##__VA_ARGS__)

@implementation MWSceneBridge

#pragma mark - Scene lookup (method first, ivar fallback)

+ (FBScene *)sceneForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;

    // 1) FBSceneManager -sceneWithIdentifier:  (iOS 13~16 主力路径)
    Class fbsm = NSClassFromString(@"FBSceneManager");
    id mgr = [fbsm respondsToSelector:@selector(sharedInstance)] ? ((id (*)(id, SEL))objc_msgSend)((id)fbsm, @selector(sharedInstance)) : nil;
    if (mgr && [mgr respondsToSelector:NSSelectorFromString(@"sceneWithIdentifier:")]) {
        id s = ((id (*)(id, SEL, id))objc_msgSend)(mgr, NSSelectorFromString(@"sceneWithIdentifier:"), bundleID);
        if (s) return s;
    }

    // 2) SBMainWorkspace.sceneManager
    Class mainWS = NSClassFromString(@"SBMainWorkspace");
    id ws = [mainWS respondsToSelector:@selector(sharedInstance)] ? ((id (*)(id, SEL))objc_msgSend)((id)mainWS, @selector(sharedInstance)) : nil;
    if ([ws respondsToSelector:@selector(sceneManager)]) {
        id sceneMgr = ((id (*)(id, SEL))objc_msgSend)(ws, @selector(sceneManager));
        if ([sceneMgr respondsToSelector:@selector(sceneWithIdentifier:)]) {
            id s = ((id (*)(id, SEL, id))objc_msgSend)(sceneMgr, @selector(sceneWithIdentifier:), bundleID);
            if (s) return s;
        }
    }

    // 3) 遍历 allScenes，按 identifier 前缀匹配
    id managers[2] = { mgr, nil };
    if ([ws respondsToSelector:@selector(sceneManager)]) managers[1] = ((id (*)(id, SEL))objc_msgSend)(ws, @selector(sceneManager));
    for (int i = 0; i < 2; i++) {
        id m = managers[i];
        if (!m || ![m respondsToSelector:@selector(allScenes)]) continue;
        for (id s in ((id (*)(id, SEL))objc_msgSend)(m, @selector(allScenes))) {
            if (![s respondsToSelector:@selector(identifier)]) continue;
            NSString *sid = [s identifier];
            // scene identifier 形如 "com.tencent.xin" 或 "com.apple.mobilesafari-<uuid>"
            if ([sid isEqualToString:bundleID] || [sid hasPrefix:bundleID]) return s;
        }
    }

    // 4) 最后的兜底：只扫一层已知字典 ivar（不做深层递归，避免耗时）
    if (mgr) {
        const char *names[] = { "_scenesByID", "_scenes", "_allScenesByID" };
        for (int i = 0; i < 3; i++) {
            id dict = MW_GetIvar(mgr, names[i]);
            if ([dict isKindOfClass:[NSDictionary class]]) {
                id s = dict[bundleID];
                if (s) return s;
                for (id k in dict) {
                    if ([k isKindOfClass:[NSString class]] && [k hasPrefix:bundleID]) return dict[k];
                }
            }
        }
    }

    MWB_LOG(@"scene NOT FOUND for %@", bundleID);
    return nil;
}

#pragma mark - Host container

+ (UIView *)hostContainerForScene:(FBScene *)scene {
    if (!scene) return nil;
    Class c = NSClassFromString(@"_UISceneLayerHostContainerView");
    if (!c) { MWB_LOG(@"_UISceneLayerHostContainerView MISSING"); return nil; }

    id container = nil;
    if ([(id)c instancesRespondToSelector:@selector(initWithScene:debugDescription:)]) {
        container = ((id (*)(id, SEL, id, id))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)c, @selector(alloc)),
            @selector(initWithScene:debugDescription:), scene, @"MW16");
    } else if ([(id)c instancesRespondToSelector:@selector(initWithScene:)]) {
        container = ((id (*)(id, SEL, id))objc_msgSend)(((id (*)(id, SEL))objc_msgSend)((id)c, @selector(alloc)),
            @selector(initWithScene:), scene);
    }
    if (!container) { MWB_LOG(@"container init failed"); return nil; }

    // iOS 16 的 initWithScene: 不会自动铺图层，需要手动建 host view
    if ([container respondsToSelector:@selector(_createHostViewForLayer:)] &&
        [scene respondsToSelector:@selector(layerManager)]) {
        id lm = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(layerManager));
        id layers = [lm respondsToSelector:@selector(layers)] ? ((id (*)(id, SEL))objc_msgSend)(lm, @selector(layers)) : nil;
        if ([layers isKindOfClass:[NSArray class]] && [layers count] > 0) {
            UIView *containerView = (UIView *)container;
            for (UIView *old in [containerView.subviews copy]) [old removeFromSuperview];
            for (id layer in layers) {
                UIView *hv = ((id (*)(id, SEL, id))objc_msgSend)(container, @selector(_createHostViewForLayer:), layer);
                if (!hv) continue;
                hv.frame = ((UIView *)container).bounds;
                hv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [(UIView *)container addSubview:hv];
            }
        }
    }
    return (UIView *)container;
}

+ (BOOL)sceneHasLayers:(FBScene *)scene {
    if (!scene || ![scene respondsToSelector:@selector(layerManager)]) return NO;
    id lm = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(layerManager));
    id layers = [lm respondsToSelector:@selector(layers)] ? ((id (*)(id, SEL))objc_msgSend)(lm, @selector(layers)) : nil;
    return [layers isKindOfClass:[NSArray class]] && [layers count] > 0;
}

#pragma mark - Frame

+ (void)updateFrame:(CGRect)frame forScene:(FBScene *)scene {
    if (!scene) return;
    @try {
        id ms = [scene respondsToSelector:@selector(mutableSettings)] ? [scene mutableSettings] : nil;
        if (!ms || ![ms respondsToSelector:@selector(setFrame:)]) return;
        ((void (*)(id, SEL, CGRect))objc_msgSend)(ms, @selector(setFrame:), frame);
        if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:)])
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, @selector(updateSettings:withTransitionContext:), ms, nil);
    } @catch (NSException *e) {
        MWB_LOG(@"updateFrame ex %@", e);
    }
}

#pragma mark - Foreground control

+ (void)setScene:(FBScene *)scene foreground:(BOOL)fg {
    if (!scene) return;
    @try {
        id settings = [scene settings];
        id ms = [settings respondsToSelector:@selector(mutableCopy)] ? [settings mutableCopy] : nil;
        if (ms && [ms respondsToSelector:@selector(setForeground:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(ms, @selector(setForeground:), fg);
            // 同时清掉失活原因，否则 iOS 16 上只改 foreground 不够
            if (!fg && [ms respondsToSelector:@selector(setDeactivationReasons:)]) {
                ((void (*)(id, SEL, unsigned long long))objc_msgSend)(ms,
                    @selector(setDeactivationReasons:), 2ULL);  // 2 = 用户主动切走，允许挂起
            } else if (fg && [ms respondsToSelector:@selector(setDeactivationReasons:)]) {
                ((void (*)(id, SEL, unsigned long long))objc_msgSend)(ms,
                    @selector(setDeactivationReasons:), 0ULL);
            }
            if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:)]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(scene,
                    @selector(updateSettings:withTransitionContext:), ms, nil);
            } else if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:completion:)]) {
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene,
                    @selector(updateSettings:withTransitionContext:completion:), ms, nil, nil);
            }
        }
    } @catch (NSException *e) {
        MWB_LOG(@"setScene foreground ex %@", e);
    }
}

#pragma mark - Keyboard host


+ (UIWindow *)keyboardHostWindow {
    static UIWindow *kbWin = nil;
    if (kbWin) return kbWin;

    UIWindowScene *ws = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { ws = (UIWindowScene *)s; break; }
    }
    kbWin = ws ? [[UIWindow alloc] initWithWindowScene:ws] : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    kbWin.frame = [UIScreen mainScreen].bounds;
    kbWin.backgroundColor = [UIColor clearColor];
    kbWin.windowLevel = UIWindowLevelAlert + 1000;
    kbWin.hidden = NO;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    kbWin.rootViewController = vc;
    return kbWin;
}

@end
