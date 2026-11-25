# 会议记录系统 chrome（#48）

> 日期：2026-11-25。构建基线：`main` = #46 合并后 + 本票改动；Xcode 27.1；iPhone 17 Pro Max 模拟器，iOS 26.4.1。

## 做了什么

- 接入共享 `ModuleToolbar`：系统导航栏承载首页/任务历史/新任务/结束任务，标题为“会议记录”（inline）。
- 移除 `ModuleChrome`/`TaskBar`；任务状态文字下沉到内容层（语言 badge 上方）。
- 语言 badge/文字稿与 2 万字计数保持不透明；多语言标注、清屏/恢复语义不变。
- 安全区改由系统导航栏处理：移除自定义顶部 padding；麦克风底部改为 16 pt（安全区自动计入）。
- 麦克风仍是唯一自定义玻璃；无任务/失败/降低透明度时回退不透明。

## 验证

- 截图：`docs/research/ui-glass-meeting/meeting-light.png`、`meeting-dark.png`。
- UI 测试：`testRestoredTaskShowsResumePrompt`（新建任务/恢复提示）、`testModuleToolbarEntries`（toolbar identifier）覆盖本模块；全部通过。
- 单测/静态/UI 套件结果见 PR。

## 边界

- 会议没有 VoiceOut；麦克风 `showsSwap: false` 不变。
- 2 万字限制、多语言识别与总结逻辑零改动。
- 语言 chip 与设置 sheet 的外观不在本票重设计范围。
