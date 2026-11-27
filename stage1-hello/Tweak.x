#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
//  MW16 Stage 1 v2 —— 可见诊断版
//
//  改动：不再依赖"日志文件"来判断是否注入成功。
//  注入成功 → 屏幕正中会出现一块深色面板，写着 MW16 OK 和系统信息。
//  注入失败 → 什么都不会出现（和 v1 一样看不到任何东西）。
//
//  同时把日志写到 4 个位置，尽量保证至少有一个能写成功。
//  不 hook 任何私有 API，不改任何系统设置。
// ---------------------------------------------------------------------------

static NSArray<NSString *> *S1LogPaths(void) {
    return @[
        @"/var/mobile/Library/Preferences/mw16_stage1.log",
        @"/var/mobile/Media/mw16_stage1.log",
        @"/var/tmp/mw16_stage1.log",
        @"/tmp/mw16_stage1.log",
    ];
}

static void S1Write(NSString *line) {
    NSLog(@"[MW16-S1] %@", line);
    NSString *full = [NSString stringWithFormat:@"%@  %@\n", [[NSDate date] description], line];
    for (NSString *path in S1LogPaths()) {
        @try {
            NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (!old) old = @"";
            if (old.length > 20000) old = [old substringFromIndex:old.length - 10000];
            [[old stringByAppendingString:full] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) {}
    }
}

@interface SpringBoard : UIApplication
- (void)applicationDidFinishLaunching:(id)application;
@end

// 找桌面窗口（只用于报告，不影响主面板）
static NSString *S1HomeWindowInfo(void) {
    Class homeClass = NSClassFromString(@"SBHomeScreenWindow");
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (homeClass && [w isKindOfClass:homeClass]) {
                return [NSString stringWithFormat:@"%@ %.0fx%.0f",
                        NSStringFromClass([w class]), w.bounds.size.width, w.bounds.size.height];
            }
        }
    }
    return @"(not found)";
}

static UIWindow *gPanelWindow = nil;

// 独立窗口画面板：不依赖桌面窗口是否找到，最不容易被别的东西盖住
static void S1ShowPanel(void) {
    if (gPanelWindow) { gPanelWindow.hidden = NO; return; }

    UIApplication *app = [UIApplication sharedApplication];
    UIWindowScene *ws = nil;
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) { ws = (UIWindowScene *)s; break; }
        if (!ws) ws = (UIWindowScene *)s;
    }

    UIWindow *win = ws ? [[UIWindow alloc] initWithWindowScene:ws]
                       : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    win.frame = [UIScreen mainScreen].bounds;
    win.windowLevel = UIWindowLevelAlert + 900;
    win.backgroundColor = [UIColor clearColor];

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    win.rootViewController = vc;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 150)];
    card.center = CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds));
    card.backgroundColor = [UIColor colorWithRed:0.10 green:0.45 blue:0.95 alpha:1.0];
    card.layer.cornerRadius = 18;
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [vc.view addSubview:card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 18, 268, 34)];
    title.text = @"MW16 注入成功";
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightHeavy];
    [card addSubview:title];

    NSString *detail = [NSString stringWithFormat:@"iOS %@\nhome: %@\narm64e dylib loaded",
                        [[UIDevice currentDevice] systemVersion], S1HomeWindowInfo()];
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 54, 268, 70)];
    sub.text = detail;
    sub.numberOfLines = 4;
    sub.textAlignment = NSTextAlignmentCenter;
    sub.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [card addSubview:sub];

    // 点一下面板就消失，方便看桌面
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:vc action:@selector(dismissSelf)];
    [card addGestureRecognizer:tap];

    win.hidden = NO;
    gPanelWindow = win;

    S1Write([NSString stringWithFormat:@"PANEL-SHOWN home=%@", S1HomeWindowInfo()]);
}

@interface UIViewController (S1Dismiss)
- (void)dismissSelf;
@end

@implementation UIViewController (S1Dismiss)
- (void)dismissSelf {
    if (gPanelWindow) gPanelWindow.hidden = YES;
    S1Write(@"panel tapped, hidden");
}
@end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    S1Write([NSString stringWithFormat:@"BOOT injected, iOS %@", [[UIDevice currentDevice] systemVersion]]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ S1ShowPanel(); });
}
%end

%ctor {
    // 只做最小动作：不在 dylib 初始化阶段碰 NSString/文件系统/UI。
    // 这些延迟到主队列再跑，避免任何"加载期崩溃"。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        S1Write(@"LOAD dylib loaded");
    });
    // 兜底：注入晚于 SpringBoard 启动时 didFinishLaunching 不会再触发，靠这条挂面板
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ S1ShowPanel(); });
    %init;
}
