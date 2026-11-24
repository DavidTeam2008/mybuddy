# 05 架构候选台账

> 本文保存 2026-11-23 架构审查的 17 项候选，以及针对 `main @ 37f0a50` 的复核结果。
> **定位**：候选台账，不是承诺，也不是排期。它只回答“有哪些候选、做到哪一步、证据是什么、建议怎么分批”。
> **真源**：产品行为、优先级与排期以 [`04-roadmap.md`](04-roadmap.md) 为准；架构现状见 [`02-architecture.md`](02-architecture.md)，选型理由见 [`03-tech-choices.md`](03-tech-choices.md)。本文件不复制 P0/P1 的验收判据。
> 证据以类型/函数名为准；行号会漂移，不写入表格。本文与 2026-11-02 退休的旧 05–13 文档无关。

---

## 0. 定位与读法

- **候选不是任务**：进入本表不代表已立项、已排期或承诺在 v1 完成；是否做、何时做由 `04-roadmap.md` 决定。
- **状态**：`已完成` = 可在代码中指出落地接缝；`部分` = 主要痛点已修但仍有明确剩余摩擦；`未做` = 复核时未发现对应实现。
- **建议强度**：保留审查原词的两档——**强（Strong）** 与 **值得探索（Worth exploring）**；动作分为合并、保留、删除。表中写作“强·合并”“值得探索·删除”等，仅表示审查建议，不表示优先级。
- **04 映射**：`已覆盖` / `部分覆盖` / `不在列表` 描述该候选在 `04-roadmap.md` 待办中的收录情况，与代码完成状态是两个维度。映射为“已覆盖”不等于代码已完成。

---

## 1. 已完成（5）

| # | 候选 | 证据 |
| --- | --- | --- |
| C01 | TaskStore 接缝只有成功路径 | `TaskStore` availability/prepare/retry + `TaskStoreV2` result reads/writes；`DeferredTaskStore` 无内存回退。Wave 1 #2/#5/#12 |
| C02 | 听写流缺少 owner/generation | `SpeechSessionGate` + `SpeechSessionHandle(owner, generation)`；3 个 VM 均经 `TaskLifecycle`。Wave 1 #3/#4/#6–#8 |
| C03 | 任务与听写生命周期没有 module | `TaskLifecycle` owns current/status/restore/prepare/startNew/startListening/end/persist-debounce/scene-phase/empty-delete。Wave 1 #4/#6–#8 |
| C05 | 翻译 job 管线复制两份 | `TranslationPipeline` + Domain `TranslationTrigger`；两个 VM 均用 pipeline，无跨 VM static。Wave 2 #15/#17/#18 |
| C07 | 翻译 Host 住在 Conversation | 共享 `TranslationHostView` + `TranslationJobBridge` + `TranslationJobPump`；Conversation/Interpretation/TaskDetail/Onboarding 使用。Wave 2 #16，P1-1 #22–#25 |

---

## 2. 剩余候选（12）

