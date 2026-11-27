#import "MWSettingsUI.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "MWPrefs.h"
#import "MWSession.h"

#define SUI_LOG(fmt, ...) NSLog(@"[MW16.settings] " fmt, ##__VA_ARGS__)

static UIWindow *gPanelWindow = nil;
static UIView *gFloatButton = nil;
static int gRetryCount = 0;

@interface MWAppEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@end
@implementation MWAppEntry
@end

// LSApplicationWorkspace 取已装应用（在后台队列执行，避免卡面板）
static NSArray<MWAppEntry *> *MWLoadApps(void) {
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    id ws = [(id)wsClass respondsToSelector:@selector(defaultWorkspace)]
                ? ((id (*)(id, SEL))objc_msgSend)((id)wsClass, @selector(defaultWorkspace)) : nil;
    if (!ws) return @[];

    NSArray *proxies = nil;
    for (NSString *selName in @[@"allInstalledApplications", @"allApplications"]) {
        SEL s = NSSelectorFromString(selName);
        if (![ws respondsToSelector:s]) continue;
        id r = ((id (*)(id, SEL))objc_msgSend)(ws, s);
        if ([r isKindOfClass:[NSArray class]]) { proxies = r; break; }
    }
    if (![proxies isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id p in proxies) {
        NSString *bid = nil, *name = nil;
        @try {
            for (NSString *k in @[@"bundleIdentifier", @"applicationIdentifier"]) {
                if ([p respondsToSelector:NSSelectorFromString(k)]) {
                    id v = [p valueForKey:k];
                    if ([v isKindOfClass:[NSString class]] && [v length]) { bid = v; break; }
                }
            }
            for (NSString *k in @[@"localizedName", @"itemName"]) {
                if ([p respondsToSelector:NSSelectorFromString(k)]) {
                    id v = [p valueForKey:k];
                    if ([v isKindOfClass:[NSString class]] && [v length]) { name = v; break; }
                }
            }
        } @catch (NSException *e) { continue; }
        if (!bid.length || [seen containsObject:bid]) continue;
        [seen addObject:bid];
        MWAppEntry *e = [MWAppEntry new];
        e.bundleID = bid;
        e.name = name.length ? name : bid;
        [out addObject:e];
    }
    [out sortUsingComparator:^NSComparisonResult(MWAppEntry *a, MWAppEntry *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return out;
}

// ---------------------------------------------------------------------------
// 悬浮按钮
// ---------------------------------------------------------------------------
@interface MWFloatButton : UIView
@end

@implementation MWFloatButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = CGRectGetWidth(frame) / 2.0;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.28;
        self.layer.shadowRadius = 12.0;
        self.layer.shadowOffset = CGSizeMake(0, 5);

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        blur.frame = self.bounds;
        blur.layer.cornerRadius = self.layer.cornerRadius;
        blur.layer.masksToBounds = YES;
        blur.userInteractionEnabled = NO;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:blur];

        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.text = @"MW";
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = UIColor.labelColor;
        l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBlack];
        l.userInteractionEnabled = NO;
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:l];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openPanel)]];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];
    }
    return self;
}

- (void)openPanel { [MWSettingsUI present]; }

- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *host = self.superview;
    if (!host) return;
    CGPoint d = [g translationInView:host];
    CGPoint c = self.center;
    c.x += d.x;
    c.y += d.y;
    CGFloat r = CGRectGetWidth(self.bounds) / 2.0;
    c.x = MAX(r + 6, MIN(c.x, CGRectGetWidth(host.bounds) - r - 6));
    c.y = MAX(r + 30, MIN(c.y, CGRectGetHeight(host.bounds) - r - 30));
    self.center = c;
    [g setTranslation:CGPointZero inView:host];
}
@end

// ---------------------------------------------------------------------------
// 面板（Auto Layout，不再硬编码 y）
// ---------------------------------------------------------------------------
@interface MWPanelController : UIViewController <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISwitch *scaleSwitch;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, copy) NSArray<MWAppEntry *> *all;
@property (nonatomic, copy) NSArray<MWAppEntry *> *filtered;
@property (nonatomic, copy) NSString *selected;
@end

