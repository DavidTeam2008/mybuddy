# 决策记录审计（D1–D14）

> 日期：2026-11-29。触发：用户要求“对项目整体复盘和检查，看看哪些重要决策是没有记录的”。
>
> 范围：`docs/decisions.md`、`docs/01-product-design.md`、`docs/02-architecture.md`、`docs/03-tech-choices.md`、`docs/04-roadmap.md`、`GLOSSARY.md`、各 `AGENTS.md`，以及这些文档对应的代码默认值。
>
> 方法：以“会影响用户可见行为 / 数据保留 / 隐私 / 失败处理 / Release 默认”为决策标准，逐项对照代码与文档。只读审计；没有设备/UI 实测的条目在文中标明。

## 0. 结论

1. **决策管理是分层的，不是所有决策都进 D 表**：
   - `docs/decisions.md`：D1–D14，产品/工程决策的唯一真源；
   - `docs/03-tech-choices.md`：技术栈选择；
   - `docs/02-architecture.md`：架构与行为不变量；
   - `docs/04-roadmap.md`：排期与验收真源；
   - `*/AGENTS.md`：工程执行约束。
2. **本轮补记**：D12（Release 默认 B）、D13（面对面默认手动换手）、D14（端侧/无后端/无第三方边界）。此前 D12/D13 只散落在 research/roadmap/architecture，没有 D 编号。
3. **仍有 D 级或代码/文档冲突项**，优先级最高的是：
   - **D6 与代码冲突**：Apple Intelligence 不可用/失败时 `FoundationModelsSummarizer` 仍返回本地 digest；D6 和 03 §7.1 明确“不生成 digest、不冒充 AI”。
   - **冻结口径与代码冲突**：TTS 队列只丢 ≤4 字确认语，队列仍可能超过硬上限 10；冻结口径要求继续丢最旧任务。
   - **能力门禁未按冻结口径落地**：只有首页设置页刷新并传入 `unavailableLanguages`，其它语言入口没有同一快照。
   - **导出快照保留策略没有决策记录**：`Caches/TranscriptExports` 保留 7 天，删除任务不会删除对应快照。
4. 这不是发布签收；P1-1/P1-3 仍未完成。

## 1. 本轮已修复/已记录

| 项 | 处理 | 证据 |
| --- | --- | --- |
| 抢占默认 B | D12；`publishesPreemptedIncumbent=true`，`no` 保留回滚 | `docs/decisions.md` D12；`Duiyi/Services/Speech/UtteranceAssembler.swift:99` |
| 面对面默认手动 | D13；代码默认 `.manual`，manual 下新任务不自动开始 | `PreferencesStore.swift:164-169`；`02-architecture.md` §6.1 |
| 真机设置被测试污染 | fixture/mic harness 加 `-duiyi.prefsSuite` 隔离；设备持久值已恢复 manual | `PreferencesStore.makeDefault()`；`tools/mic-ab-run.sh`、`tools/fixture-run.sh` |
| 产品文档“新任务自动开始”歧义 | 01 §3.3 补 manual 例外 | `docs/01-product-design.md:96` |
| 端侧/离线边界 | 新增 D14 | `docs/decisions.md` D14 |

## 2. 已验证的决策/代码冲突

### P0：D6 总结 digest 回退

- 文档：D6 明确“生成失败/空结果说明本次暂不可用，不展示 digest、不冒充 AI”；`03-tech-choices.md` §7.1 同样写“不生成 digest”。
- 代码：`FoundationModelsSummarizer.summarize` 在 availability 不可用、Foundation Models 抛错或返回空时，仍返回 `ConversationSummary(text: Self.digest(...), usedAppleIntelligence: false)`。
- 证据：`Duiyi/Services/Summary/FoundationModelsSummarizer.swift:29-44`；`SummarySheet.swift:86-97` 用 `usedAppleIntelligence` 区分样式，但 digest 仍会展示。
- 影响：iPhone 13（无 Apple 智能）会显示本地 digest，与 D6/产品文案直接冲突；也影响“总结仅 Apple Intelligence”的发布承诺。
- 建议：删除 digest 回退，返回不可用/错误；或由用户明确改 D6。不要静默保留两条口径。

### P0：TTS 队列硬上限 10 未执行

- 文档：v1 冻结口径“队列硬上限 10，超限先丢最短确认语（compact ≤4 字），再丢最旧任务”。
- 代码：`dropSurplusShortConfirmations()` 在找不到 ≤4 字确认语时直接 `break`，队列可以继续超过 `speechQueueLimit=10`。
- 证据：`Duiyi/Features/Interpretation/InterpretationViewModel.swift:881-892`；`Duiyi/Domain/Models/Clause.swift:26-27`。
- 影响：长句/多 clause 连续到达时 TTS 队列可能无界增长，延迟和内存行为与冻结口径不符。
- 建议：在短确认语清理后，仍超限则移除最旧任务（或由用户改冻结口径）。

### P1：能力门禁没有“同一可观察快照”

- 文档：v1 冻结口径“所有语言选择入口使用同一可观察能力快照；启动后台刷新一次（回到前台可再刷新）”。
- 代码：`SystemLanguageCatalog.refreshCapabilities()` 有 `hasRefreshed` 一次性 guard；唯一调用/传入 `unavailableLanguages` 的入口是 `HomeSettingsSheet`。`InterpretationSettingsSheet`、`MeetingSettingsSheet`、onboarding `LanguagePickView` 没有传入该快照。
- 证据：`Duiyi/Services/Language/SystemLanguageCatalog.swift:108-112`；`HomeSettingsSheet.swift:88-91`；`LanguageChipGrid` 的 `unavailableLanguages` 默认空。
- 影响：用户可在未门禁的入口选择不可用语言，随后才在模块里失败；与冻结口径的“所有入口”不一致。
- 建议：启动/回前台统一刷新，所有 `LanguageChipGrid` 传入同一快照；或收窄冻结口径并记录原因。

