#import "MWWindowView.h"
#import "MWSceneBridge.h"
#import "MWPrefs.h"
#import "MWSession.h"

#define W_LOG(fmt, ...) NSLog(@"[MW16.window] " fmt, ##__VA_ARGS__)

static const CGFloat kTitleH = 26.0;
static const CGFloat kDotSize = 16.0;

@implementation MWWindowView

- (instancetype)initWithContentView:(UIView *)contentView
                        identifier:(NSString *)bundleID
                             scene:(FBScene *)scene {
    if ((self = [super initWithFrame:CGRectZero])) {
        _bundleID = [bundleID copy];
        _scene = scene;
        _contentView = contentView;
        _isOpen = YES;
        _aspectLock = YES;

        self.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
        self.layer.cornerRadius = 12.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.25] CGColor];
        self.clipsToBounds = YES;

        [self buildSubviews];
        [self applyInitialFrame];
    }
    return self;
}

- (void)buildSubviews {
    UIView *mainView = [UIView new];
    mainView.clipsToBounds = YES;
    mainView.backgroundColor = [UIColor blackColor];
    mainView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:mainView];
    self.mainView = mainView;

    [self addConstraint:[NSLayoutConstraint constraintWithItem:mainView attribute:NSLayoutAttributeTop
        relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeTop multiplier:1 constant:kTitleH]];
    [self addConstraint:[NSLayoutConstraint constraintWithItem:mainView attribute:NSLayoutAttributeLeft
        relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeLeft multiplier:1 constant:0]];
    [self addConstraint:[NSLayoutConstraint constraintWithItem:mainView attribute:NSLayoutAttributeRight
        relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeRight multiplier:1 constant:0]];
    [self addConstraint:[NSLayoutConstraint constraintWithItem:mainView attribute:NSLayoutAttributeBottom
        relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeBottom multiplier:1 constant:0]];

    if (self.contentView) {
        // 不要设 autoresizingMask：缩放时由 layoutSubviews 精确控制 frame，
        // 否则父视图一改大小就会把我们的缩放尺寸覆盖掉。
        self.contentView.autoresizingMask = UIViewAutoresizingNone;
        self.contentView.frame = CGRectMake(0, 0,
            MAX(1.0, CGRectGetWidth([UIScreen mainScreen].bounds)),
            MAX(1.0, CGRectGetHeight([UIScreen mainScreen].bounds)));
        [mainView addSubview:self.contentView];
    }

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, kTitleH)];
    bar.backgroundColor = [UIColor colorWithWhite:0.22 alpha:0.97];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self addSubview:bar];
    self.titleBar = bar;

    [bar addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDrag:)]];
    [bar addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)]];

    self.closeButton = [self makeDot:[UIColor systemRedColor]];
    self.minButton   = [self makeDot:[UIColor systemYellowColor]];
    self.maxButton   = [self makeDot:[UIColor systemGreenColor]];
    self.closeButton.frame = CGRectMake(8, (kTitleH - kDotSize) / 2, kDotSize, kDotSize);
    self.minButton.frame   = CGRectMake(30, (kTitleH - kDotSize) / 2, kDotSize, kDotSize);
    self.maxButton.frame   = CGRectMake(52, (kTitleH - kDotSize) / 2, kDotSize, kDotSize);

    // 关键：三个按钮必须真的加进标题栏，否则窗口没有关闭按钮
    [bar addSubview:self.closeButton];
    [bar addSubview:self.minButton];
    [bar addSubview:self.maxButton];

    [self.closeButton addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeTapped:)]];
    [self.minButton addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(minTapped:)]];
    [self.maxButton addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(maxTapped:)]];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(74, 0, 200, kTitleH)];
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    title.textAlignment = NSTextAlignmentCenter;
    [bar addSubview:title];
    self.titleLabel = title;

    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
    handle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    handle.layer.cornerRadius = 5.0;
    [self addSubview:handle];
    self.sizeHandle = handle;

    [handle addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleResize:)]];
    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleResizeDoubleTap:)];
    dbl.numberOfTapsRequired = 2;
    [handle addGestureRecognizer:dbl];
}

- (UIButton *)makeDot:(UIColor *)color {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.backgroundColor = color;
    b.layer.cornerRadius = kDotSize / 2.0;
    b.userInteractionEnabled = YES;
    return b;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.suspendLayout) return;

    self.titleLabel.frame = CGRectMake(74, 0, MAX(0, self.bounds.size.width - 104), kTitleH);
    self.sizeHandle.frame = CGRectMake(self.bounds.size.width - 28, self.bounds.size.height - 28, 22, 22);

    if (!self.isOpen || !self.contentView) return;

    CGRect mainFrame = self.mainView.frame;
    if (mainFrame.size.width < 1 || mainFrame.size.height < 1) return;

    self.suspendLayout = YES;
    BOOL scaleMode = [[MWPrefs shared] scaleModeForBundle:self.bundleID];

    if (scaleMode) {
        self.contentView.transform = CGAffineTransformIdentity;
        self.contentView.frame = CGRectMake(0, 0, mainFrame.size.width, mainFrame.size.height);
        [MWSceneBridge updateFrame:mainFrame forScene:self.scene];
    } else {
        CGSize screen = [UIScreen mainScreen].bounds.size;
        CGFloat longSide = MAX(screen.width, screen.height);
        CGFloat shortSide = MIN(screen.width, screen.height);
        BOOL portrait = screen.height >= screen.width;
        CGFloat cx = portrait ? shortSide : longSide;
        CGFloat cy = portrait ? longSide : shortSide;
        self.contentView.transform = CGAffineTransformMakeScale(mainFrame.size.width / cx,
                                                                mainFrame.size.height / cy);
        self.contentView.frame = CGRectMake(0, 0, cx, cy);
    }
    self.suspendLayout = NO;
}

