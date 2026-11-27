#import <UIKit/UIKit.h>

@interface MWSettingsUI : NSObject

+ (void)setupIfNeeded;
+ (void)attachToWindow:(UIWindow *)window;
+ (void)present;
+ (BOOL)isAttached;

@end
