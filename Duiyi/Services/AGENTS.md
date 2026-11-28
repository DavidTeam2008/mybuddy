# AGENTS.md · Duiyi/Services

> 触发：改 `Speech` / `Audio` / `Translation` / `SpeechSynthesis` / `Persistence` / `Export` / `Summary` / `Permissions` 前先读本页。
> 本页只写 Services 的增量约束；项目规则见根 [`AGENTS.md`](../../AGENTS.md)，任务与分层契约见 [`docs/02-architecture.md`](../../docs/02-architecture.md) §7，链路事实见 [`docs/02-architecture.md`](../../docs/02-architecture.md)。

## 1. 语音：单引擎 + `SpeechSessionGate` 仲裁

- 三个常驻 VM 通过 `AppEnvironment.speechGate`（唯一 `SpeechSessionGate` actor）共享同一个 `BilingualSpeechEngine`；**不要给每个 VM 建引擎**，也不要在 VM 里直接调 `SpeechRecognizing`。
- gate 用 owner（`FeatureID`）+ 单调 generation 仲裁唯一听写流：新 start 立即取代旧 owner，旧流静默结束，旧 owner/generation 的 stop 是 no-op；只有当前流非预期结束才报 `recognitionInterrupted`。
- `BilingualSpeechEngine()` 只在组合根（`AppEnvironment` 默认参数）实例化；其它位置注入 `any SpeechSessionGating` 协议。
- 改这块必须配假引擎并发测试（20 次快速切换 + 10 次前后台）；真机快速切换仍按发布清单验证。
- 资源不足降级与 `UtteranceAssembler` 语种锁定是现状（`docs/02-architecture.md` §4），不要顺手改听写策略；脚本计数/scalar 判定委托 Domain `ScriptCounts`，不要在 Services 里复制。
- 真正的单语种 live-caption 请求用 `.trustedLocale`（非空结果不丢，只记录脚本不匹配）；请求了双 locale 但资源降到单路、以及 `meetingNotes` 保持 `.strict`。
- Range-aware 组装（P1-1）：`SpeechTranscriber.Result` 的 `range`/`isFinal` 是 phrase 的音频范围和 finality，不是句子边界；标点只用于显示/TTS，不决定 `Utterance.id`。current row = finalized phrase 前缀 + 开放 range 的 volatile。行边界只由 range gap >0.75 s、语言切换/name swap、静音和 max cap（12 s/120 字，仅在无 volatile 的 phrase 边界）决定；final-only 行也由静音关闭。**volatile 不保证会重发 final**：下一个不同 range 的 phrase/final 到达时，旧 volatile 先并入 finalized 前缀，不能丢；迟到同 range final 由 closed-range 表复用 ID，且只替换/合并其 range 的 phrase。**final 只在 range 覆盖原 phrase 时替换文本**：更窄的 final 保留原 phrase 全文；覆盖但丢掉原文本一半以上的 final 按截断处理，保留更全的 volatile。纯标点结果直接忽略，不能让它替换开放 volatile 或单独成行；尾随 ASCII 省略号（2+ 个 `.`）是续句标记，不关行；同一行后续 phrase 接入时去掉该省略号，按正常词间距拼接，不把缺失音节的片段硬拼成词；关闭行后扩展出关闭 range 的 late volatile/final（final 且文本不含旧 tail）若新行为空或当前行 range 与它重叠，则开/续新行，不合并进旧行。空 volatile 撤销尾部；静音时只有存在 volatile 才 `analyzer.finalize(through: nil)` 等 350 ms；final-only 行直接关闭，不再合成/重复 final；`silenceTimedOut` 只对 volatile 做 synthetic 兜底。源短语用 `TextNormalization.sourcePhrase` 剥离开头续句标点/折叠点串；跨 phrase 拼接按 `requiresSpace`（句末标点后加空格，CJK 标点不加）。D8 不变：只有 assembler 发新 ID；crosstalk hold、脚本纯度、greeting name-swap 不登记 closed range。研究依据：`docs/research/speech-transcriber-segmentation.md`。
- 内容保留不变量（2026-11-27 夹具回归）：finalized phrase 的 range 必须紧贴产生它的 final，**即使保留更全的 volatile 文本也不把 volatile 的 speculative tail `union` 进 phrase**。只有文本包含或 `SpokenText.isRefinement` 才视为同一 phrase；不同文本默认按 range 排序同时保留，不得用“更长者胜”互换；但确认 same audio window 且 final 覆盖该窗口时按 final 纠正替换（`I scream` → `ice cream`、`oh` → `Okay.`），不能把两种拼写都保留。volatile 与 final/volatile 只在 same audio window（重叠 ≥ 较短 range 的 50%）或文本包含时合并；volatile 原地更新还要求新 start 在旧 phrase 的 `max(0.5 s, 25% duration)` 内且 incoming compact 文本不少于 existing 的一半，否则视为 padding 窗口里的下一 phrase，先 bounded 旧 volatile 再起新 volatile（防止下一句首词 `you` 覆盖长 preview）；same-audio final 替换还要求 incoming compact 文本不少于 existing 的一半，短 final 不能截断长 preview，保留两者。新 phrase 到达前旧 volatile 的尾端 `bounded` 到新 range 的 start。gap 检测用所有 phrase 的最大 end，不依赖数组最后一项。**关闭行（gap/语言/name swap/cap）时如果还有未发布的 volatile，必须先 `queueFinalForBoundary`；引擎在发布新行前 drain `takePendingFinals()`。** 只把 volatile 放进 closedRange 历史而不发布 final 会静默丢内容；语言抢占 `preemptsIfNeeded` 的 crosstalk 丢弃是双路待验证例外，不要在没有双路 A/B 时顺手改。回归：`UtteranceAssemblerRangeTests.shortFinalBetweenLongPhrasesSurvives`、`distinctFinalInsidePartialVolatileKeepsBoth`、`sameAudioMishearingReplaced`、`shortFinalInsideLongVolatileKeepsPreview`、`shortFinalCannotTruncateLongVolatile`、`gapClosePublishesOpenVolatile` 等；夹具证据见 `docs/research/speech-transcriber-segmentation.md` §8.1–8.2。
- `stop()` 必须先停采集/输入，`finalizeAndFinishThroughEndOfInput()`（1 s 上限），给消费者 300 ms 收 final，再用 `silenceTimedOut()` 兜底，最后取消 transcriber consumers；`resetPipelineKeepingStream`/`restartSingle` 同样 finalize。不要先 cancel consumer，也不要直接 `cancelAndFinishNow()` 丢掉当前 range 的 final。

