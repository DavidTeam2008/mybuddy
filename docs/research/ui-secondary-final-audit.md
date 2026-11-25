# Liquid Glass 二级页最终验收（#62）

> 日期：2026-11-25。构建基线：`main` = `acdc10a`（#60/#61 已合并）+ 本文档；Xcode 27.1；iPhone 17 Pro Max 模拟器，iOS 26.4.1。
> 截图：`docs/research/ui-secondary-final/`。

## 自动化与模拟器矩阵

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| 全量单元测试 | PASS：379 logical / 405 expanded，0 failed / 0 skipped | `tools/test-unit.sh` |
| 全量 UI 测试 | PASS：10 logical，0 failed（1 个已知模拟器语音 skip） | `tools/test-ui.sh` |
| 静态检查 | PASS | `tools/check-static.sh` |
| 历史页浅/深色 | 通过：系统大标题、玻璃 toolbar、不透明 chips | `history-light.png` / `history-dark.png` |
| 历史页最大字号 | 大标题与空态换行正常；筛选 chips 为横向 ScrollView，屏幕边缘处可滑动查看，无文字截断 | `history-axxxl.png` |
| identifier | `nav-home`、`home-history`、`history-filter-*`、`detail-*` 保持；新增 `HomeToolbarButton` 复用 | UI 测试 |
| 边缘返回 | 详情页置顶时自定义手势让位系统返回（单测覆盖），避免双重 pop | `EdgeSwipeBackPolicyTests` |
| 无新增 skip | UI 仅既有模拟器语音 skip | `tools/test-ui.sh` |

## 需要在 iPhone 13 真机完成的项（模拟器不可覆盖）

- **详情页浅/深色截图**：需要“已完成且有文字稿”的任务。
- **详情页导航**：系统返回回历史、右上「首页」回首页、边缘滑动只回一层（不双重 pop）。
- **VoiceOver**：历史行、详情各 section、分享/删除按钮可读；删除/总结对话框的取消路径可达。
- **ShareLink/share sheet 与删除对话框浅色**：需要真实任务数据。
- **历史列表状态**：有数据时的滚动收起与系统玻璃边缘效果、List 行与 swipe 删除的浅/深色外观。
- **Reduce Transparency / Reduce Motion**：真机设置开启后目视复核（本改版无自定义玻璃，系统 toolbar 自动适配）。

## 结论

- 模拟器可覆盖项全部通过；identifier 稳定，无行为/持久化改动，无新增 skip。
- #62 保持打开，待上述真机项完成后关闭并回填 #59。
