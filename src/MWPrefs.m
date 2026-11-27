#import "MWPrefs.h"
#import <notify.h>

#define MW_PREFS_PLIST @"/var/mobile/Library/Preferences/com.mw16.prefs.plist"
#define MW_PREFS_CHANGED "com.mw16.prefs.changed"

static NSMutableDictionary *gCache = nil;
static dispatch_queue_t gQ = nil;

@implementation MWPrefs

+ (instancetype)shared {
    static MWPrefs *i;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ i = [MWPrefs new]; });
    return i;
}

- (instancetype)init {
    if ((self = [super init])) {
        gQ = dispatch_queue_create("mw16.prefs", DISPATCH_QUEUE_SERIAL);
        [self reload];
        // 别的进程改了配置就重载，避免 layoutSubviews 里读盘
        int token = 0;
        notify_register_dispatch(MW_PREFS_CHANGED, &token, dispatch_get_main_queue(), ^(int t) {
            [self reload];
        });
    }
    return self;
}

- (void)reload {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:MW_PREFS_PLIST];
    dispatch_sync(gQ, ^{
        gCache = [d isKindOfClass:[NSDictionary class]] ? [d mutableCopy] : [NSMutableDictionary dictionary];
    });
}

- (id)cached:(NSString *)key {
    __block id v = nil;
    dispatch_sync(gQ, ^{ v = gCache[key]; });
    return v;
}

- (BOOL)scaleModeForBundle:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    id map = [self cached:@"ScaleMode"];
    return [map isKindOfClass:[NSDictionary class]] ? [map[bundleID] boolValue] : NO;
}

- (void)setScaleMode:(BOOL)on forBundle:(NSString *)bundleID {
    if (!bundleID.length) return;
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:MW_PREFS_PLIST] mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    NSMutableDictionary *map = [d[@"ScaleMode"] mutableCopy];
    if (!map) map = [NSMutableDictionary dictionary];
    map[bundleID] = @(on);
    d[@"ScaleMode"] = map;
    [d writeToFile:MW_PREFS_PLIST atomically:YES];
    notify_post(MW_PREFS_CHANGED);
    [self reload];
}

- (CGFloat)defaultWidthRatio {
    id v = [self cached:@"WidthRatio"];
    CGFloat r = [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 0.62;
    if (r < 0.3) r = 0.3;
    if (r > 1.0) r = 1.0;
    return r;
}

@end
