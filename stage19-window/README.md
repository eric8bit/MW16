# Stage 19 —— 黑边和裁切的真正来源

## 问题的完整历史

| 版本 | 窗口比例 | 结果 |
|---|---|---|
| Stage17 | 2.165（整屏比例） | 上下两条黑带 |
| Stage18 | 1.80（硬压扁） | 黑带没了，但左右被裁，内容显示不全 |

两次都错在同一件事上：**没有区分「屏幕」和「App 真正画内容的区域」**。

## 黑带是哪来的

App 的 scene 是按整块屏幕（390×844）渲染的，但其中两条带子 App 自己不画：

- 顶部状态栏 47pt —— 时钟、信号、电池都是 SpringBoard 画的
- 底部 Home 指示条 34pt —— 也是 SpringBoard 画的

把 scene 搬进浮窗之后，没有 SpringBoard 去画这两条，它们就是纯黑。
所以「整屏等比缩小」必然带出上下一共 81pt 的黑边 —— 这不是配色问题，是内容本身就不存在。

## 裁切是哪来的

Stage18 把比例硬压到 1.80，但 App 画面还是 2.165 的形状。
`FitContent` 用填充式缩放：

```objc
CGFloat k = MAX(bw / sb.size.width, bh / sb.size.height);
```

取较大比例 = 铺满 = 横向溢出被切掉。这就是「内容显示不全」。

## 正确做法

只针对**中间那段真正有画面的区域**做缩放：

```objc
static CGFloat UsableHeight(void) {
    CGRect sb = [UIScreen mainScreen].bounds;
    return sb.size.height - StatusBarHeight() - HomeInset();   // 844 - 47 - 34 = 763
}

static CGFloat UsableAspect(void) {
    return sb.size.width / UsableHeight();                     // 390/763 = 0.511
}
```

让窗口的比例**等于**这个比例，那 `FitContent` 就是既不留边也不裁切的唯一解：

```objc
CGFloat cw = sb.size.width * 0.80;          // 312
CGFloat ch = cw / UsableAspect();           // 610
```

然后把整块 scene 往上推，让状态栏那条落到窗口外面：

```objc
CGFloat usableTop = (bh - usableScaled) / 2.0;
CGFloat cy = usableTop - StatusBarHeight() * k + sh / 2.0;
content.center = CGPointMake(bw / 2.0, cy);
```

## 加了一个开关

菜单右上角多了「完整 / 铺满」：

- **完整**（默认）：比例对不上就留极窄的边，App 内容一个像素都不少
- **铺满**：不留边，裁掉溢出

点一下立刻作用到已经打开的浮窗，不用关了重开。

如果你觉得还是有一点点边，或者反过来觉得该裁一点，切换这个按钮即可，不用等我出新版。
