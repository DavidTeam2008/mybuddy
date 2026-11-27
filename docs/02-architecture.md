# 02 架构（当前实现）

> 本文以 `Duiyi/` 代码为准，描述 2026-11 的现状。
> 产品行为见 [`01-product-design.md`](01-product-design.md)，选型理由见 [`03-tech-choices.md`](03-tech-choices.md)，
> 已知问题与排期见 [`04-roadmap.md`](04-roadmap.md)。

## 0. 基线

| 项 | 当前值 |
| --- | --- |
| 部署目标 | iOS 26.4，仅 iPhone、仅竖屏 |
| 语言/工具链 | Swift 6.0，Xcode 26.4+（本机 27.1） |
| 第三方依赖 | 无；全部系统框架 |
| 系统能力 | SpeechAnalyzer / SpeechTranscriber / SpeechDetector、Translation.framework、AVSpeechSynthesizer、SwiftData、FoundationModels、SwiftUI |
| 离线承诺 | 无后端、无 API Key；音频不上传、不落盘 |

---

## 1. 分层与依赖

```
Duiyi/
  App/            入口、依赖组装、导航、偏好、预览夹具
  Features/       Home / Conversation / Interpretation / Meeting / History / Onboarding / Settings / Shared
  Domain/         纯模型、路由、任务语义、文案、错误、脚本计数
  Services/       Audio / Speech / SpeechSynthesis / Translation / Persistence / Summary / Export / Assets / Permissions / Diagnostics
  DesignSystem/   Tokens、通用卡片、历史行、安全区
DuiyiTests/       Swift Testing 单元测试（数量以当前测试结果为准）
DuiyiUITests/     XCUITest 用例（4 个）
```

依赖方向严格单向：

| 层 | 允许依赖 | 禁止 |
| --- | --- | --- |
| App | 全部；负责构造实现并注入 | 编写字幕合并/翻译业务规则 |
| Features | Domain、DesignSystem、`AppEnvironment` 注入的协议 | 直接 `import Speech` / `AVFAudio`；引用其他 Feature 的 ViewModel |
| Domain | Foundation/CoreGraphics 级纯模型 | SwiftUI、Speech、Translation、SwiftData |
| Services | Domain + 系统框架 | 引用任何 Feature ViewModel |
| DesignSystem | SwiftUI | 业务状态机 |

两个系统约束必须写进设计，而不是假装它们不存在：

1. **`TranslationSession` 只能锚在 View 上**（`.translationTask`）。共享 `TranslationPipeline` 形成 `TranslationJob`，由 `TranslationHostView` / `OneWayTranslationHostView` 执行并回调 ViewModel；Service 层不持有 session。
2. **`SpeechAnalyzer` 是长生命周期资源**。当前由一个 `BilingualSpeechEngine` actor 统一持有，三个常驻 ViewModel 经 `SpeechSessionGate` 共享；gate 用 owner + generation 仲裁唯一听写流（P0-1 已关闭，见 [`04-roadmap.md`](04-roadmap.md)）。

---

## 2. 组装、导航与生命周期

### 2.1 AppEnvironment

`Duiyi/App/AppEnvironment.swift` 是唯一的依赖组装点，`@MainActor @Observable`，持有：

| 依赖 | 默认实现 | 用途 |
| --- | --- | --- |
| `PreferencesStore` | `UserDefaults` | 语言、字号、自动开始、引导进度、模块偏好 |
| `PermissionGranting` | `PermissionService` | 麦克风/语音识别授权 |
| `SpeechModelPreparing` | `SpeechAssetPreparer` | 端侧听写模型安装 |
| `TranslationAvailabilityChecking` | `TranslationAvailabilityService` | 语言对可用性 |
| `SpeechRecognizing` | `BilingualSpeechEngine` | 双/单路听写（仅由 gate 持有） |
| `SpeechSessionGating` | `SpeechSessionGate` | 唯一听写流仲裁（owner + generation） |
| `ConversationSummarizing` | `FoundationModelsSummarizer` | Apple 智能总结（v1 不使用 digest 回退） |
| `AudioSessionConfiguring` | `AudioSessionPolicy` | AVAudioSession 与路由 |
| `SpeechSynthesizing` | `SystemSpeechSynthesizer` | 同传朗读 |
| `TaskStoreV2` | `DeferredTaskStore` | 任务持久化（availability / prepare / retry + 结果化读写） |
| `ExportSharing` | `TranscriptExportService` | 导出文本 |
| `LanguageCataloging` | `SystemLanguageCatalog` | 语言目录（系统探针缓存） |
| `DiagnosticsRecording` | `DiagnosticsRecorder` | 每任务诊断 ring buffer + 聚合（DEBUG 导出，不上传） |

`DuiyiApp` 用 `@State` 持有 `AppEnvironment` 和 `AppCoordinator`，通过 `.environment()` 注入。

### 2.2 启动路径

```
DuiyiApp.init
  └─ AppEnvironment.init                    // 不打开数据库
       └─ DeferredTaskStore.init            // 后台 utility 任务开始 openContainer
RootView.body
  ├─ HomeView 首帧
  ├─ onAppear → 下一 runloop markFirstFrame
  └─ .task(priority: .utility)              // 首帧之后
       ├─ DeferredTaskStore.prepare()       // 组合根不 downcast；失败 → unavailable，可 retry
       └─ rebuildViewModelsIfNeeded()       // 四个常驻 VM
```

启动优化已暂停，结论与证据链见 [`case-startup-performance.md`](case-startup-performance.md)。当前不重启微优化，也不用模拟器证明性能。
D1 口径不变：首帧前不同步打开 `ModelContainer`；Wave 1 未新增启动路径 I/O，组合根只在首帧后的 utility task 调用 `prepare()`。

### 2.3 导航

`AppCoordinator` 持有 `NavigationPath`，路由只有：