| # | 候选 | 状态 | 建议强度 | 证据 / 剩余摩擦 | 04 映射 |
| --- | --- | --- | --- | --- | --- |
| C04 | 字幕/文字稿投影有 4 份实现 | 部分 | 强·合并 | 50 条上限导致的 transcript 丢失已修；跨 utterance id 的短句误合并已修（2026-11-24，含 PaneState/三模块语音流回归）；但 `PaneState.history` 仍可变；仍有 3 处 `upsertTranscript`（Conversation/Interpretation/Meeting），且各 VM 恢复时各自重新投影。 | Wave 3 — 已覆盖 |
| C06 | 能力门禁与资产准备没有 module | 未做 | 强·合并 | 仅 `HomeSettingsSheet` 消费 `unavailableLanguages`；5 条 `speechModels.prepare` 流程（Home/Onboarding/Conversation/Interpretation/Meeting）；无 gate module。 | P2-6 + P3-3 — 部分覆盖 |
| C08 | 总结用例没有 module | 未做 | 强·合并 | 4 条独立 summarize 路径（3 个 VM + `TaskDetailViewModel`）；2 处可用性横幅。 | P3-3（4 个总结）— 部分覆盖 |
| C09 | 组合根有两个组装点 | 未做 | 值得探索·合并 | `AppEnvironment` 仍有 12 个 let；`RootView.make*` + route switch；VM 默认使用 `InMemoryTaskStore`。 | 不在列表 |
| C10 | 模块身份散落六处 | 未做 | 值得探索·合并 | `FeatureRegistry` 仅用于显示；无 `FeatureDescriptor` 承载 route/colors/construction；`RootView` 逐模块 switch/make*。 | 不在列表 |
| C11 | AudioCapturing 只有真实适配器 | 未做 | 强·保留 | 只有 `AudioEngineCapturer`；`DuiyiTests` 无 fake PCM；`BilingualSpeechEngine` 仍持有 analyzer/transcriber/降级/切换策略。 | 不在列表（P2-2 相邻，但不是测试接缝） |
| C12 | 测试/预览替身散在三处 | 未做 | 值得探索·合并 | `PreviewSupport` 仍在 app target；测试自定义 `Mock*`；生产 VM 默认值含 `NoOpAudioSession` / `InMemoryTaskStore`。 | 不在列表 |
| C13 | ClauseSplitter volatile 分支运行时不可达 | 未做 | 强·删除 | `ClauseSplitter.consume(...isSettled:)` 仍有 volatile 分支/helpers；生产固定传 `true`；volatile 测试仍在。 | 不在列表 |
| C14 | pausedListening 只写不读 | 未做 | 值得探索·合并 | `TaskStatus.pausedListening` 存在；`TaskLifecycle` 会写入；读取方只比较 `.ended`；`TaskMapping` 未知 raw 返回 nil。 | 不在列表 |
| C15 | StaticLanguageCatalog 零引用 | 未做 | 强·删除 | 仍定义于 `Domain/LanguageCatalog.swift`；全仓零引用。 | 不在列表 |
| C16 | AudioSessionConfiguring.deactivate() 零调用 | 未做 | 强·删除 | 协议成员与实现都在；无生产调用点。 | P2-4 — 部分覆盖 |
| C17 | BufferConverter int16 分支不可达 | 未做 | 值得探索·删除 | int16 分支仍在；唯一调用点使用 tap 输入格式（Float32）。 | P2-3 — 部分覆盖 |

---

## 3. 计数与覆盖缺口

### 3.1 计数

| 项 | 数量 | 编号 |
| --- | --- | --- |
| 候选合计 | 17 | C01–C17 |
| 已完成 | 5 | C01, C02, C03, C05, C07 |
| 部分完成 | 1 | C04 |
| 未做 | 11 | C06, C08, C09, C10, C11, C12, C13, C14, C15, C16, C17 |
| 剩余合计 | 12 | C04, C06, C08–C17 |

### 3.2 与 04 待办的覆盖缺口

- **不在列表（7）**：C09、C10、C11、C12、C13、C14、C15。
- **部分覆盖（4）**：C06（P2-6 / P3-3）、C08（P3-3）、C16（P2-4）、C17（P2-3）。
- **已覆盖（1）**：C04（Wave 3）。

注意：覆盖状态只说明 `04-roadmap.md` 是否已有对应条目，与代码完成状态是两个维度。C04 已在 `04` 立项为 Wave 3，但代码上仍是“部分完成”；其余 7 项尚未进入 `04` 待办。

---

## 4. 建议的 Wave 3 分批

以下只是审查给出的分批建议，不表示依赖顺序或优先级；是否进入 Wave 3、如何排期由 `04-roadmap.md` 决定。

| 批次 | 候选 | 范围 |
| --- | --- | --- |
| 清理（低风险） | C13, C15, C16, C17 | 删除不可达分支、零引用定义与零调用成员 |
| 核心投影 | C04 | 收敛字幕/文字稿投影 |
| 模块化 | C06, C08 | 能力门禁与资产准备、总结用例 |
| 测试接缝 | C11, C12 | 可替换音频适配器、测试/预览替身 |
| 可选 / 值得探索 | C09, C10, C14 | 组合根、模块身份、`pausedListening` 语义 |

---

## 5. 维护规则

1. **单一职责**：本文件只维护候选、状态、证据与 04 映射。产品行为与验收判据放 `02`，选型理由放 `03`，优先级与排期放 `04`。
2. **编号稳定**：C01–C17 不复用；新增候选从 C18 顺延。删除或合并候选时保留编号与历史行，标记去向，不重排。
3. **状态要有证据**：状态变更必须附代码依据（类型/函数名、测试或提交）；不写“已优化”这类无锚点结论，不写易漂移的行号。
4. **完成即迁移**：候选完成后移到“已完成”表，补齐证据，更新计数与 04 映射；仅在 04 已收录时才调整 04 的排期。
5. **映射随 04 回填**：`04-roadmap.md` 的待办增删后，回填本表“04 映射”列；但不要把 04 的优先级、预估或验收判据抄进来。
6. **分批不是承诺**：Wave 3 批次只是审查建议；每轮架构审查后整表复核，未复核的旧结论应标注复核基线。
