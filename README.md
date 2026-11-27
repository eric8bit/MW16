# MW16 — iOS 16 分屏 / 小窗插件

基于 [MilkyWayReborn](https://github.com/34306/MilkyWayReborn) 思路重写，
针对 **iOS 16.6.1 + Relaxin(RootHide)** 的 iPhone 悬浮窗口化多任务。

## 不会写代码？从这里看

- **[从这里开始](开始这里.md)** — 先读这个
- [云端编译自己的插件](guides/02-云端编译自己的插件.md)
- [Stage 1 验证包的说明](stage1-hello/README.md)
- [代码检查报告](检查报告.md)

## 目录

```
stage1-hello/   Stage 1：只画一个按钮，验证注入链路（不做任何系统改动）
probe/          探针：只读系统信息，输出日志
src/            主插件（Stage 2~4）
.github/        云端自动编译
guides/         中文操作步骤
PLAN.md         技术方案与决策记录
```

## 分阶段路线

| 阶段 | 内容 | 状态 |
|---|---|---|
| Stage 1 | 注入链路验证：桌面出现 S1 按钮 | 代码就绪，待编译验证 |
| Stage 2 | 单窗口：一个 App 浮起来 | 代码就绪，未验证 |
| Stage 3 | 多窗口 + 关闭回收 | 代码就绪，未验证 |
| Stage 4 | 前台保活 + 键盘 | 代码就绪，未验证 |

## 给开发者

```bash
export THEOS_PACKAGE_SCHEME=roothide
make clean package FINALPACKAGE=1        # 主插件
cd stage1-hello && make clean package FINALPACKAGE=1
cd probe && make clean package FINALPACKAGE=1
```

需要 [roothide/theos](https://github.com/roothide/theos)。本机未安装 Theos，
全部编译在 GitHub Actions 上完成（`.github/workflows/build.yml`）。