```swift
enum AppRoute {
    case conversation
    case interpretation
    case meeting
    case history
    case taskDetail(UUID)
}
```

- 首页 `FeatureRegistry.modules` 三张功能卡 + 历史卡；新增模块需加 `FeatureID` case、Feature 目录、`AppRoute` case、`RootView.destination` 分支和 Registry 一行。
- `RootView.destination(for:)` 仍是显式 `switch`；当前只有三模块，可接受。
- 引导用 `fullScreenCover`，由 `PreferencesStore.hasCompletedOnboarding` 驱动。

### 2.4 常驻 ViewModel

`RootView.rebuildViewModelsIfNeeded()` 在首帧后创建：

- `ConversationViewModel`
- `InterpretationViewModel`
- `MeetingViewModel`
- `HistoryViewModel`

三个会话 VM 常驻，保证切模块时任务/字幕不丢；每个 VM 持有一个 `TaskLifecycle`，听写统一经 `environment.speechGate`。`scenePhase != .active` 时依次 `stop(restoreIdleTimerAfterDelay: false)` → `TaskLifecycle.pauseListening()` / `flush()`，只停麦克风，不结束任务。

---

## 3. 音频链路

```
麦克风
  → AVAudioEngine inputNode.installTap(bufferSize: 1024)
  → BufferConverter.copy / convert
  → AsyncStream<SendablePCMBuffer>
  → BilingualSpeechEngine
```

### 3.1 AudioEngineCapturer

`actor AudioEngineCapturer`：

- `start()` 先 `stop()` 保证幂等，再 `setActive(true)`、安装 tap、返回 `AsyncStream`。
- tap 回调中复制 buffer 后 `yield`，不切主线程。
- `stop()` finish 流、移除 tap、停引擎、`setActive(false)`。
- `BufferConverter` 只处理 float/int16；其他格式返回 nil（当前静默丢包，P2）。

### 3.2 AudioSessionPolicy

`actor AudioSessionPolicy` 是唯一设置 category 的地方：

| 用例 | category / mode / options |
| --- | --- |
| 面对面 | `.record` / `.measurement` / `[.duckOthers]` |
| 同传（只字幕） | `.record` / `.measurement` / `[.duckOthers]` |
| 同传（读出） | `.playAndRecord` / `.default` / `[.duckOthers, .allowBluetoothA2DP]`，并 `overrideOutputAudioPort(.none)` |

- 优先内置麦克风与底部数据源。
- 通过 `routeChangeNotification` 广播 `AudioRouteSnapshot`。
- `AudioEchoPolicy.canSpeakWithoutEcho`：输出或输入里有耳机类路由才允许朗读；外放不允许。
- 无后台音频模式；失活时 `setActive(false, .notifyOthersOnDeactivation)`。

---

## 4. 听写：BilingualSpeechEngine + SpeechSessionGate

`actor BilingualSpeechEngine` 实现 `SpeechRecognizing`，是唯一的引擎；三个模块不直接调用它，而是经 `actor SpeechSessionGate`（实现 `SpeechSessionGating`）取流：

```swift
func start(
    languages: [AppLanguage],
    fallbackLanguage: AppLanguage,
    style: SpeechRecognitionStyle
) async throws -> AsyncStream<Utterance>
func stop() async
```

gate 的接口承载流身份：

```swift
func start(owner: FeatureID, ...) async throws -> SpeechSessionHandle
func stop(_ handle: SpeechSessionHandle) async
func isCurrent(_ handle: SpeechSessionHandle) async -> Bool
```

- 新 `start` 递增 generation 并取代旧 owner；旧流结束、旧 owner 的后续 `stop` 是 no-op，避免 ABA。
- 每个句柄带 owner + generation；`isCurrent` 区分「当前流真失败」和「被新 owner 取代」。
- start/stop 经内部操作槽串行化，跨 suspension 也不会让 teardown 与启动交错；teardown 对每个会话恰好调用一次引擎 stop。
- gate 不持有 `SessionState` 或任务状态，只回答「谁是当前流」。

### 4.1 管线选择

1. `normalizedLanguages` 去重、补 fallback、最多取前 2 种。
2. 两种语言 → 先试 `startMultiPipeline`：每语言一个 `SpeechTranscriber` + 一个 `SpeechDetector(medium)`。
3. 命中资源上限（`insufficientResources` / `tooManyAssetLocalesAllocated`）→ 逐个丢弃 locale 重试；仍失败则退到单路 fallback。
4. 三模块超限 → 去掉 Detector 重试；再失败退单路。
5. 单路模式运行中若 final 语言漂移 → `restartSingle` 重建管线并 reset assembler；兼容路径，会丢一小段，无用户提示。

`SpeechTranscriber` 配置：`[.volatileResults, .fastResults]`、`[.etiquetteReplacements]`、`[.transcriptionConfidence]`。
会议用 `SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)`；实时字幕用默认 Options。

### 4.2 切句