### P1：导出快照保留 7 天，且不随任务删除

- 文档：`02-architecture.md` §8 / `03-tech-choices.md` §7.2 只描述“7 天清理机制”，没有产品/隐私决策。
- 代码：`TranscriptExportService` 把完整文字稿+总结写入 `Caches/TranscriptExports`，只按 mtime 7 天清理；删除任务只删 SwiftData，不删快照。
- 证据：`Duiyi/Services/Export/TranscriptExportService.swift:5,78-128`；`HistoryViewModel.swift:68-73`、`TaskDetailViewModel.swift:118`。
- 影响：用户删除任务后，完整文字稿仍可能在 Caches 保留最多 7 天；与“删除任务”的直觉和隐私预期不一致。
- 建议：明确决策——删除任务时删除同 task UUID 的快照，或保留但写入隐私说明；不要只靠注释。

## 3. 重要但未进 D 表的决策

以下不是“完全没记录”，而是只散落在 architecture/tech-choices/AGENTS，缺少 D 级或冻结口径：

| 候选 | 证据 | 为什么重要 | 建议 |
| --- | --- | --- | --- |
| 会议多语言对固定 `[display, display.defaultPeer]` | `01-product-design.md:147`；`02-architecture.md:362`；`MeetingRecognition.languages` | 用户不能自由选第二语言；D4 只写六语实验，没写会议配对规则 | 产品确认后加 D 或在 01/02 明确“v1 固定配对” |
| 双路 `.strict` / 单路 `.trustedLocale` 纯度策略 | `02-architecture.md:207`；`03-tech-choices.md`；`Services/AGENTS.md:13` | 直接决定混读/数字/专名是否被丢；P1-3 的质量核心 | 加 D 或 D8 附录，写清适用范围与降级 |
| 双路资源不足降到单路、失败 transcriber 单路重启、Conversation fallback=peer | `BilingualSpeechEngine.swift:203-208,303-330,530-586`；`ConversationViewModel.swift:743-758` | 一侧语言可能静默停止字幕；用户无提示 | 记录策略；评估是否加可见提示 |
| 语种路由/抢占阈值（1.0 s hold、`1.5×+2`、confidence 门槛） | `UtteranceAssembler.swift:1526-1538,1554-1568`；`ConversationViewModel.swift:674-679` | 决定串音和抢占行为；D12 只定发布行为，没定阈值 | 记录在 D8/D12 附录，避免调参无依据 |
| 行边界常量（0.75 s gap、12 s/120 字 cap、3 s reconciliation、8 条 closed history） | `UtteranceAssembler.swift:157-163,180-193` | 决定字幕行/翻译/TTS 单元 | 作为 D8 的实现附录，不必单独 D |
| 导出/总结语言跟随当前 UI 语言，而不是任务语言 | `TaskDetailView.swift`、`SummarySheet.swift`、`TaskTitle` | 切换 UI 语言会改变历史导出标题/总结语言 | 明确产品口径或按任务语言固定 |
| 偏好默认与迁移：fontSize `.larger`、appMode `.faceToFace`、meeting 单语、`meetingMultilingual.v2` 升级丢弃旧值 | `PreferencesStore.swift:141-187` | 升级后用户设置可能被重置；默认值影响首次体验 | 记录关键默认/迁移；`v2` 迁移至少写说明 |
| 耳机路由丢失时把 `voiceOutEnabled` 持久化关掉 | `InterpretationViewModel.swift:277-284,548-581,935-946` | 一次拔耳机永久改用户偏好 | 明确“仅本次”还是“持久关闭” |
| 翻译失败静默（无错误文案/重试/换语言入口） | `ConversationViewModel.swift:604-606`；`InterpretationViewModel.swift:637-639`；冻结口径要求明确错误 | 用户不知道为什么没有译文 | 归入 P1-4/失败可见状态，记录当前缺口 |
| 诊断仅 DEBUG、无 Release 崩溃/日志通道 | `DiagnosticsRecorder` 全 `#if DEBUG`；D2 把崩溃/日志策略列为待办 | 发布运维/隐私策略未决 | D2 发布工程项下补决策 |

已排除的错误候选：Meeting 切换语言并没有“麦克风流继续跑”；`MeetingView.handleRecognitionChange()` 会先 `viewModel.stop()`，再准备模型/恢复。不要按“静默继续采集”修。

## 4. 建议的决策表增补顺序

1. 先修 D6 digest 回退（代码/文档冲突，影响隐私与产品承诺）。
2. 修 TTS 硬上限 10（冻结口径，代码缺口）。
3. 决策导出快照删除/保留策略（隐私）。
4. 把能力门禁实现到所有入口，或收窄冻结口径。
5. 将会议配对、ASR 降级、纯度/阈值写入 D8/D4 附录（不一定要新 D 编号）。
6. 偏好迁移/voiceOut/导出语言归类为产品口径，按需加 D。

## 5. 验证与限制

- 本次审计为静态代码/文档对照；D6、TTS、能力门禁、导出删除均未在真机上做行为复现。
- 现有质量门禁：单测 575 logical/610 expanded，0 failed/0 skipped；工具测试 13；`verify-utterance-identity` clean；`check-static.sh` PASS。
- 决策记录规则见根 `AGENTS.md`「问题排查与根因记录」；本文件只记录审计结论，不替代 ticket/roadmap。
