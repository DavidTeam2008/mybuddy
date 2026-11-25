# 同声传译系统 chrome（#47）

> 日期：2026-11-25。构建基线：`main` = #46 合并后 + 本票改动；Xcode 27.1；iPhone 17 Pro Max 模拟器，iOS 26.4.1。

## 做了什么

- 接入共享 `ModuleToolbar`：系统导航栏承载首页/任务历史/新任务/结束任务，标题为“同声传译”（inline）；系统 toolbar 自动提供玻璃。
- 移除 `ModuleChrome`/`TaskBar`；任务状态文字下沉到内容层（方向条上方）。
- 方向条、读出译文、清屏/设置/总结入口保持原有控制层与不透明样式；字号 chip 仍为 `SelectChip`。
- 字幕 pane 与 50 条显示窗口、恢复/清屏语义不变；不在 live 字幕上加玻璃。
- 安全区改由系统导航栏处理：移除自定义 `ScreenSafeArea.top` 顶部 padding，背景仍铺满全屏；麦克风底部改为 16 pt（安全区自动计入）。
- 麦克风仍是唯一自定义玻璃（`ListeningControl`）；无任务/失败/降低透明度时回退不透明。

## 验证

- 截图：`docs/research/ui-glass-interpretation/interpretation-light.png`、`interpretation-dark.png`。
- UI 测试：`assertHomeModuleNavigation`、`testDirectionBarAndVoiceOut`、`testLanguageChips` 覆盖本模块导航/方向条/语言 chip；全部通过。
- 单测/静态/UI 套件结果见 PR。

## 边界

- DirectionBar 与底部 `VoiceOutControl` 的 44 pt 热区沿用 #44 的实现。
- 50 条显示窗口、TTS/voiceOut 门禁、翻译管线零改动。
- 总结/清屏按钮的外观不在本票重设计范围。