- 每个 transcriber 的 partial/final 带 `range` 进入 `UtteranceAssembler.ingest`。当前行 = 已 final 的 phrase 前缀 + 开放 range 的 volatile 尾部；range 连续性决定续写。**标点不决定换行**：`SpeechTranscriber.Result` 是 phrase，不是 sentence；行边界只由 range 间隔 >0.75 s、语言切换/name swap、静音和 max cap（12 s/120 字，仅在无 volatile 的 phrase 边界）决定。标点保留在文本里用于显示/TTS。研究见 [`research/speech-transcriber-segmentation.md`](research/speech-transcriber-segmentation.md)。
- volatile 结果不保证会重发 final（Apple 明确说明）。下一个 phrase（不同 range）到达时，旧的开放 volatile 先并入已定稿 phrase，不能直接丢弃；之后同 range 的 final 仍原位修订该 phrase。**final 只在 range 覆盖原 phrase 时才替换文本**：更窄的 final 保留原 phrase 全文；即使覆盖，若 final 是原文本的严格子串且不足一半，也视为截断并保留更全的 volatile（避免“预览对、结算丢前半句”）。纯标点结果（`.`、`...`）无词可承载，直接忽略；尾随 ASCII 省略号（2+ 个 `.`）是 transcriber 的续句标记，不触发换行；同一行后续 phrase 接入时去掉该省略号，按正常词间距拼接（不硬拼缺失音节的片段，避免伪造词）。关闭行之后扩展出关闭 range 的 late volatile，或文本不含旧 tail 的 late final，若新行仍为空或当前行 range 与它重叠，则开/续新行，不丢弃暂停恢复后的第一句，也不把新句替换进旧行。源短语开头的续句标点（`,..`、`...`）剥除，4+ 连续点折叠为 `...`；译文按目标语言规范省略号（中文 `……`）。
- 空 volatile 撤销该 range 的开放尾部并回退到 final 前缀；空 final 表示该 range 无语音。
- 静音（Detector 或 1.1 s 无结果）：只有存在 volatile 时才 `analyzer.finalize(through: nil)` 并等待 350 ms；final-only 行直接由 `silenceTimedOut` 关闭，不合成、不重复 final。合成与迟到 final 都按 range 重叠匹配最近关闭的行并复用 ID（`isRevision`），最多保留 8 行。关闭行保存 phrase 列表：迟到 final 只替换/合并其 range 内的 phrase，已 final 的前缀必须保留（不能把整行缩成最后一个 phrase）。
- final 后 `acknowledgeFinal` 保持 1.0 秒，抑制同句尾巴被另一路重复接收。
- `publish` 以 `(utterance.id, language, 归一化文本)` 签名去重 final：同一行的重复 final 只发一次，新行重复同一句仍会发布。

### 4.3 UtteranceAssembler

纯值 `struct`，核心职责：

- **语言纯度门禁**：`matchesClaimedLanguage` 按脚本统计拒绝明显不属于该路的文本（如中文路收到纯拉丁、英文路收到汉字）。真正的单语种请求用 `.trustedLocale` 信任唯一 transcriber：非空结果都接受，混合脚本/纯数字只记录不匹配、不丢句；请求了双 locale 但资源降到单路、以及会议，保持 `.strict`。
- **抢占**：锁定语言后，异语候选只有 `nativeUnits` 明显超过当前句才抢占。
- **同句更新**：range-aware 路径下，同一 `utteranceID` 原地更新；连续 phrase 按 range 连续性合并（标点不决定行边界），不依赖文本前缀相似度。开放 volatile 在下一个不同 range 的 phrase 到达时并入前缀（volatile 可能永远不会收到 final），同句字间按标点规则补空格（句末标点后加空格，CJK 标点不加）。无 range 的调用保留原文本启发式（测试与兼容路径）。
- **短句抑制**：`isConfident` 对短确认语不自信，沿用上一句语种，减少「嗯 / um」误切。
- **六语脚本阈值**：中/日/韩/泰/越/英各有独立计数与阈值；`resolvedLanguage` 可按文本重新判定会议行的实际语言。
- **诊断**：range/`resultsFinalizationTime` 只在引擎消费结果处记录，assembler 的组装行为不读取诊断 sink。

### 4.4 流结束

`stop()` 先停采集/输入，调用 `finalizeAndFinishThroughEndOfInput()`（1 s 上限）让转写器发布当前 range 的 final，给消费者 300 ms 收 final，再用 `silenceTimedOut()` 兜底，最后取消剩余任务并 finish 外发流；`resetPipelineKeepingStream`/`restartSingle` 也走同一个 finalize。VM 在 `stop`/`endTask`/`beginTask` 前 await `speechTask`（500 ms 上限），确保 final 进入快照。VM 的 `for await` 退出后把捕获的 `SpeechSessionHandle` 交给 `TaskLifecycle.handleStreamEnded(_:)`。
生命周期先向 gate 查 `isCurrent(handle)`：当前句柄非预期结束 = `recognitionInterrupted`；被新 owner 取代的句柄静默转 `pausedListening`，不报假错误。`fail()` 仍只 finish 流、不带错误；权限/资源错误在生命周期启动阶段单独映射。

---

## 5. 翻译：共享管线 + View 锚定 Host

翻译 job 的生命周期与 Host 执行分离：

- `TranslationPipeline`（`Duiyi/Features/Shared/TranslationPipeline.swift`，`@MainActor @Observable`）拥有 job 形成、每 utterance 独立防抖、重复抑制、单调 `sequence` 过期判定、已应用 job 去重、preview 有界且 final 不丢的有序 outbound 队列，以及 `sentSourceText` / `lastAppliedSourceCount` / `lastAppliedSequence`。`accept` 在应用前按目标语言规范化省略号（中文/日文 `……`，其它语言最多三个 ASCII 点），避免把 ASR 的点串原样显示。
- `TranslationHostView` / `OneWayTranslationHostView` 只是 `.translationTask` 的泵适配器：live 模式按 ViewModel 的 `outboundRevision` 变化 drain `takeNextOutboundJob()` 到空，逐条 `submit` 给共享 bridge；`TranslationJobPump` 每次唤醒逐条 `session.translate`，成功/失败回调 ViewModel。历史详情仍用单个 `job:` 逐条推进。
- 两个 ViewModel 只保留 feature 策略与副作用：Conversation 做语言路由与 crosstalk，并把结果写入两侧 pane/transcript；Interpretation 选目标语言、写单栏 pane/transcript 并调度 TTS。`fulfill` 是薄适配器：`pipeline.accept` 返回 `TranslationUpdate` 后写 UI。
- `TranslationTrigger`（Domain 纯函数）回答非 final 文本是立即发送、进入防抖还是丢弃：句末/从句标点立即发送，≥4 estimated words 防抖，更短丢弃；final 旁路属于 pipeline。
- 六语脚本计数与 scalar 判定放在 Domain 的 `ScriptCounts`；`TranslationTrigger` 与 Services 的 `UtteranceAssembler` 都复用它，Domain 不反向依赖 Services。
- **诊断（P1-4a）**：`TranslationPipeline` 在 job 形成与结果应用时向 `DiagnosticsRecording` 写 submit/apply 事件；`TranslationJobPump` 写 Response 语言、重试与失败类。记录只含 ID、语言、长度与延迟，不含正文；`TranslationJob` 不加时间字段，提交→应用延迟由 recorder 的 jobID 表计算。

