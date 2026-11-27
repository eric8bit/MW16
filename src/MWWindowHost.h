#import <UIKit/UIKit.h>
#import "MWHeaders16.h"

@class MWWindowView;

// 透明宿主窗口：承载所有小窗，空白处点击穿透到下层
@interface MWWindowHost : UIWindow

+ (instancetype)shared;
- (void)attach;                       // 幂等；确保窗口已建好并可见
- (void)attachWindowView:(MWWindowView *)wv;
- (void)detachWindowView:(MWWindowView *)wv;

@end
