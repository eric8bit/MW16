#import <UIKit/UIKit.h>
#import "MWHeaders16.h"

@class MWWindowView;

// 一个窗口 = 一个 Session。所有需要回收的东西都挂在这里，
// -invalidate 一次全清，避免"关了窗口 App 还被钉在前台"这类泄漏。
@interface MWSession : NSObject

@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, strong, readonly) FBScene *scene;
@property (nonatomic, strong) MWWindowView *windowView;
@property (nonatomic, strong) id processAssertion;
@property (nonatomic, assign) BOOL invalidated;

+ (instancetype)sessionForBundleID:(NSString *)bundleID;
+ (instancetype)sessionForBundleIDCreating:(NSString *)bundleID;
+ (NSArray<MWSession *> *)allSessions;
+ (MWSession *)sessionForWindowView:(MWWindowView *)view;

- (BOOL)start;      // 找 scene、建窗口、拿断言、开始保活
- (void)invalidate; // 关闭时调用，全部回收

@end