### 5.1 Host

`Duiyi/Features/Shared/TranslationHostView.swift`（跨 feature 共享：面对面、同传、历史详情、引导）：

- `TranslationHostView`：面对面双向，两个 `TranslationSession.Configuration`（user→peer、peer→user），两个 `TranslationJobBridge`。
- `OneWayTranslationHostView`：同传/会议详情单向，一个 configuration、一个 bridge。
- 两个 Host 都有两种 job 入口：live 模块用 `outboundRevision` + `takeNextOutboundJob`，每次 revision 变化与 `onAppear` 时 drain 到空；历史详情用 `job:`，调用方逐条推进并按 job 重建 Host。
- `TranslationPrepareHost`：引导/换语言时 `prepareTranslation()`，成功后回调。

configuration 使用：

```swift
TranslationSession.Configuration(
    source: from.localeLanguage,
    target: to.localeLanguage,
    preferredStrategy: .lowLatency
)
```

调用方用 `.id("<user>-<peer>")` / `.id("<source>-<target>")` 包住 Host（`ConversationView`、`InterpretationView`、`OnboardingView`），语言对变化时销毁并重建 View，两个 session 和 bridge 一起重建；旧 session 的失败（包括 14/20、`CancellationError`）只清空当前 job，不写入新语言对。`TaskDetailView` 的单向翻译按 `<source>-<utteranceID>` 逐条重建。

### 5.2 TranslationJobBridge 与 TranslationJobPump

`TranslationJobBridge`（`@unchecked Sendable` + `NSLock`）是 per-`utteranceID` 合并的 job 队列；`TranslationJobPump`（`Duiyi/Features/Shared/TranslationJobPump.swift`）是 Host 的 drain 循环：

- **每句合并**：同一 `utteranceID` 最多保留一条 pending job；替换时保留该 ID 首次出现的位置，不同 ID 之间保持 FIFO。
- **final 优先**：已排队的 final 不会被后续 non-final 覆盖；non-final 可被新的 non-final 覆盖；任何新 final 可覆盖旧 job（final 被更新 final 取代）。
- **Host 未就绪**：不设“只保留一条”的特殊模式，未安装 consumer 时同样按 ID 合并；`makeConsumer()` 安装时若队列非空立即产生一次 wakeup，历史详情逐条翻译不会因为 `onAppear` 先于 `.translationTask` 而卡住。
- **generation-scoped consumer**：`Consumer` 暴露 `wakeups`（`.bufferingNewest(1)` 的 `AsyncStream<Void>`）与 `takeNext()` / `requeue(_:)`。只有最新 generation 能取 job；旧 generation 的 `takeNext()` 返回 nil，旧 `onTermination` 不清新 continuation。`requeue` 不受 generation 限制：bridge 记录每个 `utteranceID` 最新入队 job 的 ID，只有该 job 仍是该句最新提交且队列中没有同 ID job 时才接受 requeue，插入队首并在锁外 wake 当前 consumer——旧 pump 取消的 final 仍能被新 consumer 翻译。`yield` / `finish` 在锁外执行，`submit` 多次可合并为一次唤醒。
- **pump drain 与取消**：`for await` 每次 wakeup 后循环 `takeNext()` 直到空（一次唤醒 drain 多条，不按 submit 次数排队）。每取一条先检查任务取消；已取消时若该 job 已被同 ID 新提交取代则丢弃，否则 `requeue` 到队首并退出。正常 in-flight 翻译不主动取消，结果仍经 `TranslationPipeline.accept` 判定（preview 可丢更短结果，final 一律应用）；`Task.isCancelled` / `CancellationError` 不调用 `onFailure`，真实错误仍走 `onFailure`；空白文本由 bridge 在 `submit` 时过滤（pump 只做 trim）。非任务取消的 `CancellationError` 同样让当前 pump 退出；随后 Host 的 `.translationTask` 重启安装新 consumer，drain 已 requeue 的 job（单测覆盖，无 sleep）。
- **时序保持**：40/90 ms、voiceOut 25/50 ms、380 ms TTS settle、1.1 s 静音 final 与 crosstalk 的数值/行为不变。跨句 preview 防抖不再互相取消（P0-1），因此 emit 集合按设计扩大；outbound 队列只保证连续 job 都能到达 Host，不改变 bridge 的 per-ID 合并与 final 优先。
- **测试接缝**：bridge 接口同步验证合并、顺序、final 优先级、pre-pump wakeup、generation-scoped takeNext 与 latest-job requeue（含唤醒已等待的新 consumer）；pump 通过注入 `translate` / `onSuccess` / `onFailure` 验证 drain、取消、requeue、in-flight 完成与非任务取消后的新 consumer 接管。生产路径用 `TranslationSession.translate` 适配，不新增 session 替身。

### 5.3 TranslationPipeline