@implementation MWPanelController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];

    UIView *card = [UIView new];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 20;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    UILabel *title = [UILabel new];
    title.text = @"MW16 分屏小窗";
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:close];

    self.field = [UITextField new];
    self.field.placeholder = @"搜索应用名或 bundle id";
    self.field.borderStyle = UITextBorderStyleRoundedRect;
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.field.delegate = self;
    [self.field addTarget:self action:@selector(fieldChanged) forControlEvents:UIControlEventEditingChanged];
    self.field.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.field];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 48;
    self.table.layer.cornerRadius = 10;
    self.table.clipsToBounds = YES;
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.table];

    UILabel *scaleLabel = [UILabel new];
    scaleLabel.text = @"Scale Mode（让 App 按小窗尺寸重排）";
    scaleLabel.font = [UIFont systemFontOfSize:14];
    scaleLabel.numberOfLines = 2;
    scaleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:scaleLabel];

    self.scaleSwitch = [UISwitch new];
    [self.scaleSwitch addTarget:self action:@selector(scaleChanged) forControlEvents:UIControlEventValueChanged];
    self.scaleSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.scaleSwitch];

    UIButton *open = [UIButton buttonWithType:UIButtonTypeSystem];
    [open setTitle:@"Open in Window" forState:UIControlStateNormal];
    [open setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    open.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    open.backgroundColor = UIColor.systemBlueColor;
    open.layer.cornerRadius = 10;
    [open addTarget:self action:@selector(openWindow) forControlEvents:UIControlEventTouchUpInside];
    open.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:open];

    self.status = [UILabel new];
    self.status.text = @"正在读取已装应用...";
    self.status.font = [UIFont systemFontOfSize:12];
    self.status.textColor = UIColor.secondaryLabelColor;
    self.status.numberOfLines = 2;
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:self.status];

    UILayoutGuide *m = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:m.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:m.centerYAnchor],
        [card.widthAnchor constraintEqualToAnchor:m.widthAnchor constant:-24],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:m.heightAnchor constant:-24],
        [card.widthAnchor constraintLessThanOrEqualToConstant:420],

        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],

        [close.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:32],
        [close.heightAnchor constraintEqualToConstant:32],

        [self.field.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.field.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.field.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [self.field.heightAnchor constraintEqualToConstant:38],

        [self.table.leadingAnchor constraintEqualToAnchor:self.field.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.field.trailingAnchor],
        [self.table.topAnchor constraintEqualToAnchor:self.field.bottomAnchor constant:10],
        [self.table.heightAnchor constraintEqualToConstant:150],

        [scaleLabel.leadingAnchor constraintEqualToAnchor:self.field.leadingAnchor],
        [scaleLabel.topAnchor constraintEqualToAnchor:self.table.bottomAnchor constant:14],
        [scaleLabel.trailingAnchor constraintEqualToAnchor:self.scaleSwitch.leadingAnchor constant:-10],

        [self.scaleSwitch.trailingAnchor constraintEqualToAnchor:self.field.trailingAnchor],
        [self.scaleSwitch.centerYAnchor constraintEqualToAnchor:scaleLabel.centerYAnchor],

        [open.leadingAnchor constraintEqualToAnchor:self.field.leadingAnchor],
        [open.trailingAnchor constraintEqualToAnchor:self.field.trailingAnchor],
        [open.topAnchor constraintEqualToAnchor:scaleLabel.bottomAnchor constant:16],
        [open.heightAnchor constraintEqualToConstant:44],

        [self.status.leadingAnchor constraintEqualToAnchor:self.field.leadingAnchor],
        [self.status.trailingAnchor constraintEqualToAnchor:self.field.trailingAnchor],
        [self.status.topAnchor constraintEqualToAnchor:open.bottomAnchor constant:10],
        [self.status.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];

    [self refreshSwitch];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *apps = MWLoadApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.all = apps;
            [self filter];
            self.status.text = apps.count ? [NSString stringWithFormat:@"已读取 %lu 个应用，点选后可直接开窗。", (unsigned long)apps.count]
                                          : @"读取应用列表失败，可手动输入 bundle id。";
        });
    });
}

- (void)close {
    gPanelWindow.hidden = YES;
    [gPanelWindow resignKeyWindow];
}

