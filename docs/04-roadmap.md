# 04 当前问题与优化路线

> 本文是**当前**的工程待办与风险清单，替代早期的 04/08/12 路线图与 13 的问题清单。
> 架构见 [`02-architecture.md`](02-architecture.md)，选型见 [`03-tech-choices.md`](03-tech-choices.md)。
> 每条都尽量给出代码依据；行号会漂移，以类型/函数名为准。
> **真源声明**：本文件的 P0/P1 验收判据与排期是唯一真源；[`decisions.md`](decisions.md) 的 D1–D8 / D-B* / D-AI* 只是决策记录，不影响排期判定；
> 所有待确认决策统一见 [`decisions.md`](decisions.md)（本文件 §7 只保留指针）。

## 0. 状态

| 项 | 状态 |
| --- | --- |
| 启动优化 | 已暂停；200 ms 目标判定不可达，见 [`case-startup-performance.md`](case-startup-performance.md) |
| 已结束任务译文回填 | 已修复（历史修复记录见 git 历史） |
| UI 测试“存在但不可点击” | 已闭环（回归测试在 `DuiyiUITests`） |
| 文档整理 | 2026-11-02 合并 01–13 为 01–04；05–13 已退休 |
| 死代码清理 | 2026-11-02 删除未引用函数/常量/本地化键（见 §5） |
| 导出竞态与内容刷新 | 已修复（2026-11-17；回归测试在仓库内；原归档证据未随提取保留） |
| 语言切换清态 | 已修复；当前实现与回归覆盖见 Conversation/Interpretation ViewModel 测试 |
| 语言目录实查 | 生产注入 `SystemLanguageCatalog`（探针缓存）；当前仅首页设置消费，v1 扩展到所有语言入口 |
| Wave 1 数据完整性 | 已合并到 `wave-1-data-integrity`（#2–#12，tip `fd820e4`）：TaskStoreV2、SpeechSessionGate、TaskLifecycle、显性存储降级、清屏/50 条/2 万字语义。iPhone 13 真机清单未验证 |
| P1-1 翻译队列积压 | 已完成（#22–#25，main `37f0a50`）；真机验证 2026-11-24 通过（用户确认）；#21/#26 已关闭 |
| Wave 3 C04 字幕/文字稿投影 | 已完成（#28–#31，PR #33–#36；#32 清理+文档+iPhone 13 真机矩阵，用户确认 2026-11-25）；候选台账见 [05-architecture-backlog.md](05-architecture-backlog.md) |
| 测试基线 | 只增不减；入口为 `DuiyiTests` / `DuiyiUITests`；原 harness 基线未随提取保留 |

### Wave 1 测试调整说明（2026-11-23）

- #2–#12 期间既有单元测试为适配 async setter 与 `TaskStoreV2` 结果接口做了机械迁移（改为 `await` 与结果分支），断言与用例语义未改；没有删除测试，也没有新增 skip。
- 新增的 `storage-retry`、`*-not-saved-banner`、`*-resume-prompt` 标识中，`meeting-resume-prompt` 有模拟器 UI 回归（新建任务 → 重启 → 恢复）。存储失败横幅需要启动期 store 失败注入钩子，暂由 ViewModel 单测覆盖，未新增 UI 用例或 skip。

---

## 1. P0：会丢数据或卡死主链路

### P0-1 单引擎全局仲裁（已实现，Wave 1）

**状态**：已实现并合并（#3 gate、#4 lifecycle、#6–#8 三模块接入、#12 契约收口）。

**原现象（Wave 1 前，保留历史）**：三个常驻 ViewModel（面对面、同传、会议）共享同一个 `BilingualSpeechEngine` actor。快速切模块、前后台切换、或旧 `stop()` 晚到时，可能出现 A 已 `start`、B 的 `stop()` 后到，把 A 的流 finish 掉。

**已落地**：

- `SpeechSessionGate`（actor，`SpeechSessionGating`）持全局 generation + 当前 owner `FeatureID`。
- 新 `start` 立即取代旧 owner：旧流结束，旧 owner 的后续 stop 是 no-op；同一 owner 重复 start 也生成新 generation，避免 ABA。
- 三个 VM 经各自 `TaskLifecycle` 使用同一个 `environment.speechGate`，不直接调 engine。
- 流结束分类：`isCurrent` 为真 → `recognitionInterrupted`；被取代 → 静默 `pausedListening`，不误报。
- 启动失败只让新 owner 报错，旧 owner 保持 paused。