- 接口：`submit(TranslationSubmission)`、`takeNextOutboundJob()`、`outboundRevision`、`accept(job:text:) -> TranslationUpdate?`、`fail(job:)`、`reset()`、`outboundJob`（未 drain 的最新 job，供测试观察）。
- `TranslationSubmission` 由 feature 在提交时算好行、`isFinal`、目标语言、首包/后续延迟；pipeline 不读取 feature 状态。
- 非 final 由 `TranslationTrigger.action(for:language:)` 三选一：以 `ClauseSplitter` 终止符（含仅看末字符时的 ASCII `.`）结尾 → `.sendNow`；≥4 estimated words → `.debounce`（首包/后续延迟）；更短 → `.drop`，不翻译两词片段。estimated words：英文按词数；越南语按音节数/2；中/日/韩按脚本字符/2；泰语按字符/3（启发式，随 P1-4 设备数据调整）。final 直接 `.sendNow` 旁路防抖。
- 防抖按 `utteranceID` 独立：新行/新 final 只取消同一句的待发 preview，不会取消其他句的 preview。空文本直接返回且不改队列。
- outbound 是**有界有序队列**：同一句最多排一条，替换保留首次位置；已排队 final 不被迟到的 preview 取代；preview 积压上限 `outboundQueueLimit`（超限丢最旧 preview，final 永不丢弃）。每次入队递增 `outboundRevision`，Host 据此 drain `takeNextOutboundJob()` 到空；不要退回单个 `outboundJob` 观察值（SwiftUI 会合并两次渲染之间的 job）。
- 每个 pipeline job 带单调 `sequence`；`accept` 拒绝同句**不新于**已应用 sequence 的结果（`<=`），因此同一 pipeline job 不会被重放。非 pipeline job（sequence 0）另按 job ID 去重（记录最近 256 个）。
- 结果应用规则统一：**final 译文一律应用（即使源文更短）**；preview 结果在比上次已应用结果更短或 sequence 更旧时丢弃。不再按 feature 注入不同策略。
- `reset()` 取消全部防抖并清空队列、`sentSourceText`、`lastAppliedSourceCount`、`lastAppliedSequence` 与已应用 ID 表。`fail(job:)` 只把尚未 drain 的该 job 移出队列，不影响其他 job。
- `accept` 返回 job 的 `utteranceID`；行身份就是 `Utterance.id`（D8），pipeline 不做跨 ID 文本合并。
- 调度器只通过 ViewModel 的 internal 测试初始化器注入；生产构造器不暴露它。生产用 `Task.sleep`，测试用手动调度器确定性驱动防抖窗口。
- 两个 ViewModel 各自构造 pipeline；任何构造器都不接收 pipeline。final 权威规则由 pipeline 自身负责。

### 5.4 节流与去抖

| feature | 目标语言 | 首包/后续延迟 | 结果应用 |
| --- | --- | --- | --- |
| 面对面 | `LanguageRouter.targetLanguage(detected:userLanguage:peerLanguage:)` | 40/90 ms | final 一律应用；preview 丢短/旧 sequence；同句 sequence 必须递增 |
| 同传 | 用户选中的目标语言 | voiceOut 开 25/50 ms；否则 40/90 ms | final 一律应用；preview 丢短/旧 sequence；同句 sequence 必须递增 |

- ViewModel 在提交时计算目标与延迟，调用 `pipeline.submit`，自身不再持有防抖 Task、`sentSourceText` 或 `lastAppliedSourceCount`。
- 结果经 `pipeline.accept` 按 `utteranceID` 写回并判过期；Conversation 先写两侧 pane 再更新 transcript，Interpretation 先写字幕再按既有 380 ms 结算调度 TTS。

### 5.5 取消

`TranslationErrorDomain` 14/20 与 `CancellationError` 视为过期，不弹错。真正失败只记日志/状态，不把系统错误直接丢上字幕板。

---

## 6. 三个 Feature 的流水线

