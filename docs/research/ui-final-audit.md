# Liquid Glass 改版最终验收（#49）

> 日期：2026-11-25。构建基线：`main` = `3375d5d`（#45–#48 已合并）+ 本文档；Xcode 27.1；iPhone 17 Pro Max 模拟器，iOS 26.4.1。
> 截图：`docs/research/ui-final-audit/`。

## 自动化与模拟器矩阵

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| 全量单元测试 | PASS：378 logical / 404 expanded，0 failed / 0 skipped | `tools/test-unit.sh` |
| 全量 UI 测试 | PASS：10 logical，0 failed（1 个已知模拟器语音 skip） | `tools/test-ui.sh` |
| 静态检查 | PASS | `tools/check-static.sh` |
| 浅/深色：首页 + 三模块 | 通过，内容不透明、系统 toolbar 玻璃 | `*-light.png` / `*-dark.png`（8 张） |
| 最大字号（accessibility-extra-extra-extra-large） | 首页可滚动到模块卡；文字换行不截断；同传方向条/读出译文可读 | `home-axxxl.png`、`interpretation-axxxl.png` |
| Increase Contrast | 玻璃自动更实、文字高对比；麦克风金色不透明 | `face-to-face-increase-contrast.png` |
| Reduce Transparency | 麦克风走不透明 `listen` 回退（代码路径；视觉与玻璃态同为金色圆） | `ListeningControl.micFill` |
| Reduce Motion | 麦克风 pulse 仍由 `ReduceMotion.allowed` 门控；本次未新增动画 | 代码与既有行为 |
| 44pt | 自定义控件均由 `HitTargetTests` 覆盖；系统 toolbar 由 Apple 管理 | `DuiyiUITests/HitTargetTests` |
| identifier 稳定 | `nav-*`/`taskbar-*`/`home-*`/`langchip-*`/`direction-*`/`voice-out`/`history-filter-*` 均保留或仅新增 | UI 测试 |
| 系统组件复核 | toolbar/sheet/dialog/share 均为系统组件；HomeSettingsSheet 系统材质可见；confirmationDialog 仍为系统卡片 | `docs/research/xcode-27-appearance-audit.md` + #43 截图 |
| 范围外页面 | 历史/设置/引导在浅/深色可读（#43 截图），本票无改动 | `docs/research/ui-tokens/` |

## iPhone 13 真机验证（2026-11-25 完成）

用户已在 iPhone 13 真机上完成并确认以下项全部通过：

- **Release 连续 60 分钟中↔英会话**：无崩溃、无静音卡死、无识别暂停误报、无热中断。
- **VoiceOver 只读用户侧**：进入面对面后只朗读用户侧内容，倒字侧不朗读（倒字侧保留 `.accessibilityHidden(true)`）。说明：本票曾尝试用 XCUITest 断言，但当前运行时 XCUITest 仍能枚举标记 `accessibilityHidden` 的元素，因此该结论以真机 VoiceOver 听读为准。
- **Reduce Transparency / Reduce Motion**：真机设置开启后目视复核通过（麦克风回退不透明、pulse 停用）。
- **ShareLink/share sheet 与 confirmationDialog 浅色**：真机用“已完成且有文字稿”的任务验证通过。
- **confirmationDialog 取消按钮的 VoiceOver 可达性**：真机复核通过。

## 结论

- 模拟器矩阵与 iPhone 13 真机项全部通过；改版未改 VM/持久化/翻译/听写/TTS 行为，identifier 稳定，无新增 skip。
- #49 可关闭，#41 已回填最终结果。
