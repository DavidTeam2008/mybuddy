# AGENTS.md · Duiyi/Features

> 触发：改 ViewModel / View / 导航入口 / 任务条交互前先读本页。
> 本页只写 Features 的增量约束；项目规则见根 [`AGENTS.md`](../../AGENTS.md)，依赖理由见 [`docs/02-architecture.md`](../../docs/02-architecture.md) §1，加模块步骤见 [`docs/02-architecture.md`](../../docs/02-architecture.md)。

## 1. 依赖与注入

- Features 只依赖 Domain + Services 协议；VM 通过构造器注入 `any SpeechSessionGating` / `any TaskStoreV2` / `SpeechSynthesizing` / `PreferencesStore` 等，不 new 具体 Service。听写入口是 gate，不是 `SpeechRecognizing`；兼容用 `speech:` initializer 只在内部包一层 `SpeechSessionGate`。
- 不 import `Speech` / `AVFoundation` / `SwiftData`；`Translation` 只允许在跨 feature 共享的 `Shared/TranslationHostView.swift`（`@preconcurrency import Translation`）。
- 不直读 SwiftData；历史详情走 `TaskStoreV2` 的结果化只读查询（`readTask` 等），读失败显示存储横幅而不是空列表；不复用现场字幕状态机。

## 2. 并发与主线程

- ViewModel 是 `@MainActor`；UI 状态只在主线程改；`await` 服务返回后回主线程再更新。
- 长 I/O 交给 Service（`DeferredTaskStore` 已延迟开库）；不要在 `body`、`init` 或首帧路径做同步文件/SwiftData 工作。
- 回调用 `Task { @MainActor in ... }`；不要用 `Task.detached` 改 UI 状态；任务取消后不得写入过期状态。

## 3. 翻译走 `TranslationPipeline`、锚 View，字幕以内存为准

- 需要翻译时由 VM 调 `Shared/TranslationPipeline.submit(TranslationSubmission)`：行、`isFinal`、目标语言与首包/后续延迟在提交时算好。pipeline 负责 job 形成、每 utterance 独立防抖、重复抑制、单调 `sequence` 过期判定（同句必须递增）、已应用 job 去重（非 pipeline job 窗口 256）与 preview 有界、final 不丢的有序 outbound 队列；VM 不再自持防抖 Task、`sentSourceText` 或 `lastAppliedSourceCount`。
- 非 final preview 由 `TranslationTrigger.action(for:language:)` 三选一：终止符 → `.sendNow`；≥4 estimated words → `.debounce`（首包/后续延迟）；更短 → `.drop`。不要绕过去直接提交短片段；final 仍旁路全部 gate。
- VM 自建 `TranslationPipeline`。结果规则统一：**final 译文一律应用（即使源文更短）**；preview 结果在比上次已应用结果更短或 `sequence` 不新于已应用时丢弃；同一 job 的重复结果不会应用两次。`pipeline.accept` 在应用前用 `TextNormalization.translation` 按目标语言规范省略号（中文/日文 `……`，其它语言最多三个 ASCII 点），下游拿到的都是规范化文本。调用方构造器不接收 pipeline 或 scheduler；测试只通过 internal 的 `scheduler:` 初始化器注入调度器。
- live Host 不接受单个 `outboundJob`：View 把 VM 的 `outboundRevision` 与 `takeNextOutboundJob` 传给 `TranslationHostView` / `OneWayTranslationHostView`，Host 在 revision 变化和 `onAppear` 时 drain 到空再 submit 给 bridge。不要退回只观察“最新 job”：SwiftUI 会合并两次渲染之间的 final，第一个永远到不了 Host。历史详情的逐条翻译保留 `job:` 初始化器。
- 译文结果在显示/落库前必须过 `TextIntegrity`：含 U+FFFD 或可疑控制字符的 final 由 pump 重试一次；仍坏则走失败（不显示、不落库、不导出）。投影层对任何损坏译文直接拒绝。
- `fulfill` 只把 `pipeline.accept` 返回的 `TranslationUpdate` 写入 pane/transcript；同传再按既有 380 ms 结算调度 TTS。View 通过 `outboundRevision` + `takeNextOutboundJob` 把 job 交给 `TranslationHostView` / `OneWayTranslationHostView` 的 `.translationTask`；VM 不持有 `TranslationSession`。结束任务后到达的 final 译文若 projection 已 reset（`contains` 为 false），`fulfill` 必须经 `LateTranslationBackfill` 交给 `lifecycle.backfillTranslation` 回填已结束任务；结束写入在途时先暂存、返回后回填；preview 不回填。
- 诊断（P1-4a）：`TranslationPipeline` 与 `TranslationJobPump` 向注入的 `DiagnosticsRecording` 写 submit/apply/response/failure；只写 ID、语言、长度、延迟与失败类，不写正文。live Host 从 VM 的 `translationDiagnostics` 取 sink；历史详情的顺序 Host 用默认 no-op。不要在 ViewModel 里另建 recorder 或上传数据。
- Host 共享 `TranslationJobBridge` + `TranslationJobPump`：bridge 按 `utteranceID` 每句最多保留一条 pending，替换保留首次位置；已排队 final 不被新 non-final 覆盖，任何新 final 可覆盖旧 job。consumer 的 `takeNext()` 是 generation-scoped；`requeue` 接受任意 generation，只要该 job 仍是该句最新提交且无同 ID pending，插入队首并 wake 当前 consumer；`makeConsumer()` 时队列非空立即补 wakeup，Host 未就绪时也按 ID 合并。`TranslationJobPump` 每次唤醒 drain 到空；取消时该 job 已被同 ID 更新取代就丢弃，否则 requeue 到队首并退出，取消不触发 `onFailure`；非任务取消的 `CancellationError` 由下一次 `.translationTask` 重启的新 consumer drain。
- 测试接缝：bridge 接口（同步验证合并、顺序、final 优先级、pre-pump wakeup、generation-scoped takeNext、latest-job requeue 与唤醒已等待 consumer）与 pump 注入的 `translate` / `onSuccess` / `onFailure`（验证 drain、取消、requeue、in-flight 完成、非任务取消后的新 consumer 接管）；不要为生产路径新增 `TranslationSession` 替身，也不要用 sleep 驱动。
- 现场字幕读 VM 的 `PaneState`/内存数组，不读 SwiftData；落盘异步，View 不等待落盘再更新。