**验收状态**：

- 单元：`SpeechSessionGateTests` / `TaskLifecycleTests` 覆盖 A start → B start → A stop、幂等 stop、同 owner 重启、快速切换与前后台循环；全量单测绿。
- 真机：iPhone 13 三模块连续切换 + 前后台 10 次**未验证**，按 #13 真机清单执行。

### P0-2 长会话的数据留存（显示窗口已完成，D7 续集组待后续）

**状态**：显示窗口与计数已实现（#9 会议清屏/计数、#10 同传 50 仅显示、#11 面对面 3 条窗口与恢复）。D7 的续集任务组**不在 Wave 1**，仍为后续 wave。

**原现象（Wave 1 前，保留历史）**：

| 模块 | 原问题 |
| --- | --- |
| 面对面 | `pane.history` 无上限，恢复回填无窗口 |
| 同传 | 显示窗口曾连带裁掉 transcript，早期内容从内存消失（Wave 1 #10 已修复） |
| 会议 | 20,000 字符计数按内存 transcript，清屏曾复位（Wave 1 #9 已改为累计）；无续集关联 |

**已落地**：

- 面对面 pane 保留 `live` + 最多 3 条历史（`ConversationLayout.paneHistoryLimit`），恢复只回填每侧 3 条，transcript 全量。
- 同传 50 条只裁 `pane.history` 显示与恢复回填，transcript / 落盘 / 导出全量；删除同时截断 transcript 的逻辑。
- 会议 20,000 字符按任务累计，清屏不复位；达到上限自动停听并标记 `isLengthLimited`，任务保持进行中。
- 清屏只清显示，先 `flush()`；transcript、总结数据与导出全量。

**仍待后续**：

- D7 续集任务组：组 ID、「结束并继续」、组内跳转、整组合并导出（当前只能结束并手动新建；文案/术语表已冻结方向，但未实现）。
- 历史详情分页加载，避免一次渲染全量。

**验收状态**：模拟器单测覆盖清屏/计数/窗口；iPhone 13 模拟 1 小时文字稿、同传 50+ 条历史读回、会议 2 万字边界**未验证**，按 #13 真机清单执行。

### P0-3 持久化可靠性与写放大（降级/结果接缝已完成，写放大/迁移待后续）

**状态**：降级显性化与结果化接缝已实现（#2 TaskStoreV2、#5 首页/历史/详情横幅与安全删除、#12 契约收口）。写放大与迁移计划未在 Wave 1 范围。

**原现象（Wave 1 前，保留历史）**：

- 旧实现（Wave 1 已修复）：容器失败时退回内存 store，用户以为已保存。
- 旧实现（Wave 1 已修复）：SwiftData 自动保存与显式 save 叠加，错误被吞掉。
- 无 `SchemaMigrationPlan`，字段变更可能崩库/丢库。

**已落地**：

- 可用性显式（`opening` / `ready` / `unavailable(reason)`），接口提供 `prepare()` / `retry()`；组合根不再 downcast。
- 读结果区分「空」与「读失败」；写返回 `persisted` / `notPersisted(reason)`；`end` 返回 `ended` / `discardedEmpty` / `notPersisted`，先 append 再按 store 内容判空，失败保持运行中。
- 首页/历史/详情共享「本机存储不可用」横幅 + 重试；已加载内容不清空；模块标记「本次内容不会保存」，结束后可从内存导出；不自动回填 memory-only 任务。
- `SwiftDataTaskStore` 关闭 autosave，每个变更显式 `save()` 并 `rollback()`；写失败只自动重试一次，仍失败即停止。
- 删除任务返回结果，历史/详情确认弹窗与失败提示已上线。

**仍待后续**：

- 增量落盘：`append` 仍按传入快照 upsert，长会写放大尚未量化/优化。
- `SchemaMigrationPlan` v1→v2 演练与自动化测试（P3-1）。

**验收状态**：单元测试覆盖 open/read/write/delete 失败、重试、空稿三态与 v1 样例 round-trip；iPhone 13 注入打开失败看横幅/重试/导出**未验证**，按 #13 真机清单执行。

---

## 2. P1：识别/翻译质量与数据一致性

### P1-1 翻译队列积压（已完成，真机验证通过）

