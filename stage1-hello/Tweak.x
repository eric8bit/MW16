#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------------
//  MW16 Stage 1 — "Hello"
//
//  目的：只验证三件事，不做任何危险操作。
//    1. roothide 包能不能编出来、装上
//    2. dylib 能不能注入 SpringBoard
//    3. 我们能不能在桌面上画一个自己的按钮
//
//  不 hook 任何私有 API（只 hook 公开存在的 applicationDidFinishLaunching:），
//  不改任何系统设置。最坏结果就是按钮不出现。
// ---------------------------------------------------------------------------

#define S1_LOG      @"/var/mobile/Library/Preferences/mw16_stage1.log"
#define S1_LOG_ALT  @"/tmp/mw16_stage1.log"

static int gAttachAttempts = 0;
static const int kMaxAttachAttempts = 40;

static void S1Write(NSString *line) {
    NSLog(@"[MW16-S1] %@", line);
    NSString *full = [NSString stringWithFormat:@"%@  %@\n", [[NSDate date] description], line];
    for (NSString *path in @[S1_LOG, S1_LOG_ALT]) {
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

// 找一个可以挂子视图的窗口。逐级降级，绝不返回 nil 就无限重试。
static UIWindow *S1FindHostWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];

    // 1) 桌面窗口（最理想）
    Class homeWindowClass = NSClassFromString(@"SBHomeScreenWindow");
    if (homeWindowClass) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if ([w isKindOfClass:homeWindowClass] && !CGRectIsEmpty(w.bounds)) return w;
            }
        }
        for (UIWindow *w in app.windows) {
            if ([w isKindOfClass:homeWindowClass] && !CGRectIsEmpty(w.bounds)) return w;
        }
    }

    // 2) 退而求其次：任何 normal 层级的窗口
    for (UIWindow *w in app.windows) {
        if (w.windowLevel == UIWindowLevelNormal && !CGRectIsEmpty(w.bounds) && !w.hidden) return w;
    }

    // 3) 最后：key window
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
            if (key) break;
        }
    }
    return key;
}

@interface S1Button : UIView
@end

@implementation S1Button
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:0.20 green:0.52 blue:1.0 alpha:0.92];
        self.layer.cornerRadius = CGRectGetWidth(frame) / 2.0;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.3;
        self.layer.shadowRadius = 10;
        self.layer.shadowOffset = CGSizeMake(0, 4);

        UILabel *label = [[UILabel alloc] initWithFrame:self.bounds];
        label.text = @"S1";
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightHeavy];
        label.userInteractionEnabled = NO;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:label];

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(s1tapped)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)s1tapped {
    S1Write(@"TAP-OK 按钮被点击 —— 注入 + UI + 事件 全部正常");
    [UIView animateWithDuration:0.15 animations:^{
        self.transform = CGAffineTransformMakeScale(0.85, 0.85);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.15 animations:^{
            self.transform = CGAffineTransformIdentity;
        }];
    }];
}
@end

static S1Button *gButton = nil;

static void S1Attach(void) {
    // 已经挂上就只提到最前，不重复创建
    if (gButton && gButton.window) {
        [gButton.window bringSubviewToFront:gButton];
        return;
    }

    if (gAttachAttempts >= kMaxAttachAttempts) {
        S1Write([NSString stringWithFormat:@"放弃：尝试 %d 次仍没有可用窗口", gAttachAttempts]);
        return;
    }
    gAttachAttempts++;

    UIWindow *host = S1FindHostWindow();
    if (!host) {
        if (gAttachAttempts == 1 || gAttachAttempts % 10 == 0) {
            S1Write([NSString stringWithFormat:@"第 %d 次：还没有可用窗口，1 秒后再试", gAttachAttempts]);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ S1Attach(); });
        return;
    }

    [gButton removeFromSuperview];

    CGRect bounds = host.bounds;
    if (CGRectIsEmpty(bounds)) bounds = [UIScreen mainScreen].bounds;
    CGFloat size = 44;
    S1Button *btn = [[S1Button alloc] initWithFrame:
        CGRectMake(CGRectGetWidth(bounds) - size - 16,
                   CGRectGetHeight(bounds) * 0.55,
                   size, size)];
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [host addSubview:btn];
    [host bringSubviewToFront:btn];
    gButton = btn;

    S1Write([NSString stringWithFormat:@"ATTACH-OK 按钮已挂到 %@ (level=%.0f, %d 次尝试)",
             NSStringFromClass([host class]), (double)host.windowLevel, gAttachAttempts]);
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    S1Write([NSString stringWithFormat:@"BOOT SpringBoard 已注入，iOS %@",
             [[UIDevice currentDevice] systemVersion]]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ S1Attach(); });
}
%end

%ctor {
    @autoreleasepool {
        S1Write(@"LOAD dylib 已加载");
        // 兜底：如果注入发生在 SpringBoard 启动之后，didFinishLaunching 不会再触发，
        // 这条延时也会把按钮挂上。两条路径都幂等。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ S1Attach(); });
    }
    %init;   // 自定义 %ctor 时必须手动初始化默认组，否则 %hook 不生效
}
