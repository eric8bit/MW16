#import <UIKit/UIKit.h>
#import "MWHeaders16.h"

@interface MWWindowView : UIView

@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) FBScene *scene;
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIView *mainView;
@property (nonatomic, strong) UIView *titleBar;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *minButton;
@property (nonatomic, strong) UIButton *maxButton;
@property (nonatomic, strong) UIView *sizeHandle;

@property (nonatomic, assign) BOOL isOpen;
@property (nonatomic, assign) BOOL aspectLock;
@property (nonatomic, assign) CGRect prevFrame;
@property (nonatomic, assign) CGRect savedFrame;
@property (nonatomic, assign) CGPoint dragOffset;

// 防重入：避免 _setLayers: → refreshLayers → layout → updateSettings 自激
@property (nonatomic, assign) BOOL refreshingLayers;
@property (nonatomic, assign) BOOL suspendLayout;

- (instancetype)initWithContentView:(UIView *)contentView
                        identifier:(NSString *)bundleID
                             scene:(FBScene *)scene;

- (void)refreshLayers;
- (void)updateContentViewFrame:(CGRect)frame;

@end