**状态**：已完成并合并（#22–#25，代码评审修复合并于 `37f0a50`）：bridge 改为 per-`utteranceID` 合并队列 + final 优先 + generation-scoped `takeNext`；pump 一次唤醒 drain 到空并处理取消/requeue。单测覆盖合并、顺序、final 优先级、pre-pump wakeup、generation、latest-job requeue、drain/取消。真机验证已于 2026-11-24 通过（用户确认）；#21/#26 已关闭。

**原现象（P1-1 前，保留历史）**：`TranslationJobBridge` 只有 1 个 pending 槽位，但 host 就绪后 `AsyncStream` 无界；高频 volatile 会排队。`TranslationPipeline.accept` 用 `lastAppliedSourceCount` 丢弃过期结果，但积压仍占 session、抬高延迟。同传 voiceOut 档防抖更激进（25/50 ms）。

**已落地**（#22–#24）：

- 同一 `utteranceID` 最多保留一条 pending job，替换保留该 ID 首次出现的位置；不同 ID 保持 FIFO。
- 已排队 final 不被后续 non-final 覆盖；non-final 可互相覆盖；任何新 final 可覆盖旧 job。
- Host 未就绪时也按 ID 合并；`makeConsumer()` 在队列非空时立即补一次 wakeup。
- consumer generation-scoped `takeNext()`：旧 generation 返回 nil，旧 `onTermination` 不清新 continuation；`requeue` 接受任意 generation，只要该 job 仍是该句最新提交且无同 ID pending，插入队首并 wake 当前 consumer。
- pump 每次唤醒 `takeNext()` 到空；取消时该 job 已被同 ID 更新取代则丢弃，否则 requeue 到队首并退出；取消错误不触发 `onFailure`。非任务取消的 `CancellationError` 由下一次 `.translationTask` 重启的新 consumer drain。
- 时序不变：40/90 ms、voiceOut 25/50 ms、380 ms TTS settle、1.1 s 静音 final、crosstalk、emit 与单槽 `outboundJob`。

**验收**：`check-static` PASS；模拟器回归单测 326 logical / 352 expanded，0 failed / 0 skipped；UI 5 logical / 4 expanded，0 failed / 1 既有模拟器语音 skip。真机口径（连续快速说话时最终译文延迟不随会话增长、无旧 job 后到）由用户在 2026-11-24 报告通过，未提供 p95 数值。

### P1-2 导出竞态与导出内容不刷新（已修复 2026-11-17）

**原现象（修复前，保留历史）**：

- `TranscriptExportService.cleanupOldExports` 每次导出删除全部 `Duiyi-*.txt`；`ShareLink` 还在读取时可能被删。
- `TaskDetailView` 的 `ExportShareButton` 用 `.task(id: task.id)` 准备文件；任务译文更新后 `task.id` 不变，分享 URL 可能仍是旧内容。

**已落地**：

- 快照按 task UUID 与完整导出内容 SHA-256 命名，已准备快照不可变；后续导出不得覆盖。
- 清理仅匹配本服务普通文件，mtime 严格超过 7 天且未被本进程准备时才可回收。
- 分享准备版本由完整导出内容和 language 计算；任务 ID 不变但译文、总结或语言变化时重新准备。

**验收**：仓库内单元与 UI 回归覆盖连续导出/分享与详情页译文更新后的内容刷新；原运行证据未随提取保留。真实 ShareSheet 读取按 P0 书面豁免保持未验证。

### P1-3 切换语言后的旧翻译状态

**现象**：语言对变化时 `ConversationView` / `InterpretationView` 用 `.id` 重建 Host，旧 session 取消；翻译态（`outboundJob`、防抖、`sentSourceText`、`lastAppliedSourceCount`、aliases）现由 `TranslationPipeline` 持有，`reset()` 会一并清空，但 `setUserLanguage` / `handlePairChange` 的调用时序仍可能漏一句。

**目标**：`applyDirectionChange` / `setUserLanguage` / `handlePairChange` 在重建配置前统一调用 `pipeline.reset()`。

**状态**：Wave 2（#19）已统一 reset 接缝（`TranslationPipeline.reset()`）；P1-3 的时序行为修复尚未开始，不能据此宣称已修复。

**验收**：切换语言立即说话，不出现旧语言译文写入新行；无串行/重复。

### P1-4 中英混读与短句质量

**现象**：

- `UtteranceAssembler.matchesClaimedLanguage` 纯度要求较严（中文路要求 `han ≥ latin`，英文路要求无汉字等），中英混读句可能被两路同时丢弃。
- 面对面 final 后 1 秒内的非自信异语会被 `shouldIgnoreCrosstalk` 丢弃，快速 code-switch 会丢合法内容。
- 文档曾提的 `NLLanguageRecognizer` 第三票未实现。

