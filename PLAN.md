# iOS 16.6.1 / Relaxin(roothide) 分屏小窗插件 —— 可行方案

> 目标机：iPhone，iOS 16.6.1，Relaxin（RootHide）越狱
> 基线源码：MilkyWayReborn-for-iOS16（SpringBoard 注入）
> 结论先行：**技术路线成立，但这份源码不能直接编译上线**——它实际是按 iOS 17/26 写的，
> 场景查找、hook 集合、打包方式三处都不匹配 16.6.1。建议按下面 4 个阶段做。

---

## 0. 环境事实（已核对）

| 项 | 值 |
|---|---|
| 越狱类型 | Relaxin 是 **RootHide** 越狱（OwnGoalStudio/Relaxin），不是 rootless |
| 包格式 | 必须 `THEOS_PACKAGE_SCHEME=roothide`，用 [roothide/theos](https://github.com/roothide/theos) |
| 注入框架 | ellekit（roothide bootstrap 自带），SpringBoard 默认注入 |
| 越狱路径 | 随机 jbroot；访问越狱文件必须走 `jbroot()`（本插件不需要，偏好文件在 /var/mobile 真路径） |
| `Architecture` | 必须写 `iphoneos-arm64`；现有 control 写的是 `iphoneos-arm`（rootful），装不上 |
| 私有 API 依据 | iPhone/iPad 共用同一 SpringBoard 二进制，Medusa/场景托管代码都在，只是 iPhone 上被开关关掉 |

---

## 1. 三条技术路线，选哪条

### 路线 A：图层托管小窗（本仓库做法）— **建议作为 MVP**

把目标 App 的 `FBScene` 的远程图层，用 `_UISceneLayerHostContainerView` 挂到你在 SpringBoard 里自建的透明窗口上。

- 原理已被证明：**App 切换器卡片就是这个机制**（SpringBoard 托管 app scene 图层），所以 iPhone 上一定能出画面，不依赖 Medusa。
- 优点：改动局限在 SpringBoard 进程、不碰 app 进程、不动系统布局引擎；一个 App 一个小窗。
- 缺点：App 内部仍按全屏尺寸排版，靠 transform 缩放（或 Scale Mode 改 scene frame）；键盘、旋转、手势冲突需逐个处理。
- 工作量：**1～2 周**能到可用。

### 路线 B：打开原生 Medusa（iPad 式分屏）— 进阶

patch `isMedusaCapable` / `SBAppLayout` / `SBMedusaSettings` 等判定，让 SpringBoard 自己排双 App。

- 优点：真·分屏，键盘/旋转/拖拽全由系统处理，体验最好。
- 缺点：判定点极多（TrollPad、SplitViewPro 类项目为此维护上百个 hook），iPhone 逻辑分辨率下系统会给 iPad 布局，需再压一轮；崩溃面大、系统升级全废。
- 工作量：**1～2 个月**，不建议第一天就做。

### 路线 C：快照伪窗口 — 不选

拿 `FBScene` 快照贴在窗口里，看着像但不能交互。只适合做任务预览，不叫分屏。

> **建议**：A 做 MVP，架构留好扩展位（见第 3 节），B 放到 2.0。
> iPhone 屏幕小，**“一主 + 多个悬浮小窗”实际比左右分屏更好用**，这也是 A 的价值。

---

## 2. 这份源码在 16.6.1 上的真实差距（必改项）

### 2.1 场景查找整段要换掉（最致命）

现有实现用 6 级 ivar 盲扫（`_scenesByID` / `_scenes` / `_workspace` / `_persistentMapSceneIdentityToSceneHandle`…），
这些名字是 iOS 26 的。**iOS 16 有直接可用的方法：**

```objc
// iOS 13~16 通用
id mgr = [(id)NSClassFromString(@"FBSceneManager") sharedInstance];
FBScene *scene = [mgr sceneWithIdentifier:identifier];   // 或按 bundleID 前缀匹配
```

改成「**方法优先 → ivar 兜底**」：
1. `[FBSceneManager sharedInstance] sceneWithIdentifier:`
2. `SBSceneManager -allScenes` 里按 identifier 前缀匹配
3. 仍失败才退回现有 ivar 扫描（保留但放最后，且加日志）

这一步能把 `MWSceneHelper.m` 从 259 行砍到 ~80 行，也是**成功率最高**的一处改动。
请先用第 4 节的探针确认 `sceneWithIdentifier:` 确实存在（不同 build 可能改名）。

### 2.2 hook 集合要按系统版本分组

| hook | 16.6.1 | 处理 |
|---|---|---|
| `FBScene -updateSettings:withTransitionContext:completion:` | 有 | 保留；**补上两参版本**（源码漏了，而自家 helper 优先调两参版） |
| `UIMutableApplicationSceneSettings -setDeactivationReasons:` | 有 | 保留，但删掉“取不到 identifier 就全局 `%orig(0)`”的分支（会误伤所有场景） |
| `_UISceneHostingActivationStateHostComponent` | **没有**（iOS 17+） | 包进 `%group` + 运行时判断类存在再 `%init` |
| `SBHomeScreenView / SBRootFolderView -didMoveToWindow:` | 有 | 保留（用来挂设置按钮） |

`%hook` 一个不存在的类在 Logos 里是未定义行为，务必这样写：

```objc
%group gIOS17
%hook _UISceneHostingActivationStateHostComponent
- (void)setForeground:(BOOL)fg { /* ... */ %orig; }
%end
%end

%ctor {
    if (objc_getClass("_UISceneHostingActivationStateHostComponent")) %init(gIOS17);
}
```

### 2.3 `isMedusaCapable` 挂错位置（Scale Mode 起不来）

iOS 16 上这个能力判定大概率在 **`SBApplicationInfo`**，不在 `SBApplication`。两个都 hook，用 `respondsToSelector` 兜：

```objc
%hook SBApplicationInfo
- (BOOL)isMedusaCapable { return MWScaleValueForBundle(self.bundleIdentifier) ?: %orig; }
%end
```

（先用探针确认 `SBApplicationInfo` 上到底有没有 medusa 相关 selector。）

### 2.4 宿主窗口的 windowScene 选错风险

`MWPassthroughWindow` 现在取“第一个 UIWindowScene”。SpringBoard 里可能有多个（home screen、switcher、banner…）。
改成取 **homescreen 那个 window 的 windowScene**：

```objc
UIWindow *home = MWHomescreenWindow();   // 已有实现，可复用
UIWindowScene *ws = home.windowScene;
```

### 2.5 上次审查的 P0/P1 必须一起修

1. **关闭窗口漏清白名单**（`closeButtonAction` 没调 `setForeground:enabled:NO`）→ App 被永久钉在前台。
2. **图层刷新正反馈**（`FBSceneLayerManager._setLayers:` → `updateLayers` → `layoutSubviews` → `updateSettings:` → `_setLayers:`）→ 加重入标志 + 100ms 合并。
3. **`layoutSubviews` 里读 plist**（每帧一次磁盘 IO）→ scaleMode 缓存进内存，notify 变化时刷新。
4. **主题 plist 缺字段按钮变 0×0** → 逐字段兜默认值。

---

## 3. 推荐架构（一次留好扩展位）

```
MW16  (SpringBoard 注入)
├─ MWSceneBridge    场景获取 / 图层宿主视图构造（版本自适应）
├─ MWSession        一个窗口 = 一个 Session：scene + 白名单 + 断言 + 定时器，strong-own
├─ MWWindowView     窗口 UI（标题栏/拖拽/缩放/最小化/关闭）—— 基本沿用现有实现
├─ MWWindowHost     透明宿主窗口 + hitTest 穿透 + 旋转
├─ MWPrefs          scaleMode / 主题 / 布局，统一 CFPreferences + Darwin notify
└─ MWSettingsUI     悬浮球 + 面板（沿用，改成 Auto Layout）
```

关键设计：**所有状态收敛到 `MWSession` 对象**，`close` 时一个 `-invalidate` 全部回收（白名单、断言、定时器、宿主视图）。
现在源码把这些散在 4 个文件里，这就是 P0 bug 的根因。

---

## 4. 第 0 天：先跑探针，别急着改代码

```
make package THEOS_PACKAGE_SCHEME=roothide
# 安装后 respring；日志：NSLog + 写入 /var/mobile/Library/Preferences/mw16_probe.log
```

探针 dump 出 6 项（见 probe/Tweak.x）：
1. `FBSceneManager` / `SBSceneManager` 是否有 `sceneWithIdentifier:`、`allScenes`；
2. 现场所有 scene 的 identifier（判断能否用 bundleID 直接命中）；
3. `_UISceneLayerHostContainerView` 的 `init*` 选择器（16 上是 `initWithScene:` 还是带 debugDescription）；
4. `SBApplication` / `SBApplicationInfo` 上 medusa 相关 selector；
5. SpringBoard 的 windowScene / window 类名；
6. **RBS 断言自测**：对自身 pid 建一条 `RBSLegacyAttribute` 断言，看 `acquireWithError:` 是否成功。

---

## 5. 里程碑

| 阶段 | 内容 | 验收 | 估时 |
|---|---|---|---|
| M0 | 探针跑通，拿到 6 项事实 | 日志齐全 | 0.5 天 |
| M1 | 场景查找重写 + 单 App 浮窗出画面（缩放模式） | 微信/Safari 能浮起来 | 2～3 天 |
| M2 | 窗口交互 + 多开 + 关闭回收（P0 全修） | 开 3 个窗、关掉后 App 正常休眠 | 3～4 天 |
| M3 | 前台保活（断言/场景双保险）+ 键盘 | 切主 App 后小窗不黑 | 2～3 天 |
| M4 | 设置面板 + 持久化 + 旋转 | 重启后配置还原 | 2 天 |
| M5（可选） | 原生 Medusa 分屏 | 左右分屏 | 后续 |

---

## 6. roothide 打包配置（直接替换原 Makefile）

```make
export THEOS_PACKAGE_SCHEME = roothide
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0
export DEBUG = 0

TWEAK_NAME = MW16
MW16_FILES = Tweak.x MWSceneBridge.m MWSession.m MWWindowView.m MWWindowHost.m MWPrefs.m MWSettingsUI.m
MW16_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
MW16_FRAMEWORKS = UIKit CoreGraphics QuartzCore

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
```

control 里 `Architecture` 改 `iphoneos-arm64`，其余不变。

---

## 7. 风险与放弃条件

| 风险 | 缓解 |
|---|---|
| `sceneWithIdentifier:` 在 16.6.1 不可用 | 探针确认；退化到 `allScenes` 前缀匹配 |
| SpringBoard 无 RBS 断言权限 | 只靠“场景保持前台”保活（已在 hook 三层），App 大概率不挂 |
| roothide 下偏好文件权限 | 用 `/var/mobile/Library/Preferences/`（真路径），已验证可写 |
| 系统更新到 17+ 后私有 API 变动 | 场景层收敛到 `MWSceneBridge` 单点 |
| 无 `task_for_pid` 权限 | 删掉 `task_for_pid`+`task_resume`（会失败且增加被检测风险），必要时改 `SIGCONT` |

**放弃条件**：若 M1 拿不到画面（`_UISceneLayerHostContainerView` 在 16.6.1 建不出可用 host view），
直接转路线 B（Medusa 开关），不要在路线 A 上纠缠。