> C04（spec [#27](https://github.com/DavidTeam2008/mybuddy/issues/27)，D8）已完成代码收敛：字幕/文字稿投影统一为 `Domain/Projection/CaptionProjection` 的单一有序 record store。每行以 `Utterance.id` 为唯一身份；显示窗口（live / history）与全量 transcript 都由 record 派生；清屏移动显示代次而不删 record，`PaneState` 只是派生快照。

### 6.1 面对面

默认是**手动换手**（`ConversationListeningMode.manual`）：

```
点一侧 → activeSpeaker（user/peer）；无 active 时中间控制默认 user
  → 单路 [activeSpeaker 的语言]（切 turn：pause → drain → start）
  → projection.ingest(utterance, pane: listener = activeSpeaker.opposite, speaker: speaker)
  → enqueueTranslation（target = listener 的语言）→ TranslationPipeline.submit → TranslationHostView
  → fulfill → TranslationPipeline.accept → projection.applyTranslation
  → settled 时 TaskLifecycle.persist(projection.transcript)（250ms 防抖）
```

- 手动模式不跑 `shouldIgnoreCrosstalk`/`LanguageRouter`；pane 固定为听者侧；迟到 final 仍按 utterance ID pin。
- 新任务不自动开始（即使 `autoStartListening` 为 true）；暂停恢复保留 active；换语言/对调/新任务/结束清空 active。
- 自动模式是备选，保留原来的语种路由流水线：

```
Utterance
  → shouldIgnoreCrosstalk（final 后 1s、异语、非自信 → 丢弃）
  → LanguageRouter.targetSide(detected, userLanguage) + routedSideByUtterance pin
  → 确定 listener / speaker
  → projection.ingest(utterance, pane: listener, speaker: speaker)
  → enqueueTranslation（用返回行）→ TranslationPipeline.submit → TranslationHostView
  → fulfill → TranslationPipeline.accept → projection.applyTranslation
  → settled 时 TaskLifecycle.persist(projection.transcript)（250ms 防抖）
```

- `routedSideByUtterance` 固定同一句的去向，避免 partial 改语言导致左右跳。
- 身份与文本选择在投影模块内：同一 ID 只有一行；`UtteranceAssembler` 独占新 ID 判定（含 volatile greeting name swap）。
- 每侧 pane 只保留 `live` + 最多 3 条历史（`CaptionDisplayPolicy.conversation`）；更早行只进 transcript。恢复任务也只回填每侧最近 3 条，transcript 全量。
- 暂停/后台 `flush()`；结束任务走 `TaskLifecycle.endTask`（flush + 原子 `TaskStoreV2.end`）；清屏前先 `flush()`。
- 清屏只清显示（`projection.clearDisplay()`），不停听、不结束任务；transcript、任务数据、历史与导出以全量为准。

### 6.2 同声传译

```
Utterance
  → guard utterance.language == sourceLanguage
  → projection.ingest(utterance, pane: .user, speaker: .peer)
  → TranslationPipeline.submit（单向 source→target）
  → fulfill → TranslationPipeline.accept → projection.applyTranslation
       返回行 → 字幕 / TTS；nil（清屏 floor 或 50 条窗口外）→ 只更新 transcript，不朗读
  → settled → ClauseSplitter.consume → TTS 队列
```

- `CaptionDisplayPolicy.interpretation` 的 `historyLimit = 50` 只裁 pane 显示与恢复回填；transcript、落盘与导出全量。
- 朗读只接受 final；`speechSettleDelay = 380 ms` 合并 ASR 尾修；TTS 直接使用投影返回行的 `translatedText`，不再回查 pane。
- `pendingJobs` 硬上限 10；超限先丢短确认语，再丢最旧任务；去重使用已读前缀、280 字 `spokenCompactTail` 和队列内 compact 拼接。
- `speechGeneration` 令牌防止旧朗读任务在暂停/换方向后继续。
- 方向/语言变化停听、`projection.archiveLive(pane: .user)`、清队列、重建配置；历史保留。

### 6.3 会议记录

```
MeetingRecognition.languages(multilingual:pinned:display:)
  → start(languages:..., fallback:..., style: .meetingNotes)
  → accept: 非多语时丢弃非 sourceLanguage
  → UtteranceAssembler.resolvedLanguage 给每行定实际语种
  → projection.ingest(..., pane: .user, speaker: .user)（无翻译）
  → settled 时 20,000 字符检查（projection.transcriptCharacterCount）
```

- 多语言：`[display, display.defaultPeer]`；单语：只跑 pinned。
- 达到字符上限：`isLengthLimited = true` 并自动停听，任务保持进行中；计数按任务累计（含清屏前内容），清屏不复位。D7 的续集任务组（组 ID、「结束并继续」、组内跳转）**不在 Wave 1**，仍是后续 wave；当前只能结束并手动新建。
- 清屏只清 pane / 总结显示（`projection.clearDisplay()`），保留 transcript、`isLengthLimited` 与计数器；清屏后继续记录追加到同一 transcript。
- 会议详情可逐条单向翻译并 `updateTranslations` 回填，不新增条目。

---

## 7. 任务与持久化

### 7.1 Domain 语义

`TaskSession`：`id / feature / status / startedAt / endedAt / title / subtitle / sourceLanguage / targetLanguage / entries / summary`。

`TaskStatus`：`running / pausedListening / ended`。只有 `ended` 进历史；空稿由 store 按持久化内容判断后删除。

`TaskLifecycle`（每个 Feature 一个，由三个 VM 持有）拥有当前任务、状态转换、restore、两阶段开始、结束、250 ms 防抖、flush、scenePhase 暂停与 `notSaved` 标记：

- `restore()`：恢复该 feature 最新未结束任务；返回任务自带语言对，VM 应用并显示「继续任务：…」；屏幕只回填窗口（面对面每侧 3 条、同传 50 条），transcript 全量。
- `prepareForNewTask()`：停当前听写 → flush → 以 store-aware 空稿判断结束旧任务；返回 `.ready` / `.blockedByUnsavedTask` / `.notSaved(reason)`。VM 只在 `.ready` 后清本模块字幕。
- `startNewTask(request)`：用 `TaskDraft` 新建；store 写失败则创建 memory-only 任务并标记 `isNotSaved`；按 `autoStart` 决定是否经 gate 开始听写。
- `persist(transcript)`：统一 250 ms 防抖；`flush()` 供结束、清屏、进后台使用；begin/end 取消旧防抖，防止旧内容写到新任务。
- `endTask(transcript:summary:)`：停听 → flush → `TaskStoreV2.end` 原子结束；只有 `.ended` / `.discardedEmpty` 清空字幕；`.notSaved` 保留任务与字幕供导出。
- `pauseListening()` / `pauseForScenePhase()`：只停流并 flush，任务保持进行中。
- `handleStreamEnded(_:)`：先确认传入句柄仍是 lifecycle 的当前活动句柄（重启/暂停后的迟到消费者直接忽略），再用 gate 的 `isCurrent` 区分被取代（静默暂停）与真中断（`recognitionInterrupted`）。

### 7.2 DeferredTaskStore

`DeferredTaskStore` 是 `TaskStoreV2` 的延迟包装：

- `init` 不阻塞主线程，后台 `Task.detached(priority: .utility)` 打开 `ModelContainer`。
- 组合根只持 `any TaskStoreV2`；首页/历史/恢复调用 `prepare()` 等待容器，不再需要具体 store 的预热方法或 downcast。
- 可用性显式：`opening` → `ready`，失败为 `unavailable(reason)`；`retry()` 重新打开。首页、历史、详情与三个模块共享同一个 store 实例：前三个读 `availability` 显示横幅，模块按写结果标记 `isNotSaved`。
- 打开失败不静默回退 `InMemoryTaskStore`；模块可继续，但写入返回 `notPersisted` 并显示「本次内容不会保存」。读失败返回 `.unavailable`，不显示成空列表。
- 写失败只在接缝内重试一次（`saveFailed`）；仍失败返回 `notPersisted`，不轮询、不回填。`end` 的三态为 `ended` / `discardedEmpty` / `notPersisted`。
- `RootView` 首帧后 `prepare()`，通常用户导航时已就绪。

### 7.3 SwiftData

`schema = [TaskEntity, TranscriptEntity]`：

- `TaskEntity`：任务元数据、状态、总结、`schemaVersion`。
- `TranscriptEntity`：按 `taskID` 关联、cascade 删除、`sortIndex` 保序。
- `SwiftDataTaskStore` 使用主线程 `ModelContext`，显式关闭 autosave（`autosaveEnabled = false`）；每个变更 `try context.save()` 并把失败映射为 `.notPersisted`，失败时 `rollback()`，不用 `try?` 吞错。
- `append` 按 entry ID upsert 传入条目后显式 `save()`；同一 ID 的 volatile 更新原地覆盖，不重复插入；已结束任务上的迟到 append 是 no-op。`updateTranslations` 只回填已有条目的译文，允许已结束任务。
- `end` 原子：先 upsert pending 条目，再以 `entity.entries` 判空稿，有内容则结束、无内容则删除，最后只 `save()` 一次；保存失败 rollback，任务保持进行中且不删除。
- `read*` 返回 `value` / `unavailable`；`list` 只取 `ended`，倒序；`end` 补会议 subtitle。
- 尚无 `SchemaMigrationPlan`（P3）。

写入点统一：settled 时由 `TaskLifecycle` 做 250 ms 防抖、暂停/后台 `flush()`、结束全量交给 `end`、清屏前 `flush()`。实时字幕始终以内存为准，View 不直接读 SwiftData。
`endTask` 与新建任务的 `prepareForNewTask` 都保留最近一个已结束任务的快照；结束/重置后到达的 final 译文由 `TaskLifecycle.backfillTranslation` 通过 `TaskStoreV2.updateTranslations` 回填（store 允许对已结束任务只写译文），preview 不落库。结束写入在途时到达的 final 由 `LateTranslationBackfill` 暂存，写入返回后回填。

---

## 8. 总结、导出、资源、权限

- **总结**：`FoundationModelsSummarizer` 按 `SystemLanguageModel.availability` 分支；仅在可用时生成；失败/不可用/空结果只说明原因，不生成本地 digest（v1）。
- **导出**：`TranscriptExportService` 写 Caches，UTF-8 原子写；快照按 task UUID 与完整内容 SHA-256 命名且不可变，仅清理严格超过 7 天且未被本进程准备的普通文件；`ShareLink` 分享。
- **模型准备**：`SpeechAssetPreparer` 用 `SpeechTranscriber(preset: .progressiveTranscription)` 占位模块创建 `AssetInventory` 安装请求，200 ms 轮询进度。
- **翻译可用性**：`TranslationAvailabilityService` 双向查 `LanguageAvailability` 并合并状态。
- **权限**：`PermissionService` 映射麦克风/语音识别四态；`requestAccess` 先麦后音后重查。
- **语言目录**：生产注入 `SystemLanguageCatalog`，由 `SpeechTranscriber.supportedLocale`、`LanguageAvailability`、`AVSpeechSynthesizer` 探针填充缓存；当前只有首页设置消费，v1 扩展到所有语言入口。
- **诊断（P1-4a）**：`DiagnosticsRecorder` 是唯一实现，`AppEnvironment` 注入；`TaskLifecycle` 在任务开始/恢复/结束处 begin/end 会话，结束后迟到的事件仍归最近结束任务。ring buffer 默认 4096 事件，聚合计数独立累加；DEBUG 设置页写 `Documents/duiyi-diagnostics-<时间>.json` 并 ShareLink，不上传。ASR 事件在引擎消费 `SpeechTranscriber.Result` 处记录 `range`/`resultsFinalizationTime`/synthetic/脚本不匹配，不改组装行为。`speech.failure` 记录失败语言、错误 domain/code 与恢复决策（`singleFallback`/`none`/`restartFailed`），不写错误文案。

---

## 9. 并发模型

| 组件 | 隔离 | 原因 |
| --- | --- | --- |
| `BilingualSpeechEngine` | `actor` | tap、analyzer 流、任务取消 |
| `SpeechSessionGate` | `actor` | 单一 owner/generation、start/stop 串行化 |
| `AudioEngineCapturer` | `actor` | AVAudioEngine 非线程安全 |
| `AudioSessionPolicy` | `actor` | session/route 通知 |
| `SpeechAssetPreparer` | `actor` | 下载与进度回调 |
| `AppEnvironment` / 三个会话 VM / `TaskLifecycle` / `HistoryViewModel` | `@MainActor` | 驱动 SwiftUI |
| `DeferredTaskStore` / `SwiftDataTaskStore` | `@MainActor` | 主上下文 |
| `LanguageRouter` / `UtteranceAssembler` / `SpokenText` / `ClauseSplitter` / `ScriptCounts` | `Sendable` 值语义 / 无状态纯函数 | 可重入、可单测 |
| `SystemSpeechSynthesizer` | `@MainActor` + delegate | AVSpeechSynthesizer 代理回调 |
| `TranslationPipeline` | `@MainActor` + `@Observable` | 翻译 job 生命周期与 UI 状态 |
| `TranslationJobBridge` | `@unchecked Sendable` + `NSLock` | 跨 View 任务队列与 consumer 唤醒流 |
| `DiagnosticsRecorder` | `@unchecked Sendable` + `NSLock` | speech actor 与主线程共同写入的 ring buffer |

`SendablePCMBuffer` 用 `@unchecked Sendable` 包装 `AVAudioPCMBuffer`，跨 actor 传递，责任在音频层。

---

## 10. 测试与验证

| 层级 | 覆盖 | 入口 |
| --- | --- | --- |
| Domain 纯逻辑 | 路由、assembler（文本与 range-aware）、spoken 合并、clause、翻译触发阈值、任务映射 | `DuiyiTests`（Swift Testing） |
| 翻译管线 | job 形成、每句防抖、重复抑制、final 权威与 preview 过期、有序 outbound 队列与 drain、sequence/去重、`reset` | `DuiyiTests`（`TranslationPipelineTests`） |
| 翻译 job bridge / pump | per-`utteranceID` 合并、final 优先、pre-pump wakeup、generation-scoped takeNext、latest-job requeue、drain/取消 | `DuiyiTests`（`TranslationJobBridgeTests`、`TranslationJobPumpTests`） |
| ViewModel / 生命周期 | 三模块状态机、pipeline 接线、清屏、任务恢复、TTS 队列、`TaskLifecycle`/`SpeechSessionGate` 接缝 | `DuiyiTests` |
| 音频策略 | 路由快照/回声判定 | `DuiyiTests` |
| UI | 冷启动、首页导航、同传听写压力、滑动返回 | `DuiyiUITests`（XCTest，4 个用例） |
| 诊断 | ring buffer 淘汰、聚合计数、会话 begin/end、submit→apply 延迟、拒收原因、JSON 字段 | `DuiyiTests`（`DiagnosticsRecorderTests`、`TranslationPipelineDiagnosticsTests`） |
| 真机 | 语音、翻译、TTS、持久化、长会话 | 真机手动验证（原 harness 脚本未随提取保留） |

基线：以仓库当前 `DuiyiTests` / `DuiyiUITests` 结果为准；原 harness 的基线计数未随提取保留。模拟器没有 `SpeechTranscriber`，`testSimultaneousListeningPressure` 会 skip，这是预期行为。

---

## 11. 已知架构风险（摘要）

完整问题、证据与排期见 [`04-roadmap.md`](04-roadmap.md)。

- **P0-1 单引擎仲裁（已实现，Wave 1 #3/#4/#6–#8）**：`SpeechSessionGate` 用 owner + generation 仲裁唯一流；stale stop no-op，被取代的流静默暂停，当前流非预期结束才报中断。快速切模块/前后台的真机验证仍按发布清单执行。
- **P0-2 长会话留存（显示窗口已完成，续集组待后续）**：Conversation pane 窗口 N=3、transcript 全量；Interpretation 50 条仅显示与恢复回填；Meeting 2 万字按任务累计、清屏不复位。D7 的续集任务组不在 Wave 1。
- **P0-3 持久化可靠性（降级已实现，写放大/迁移待后续）**：可用性显式 + `prepare()`/`retry()`、结果化读写、单次写重试、原子 `end`、autosave off + 显式 save 已落地；`append` 仍是全量快照 upsert，尚无迁移计划（P3-1）。
- **P1**：翻译桥积压、导出清理竞态、切语言旧翻译状态、中英混读丢弃、单路漂移丢句。
- **P2/P3**：Detector 失败静默、`fail` 吞因、TTS 语速/音色设置、MainActor 上的 LCS 计算、非音频格式静默丢包。

---

## 12. 关键文件索引

| 主题 | 文件 |
| --- | --- |
| 入口/组装 | `Duiyi/App/DuiyiApp.swift`、`AppEnvironment.swift`、`RootView.swift`、`AppCoordinator.swift`、`FeatureRegistry.swift`、`PreferencesStore.swift` |
| 音频 | `Duiyi/Services/Audio/AudioEngineCapturer.swift`、`BufferConverter.swift`、`AudioSessionPolicy.swift` |
| 听写 | `Duiyi/Services/Speech/BilingualSpeechEngine.swift`、`SpeechSessionGate.swift`、`UtteranceAssembler.swift`、`Duiyi/Services/ServiceProtocols.swift`、`Duiyi/Features/Shared/SpeechTaskDrain.swift` |
| 翻译 | `Duiyi/Features/Shared/TranslationPipeline.swift`、`Duiyi/Domain/Models/TranslationTrigger.swift`、`Duiyi/Domain/Models/ScriptCounts.swift`、`Duiyi/Features/Shared/TranslationHostView.swift`、`Duiyi/Domain/Models/TranslationJob.swift`、`Duiyi/Services/Translation/TranslationAvailabilityService.swift` |
| 面对面 | `Duiyi/Features/Conversation/ConversationView.swift`、`ConversationViewModel.swift`、`CaptionPaneView.swift`、`ListeningControl.swift` |
| 同传 | `Duiyi/Features/Interpretation/InterpretationView.swift`、`InterpretationViewModel.swift`、`DirectionBar.swift`、`VoiceOutControl.swift`、`Duiyi/Domain/Models/Clause.swift` |
| 会议 | `Duiyi/Features/Meeting/MeetingView.swift`、`MeetingViewModel.swift` |
| 任务/持久化 | `Duiyi/Domain/TaskSession.swift`、`Duiyi/Services/TaskLifecycle.swift`、`Duiyi/Services/Persistence/DeferredTaskStore.swift`、`SwiftDataTaskStore.swift`、`TaskEntities.swift`、`InMemoryTaskStore.swift` |
| 存储状态 UI | `Duiyi/Features/Shared/StorageUnavailableBanner.swift`、`Duiyi/Features/Home/HomeViewModel.swift`、`Duiyi/Features/History/HistoryViewModel.swift` |
| 总结/导出 | `Duiyi/Services/Summary/FoundationModelsSummarizer.swift`、`Duiyi/Services/Export/TranscriptExportService.swift` |
| 任务详情 | `Duiyi/Features/History/HistoryView.swift`、`HistoryViewModel.swift`、`TaskDetailView.swift` |
| 设计系统 | `Duiyi/DesignSystem/Tokens.swift`、`HomeModuleCard.swift`、`HistoryRow.swift`、`ScreenSafeArea.swift` |
