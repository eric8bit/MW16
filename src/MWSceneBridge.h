#import <UIKit/UIKit.h>
#import "MWHeaders16.h"

@interface MWSceneBridge : NSObject

// 拿到指定 bundle 的 FBScene；内部逐级降级，全部失败返回 nil
+ (FBScene *)sceneForBundleID:(NSString *)bundleID;

// 用 scene 建一个可以承载远程图层的容器视图（版本自适应）
+ (UIView *)hostContainerForScene:(FBScene *)scene;

// 找到承载键盘/外部图层的窗口（没有则创建）
+ (UIWindow *)keyboardHostWindow;

// 改 scene 的 frame（Scale Mode 用）
+ (void)updateFrame:(CGRect)frame forScene:(FBScene *)scene;

// 强制场景前台/后台
+ (void)setScene:(FBScene *)scene foreground:(BOOL)fg;

// 该场景当前是否还能取到 layer
+ (BOOL)sceneHasLayers:(FBScene *)scene;

@end
