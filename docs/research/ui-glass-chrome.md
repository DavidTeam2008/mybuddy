# 系统 chrome 与面对面玻璃（#45）

> 日期：2026-11-25。构建基线：`main` = `d18d5e3` + 本票改动；Xcode 27.1；iPhone 17 Pro Max 模拟器，iOS 26.4.1。

## 做了什么

- 新增共享 `ModuleToolbar`：系统 `NavigationStack` 导航栏承载首页（leading）、任务历史/新任务/结束任务（trailing），标题为模块名（inline）。系统 toolbar 自动提供 Liquid Glass；不再绘制自定义 bar 背景。
- 新增共享 `ToolbarGlyph`：toolbar 图标使用 44 pt label（视觉字形不变）。
- 面对面（`ConversationView`）：
  - 移除 `ModuleChrome` 与 `TaskBar`；状态文字（进行中/没有进行中的任务）移到内容层，位于下方 pane 之上。
  - 双 pane 保持不透明、旋转 180° 与 `accessibilityHidden` 不变。
  - 中央麦克风是唯一自定义玻璃：`.glassEffect(.regular.tint(Tokens.listen).interactive(), in: Circle())`，命中区 88 pt；失败态回退不透明 `danger`，禁用态回退 `controlIdle`，Reduce Transparency 回退不透明 `listen`。
  - 中间控制带（对调/设置）保持不透明 `canvas`；设置/对调仍由 `ListeningControl` 承载。
- 同传/会议暂未换 chrome（在 #47/#48 接入同一 `ModuleToolbar`/`ListeningControl`）。

## 验证

- 截图：`docs/research/ui-glass-chrome/face-to-face-light.png`、`face-to-face-dark.png`（恢复任务后、未开始聆听 → 玻璃麦克风）；失败态见 `face-to-face-failed-light.png`（不透明 danger 圆 + 感叹号）。
- `DuiyiUITests`：`nav-home`/`nav-history`/`taskbar-new-task`/`taskbar-end-task` 现在位于系统 toolbar，identifier 与禁用态由 `HitTargetTests.testModuleToolbarEntries` 覆盖；系统 toolbar item 的无障碍框由 Apple 管理（实测约 44×36），不再按自定义控件量测。
- 自定义控件（DirectionBar、VoiceOut、chips、历史筛选、设置齿轮）仍按 ≥44×44 断言。
- 单测/静态/UI 套件结果见 PR。

## 边界

- 状态文字不再是固定 bar 的一部分；滚动/长标题时随内容移动（本屏无滚动，无影响）。
- 系统 toolbar 的玻璃外观随 iOS 版本与 Reduce Transparency/Increase Contrast 自动变化；未自定义 toolbar 背景。
- 每屏只有系统 toolbar（系统玻璃）与一个麦克风（自定义玻璃）；麦克风位于不透明控制带上，无 glass-on-glass。
- Reduce Motion 仍门控麦克风 pulse；VoiceOver label/hint 未改。
- iPhone 13 构建在 PR 中验证（generic iOS build，签名来自本地 `Config/Local.xcconfig`）。
