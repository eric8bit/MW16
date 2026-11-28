# Stage 18 —— 形状 + 手柄命中

## 两个问题，两个独立原因

### 1. 纵向太长

之前窗口尺寸写成：

```objc
CGFloat aspect = sb.size.height / sb.size.width;   // 844/390 = 2.165
CGFloat ch = sb.size.height * 0.58;
CGFloat cw = ch / aspect;
```

也就是说，窗口就是把整块手机屏幕**等比缩小到 58%**。
手机的 2.165 比例本来就瘦，缩成小窗之后就是一根竖长条。

现在：

```objc
const CGFloat kAspect = 1.85;
CGFloat cw = sb.size.width * 0.74;
CGFloat ch = cw * kAspect;
```

289 × 534，横向铺开到屏宽的 74%，纵向只占 63%。

比例不再是屏幕比例，就必然要处理「画面放不进去」——
`FitContent` 用的是**填充式**缩放（`MAX` 而不是 `MIN`）：

```objc
CGFloat k = MAX(bw / sb.size.width, bh / sb.size.height);
if (sh > bh) cy = bh - sh / 2.0;   // 超出部分从顶部裁掉，底部对齐
```

所以：**没有黑边**，代价是顶部那条状态栏被裁掉。
底部标签栏完整保留——对 App 来说那个更重要。

### 2. 触发点在弧和拐角之间的空白

两处都错了。

**位置错**：上一版把手柄圆心放在内容右下角 `(cw, ch)`，弧向**右下外侧**鼓出去。
弧的 45° 中点落在 `(cw+21, ch+21)`，离面板 30pt，看起来就是一条挂在窗口外面的独立弧线。

**命中错**：手柄视图是 68×68 的正方形，`UIView` 默认整块都能接触摸。
弧只占这个正方形里的一条边，剩下全是空白——用户按到的是空白，不是弧。

现在：

```objc
const CGFloat cornerR = 22;                               // 内容圆角
const CGFloat arcR = 26;                                  // 比圆角大 4pt
CGPoint arcC = CGPointMake(cw - cornerR, ch - cornerR);   // 圆角的圆心
```

弧的圆心 = 内容圆角的圆心，半径 26。于是这条弧**始终贴着圆角外侧 4pt** 走：

- 0° 端点 `(cw+4, ch-22)`
- 45° 中点 `(cw-3.6, ch-3.6)`
- 90° 端点 `(cw-22, ch+4)`

整条弧咬着拐角，不再悬空。窗口的 `gap` 也从 30 缩到 10。

命中区用 `MWHandleHitView` 重写：

```objc
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat dx = point.x - _arcCenterInView.x;
    CGFloat dy = point.y - _arcCenterInView.y;
    CGFloat d = sqrt(dx * dx + dy * dy);
    if (dx < 0 || dy < 0) return NO;             // 只在那一象限
    if (fabs(d - _arcRadius) > 16.0) return NO;  // 只在弧线 +-16pt 的环带上
    return YES;
}
```

正方形里除了弧线附近，其它位置一律 `NO`——触摸会穿透到下面的 App。
**能按到的就是看见的那条白弧**，误差 ±16pt（约一个手指宽度），保证好按。

## 手势

| 操作 | 效果 |
|---|---|
| 双击白弧 | 关闭浮窗 |
| 快速拖动白弧 | 移动浮窗 |
| 按住白弧 0.4s 不动 | 轻震一次，**不抬手**继续拖 = 缩放 |