**目标**：混句不直接丢，按 `resolvedLanguage` 重判；crosstalk 窗口按置信度动态；用固定音频夹具做路由准确率回归。

**验收**：中英混读夹具命中率提升且不增加串音；快速切换说话人不丢整句。

### Wave 3：C04 字幕/文字稿投影（已完成）

**来源**：2026-11-23 架构审查候选 C04；完整台账见 [`05-architecture-backlog.md`](05-architecture-backlog.md)。

**原现象（C04 前）**：字幕/文字稿投影有 3 处 `upsertTranscript`（Conversation / Interpretation / Meeting），`PaneState.history` 可变，各 ViewModel 恢复时各自重新投影；显示窗口与文字稿全集的边界分散。

**目标**：把 live / history / archive / merge / restore 投影收敛到一个 module，保持显示窗口（面对面 3 条/侧、同传 50 条仅显示、会议 2 万字累计）与 transcript 全集分离；不改变 P1-1 的 40/90、25/50、voiceOut、crosstalk 与单槽 `outboundJob`。**已达成**：`CaptionProjection` + `CaptionDisplayPolicy` 单一 record store，三 VM 全部迁移。

**验收**：现有三模块字幕/恢复/清屏/导出测试保持通过；新增投影 module 的边界测试；真机回归字幕窗口、恢复、清屏与导出。

**进展**：2026-11-24 完成 C04a–d（#28–#31，PR #33–#36）：新增投影模块与 28 条契约测试，三 VM 迁移，删除三份 `upsertTranscript` / alias / 跨 ID 文本合并；补齐 `UtteranceAssembler` 的 volatile greeting name swap 新 ID。C04e（#32）的清理与文档已回填：`PaneState` 仅保留派生快照，`TranslationPipeline` alias API 与 `SpokenText.isDistinctGreeting` 删除。完整 iPhone 13 真机矩阵由用户确认通过（2026-11-25）；#32 与父票 #27 已关闭，C04 收口完成。

---

## 3. P2/P3：可观测性、音频、TTS、国际化

| # | 问题 | 代码依据 | 建议 |
| --- | --- | --- | --- |
| P2-1 | Detector 失败静默 | `consume(detector:)` catch 只日志 | 降级提示或打点，切句退化可观测 |
| P2-2 | 单路漂移丢句 | `restartSingle` 全量 reset | 切 locale 时保留最后 final，或提示用户 |
| P2-3 | `BufferConverter` 非 float/int16 静默 nil | `copy` 双分支 | 加计数/日志 |
| P2-4 | 双头管理 AudioSession | Capturer 与 Policy 都 `setActive` | 统一走 Policy gate |
| P2-5 | TTS 参数写死 | `rate = default * 1.28` | v1 补 `prefersAssistiveTechnologySettings`；语速档/试听留 v1.x |
| P2-6 | 语言门禁仅覆盖首页设置 | 生产已注入 `SystemLanguageCatalog` 缓存；其余入口仍可选到不可用语言 | v1 扩展到所有语言入口（单语言能力） |
| P2-7 | 界面文案 `pick` 六参 | `Copy.swift` 遍布六参 | 迁移到 String Catalog，冻结新增 `pick` 参数 |
| P2-8 | MainActor 上的 LCS/compact | `SpokenText.isRefinement` 等在 VM 主线程 | 下沉后台纯函数，缓存 compact 结果 |
| P2-9 | 恢复任务不恢复语言对（已修复 Wave 1 #4/#6–#8） | `TaskLifecycle.restore()` 返回任务语言对，VM 应用并提示「继续任务」 | 已闭环；首页具体任务/启动对账仍留 v1.x |
| P3-1 | 无迁移计划 | `TaskEntity.schemaVersion` 只写不读 | 加 `SchemaMigrationPlan` 与演练 |
| P3-2 | 空稿/误触结束（已修复 Wave 1） | `TaskLifecycle.endTask` + `TaskStoreV2.end` 按持久化内容判空稿；历史/详情删除有确认与失败提示（#5/#12） | 已闭环，保持 |
| P3-3 | 重复能力检查/总结/胶囊样式 | 5 套能力检查、4 套总结、10+ 处 chip | 先抽 `ChipStyle` 与 `ModelPreparation` 协调器，再逐项迁移 |