## 2. 翻译：Session 只在 Host View

- `TranslationSession` 只能出现在 `*TranslationHostView` 的 `.translationTask`：`Features/Shared/TranslationHostView.swift`（含 `OneWayTranslationHostView`）。Services 不持有、不调用 `TranslationSession`。
- `TranslationJobBridge` 是共享 Host 模块的 per-`utteranceID` 合并队列：同一句最多保留一条 pending，替换保留首次位置；已排队 final 不被新 non-final 覆盖，任何新 final 可覆盖旧 job。consumer 的 `takeNext()` 是 generation-scoped；`requeue` 接受任意 generation，只要该 job 仍是该句最新提交且无同 ID pending，插入队首并 wake 当前 consumer。Host 未就绪时同样按 ID 合并，安装 consumer 时队列非空立即补 wakeup。job 形成、防抖与过期丢弃仍在 `Features/Shared/TranslationPipeline`，bridge 不复制这些策略。
- `TranslationJobPump`（`Features/Shared/TranslationJobPump.swift`）是 Host 的 drain 循环：一次唤醒 `takeNext()` 到空；取消时该 job 已被同 ID 更新取代就丢弃，否则 `requeue` 到队首并退出，取消错误不算失败；非任务取消的 `CancellationError` 由下一次 `.translationTask` 重启的新 consumer 接管。测试注入 `translate` / `onSuccess` / `onFailure`，不要 mock `TranslationSession`。
- 语言对变化由 `.id` 重建 Host；Service 只提供 availability（`TranslationAvailabilityChecking`）。

## 3. 持久化：结果化接缝、内存为准

