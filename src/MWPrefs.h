#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface MWPrefs : NSObject

+ (instancetype)shared;

// 重新从磁盘读取配置（Darwin notify 触发时也会自动调用）
- (void)reload;

// 每个窗口的缩放模式（对应原 scalemode.plist）
- (BOOL)scaleModeForBundle:(NSString *)bundleID;
- (void)setScaleMode:(BOOL)on forBundle:(NSString *)bundleID;

// 窗口默认尺寸比例（0.3 ~ 1.0）
- (CGFloat)defaultWidthRatio;

@end
