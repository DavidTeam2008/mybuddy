# 语义 token 与系统明暗（#43）

> 日期：2026-11-25。构建基线：`main` = `0eeda74` + 本票改动；Xcode 27.1；iPhone 17 Pro Max 模拟器，iOS 26.4.1。
> 截图均为模拟器；`light-*` / `dark-*` 对应系统外观。

## 做了什么

- 固定暗色 hex 改为语义 `TokenPalette`：light / dark / increased contrast 三档，覆盖画布、pane、文本、强调、危险、警告、控制、chip、sheet、品牌卡片与语言色。
- 品牌金色保留为填充 `Tokens.listen`；链接/图标/文本改用可读的 `Tokens.accentText`；新增 `onAccent`、`onDanger`、`blockedBackground`、`warningText`/`warningBackground`、`intelligenceText`/`intelligenceBackground` 等状态 token。
- 移除 App 入口与所有页面的 `.preferredColorScheme(.dark)`；App 跟随系统明暗。
- 移除 HomeSettingsSheet 内部 `.background(Tokens.canvas)`，系统 sheet 材质可见。
- 修复同传方向条 10 pt 说明文字（`他说`/`我听`）固定 `.opacity(0.7)` 在浅色下对比度不足的问题：改为全不透明 `Tokens.textSecondary`；语言徽标统一用 `Tokens.languageBadge(_:)`。
- `TokensTests` 固定对比度：普通文本 4.5:1；失败态大符号 3:1；覆盖 light/dark/increased contrast，以及 pane、sheet、chip、控制件、品牌卡片、语言徽标与 Apple 智能徽章。
- 未改 VM、持久化、翻译/听写/TTS 行为或 accessibility identifier。

## 验证

- `tools/test-unit.sh`：**378 logical / 404 expanded，0 failed / 0 skipped**。
- `tools/check-static.sh`：PASS。
- `tools/test-ui.sh`：PASS（仅已知模拟器语音 skip）。
- 截图（`docs/research/ui-tokens/`，共 14 张）：`light-home`、`light-settings`、`light-conversation`、`light-interpretation`、`light-meeting`、`light-history`、`light-onboarding`；同名的 `dark-*` 7 张。Settings 截图可见系统 sheet 的半透明材质；引导页、历史页与同传方向条也随系统明暗切换。

## 边界与注意

- 设置页的语言 chip 中，未安装模型的语言为禁用态（0.45 opacity）；禁用控件不参与 WCAG 对比度阈值。
- 首页存在一条未结束任务横幅，属模拟器测试数据；历史页为空态截图。任务详情（TaskDetail）需要已结束的任务才能进入，本轮没有对应数据，未截图；该页只做 token 替换，无布局改动。
- 插画仍是自包含的固定色（内容装饰），未 token 化；Apple 智能徽章已 token 化。
- 三模块仍使用自定义 `ModuleChrome`/`TaskBar`；系统导航与玻璃在 #45–#48。
- 44 pt 触达在 #44。