---

## 4. 明确不做 / 不再投入

- **不重启启动微优化**：200 ms 目标已被控制组地板否定；不要用模拟器证明性能；不要手写 `Order/App.order`。
- **不引入云后端/账号/同步**：违背本机优先与离线承诺。
- **不引入 TCA/RIBs**：三个模块体量不够。
- **不做外放朗读**：回声自激，产品明确禁止。
- **不做实时说话人分离**：当前以语种为路由键；声纹/分离只做技术 spike，不承诺 v1。
- **不在会议记录里做实时同传朗读**：会议目标是全文稿与会后总结。
- **不为了“实时感”无限提高翻译频率**：P1-1 的队列合并已完成（真机验证通过），仍不要用更高翻译频率换实时感。
- **不做本地 digest 回退总结**（D6）；Apple 智能不可用时不提供总结。
- **不做历史自动清理**（D5）；**不做整组会议导出**（D7）。
- **不做六语同等发布承诺 / 繁体中文市场**（D4）；**不做大陆首发**（D2，第二阶段）。

---

## 5. 已完成的清理（2026-11-02）

- 文档合并：`01` 产品、`02` 架构、`03` 选型、`04` 本文件；删除已完成的路线图与重复设计稿（05–13），git 历史仍可追溯。
- 删除未引用代码：`CaptionTypography.controlFont`、`Copy.exportHeader`、`Copy.languageUnavailable`、`Copy.summaryLocalFallback`、`TaskSession.characterCount`、`AppLaunchTracker.launchDurationToNow`、`UtteranceAssembler.isShort`、`UtteranceAssembler.finalizeCurrentIfNeeded`、`ConversationLayout.captionAnimationDuration` / `captionAppearOffset`、`DuiyiError.translationUnavailable`。
- 删除 8 个无引用的 `platform.*` 本地化键；保留被 `Text` 字面量使用的键。
- 合并 `ConversationViewModel` / `InterpretationViewModel` 中完全重复的 `failTranslation` 分支，删除仅用于该分支的取消错误分类；`BilingualSpeechEngine.fail` 去掉未使用参数（原 P2-2）。
- 删除仓库根目录已跟踪的过期 Instruments trace；本地 `build/`、`.hvigor/`、`.DS_Store`、未跟踪 trace 不进入版本库。
- 修正 `docs/02` 对 `.id` 重建、`DeferredTaskStore`、`modelRetention` 的描述；`tools/generate-order-file.sh` 指向现存文档。

---

## 6. 建议排期

> 本节是排期的唯一真源；[`decisions.md`](decisions.md) 的 D1–D7 已于 2026-11-23 确认，D8 于 2026-11-24 补充，本表按同一顺序导航，不重复预估。
> 架构候选台账见 [05-architecture-backlog.md](05-architecture-backlog.md)。

| 顺序 | 事项 | 依赖 | 状态 / 预估 |
| --- | --- | --- | --- |
| 1 | P0-1 `SpeechSessionGate` + `TaskLifecycle` + 三模块接入 + 测试 | 无 | 已完成 Wave 1（#3/#4/#6–#8） |
| 2 | P0-3 降级显性化 + 结果化接缝 + 显式 save | 无 | 已完成 Wave 1（#2/#5/#12）；增量落盘、迁移演练仍待后续（3–5 天） |
| 3 | P0-2 长会话显示窗口 + 计数 | P0-3 已完成部分 | 已完成 Wave 1（#9/#10/#11）；D7 续集任务组仍待后续（1–2 周） |
| 4 | P1-1 翻译队列合并 | 无 | 已完成（#22–#25，main `37f0a50`）；真机验证 2026-11-24 通过（用户确认） |
| 5 | P1-4 混读/短句质量 | 真机夹具 | 未开始（1–2 周） |
| 6 | Wave 3 C04 字幕/文字稿投影 | 无（建议 P1-4 后） | 已完成（#28–#32；真机矩阵 2026-11-25 用户确认） |

同一失败检查修复 2 次仍失败，或同一子任务 3 轮修复-验证无进展时停止上报（团队规则）。

---

## 7. 交接前需要确认的产品/工程决策

决策已合并到 [`decisions.md`](decisions.md) 的 **D1–D8**（唯一真源，D8 于 2026-11-24 补充）；
本文件不再保留重复列表，只在此留指针。P0-2/P0-3 的产品侧行为按 D5–D7 与「v1 冻结口径」实现。
