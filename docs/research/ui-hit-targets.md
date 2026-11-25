# 44 pt 热区与无障碍基线（#44）

> 日期：2026-11-25。构建基线：`main` = `0b83453` + 本票改动；Xcode 27.1；iPhone 17 Pro Max 模拟器，iOS 26.4.1。
> 量测来源：Maestro/XCUITest 无障碍层级（屏幕坐标，单位 pt）。

## 做了什么

- 新增 `Tokens.minHitTarget`（44）与 `Duiyi/DesignSystem/HitTarget.swift` 的 `View.minHitTarget()`：只扩大控件的布局/命中区域，不放大内部视觉。
- 新增共享 `SelectChip` 与 `FontSizeChips`，替换四个设置页里重复的私有 chip 与字号三连实现（Settings、HomeSettings、Meeting、Interpretation）；chip 视觉保持约 42 pt，命中/无障碍框 44 pt。
- 覆盖票面列出的控件：
  - `TaskBar` 新任务 / 结束任务（文字按钮 → label 内 44 pt）；
  - `ModuleChrome` 首页 / 任务历史；
  - `DirectionBar` 交换钮视觉保持 40 pt，命中/无障碍框 44 pt；方向徽标加 `minHeight` + `contentShape`；
  - `VoiceOutControl` 胶囊视觉 36 pt，命中/无障碍框 44 pt；
  - `LanguageChipGrid`、设置页 `SelectChip`、`HomeSettingsSheet` 字号 chip；
  - `HistoryView` 筛选 chips（胶囊视觉 28 pt，命中/无障碍框 44 pt）。
- 补充标识符（只增不改）：`settings-open`、`direction-swap`、`voice-out`、`history-filter-all`、`history-filter-<feature>`（沿用 `home-module-<feature>` 的 rawValue 命名）。
- VoiceOver label/hint、倒字侧 `accessibilityHidden`、Reduce Motion 对 pulse/scroll 的门控均未改动。

## 量测（模块内 1:1 屏幕坐标）

| 控件 | 量测 | 尺寸 |
| --- | --- | --- |
| nav-home | `[22,70]–[66,114]` | 44×44 |
| nav-history | `[358,70]–[418,114]` | 60×44 |
| settings-open（模块） | `[382,456]–[426,500]` | 44×44 |
| taskbar-new-task | `[301,118]–[346,162]` | 45×44 |
| taskbar-end-task（禁用） | `[358,118]–[418,162]` | 60×44 |
| direction-source | `[22,170]–[190,214]` | 168×44 |
| direction-swap | `[198,170]–[242,214]` | 44×44 |
| direction-target | `[250,170]–[418,214]` | 168×44 |
| voice-out | `[176,878]–[264,922]` | 88×44 |
| langchip（模块设置层） | `[30,289]–[151,333]` | 121×44 |
| SelectChip「面对面」 | `[30,144]–[216,188]` | 186×44 |
| SelectChip「标准/更大/最大」 | `[30,539]–[110,583]` 等 | 44 高 |
| history-filter-all | `[22,118]–[72,162]` | 50×44 |
| history-filter-meeting | `[234,118]–[310,162]` | 76×44 |

## 系统 sheet 的缩放说明

`HomeSettingsSheet` 是系统 `.sheet`。当前运行时把 sheet 内容绘制在 424 pt 宽的卡片里（屏幕 440 pt），缩放比 424/440 ≈ 0.9636；因此**布局 44 pt 的 chip 在屏幕坐标读数为 42.4 pt**（XCUITest 实测 `42.40000000000009`），与 Apple 自带控件在同一 sheet 中的读数一致。

处理方式（不是豁免）：`HitTargetTests.testHomeSettingsSheetChipLayout` 用 sheet 导航栏宽度 / 屏幕宽度求出呈现缩放，再把 chip 的屏幕 frame 归一化回 sheet 坐标后断言 ≥44；该用例在含禁用语言 chip 的首页 sheet 上通过。模块内嵌设置层（1:1）另有 `testLanguageChips` 直接断言 44。

## 验证

- 新增 `DuiyiUITests/HitTargetTests`（5 个用例）：ModuleChrome/TaskBar、DirectionBar+VoiceOut、语言 chips（模块内 1:1）、首页系统 sheet chip（缩放归一化）、历史筛选 chips。断言会先等待 frame 稳定（sheet/导航动画），并允许 0.5 pt 浮点回读误差。
- `tools/check-static.sh`：PASS。
- `tools/test-unit.sh`：378 logical / 404 expanded，0 failed / 0 skipped。
- `tools/test-ui.sh`：10 logical（含新增 5 个），仅已知模拟器语音 skip。

## 边界

- 设置页里的文字链接（清屏/总结/重新下载/完成）不在本票清单内，未扩热区；它们仍受后续 #49 真机无障碍复核覆盖。
- 首页模块卡与历史行本身已 ≥44 pt，未改动。
- DirectionBar 的源/目标徽标不在票面括号清单里，但同属 “所有交互控件 ≥44” 的标题要求，且原高度约 42 pt，因此一并补齐；视觉外观不变。
- `SelectChip`/`FontSizeChips` 的抽取是行为中性的复用（四个设置页原本各有一份私有实现），用于让热区修正在一处生效。
- 视觉上没有风格改动：文字按钮只加布局热区，胶囊/圆形/徽标的可见尺寸保持不变。