- (void)updateContentViewFrame:(CGRect)frame {
    [MWSceneBridge updateFrame:frame forScene:self.scene];
}

- (void)applyInitialFrame {
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat ratio = [[MWPrefs shared] defaultWidthRatio];
    CGFloat w = sb.size.width * ratio;
    CGFloat h = w * 1.75;
    if (h > sb.size.height * 0.72) h = sb.size.height * 0.72;
    self.frame = CGRectMake(sb.size.width - w - 16, 90, w, h);
}

#pragma mark - 拖拽 / 缩放

- (void)handleDrag:(UIPanGestureRecognizer *)g {
    CGPoint loc = [g locationInView:self.superview];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragOffset = CGPointMake(loc.x - self.center.x, loc.y - self.center.y);
        [self.superview bringSubviewToFront:self];
        return;
    }
    if (g.state == UIGestureRecognizerStateChanged) {
        self.center = CGPointMake(loc.x - self.dragOffset.x, loc.y - self.dragOffset.y);
    }
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    [self.superview bringSubviewToFront:self];
}

- (void)handleResize:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        self.savedFrame = self.frame;
        return;
    }
    if (g.state != UIGestureRecognizerStateChanged) return;

    CGPoint d = [g translationInView:self.superview];
    [g setTranslation:CGPointZero inView:self.superview];

    CGFloat dx = d.x, dy = d.y;
    if (self.aspectLock) {
        CGFloat ratio = self.frame.size.height / MAX(1.0, self.frame.size.width);
        dy = dx * ratio;
    }

    CGRect f = self.frame;
    f.size.width = MAX(140.0, f.size.width + dx);
    f.size.height = MAX(120.0, f.size.height + dy);
    self.frame = f;
    [self layoutSubviews];
}

- (void)handleResizeDoubleTap:(UITapGestureRecognizer *)g {
    self.aspectLock = !self.aspectLock;
    self.sizeHandle.backgroundColor = self.aspectLock
        ? [UIColor colorWithWhite:1.0 alpha:0.18]
        : [UIColor colorWithWhite:1.0 alpha:0.06];
}

#pragma mark - 按钮

- (void)closeTapped:(id)sender {
    MWSession *s = [MWSession sessionForWindowView:self];
    if (s) {
        [s invalidate];
    } else {
        [self removeFromSuperview];
    }
}

- (void)minTapped:(id)sender {
    if (self.isOpen) {
        self.prevFrame = self.frame;
        self.isOpen = NO;
        self.contentView.hidden = YES;
        [UIView animateWithDuration:0.2 animations:^{
            self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y,
                                    self.frame.size.width, kTitleH);
        }];
    } else {
        self.isOpen = YES;
        self.contentView.hidden = NO;
        [UIView animateWithDuration:0.2 animations:^{
            self.frame = self.prevFrame;
        } completion:^(BOOL f) {
            [self layoutSubviews];
            [self refreshLayers];
        }];
    }
}

- (void)maxTapped:(id)sender {
    if (self.isOpen) {
        self.prevFrame = self.frame;
        [UIView animateWithDuration:0.2 animations:^{
            self.frame = [UIScreen mainScreen].bounds;
        } completion:^(BOOL f) { [self layoutSubviews]; }];
    } else {
        [self minTapped:sender];
    }
}

#pragma mark - 图层刷新（重入保护）

- (void)refreshLayers {
    if (self.refreshingLayers) return;
    if (!self.isOpen || !self.scene || !self.contentView) return;
    self.refreshingLayers = YES;

    @try {
        [self.contentView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

        // 注意：这里不能用 return 提前退出，否则 refreshingLayers 永远停不下来。
        BOOL canBuild = [self.scene respondsToSelector:@selector(layerManager)] &&
                         [self.contentView respondsToSelector:@selector(_createHostViewForLayer:)];
        id lm = canBuild ? ((id (*)(id, SEL))objc_msgSend)(self.scene, @selector(layerManager)) : nil;
        id layers = [lm respondsToSelector:@selector(layers)] ? ((id (*)(id, SEL))objc_msgSend)(lm, @selector(layers)) : nil;
        BOOL ok = canBuild && [layers isKindOfClass:[NSArray class]] && [layers count] > 0;

        if (ok) {
            for (id layer in layers) {
                UIView *hv = ((id (*)(id, SEL, id))objc_msgSend)(self.contentView, @selector(_createHostViewForLayer:), layer);
                if (!hv) continue;
                if ([NSStringFromClass([hv class]) containsString:@"External"]) {
                    UIWindow *kw = [MWSceneBridge keyboardHostWindow];
                    hv.frame = kw.bounds;
                    [kw.rootViewController.view addSubview:hv];
                } else {
                    hv.frame = self.contentView.bounds;
                    hv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                    [self.contentView addSubview:hv];
                }
            }
        } else {
            W_LOG(@"refreshLayers: no layers yet for %@", self.bundleID);
        }
    } @catch (NSException *e) {
        W_LOG(@"refreshLayers ex %@", e);
    }

    self.refreshingLayers = NO;
}

@end
