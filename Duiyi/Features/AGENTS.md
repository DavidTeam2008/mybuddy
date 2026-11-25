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

- 需要翻译时由 VM 调 `Shared/TranslationPipeline.submit(TranslationSubmission)`：行、`isFinal`、目标语言与首包/后续延迟在提交时算好。pipeline 负责 job 形成、防抖/取消、重复抑制、过期判定、单槽 `outboundJob` 与 aliases；VM 不再自持防抖 Task、`sentSourceText`、`lastAppliedSourceCount` 或 `utteranceAliases`。
- VM 自建 `TranslationPipeline` 并固定自己的 `StalePolicy`（面对面 `.dropShorterNonFinal`、同传 `.dropShorterAny`）。调用方构造器不接收 pipeline 或 scheduler；测试只通过 internal 的 `scheduler:` 初始化器注入调度器。
- `fulfill` 只把 `pipeline.accept` 返回的 `TranslationUpdate` 写入 pane/transcript；同传再按既有 380 ms 结算调度 TTS。View 从 VM 的 `outboundJob` 计算属性取 job，交给 `TranslationHostView` / `OneWayTranslationHostView` 的 `.translationTask`；VM 不持有 `TranslationSession`。
- Host 共享 `TranslationJobBridge` + `TranslationJobPump`：bridge 按 `utteranceID` 每句最多保留一条 pending，替换保留首次位置；已排队 final 不被新 non-final 覆盖，任何新 final 可覆盖旧 job。consumer 的 `takeNext()` 是 generation-scoped；`requeue` 接受任意 generation，只要该 job 仍是该句最新提交且无同 ID pending，插入队首并 wake 当前 consumer；`makeConsumer()` 时队列非空立即补 wakeup，Host 未就绪时也按 ID 合并。`TranslationJobPump` 每次唤醒 drain 到空；取消时该 job 已被同 ID 更新取代就丢弃，否则 requeue 到队首并退出，取消不触发 `onFailure`；非任务取消的 `CancellationError` 由下一次 `.translationTask` 重启的新 consumer drain。
- 测试接缝：bridge 接口（同步验证合并、顺序、final 优先级、pre-pump wakeup、generation-scoped takeNext、latest-job requeue 与唤醒已等待 consumer）与 pump 注入的 `translate` / `onSuccess` / `onFailure`（验证 drain、取消、requeue、in-flight 完成、非任务取消后的新 consumer 接管）；不要为生产路径新增 `TranslationSession` 替身，也不要用 sleep 驱动。
- 现场字幕读 VM 的 `PaneState`/内存数组，不读 SwiftData；落盘异步，View 不等待落盘再更新。

## 4. 任务语义（交互必须保持）

- 任务生命周期在 `TaskLifecycle`：`beginTask` 走 `prepareForNewTask()` → 清本模块字幕 → `startNewTask()`；结束走 `endTask`；VM 不自行实现 250ms 防抖、restore 映射或空稿判断。
- 显式“新任务 → 结束任务”；只有 ended 进历史；空稿由 `TaskStoreV2.end` 按 store 中持久化内容判断后删除；暂停只停麦克风，不结束任务。
- 清屏用 `clearDisplay()`：先 `flush()`，只清显示（pane/字幕/翻译与总结显示），保留 transcript、总结数据与会议计数；`resetCaptions()` 只用于新任务、结束任务、换语言/方向。
- 同传 50 条只裁 pane 显示与恢复回填；面对面每侧 live + 3 条历史、恢复只回填 3 条；transcript / 历史 / 导出始终全量。会议 2 万字按任务累计，清屏不复位。
- 存储不可用时继续显示已加载内容，用共享横幅 + 重试；当前任务标记「本次内容不会保存」，结束后不写历史但可从内存导出；有内容的未保存任务在新建前必须让用户选择导出或放弃。
- 后台/切模块只停听，不自动结束；不要把“结束任务”改成自动保存。

## 5. UI 入口与可测试性

- 新增 UI 入口必须加 `accessibilityIdentifier`，沿用 kebab-case（`home-module-*`、`nav-*`、`taskbar-*`、`caption-*`、`langchip-*`、`listening-control`）；不靠中文文案或坐标定位。
- 改入口/标识要同步 `DuiyiUITests`；历史返回用 `nav-home`，不要用系统返回键。
- View 保持薄：复用 `Shared/`（`ModuleToolbar`/`HistoryToolbar`、`ToolbarGlyph`、`TaskBar`、`LanguageChipGrid`）与 `DesignSystem`，不要复制布局常量。首页/三模块/历史/详情优先用系统导航栏；`ModuleChrome` 仅剩详情页过渡使用，详情改造后删除。

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
