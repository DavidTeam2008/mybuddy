# 首页系统 chrome（#46）

> 日期：2026-11-25。构建基线：`main` = #45 合并后 + 本票改动；Xcode 27.1；iPhone 17 Pro Max 模拟器，iOS 26.4.1。

## 做了什么

- 首页改用系统 `NavigationStack` 大标题（`对译`）+ 系统玻璃 toolbar：右上角任务历史（`home-history`）与设置（`settings-open`）。
- 移除自定义 header（旧的大标题 + 齿轮）与底部“任务历史”大卡片；历史入口移到 toolbar，identifier 保留。
- 模块卡片与未结束任务行保持不透明、品牌 tint 不变；不使用玻璃卡片。
- `FeatureRegistry.visible` 三张卡的 `home-module-*` identifier、label、hint 不变。
- toolbar 图标使用共享 `ToolbarGlyph`（44 pt label；系统 glass 由 toolbar 提供）。

## 验证

- 截图：`docs/research/ui-glass-home/light-home.png`、`dark-home.png`（大标题、玻璃 toolbar、不透明卡片）。
- `DuiyiUITests`：`assertHomeModuleNavigation`/`testHistoryFilterChips` 经 `home-history`（现在是 toolbar 项）进入历史；`testHomeSettingsSheetChipLayout` 经 `settings-open` 打开系统 sheet，均通过。
- 单测/静态/UI 套件结果见 PR；generic iOS 真机构建通过。

## 边界

- 未结束任务行仍按原有行布局与颜色；本票不重设计。
- 大标题的滚动态与 toolbar 玻璃由系统处理；未添加自定义 `scrollEdgeEffectStyle` 或背景。
- 历史页本身仍是 #42 审计出的自定义 `ModuleChrome`（不在本票范围）。
