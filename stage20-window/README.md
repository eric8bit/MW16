# Stage 20 —— 进后台切换器时关闭全部浮窗

## 为什么以前没关掉

之前的判断是「看主屏图标视图还剩多少可见面积」：

```objc
CGRect f = [iconView convertRect:iconView.bounds toView:nil];
CGRect inter = CGRectIntersection(f, sb);
CGFloat ratio = inter.size.width * inter.size.height / (sb.size.width * sb.size.height);
return ratio < 0.18;   // 小于 18% 就认为切换器开了
```

这个假设是错的。**切换器里图标视图并没有被移出层级，只是被盖住、缩小了一点**，
面积比例仍然大于 0.18，所以判断永远返回 NO，浮窗一次都没被关过。

这也是为什么你之前看到的是「浮窗只是黑屏了但没消失」——
窗口还在层级里，只是被切换器的卡片盖住了一半。

## 现在的做法

不再猜视图面积，直接挂切换器自己的视图控制器：

```objc
%hook SBMainSwitcherViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    gSwitcherFlag = YES;
    if (gWindows.count) CloseAll();
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    gSwitcherFlag = NO;
}
%end
```

两个类都挂（`SBMainSwitcherViewController` 和 `SBFluidSwitcherViewController`），
哪个存在就挂哪个 —— iOS 版本之间类名不稳定，这是保险。

### 为什么用 viewWillAppear 而不是 viewDidAppear

切换器会**给各个 App 拍卡片快照**。如果等到 `viewDidAppear`，
浮窗那块黑窗口已经被拍进卡片里了，看起来就是「浮窗变黑但还在」。
`viewWillAppear` 时窗口还在，先删干净，卡片就是干净的。

## 兜底

轮询还是留着，但判据多了一层：

- `gSwitcherFlag`（hook 置位，3 秒保鲜期）
- `SwitcherHasCards()` —— 切换器里的 App 卡片容器只有切换器存在时才有
- `IconViewShrunk()` —— 老判据，降级为最后一道

并且轮询在「浮窗刚出现」时只记基线不动作，
避免某个判据误报 YES 导致浮窗一开就被自己关掉。