- (NSString *)currentBundleID {
    if (self.selected.length) return self.selected;
    NSString *t = [self.field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return t.length ? t : nil;
}

- (void)fieldChanged {
    self.selected = nil;
    [self filter];
    [self refreshSwitch];
}

- (void)filter {
    NSString *q = self.field.text.lowercaseString;
    if (!q.length) { self.filtered = self.all; }
    else {
        NSMutableArray *m = [NSMutableArray array];
        for (MWAppEntry *e in self.all) {
            if ([e.name.lowercaseString containsString:q] || [e.bundleID.lowercaseString containsString:q])
                [m addObject:e];
        }
        self.filtered = m;
    }
    [self.table reloadData];
}

- (void)refreshSwitch {
    NSString *bid = [self currentBundleID];
    self.scaleSwitch.enabled = bid.length > 0;
    self.scaleSwitch.on = bid.length ? [[MWPrefs shared] scaleModeForBundle:bid] : NO;
}

- (void)scaleChanged {
    NSString *bid = [self currentBundleID];
    if (!bid.length) return;
    [[MWPrefs shared] setScaleMode:self.scaleSwitch.isOn forBundle:bid];
    self.status.text = [NSString stringWithFormat:@"%@  Scale Mode: %@  （下次开窗生效）",
                        bid, self.scaleSwitch.isOn ? @"On" : @"Off"];
}

- (void)openWindow {
    NSString *bid = [self currentBundleID];
    if (!bid.length) { self.status.text = @"先搜索并点选一个应用。"; return; }
    [self.view endEditing:YES];
    self.status.text = [NSString stringWithFormat:@"正在打开 %@ ...", bid];

    if ([MWSession sessionForBundleID:bid]) {
        self.status.text = @"该应用已经在窗口里了。";
        return;
    }
    MWSession *s = [MWSession sessionForBundleIDCreating:bid];
    self.status.text = [s start] ? [NSString stringWithFormat:@"已打开 %@", bid]
                                  : [NSString stringWithFormat:@"打开失败：找不到 %@ 的 scene", bid];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.filtered.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"MWAppCell";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    MWAppEntry *e = self.filtered[ip.row];
    c.textLabel.text = e.name;
    c.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    c.detailTextLabel.text = e.bundleID;
    c.detailTextLabel.font = [UIFont systemFontOfSize:11];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = [e.bundleID isEqualToString:self.selected] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    MWAppEntry *e = self.filtered[ip.row];
    self.selected = e.bundleID;
    self.field.text = e.name;
    [self filter];
    [self refreshSwitch];
    self.status.text = [NSString stringWithFormat:@"已选择 %@", e.bundleID];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

@end

@implementation MWSettingsUI

+ (void)setupIfNeeded {
    if (gFloatButton && gFloatButton.window) return;

    UIWindow *host = nil;
    Class hw = NSClassFromString(@"SBHomeScreenWindow");
    if (hw) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if ([w isKindOfClass:hw]) { host = w; break; }
            }
            if (host) break;
        }
    }
    if (!host) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.windowLevel == UIWindowLevelNormal && w.isKeyWindow) { host = w; break; }
        }
    }

    if (!host) {
        gRetryCount++;
        if (gRetryCount > 15) { SUI_LOG(@"give up attaching settings button"); return; }  // 必须有上限
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self setupIfNeeded]; });
        return;
    }
    [self attachToWindow:host];
}

+ (void)attachToWindow:(UIWindow *)window {
    if (!window) return;

    // 已经挂过：只在需要时提到最前，绝不重复创建
    if (gFloatButton) {
        if (gFloatButton.window == window) {
            [window bringSubviewToFront:gFloatButton];
            return;
        }
        [gFloatButton removeFromSuperview];
        gFloatButton = nil;
    }

    CGRect b = window.bounds;
    if (CGRectIsEmpty(b)) b = [UIScreen mainScreen].bounds;
    CGFloat size = 48;
    MWFloatButton *btn = [[MWFloatButton alloc] initWithFrame:
        CGRectMake(CGRectGetWidth(b) - size - 12, CGRectGetHeight(b) * 0.60, size, size)];
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                           UIViewAutoresizingFlexibleTopMargin |
                           UIViewAutoresizingFlexibleBottomMargin;
    [window addSubview:btn];
    [window bringSubviewToFront:btn];
    gFloatButton = btn;

    if (!gPanelWindow) {
        UIWindowScene *ws = window.windowScene;
        gPanelWindow = ws ? [[UIWindow alloc] initWithWindowScene:ws]
                          : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gPanelWindow.frame = [UIScreen mainScreen].bounds;
        gPanelWindow.windowLevel = UIWindowLevelAlert + 600;
        gPanelWindow.backgroundColor = UIColor.clearColor;
        gPanelWindow.rootViewController = [MWPanelController new];
        gPanelWindow.hidden = YES;
    }
}

+ (void)present {
    if (!gFloatButton || !gPanelWindow) [self setupIfNeeded];
    if (!gPanelWindow) return;
    gPanelWindow.hidden = NO;
    [gPanelWindow makeKeyAndVisible];
}

+ (BOOL)isAttached { return gFloatButton.window != nil; }

@end
