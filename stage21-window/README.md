# Stage 21 —— 让浮窗里的 App 同时出现在后台切换器

## 为什么默认不会出现

浮窗的本质是**把 App 的图层搬进我们自己的 UIWindow**，
而不是真的把这个 App 送到前台。

后台切换器的内容是 `SBAppSwitcherModel` 里的一串 `SBAppLayout`。
SpringBoard 只在**真正切换 App** 的时候往里写记录。
我们绕过了那一步，所以 model 里没有它 —— 切换器自然就没有这张卡片。

图层搬过去了、App 进程也活着（我们有 RBS assertion 保活），
但 SpringBoard 的「谁在后台」账本上没记这一笔。

## 做法：手工补账

三步：

```objc
// 1. 造 SBDisplayItem（指向这个 App）
id item = [SBDisplayItem applicationDisplayItemWithBundleIdentifier:bid sceneIdentifier:nil];

// 2. 造 SBAppLayout（只放这一个 item，占 role 1 = 全屏主角色）
id layout = [[SBAppLayout alloc] initWithItemsForLayoutRoles:@{ @1 : item }
                                              configuration:cfg
                                                environment:env
                                     preferredDisplayOrdinal:0];

// 3. 塞进切换器的 model
[coordinator _addAppLayoutToFront:layout];
```

`cfg` / `env` 这两个枚举值不敢猜，做法是**从已有的 layout 上读回来**：

```objc
id l = existing.firstObject;
cfg = [[l valueForKey:@"configuration"] longLongValue];
env = [[l valueForKey:@"environment"] longLongValue];
```

## 全是私有 API，所以每一步都自证

构造函数不是每个 iOS 版本都一样，所以每个都写成「有就试，试完回读验证」：

- `applicationDisplayItemWithBundleIdentifier:sceneIdentifier:` 优先
- 退路是 `displayItemWithType:bundleIdentifier:uniqueIdentifier:`，type 从 1 试到 4，
  用 `bundleIdentifier` 回读确认猜对了枚举值
- layout 构造函数准备了三套参数形态，哪个 `instancesRespondToSelector:` 就试哪个
- 塞入也有三种：`_addAppLayoutToFront:` / `addToFront:` / `addAppLayout:atIndex:`

最后 0.6 秒后回读一次，日志直接写结论：

```
[switcher] 回读 com.xxx -> 已在切换器
```

失败最多是「不出现」，不会崩 —— 每步都在 `@try` 里。
