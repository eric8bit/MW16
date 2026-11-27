#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "MWHeaders16.h"
#import "MWSceneBridge.h"
#import "MWSession.h"
#import "MWWindowHost.h"
#import "MWWindowView.h"
#import "MWPrefs.h"
#import "MWSettingsUI.h"

#define T_LOG(fmt, ...) NSLog(@"[MW16] " fmt, ##__VA_ARGS__)

extern BOOL MWSessionShouldKeepBundle(NSString *bundleID);
extern BOOL MWSessionShouldKeepScene(NSString *sceneID);
extern BOOL MWSessionHasAny(void);

// ---------------------------------------------------------------------------
// 多任务卡片长按 / 图标菜单 入口
// ---------------------------------------------------------------------------
static NSString *MWBundleIDFromLayout(id layout) {
    if (!layout) return nil;
    if ([layout respondsToSelector:@selector(allItems)]) {
        for (id item in ((id (*)(id, SEL))objc_msgSend)(layout, @selector(allItems))) {
            if ([item respondsToSelector:@selector(bundleIdentifier)]) {
                NSString *b = ((id (*)(id, SEL))objc_msgSend)(item, @selector(bundleIdentifier));
                if (b.length) return b;
            }
        }
    }
    if ([layout respondsToSelector:@selector(centerItem)]) {
        id item = ((id (*)(id, SEL))objc_msgSend)(layout, @selector(centerItem));
        if ([item respondsToSelector:@selector(bundleIdentifier)])
            return ((id (*)(id, SEL))objc_msgSend)(item, @selector(bundleIdentifier));
    }
    return nil;
}

static void MWOpenWindowForBundle(NSString *bundleID) {
    if (!bundleID.length) return;
    if ([MWSession sessionForBundleID:bundleID]) {
        T_LOG(@"%@ already windowed", bundleID);
        return;
    }
    MWSession *s = [MWSession sessionForBundleIDCreating:bundleID];
    if (![s start]) {
        T_LOG(@"failed to open window for %@", bundleID);
    }
}

static void MWDismissSwitcher(void) {
    Class mc = NSClassFromString(@"SBMainSwitcherViewController");
    Class lc = NSClassFromString(@"SBAppLayout");
    id sw = [mc respondsToSelector:@selector(sharedInstance)] ? ((id (*)(id, SEL))objc_msgSend)((id)mc, @selector(sharedInstance)) : nil;
    SEL sel = NSSelectorFromString(@"_dismissSwitcherNoninteractivelyToAppLayout:dismissFloatingSwitcher:animated:");
    if (!sw || ![sw respondsToSelector:sel] || ![lc respondsToSelector:@selector(homeScreenAppLayout)]) return;
    id home = ((id (*)(id, SEL))objc_msgSend)((id)lc, @selector(homeScreenAppLayout));
    ((BOOL (*)(id, SEL, id, BOOL, BOOL))objc_msgSend)(sw, sel, home, YES, YES);
}

%group gSwitcherContainer
%hook SBFluidSwitcherItemContainer
- (id)initWithFrame:(CGRect)frame {
    id r = %orig;
    if (r) {
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:r action:@selector(mw16_longPress:)];
        [(UIView *)r addGestureRecognizer:lp];
    }
    return r;
}
%new
- (void)mw16_longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    id layout = [self respondsToSelector:@selector(appLayout)] ? [self appLayout] : nil;
    NSString *bid = MWBundleIDFromLayout(layout);
    if (!bid) return;
    MWOpenWindowForBundle(bid);
    MWDismissSwitcher();
}
%end
%end

// ---------------------------------------------------------------------------
// 图标菜单入口
// ---------------------------------------------------------------------------
// 图标快捷菜单：只在系统确实有这个 selector 时才 hook，避免 %orig 调用空实现导致崩溃
%group gIconShortcut
%hook SBIconView
- (NSArray *)applicationShortcutItems {
    NSArray *orig = %orig;
    NSString *bid = [self respondsToSelector:@selector(applicationBundleIdentifier)]
                     ? [self applicationBundleIdentifier] : nil;
    if (!bid.length) return orig;

    Class sc = NSClassFromString(@"SBSApplicationShortcutItem");
    if (!sc) return orig;
    id item = ((id (*)(id, SEL))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)sc, @selector(alloc)), @selector(init));
    if (!item) return orig;
    @try {
        [item setValue:@"Open in Window" forKey:@"localizedTitle"];
        [item setValue:bid forKey:@"bundleIdentifierToLaunch"];
        [item setValue:@"com.mw16.openwindow" forKey:@"type"];
    } @catch (NSException *e) { return orig; }

    return orig ? [orig arrayByAddingObject:item] : @[item];
}

+ (void)activateShortcut:(id)item withBundleIdentifier:(NSString *)bundleID forIconView:(id)iconView {
    BOOL ours = NO;
    @try {
        ours = [[item valueForKey:@"type"] isEqualToString:@"com.mw16.openwindow"];
    } @catch (NSException *e) { ours = NO; }
    if (ours) {
        MWOpenWindowForBundle(bundleID);
        return;
    }
    %orig;
}
%end
%end

