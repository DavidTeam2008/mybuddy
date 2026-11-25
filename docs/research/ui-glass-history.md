# 历史页系统 chrome（#60）

> 日期：2026-11-25。构建基线：`main` = `5ae025a` + 本票改动；Xcode 27.1；iPhone 17 Pro Max 模拟器，iOS 26.4.1。

## 做了什么

- 新增共享 `HistoryToolbar`：系统大标题 + 左上「首页」（`nav-home`，隐藏系统返回以保持旧语义）。
- 历史页移除 `ModuleChrome` 与 `.toolbar(.hidden)`；筛选 chips 保留在标题下方内容层。
- `List` 行、空态、swipe 删除、错误横幅与系统对话框全部保持原样且不透明。
- 44 pt：toolbar 图标走共享 `ToolbarGlyph`；筛选 chips 沿用 #44 的 `minHitTarget`。

## 验证

- 截图：`docs/research/ui-glass-history/history-light.png`、`history-dark.png`（大标题、玻璃 toolbar、不透明 chips）。
- 全量单测/静态/UI 结果见 PR。
- 共享 toolbar：本票落地大标题 + 首页的 `HistoryToolbar`；详情变体随 #61 落地（避免先提交未使用的代码）。

## 模拟器覆盖不到、留给最终验收（#62）真机清单

- 有历史行时的滚动收起与系统玻璃边缘效果：模拟器没有“已完成且有文字稿”的任务，空态无法产生滚动内容。
- List 行、swipe 删除、错误横幅的浅/深色截图：同上，需要真机数据。

## 边界

- 未改历史行布局、筛选逻辑、删除语义或持久化。
- 筛选 chips 固定在标题下方；列表滚动时 chips 不随行移动。
- `ModuleChrome` 仍被详情页使用，#61 完成后删除。
