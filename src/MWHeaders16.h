#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
//  iOS 16.x 私有头（只列本插件用到的）
//  说明：iPhone 与 iPad 共用同一 SpringBoard，Medusa/场景托管代码都在，
//        只是 iPhone 上被能力开关关掉。这里只做"够用"的声明。
// ---------------------------------------------------------------------------

NS_INLINE id MW_GetIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        Ivar iv = class_getInstanceVariable(c, name);
        if (iv) return (__bridge id)(*(void **)((__bridge void *)obj + ivar_getOffset(iv)));
    }
    return nil;
}

// --- FrontBoard ---
@interface FBScene : NSObject
@property (nonatomic, readonly) NSString *identifier;
- (id)settings;
- (id)mutableSettings;
- (id)layerManager;
- (void)updateSettings:(id)settings withTransitionContext:(id)ctx;
- (void)updateSettings:(id)settings withTransitionContext:(id)ctx completion:(id)completion;
@end

@interface FBSceneManager : NSObject
+ (instancetype)sharedInstance;
- (FBScene *)sceneWithIdentifier:(NSString *)identifier;
@end

@interface FBSceneLayerManager : NSObject
- (NSArray *)layers;
@end

@interface FBSMutableSceneSettings : NSObject
@property (nonatomic, getter=isForeground) BOOL foreground;
- (id)mutableCopy;
@end

@interface UIMutableApplicationSceneSettings : NSObject
- (void)setDeactivationReasons:(unsigned long long)reasons;
- (unsigned long long)deactivationReasons;
- (void)setForeground:(BOOL)fg;
- (void)setFrame:(CGRect)frame;
@end

// --- SpringBoard ---
@interface SBApplication : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *displayName;
- (BOOL)isMedusaCapable;
- (id)processState;
@end

@interface SBApplicationInfo : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
- (BOOL)isMedusaCapable;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (SBApplication *)applicationWithBundleIdentifier:(NSString *)identifier;
@end

@interface SBMainWorkspace : NSObject
+ (instancetype)sharedInstance;
- (id)sceneManager;
@end

@interface SBSceneManager : NSObject
- (id)allScenes;
- (id)sceneWithIdentifier:(NSString *)identifier;
@end

@interface SBAppLayout : NSObject
+ (id)homeScreenAppLayout;
- (id)rolesToLayoutItemsMap;
- (NSArray *)allItems;
- (id)centerItem;
@end

@interface SBDisplayItem : NSObject
+ (id)displayItemWithType:(long long)type bundleIdentifier:(NSString *)bundleID uniqueIdentifier:(NSString *)uniqueID;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *uniqueIdentifier;
@end

@interface SBFluidSwitcherItemContainer : UIView
- (id)appLayout;
@end

@interface SBAppSwitcherPageView : UIView
- (id)appLayout;
@end

@interface SBMainSwitcherViewController : UIViewController
+ (instancetype)sharedInstance;
- (BOOL)_dismissSwitcherNoninteractivelyToAppLayout:(id)layout dismissFloatingSwitcher:(BOOL)dis animated:(BOOL)anim;
@end

@interface SpringBoard : UIApplication
- (void)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
@end

@interface SBIconView : UIView
- (NSString *)applicationBundleIdentifier;
@end

// --- UIKit 私有 ---
@interface _UISceneLayerHostContainerView : UIView
- (instancetype)initWithScene:(id)scene;
- (instancetype)initWithScene:(id)scene debugDescription:(id)desc;
- (id)_createHostViewForLayer:(id)layer;
@end

@interface SBSApplicationShortcutItem : NSObject
@property (nonatomic, copy) NSString *localizedTitle;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *bundleIdentifierToLaunch;
@end

@interface _UISceneHostingActivationStateHostComponent : NSObject
- (void)setForeground:(BOOL)fg;
- (id)hostScene;
- (void)evaluateActivationState;
@end

@interface SBHomeScreenWindow : UIWindow
@end

@interface SBHomeScreenView : UIView
@end

@interface SBRootFolderView : UIView
@end

// --- RunningBoard ---
@interface RBSTarget : NSObject
+ (instancetype)targetWithPid:(int)pid;
+ (instancetype)currentProcess;
@end

@interface RBSLegacyAttribute : NSObject
+ (instancetype)attributeWithReason:(NSUInteger)reason flags:(NSUInteger)flags;
@end

@interface RBSAssertion : NSObject
- (instancetype)initWithExplanation:(NSString *)explanation target:(RBSTarget *)target attributes:(NSArray *)attrs;
- (BOOL)acquireWithError:(NSError **)error;
- (void)invalidate;
@end

enum {
    BKSProcessAssertionPreventTaskSuspend      = (1 << 0),
    BKSProcessAssertionPreventTaskThrottleDown = (1 << 1),
    BKSProcessAssertionWantsForegroundPriority = (1 << 3),
};
enum { BKSProcessAssertionReasonBackgroundUI = 7 };

@class MWWindowView;
@class MWWindowHost;
@class MWSession;
