# 任务详情页系统 chrome（#61）

> 日期：2026-11-25。构建基线：`main` = #60 合并后 + 本票改动；Xcode 27.1；iPhone 17 Pro Max 模拟器，iOS 26.4.1。

## 做了什么

- 新增共享 `DetailToolbar`：系统返回（回历史）+ 右上「首页」（`nav-home`），标题「记录」（inline）。
- 详情页移除 `ModuleChrome` 与 `.toolbar(.hidden)`；任务标题与 meta 保留为内容首行。
- 总结、文字稿、翻译、导出（`ExportShareButton` 实底）、删除/总结对话框、分享面板保持原样；内容不透明。
- 删除已无调用方的 `ModuleChrome` 与 `TaskBar`；`TaskStatusText` 抽到独立文件（三模块仍在用）。
- `Duiyi/Features/AGENTS.md` 的共享组件清单更新为系统 chrome。
- 系统返回与自定义边缘返回手势的冲突：详情页位于栈顶时自定义手势让位（`EdgeSwipeBackPolicy.defersToSystemPop`，带单测），避免一次滑动双重 pop。

## 验证

- 全量单测/静态/UI 结果见 PR。
- 详情页需要“已完成且有文字稿”的任务；模拟器没有数据 seam，本票不做截图。浅/深色、VoiceOver、分享面板、删除对话框与系统返回行为列入 #62 真机清单。

## 边界

- 未改 VM、持久化、导出/翻译/总结/删除逻辑。
- `detail-*` 等 identifier 不变；`nav-home` 由新 toolbar 提供。
- 无自定义玻璃；仅系统 toolbar/分享面板/对话框。