// ---------------------------------------------------------------------------
// 场景保活：iOS 16 只有两层，第三层是 iOS 17+ 的
// ---------------------------------------------------------------------------
%hook FBScene
- (void)updateSettings:(id)settings withTransitionContext:(id)ctx {
    if (MWSessionHasAny()) {
        @try {
            id ms = [settings respondsToSelector:@selector(mutableCopy)] ? [settings mutableCopy] : nil;
            NSString *sid = [self respondsToSelector:@selector(identifier)] ? [self identifier] : nil;
            if (ms && sid && MWSessionShouldKeepScene(sid) && [ms respondsToSelector:@selector(setForeground:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(ms, @selector(setForeground:), YES);
                %orig(ms, ctx);
                return;
            }
        } @catch (NSException *e) {}
    }
    %orig;
}

- (void)updateSettings:(id)settings withTransitionContext:(id)ctx completion:(id)completion {
    if (MWSessionHasAny()) {
        @try {
            id ms = [settings respondsToSelector:@selector(mutableCopy)] ? [settings mutableCopy] : nil;
            NSString *sid = [self respondsToSelector:@selector(identifier)] ? [self identifier] : nil;
            if (ms && sid && MWSessionShouldKeepScene(sid) && [ms respondsToSelector:@selector(setForeground:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(ms, @selector(setForeground:), YES);
                %orig(ms, ctx, completion);
                return;
            }
        } @catch (NSException *e) {}
    }
    %orig;
}
%end

%hook UIMutableApplicationSceneSettings
- (void)setDeactivationReasons:(unsigned long long)reasons {
    // 只放行"我们管理的"场景，绝不全局屏蔽（原版那个分支会误伤所有 App）
    if (reasons != 0 && MWSessionHasAny()) {
        NSString *ident = nil;
        for (NSString *k in @[@"_identifier", @"_sceneIdentifier"]) {
            ident = MW_GetIvar(self, [k UTF8String]);
            if (ident.length) break;
        }
        if (ident.length && MWSessionShouldKeepScene(ident)) {
            %orig(0);
            return;
        }
    }
    %orig;
}
%end

// iOS 17+ 才有，用 group 包起来，类不存在就不 init
%group gIOS17
%hook _UISceneHostingActivationStateHostComponent
- (void)setForeground:(BOOL)fg {
    if (!fg && MWSessionHasAny()) {
        @try {
            id hs = [self respondsToSelector:@selector(hostScene)] ? [self hostScene] : nil;
            if (hs && [hs respondsToSelector:@selector(identifier)]) {
                NSString *sid = ((id (*)(id, SEL))objc_msgSend)(hs, @selector(identifier));
                if (sid && MWSessionShouldKeepScene(sid)) { %orig(YES); return; }
            }
        } @catch (NSException *e) {}
    }
    %orig;
}
%end
%end

// ---------------------------------------------------------------------------
// 图层变化 → 刷新窗口（带节流）
// ---------------------------------------------------------------------------
static void MWScheduleLayerRefresh(void) {
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        scheduled = NO;
        for (MWSession *s in [MWSession allSessions]) {
            [s.windowView refreshLayers];
        }
    });
}

%hook FBSceneLayerManager
- (void)_setLayers:(id)layers {
    %orig;
    MWScheduleLayerRefresh();
}
%end

// ---------------------------------------------------------------------------
// App 退出：清掉对应窗口，避免残留
// ---------------------------------------------------------------------------
%hook SBApplication
- (void)_didExitWithContext:(id)ctx {
    NSString *bid = [self respondsToSelector:@selector(bundleIdentifier)] ? [self bundleIdentifier] : nil;
    if (bid.length) {
        MWSession *s = [MWSession sessionForBundleID:bid];
        if (s) [s invalidate];
    }
    %orig;
}
%end

// ---------------------------------------------------------------------------
// SpringBoard 启动：建宿主窗口 + 挂设置按钮
// ---------------------------------------------------------------------------
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)app {
    %orig;
    [[MWPrefs shared] reload];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[MWWindowHost shared] attach];
        [MWSettingsUI setupIfNeeded];
    });
}
%end

%hook SBHomeScreenView
- (void)didMoveToWindow {
    %orig;
    if (self.window) [MWSettingsUI attachToWindow:self.window];
}
%end

%ctor {
    @autoreleasepool {
        T_LOG(@"loaded on iOS %@", [[UIDevice currentDevice] systemVersion]);
        if (objc_getClass("_UISceneHostingActivationStateHostComponent")) %init(gIOS17);

        // 切换器卡片：只有系统真的有这个类才 hook
        Class switcherCls = objc_getClass("SBFluidSwitcherItemContainer");
        if (switcherCls && [(id)switcherCls instancesRespondToSelector:@selector(initWithFrame:)]) {
            %init(gSwitcherContainer);
        } else {
            T_LOG(@"SBFluidSwitcherItemContainer 不存在，跳过卡片长按 hook");
        }
        // 两个 selector 都必须存在，否则 %orig 会调到空实现直接崩
        Class iconCls = objc_getClass("SBIconView");
        BOOL hasIconAM = iconCls && [(id)iconCls instancesRespondToSelector:@selector(applicationShortcutItems)];
        BOOL hasIconAS = iconCls && [(id)iconCls respondsToSelector:@selector(activateShortcut:withBundleIdentifier:forIconView:)];
        if (hasIconAM && hasIconAS) {
            %init(gIconShortcut);
        } else {
            T_LOG(@"SBIconView 快捷菜单接口不全 (items=%d, activate=%d)，跳过", hasIconAM, hasIconAS);
        }
        %init;   // 默认组（所有未分组的 hook）必须手动初始化
    }
}
