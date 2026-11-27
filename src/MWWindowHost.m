#import "MWWindowHost.h"
#import "MWWindowView.h"

static CGFloat gAngle = 0;

// 只有点到真正有内容的子视图才响应，其它一律穿透
@interface MWHostRootView : UIView
@end
@implementation MWHostRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}
@end

@interface MWWindowHost ()
@property (nonatomic, strong) UIView *rootView;
- (void)setup;
- (void)orientationChanged:(NSNotification *)note;
@end

@implementation MWWindowHost

+ (instancetype)shared {
    static MWWindowHost *w;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIWindowScene *ws = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            if (s.activationState == UISceneActivationStateForegroundActive) { ws = (UIWindowScene *)s; break; }
            if (!ws) ws = (UIWindowScene *)s;
        }
        w = ws ? [[MWWindowHost alloc] initWithWindowScene:ws]
               : [[MWWindowHost alloc] initWithFrame:[UIScreen mainScreen].bounds];
        [w setup];
    });
    return w;
}

- (void)setup {
    self.frame = [UIScreen mainScreen].bounds;
    self.backgroundColor = [UIColor clearColor];
    self.windowLevel = UIWindowLevelAlert - 1;
    self.hidden = NO;

    UIViewController *vc = [UIViewController new];
    MWHostRootView *root = [[MWHostRootView alloc] initWithFrame:self.bounds];
    root.backgroundColor = [UIColor clearColor];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    vc.view = root;
    self.rootViewController = vc;
    self.rootView = root;

    if ([UIDevice currentDevice].userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(orientationChanged:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
    }
}

- (void)attach {
    if (self.hidden) self.hidden = NO;
    [self.rootViewController.view setNeedsLayout];
}

- (void)attachWindowView:(MWWindowView *)wv {
    if (!wv) return;
    [self attach];
    [self.rootView addSubview:wv];
}

- (void)detachWindowView:(MWWindowView *)wv {
    if (wv.superview == self.rootView) [wv removeFromSuperview];
}

- (void)orientationChanged:(NSNotification *)note {
    UIDeviceOrientation o = ((UIDevice *)note.object).orientation;
    CGFloat angle = 0;
    switch (o) {
        case UIDeviceOrientationPortrait: angle = 0; break;
        case UIDeviceOrientationLandscapeRight: angle = M_PI_2; break;
        case UIDeviceOrientationLandscapeLeft: angle = -M_PI_2; break;
        default: return;
    }
    if (fabs(angle - gAngle) < 0.01) return;
    gAngle = angle;
    [UIView animateWithDuration:0.25 animations:^{
        self.transform = CGAffineTransformMakeRotation(angle);
        self.frame = [UIScreen mainScreen].bounds;
    }];
}

@end