## 4. 任务语义（交互必须保持）

- 任务生命周期在 `TaskLifecycle`：`beginTask` 走 `prepareForNewTask()` → 清本模块字幕 → `startNewTask()`；结束走 `endTask`；VM 不自行实现 250ms 防抖、restore 映射或空稿判断。
- 显式“新任务 → 结束任务”；只有 ended 进历史；空稿由 `TaskStoreV2.end` 按 store 中持久化内容判断后删除；暂停只停麦克风，不结束任务。
- 清屏用 `clearDisplay()`：先 `flush()`，只清显示（pane/字幕/翻译与总结显示），保留 transcript、总结数据与会议计数；`resetCaptions()` 只用于新任务、结束任务、换语言/方向。
- 停止/结束/新建任务前：先 `lifecycle.pauseListening()`，再 await 本模块的 `speechTask`（`drainSpeechTask()` → `SpeechTaskDrain.wait`，500 ms 上限），最后 snapshot/reset；不要先 cancel consumer，否则引擎 stop 时发布的 final 会丢。
- 同传 50 条只裁 pane 显示与恢复回填；面对面每侧 live + 3 条历史、恢复只回填 3 条；transcript / 历史 / 导出始终全量。会议 2 万字按任务累计，清屏不复位。
- 存储不可用时继续显示已加载内容，用共享横幅 + 重试；当前任务标记「本次内容不会保存」，结束后不写历史但可从内存导出；有内容的未保存任务在新建前必须让用户选择导出或放弃。
- 后台/切模块只停听，不自动结束；不要把“结束任务”改成自动保存。

## 5. UI 入口与可测试性

- 新增 UI 入口必须加 `accessibilityIdentifier`，沿用 kebab-case（`home-module-*`、`nav-*`、`taskbar-*`、`caption-*`、`langchip-*`、`listening-control`）；不靠中文文案或坐标定位。
- 改入口/标识要同步 `DuiyiUITests`；历史页返回用 `nav-home`，详情页用系统返回（回历史）+ 右上 `nav-home`（回首页）。
- View 保持薄：复用 `Shared/`（`ModuleToolbar`/`HistoryToolbar`/`DetailToolbar`、`ToolbarGlyph`、`TaskStatusText`、`LanguageChipGrid`）与 `DesignSystem`，不要复制布局常量。所有页面优先用系统导航栏，不再自绘 chrome。

## 6. 新增模块（六步）

1. `Domain/FeatureID.swift` 加 case 与 `AppMode` 映射；
2. `App/AppCoordinator.swift` 的 `FeatureID.route` 加映射；
3. `App/FeatureRegistry.swift` 登记标题/图标，补 `Copy+Platform` 与 `Tokens`；
4. 新建 `Features/<Name>/` 的 View + ViewModel；
5. `App/AppRoute.swift` + `RootView.destination(for:)` 加分支；
6. 首页 identifier 自动带新 feature id，补对应 UI 测试。

- 三个常驻 VM 在 `RootView` 首帧后创建；不要把 VM 创建或 store 打开放到启动关键路径。

## 7. 完成判据

- VM/纯逻辑：`DuiyiTests`（Swift Testing）；导航/布局：`DuiyiUITests`（XCTest）；语音/翻译/TTS 相关：真机验证。不能操作设备写“未验证”。