- 存储接缝分两层：`TaskStore` 只负责 `availability`（opening/ready/unavailable）、`prepare()`、`retry()`；`TaskStoreV2` 提供结果化读写（`readActiveTask` / `readUnfinishedTasks` / `readList` / `readTask`、`startNew` / `append` / `updateTranslations` / `setStatus` / `saveSummary` / `end` / `deleteTask`）。不要恢复 success-only 或静默吞错的变体。
- 实时字幕/`PaneState` 是内存事实；落盘的 250ms debounce 由 `TaskLifecycle.persist` 统一负责，VM 不要各自 schedule；结束、清屏、进后台用 `flush()`。
- `TaskLifecycle` 在 `endTask` 与 `prepareForNewTask` 两条结束路径都保留最近一个已结束任务的快照；`backfillTranslation` 用 `TaskStoreV2.updateTranslations` 回填结束后到达的 final 译文（允许已结束任务），preview 与损坏文本不写。
- 读取已存文字稿时 `TaskMapping` 把损坏译文（U+FFFD/可疑控制字符）视为空；导出 `TranscriptExportService` 不渲染损坏译文。不要静默把坏字符替换成其他文字冒充正确译文。
- `TaskStoreV2.end` 是原子操作：先 upsert pending 条目，再以 store 中持久化内容判空稿；失败返回 `notPersisted` 且任务保持进行中、不删除。空稿判断不要在 VM 里用内存数组另做一套。
- `DeferredTaskStore` 延迟开库；打开失败保持 `unavailable` 并提供 `retry()`，模块可继续但标记「本次内容不会保存」，**绝不静默回退 `InMemoryTaskStore`**；写失败只重试一次，仍失败即 `notPersisted`，不轮询、不自动回填。不要在 `AppEnvironment.init` 或首帧前同步 open container（D1）。
- `SwiftDataTaskStore` 关闭 autosave（`autosaveEnabled = false`），每个变更显式 `save()` 并把错误返回接缝；失败时 `rollback()`，不依赖 `try?`。
- View/VM 不直读 SwiftData 当实时状态；历史详情只读，不复用现场字幕状态机。
- 改持久化/迁移前：先备份 store 样例（真机拷出或测试 fixture），再写迁移测试；不要用“删库重装”验证数据安全。

## 4. 测试替身与边界

- 单测用假实现：假引擎（记录 start/stop、可手动 emit）、`InMemoryTaskStore`（已是 `TaskStoreV2`）、失败注入用 `DuiyiTests/StorageTestSupport.swift` 的 `ScriptedTaskStore`、假合成器、假 audio session；不得连真麦克风/真模型。
- 真机夹具回放是 DEBUG-only 的 `AudioCapturing` 替身（`Services/Audio/FixtureAudioCapturer`）：只替换采集源，按 1024 帧、原生格式喂文件，后面的 `BilingualSpeechEngine`/`BufferConverter`/`SpeechAnalyzer`/assembler/翻译/落库必须是真的；不得换成 mock 引擎或 mock `TranslationSession`。1× 节拍是墙钟语义的常规口径，`max` 只用于 ASR 文本筛选。入口 `tools/fixture-run.sh`，详见 `docs/agents/device-testing.md` §5.1。
- **不得 mock 能力检查**（如 `SpeechTranscriber.isAvailable`）来让模拟器用例变绿；语音/翻译/TTS/音频/持久化的最终验收在真机。
- 新协议放 `ServiceProtocols.swift` 或所属目录，由 `AppEnvironment` 注入；预览替身放 `App/PreviewSupport.swift`。
- 分层：Services 不引用 ViewModel；Domain 不 import SwiftUI/语音/翻译/SwiftData；由 code review 与测试保证（原 `make check-arch` 未随提取保留）。

## 4.1 诊断（P1-4a）

- `DiagnosticsRecorder`（`Services/Diagnostics`）是进程内唯一 sink，`AppEnvironment` 注入；读写都过同一把锁（ASR 来自 speech actor，翻译来自主线程）。`TaskLifecycle` 负责 begin/end 会话：任务开始/恢复时重置，结束后保留快照，迟到事件仍写入最近结束任务。
- payload 只含 ID、语言、长度、时间、失败类与 App/设备版本元数据（型号、系统版本、App 版本；不含 UDID），**不得写正文或音频**；`source_hash` 只用于关联重复 job。ring buffer 有界（默认 4096），聚合计数增量维护。ASR 的 `range`/`resultsFinalizationTime` 只在引擎消费 `SpeechTranscriber.Result` 处记录，不要为诊断改组装行为。
- 语音失败写 `speech.failure`：失败语言、`errorDomain`/`errorCode`（不写错误文案）与恢复决策 `singleFallback`/`none`/`restartFailed`；feature 由 recorder 会话附加。
- 导出仅 DEBUG：设置页写 Documents JSON 并 ShareLink，不上传、不新增网络路径。测试用 `DiagnosticsRecorder(eventLimit:now:)` 或 no-op；不要把 recorder 变成全局单例。

## 5. 导出与产物

- 导出：快照按 task UUID + 完整内容 SHA-256 命名且不可变；只清理严格超过 7 天且未被本进程准备的本服务普通文件；不得删除全部 `Duiyi-*.txt`；不改共享语义。
- 测试用临时目录；不写仓库内路径；不提交 build/trace/测试产物。

## 6. 完成判据

- Service 变更 = 对应单测（`DuiyiTests`）；涉及真机链路（语音/翻译/TTS/持久化）补真机验证结果；不能操作设备时写“未验证”+ 手动步骤。
