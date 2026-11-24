# AGENTS.md · Duiyi/Services

> 触发：改 `Speech` / `Audio` / `Translation` / `SpeechSynthesis` / `Persistence` / `Export` / `Summary` / `Permissions` 前先读本页。
> 本页只写 Services 的增量约束；项目规则见根 [`AGENTS.md`](../../AGENTS.md)，任务与分层契约见 [`docs/02-architecture.md`](../../docs/02-architecture.md) §7，链路事实见 [`docs/02-architecture.md`](../../docs/02-architecture.md)。

## 1. 语音：单引擎 + `SpeechSessionGate` 仲裁

- 三个常驻 VM 通过 `AppEnvironment.speechGate`（唯一 `SpeechSessionGate` actor）共享同一个 `BilingualSpeechEngine`；**不要给每个 VM 建引擎**，也不要在 VM 里直接调 `SpeechRecognizing`。
- gate 用 owner（`FeatureID`）+ 单调 generation 仲裁唯一听写流：新 start 立即取代旧 owner，旧流静默结束，旧 owner/generation 的 stop 是 no-op；只有当前流非预期结束才报 `recognitionInterrupted`。
- `BilingualSpeechEngine()` 只在组合根（`AppEnvironment` 默认参数）实例化；其它位置注入 `any SpeechSessionGating` 协议。
- 改这块必须配假引擎并发测试（20 次快速切换 + 10 次前后台）；真机快速切换仍按发布清单验证。
- 资源不足降级与 `UtteranceAssembler` 语种锁定是现状（`docs/02-architecture.md` §4），不要顺手改听写策略；脚本计数/scalar 判定委托 Domain `ScriptCounts`，不要在 Services 里复制。

## 2. 翻译：Session 只在 Host View

- `TranslationSession` 只能出现在 `*TranslationHostView` 的 `.translationTask`：`Features/Shared/TranslationHostView.swift`（含 `OneWayTranslationHostView`）。Services 不持有、不调用 `TranslationSession`。
- `TranslationJobBridge` 是共享 Host 模块的 per-`utteranceID` 合并队列：同一句最多保留一条 pending，替换保留首次位置；已排队 final 不被新 non-final 覆盖，任何新 final 可覆盖旧 job。consumer 的 `takeNext()` 是 generation-scoped；`requeue` 接受任意 generation，只要该 job 仍是该句最新提交且无同 ID pending，插入队首并 wake 当前 consumer。Host 未就绪时同样按 ID 合并，安装 consumer 时队列非空立即补 wakeup。job 形成、防抖与过期丢弃仍在 `Features/Shared/TranslationPipeline`，bridge 不复制这些策略。
- `TranslationJobPump`（`Features/Shared/TranslationJobPump.swift`）是 Host 的 drain 循环：一次唤醒 `takeNext()` 到空；取消时该 job 已被同 ID 更新取代就丢弃，否则 `requeue` 到队首并退出，取消错误不算失败；非任务取消的 `CancellationError` 由下一次 `.translationTask` 重启的新 consumer 接管。测试注入 `translate` / `onSuccess` / `onFailure`，不要 mock `TranslationSession`。
- 语言对变化由 `.id` 重建 Host；Service 只提供 availability（`TranslationAvailabilityChecking`）。

## 3. 持久化：结果化接缝、内存为准

- 存储接缝分两层：`TaskStore` 只负责 `availability`（opening/ready/unavailable）、`prepare()`、`retry()`；`TaskStoreV2` 提供结果化读写（`readActiveTask` / `readUnfinishedTasks` / `readList` / `readTask`、`startNew` / `append` / `updateTranslations` / `setStatus` / `saveSummary` / `end` / `deleteTask`）。不要恢复 success-only 或静默吞错的变体。
- 实时字幕/`PaneState` 是内存事实；落盘的 250ms debounce 由 `TaskLifecycle.persist` 统一负责，VM 不要各自 schedule；结束、清屏、进后台用 `flush()`。
- `TaskStoreV2.end` 是原子操作：先 upsert pending 条目，再以 store 中持久化内容判空稿；失败返回 `notPersisted` 且任务保持进行中、不删除。空稿判断不要在 VM 里用内存数组另做一套。
- `DeferredTaskStore` 延迟开库；打开失败保持 `unavailable` 并提供 `retry()`，模块可继续但标记「本次内容不会保存」，**绝不静默回退 `InMemoryTaskStore`**；写失败只重试一次，仍失败即 `notPersisted`，不轮询、不自动回填。不要在 `AppEnvironment.init` 或首帧前同步 open container（D1）。
- `SwiftDataTaskStore` 关闭 autosave（`autosaveEnabled = false`），每个变更显式 `save()` 并把错误返回接缝；失败时 `rollback()`，不依赖 `try?`。
- View/VM 不直读 SwiftData 当实时状态；历史详情只读，不复用现场字幕状态机。
- 改持久化/迁移前：先备份 store 样例（真机拷出或测试 fixture），再写迁移测试；不要用“删库重装”验证数据安全。

## 4. 测试替身与边界

- 单测用假实现：假引擎（记录 start/stop、可手动 emit）、`InMemoryTaskStore`（已是 `TaskStoreV2`）、失败注入用 `DuiyiTests/StorageTestSupport.swift` 的 `ScriptedTaskStore`、假合成器、假 audio session；不得连真麦克风/真模型。
- **不得 mock 能力检查**（如 `SpeechTranscriber.isAvailable`）来让模拟器用例变绿；语音/翻译/TTS/音频/持久化的最终验收在真机。
- 新协议放 `ServiceProtocols.swift` 或所属目录，由 `AppEnvironment` 注入；预览替身放 `App/PreviewSupport.swift`。
- 分层：Services 不引用 ViewModel；Domain 不 import SwiftUI/语音/翻译/SwiftData；由 code review 与测试保证（原 `make check-arch` 未随提取保留）。

## 5. 导出与产物

- 导出：快照按 task UUID + 完整内容 SHA-256 命名且不可变；只清理严格超过 7 天且未被本进程准备的本服务普通文件；不得删除全部 `Duiyi-*.txt`；不改共享语义。
- 测试用临时目录；不写仓库内路径；不提交 build/trace/测试产物。

## 6. 完成判据

- Service 变更 = 对应单测（`DuiyiTests`）；涉及真机链路（语音/翻译/TTS/持久化）补真机验证结果；不能操作设备时写“未验证”+ 手动步骤。
