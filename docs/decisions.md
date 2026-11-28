# 决策记录（D 系列）

> **唯一决策表**：其他文档只引用 D 编号，不复制内容。确认后更新本表并标注日期；未确认前不按假设实现。
> 排期与验收见 [`04-roadmap.md`](04-roadmap.md)；工程论证见相关案例文档，不在此复述。
> 状态：**D1–D7 已于 2026-11-23 确认；D8 已于 2026-11-24 确认；D9–D10 于 2026-11-28 确认**；D1–D10 之外的产品口径见文末「v1 冻结口径」。

## D1–D10（产品 / 工程，状态：已确认 2026-11-23；D8 于 2026-11-24、D9–D10 于 2026-11-28 确认）

| ID | 决策点 | 当前事实 / 已实现 | 已确认决策 | 验收影响 |
| --- | --- | --- | --- | --- |
| D1 | 启动目标与口径 | 真机冷启动 240–280ms（`AppLaunchTracker`：进程创建 → 首帧提交）；200ms 已被最小对照组地板（空壳 p50=210ms）判为不可达；启动微优化已暂停，详见 [`case-startup-performance.md`](case-startup-performance.md) | **p50 ≤ 300ms**；口径固定为 iPhone 13 / Release / 物理设备 / warmup 3 / n≥20 / 间隔 5s / 指标 `startup.cold.first_frame`。不重启启动微优化，不做架构级启动改造；不用模拟器证明性能 | iPhone 13 真机 Release p50 ≤ 300ms 即达标；XCTest 0.31–0.33s 仅作回归参考 |
| D2 | 发布形态 | App Store / TestFlight / 企业分发此前未定；无 Archive/Export 流程、无 PrivacyInfo、无发布 CI | **App Store 正式发布，TestFlight 外测前置**；海外首发（美/加/澳/新/马等），中国大陆第二阶段（待 App 备案）；不做企业分发。发布工程与合规进入 v1：Archive/Export、PrivacyInfo、隐私政策、商店元数据、崩溃/日志策略、App 备案（第二阶段） | 未完成发布工程与合规项不得发布；大陆区上架以 App 备案完成为前置 |
| D3 | 设备矩阵 | 部署目标 iOS 26.4；仅 iPhone 竖屏；参考机 iPhone 13（无 Apple 智能）；代码无设备型号门禁 | **iOS 26.4 不下调；最低支持 iPhone 13**；iPhone 13 必须通过中↔英全链路；参考机为 iPhone 13 + 一台支持 Apple 智能的现售 Pro；不新增 iPad/横屏/Mac Catalyst；实验语言不设机型承诺 | iPhone 13 是中英发布阻断设备；高端参考机验证 Apple 智能总结 |
| D4 | 语言优先级 | 六语已实现（中/英/日/韩/泰/越）；听写/翻译依赖系统资源；泰/越需真机抽测 | **v1 只承诺中↔英**；日/韩/泰/越保留可见、标注「实验」、按能力门禁禁用不可用项，不进发布阻断；界面语言承诺中文 + English，其余四语 UI 同实验档；不做繁体中文市场 | 中英为阻断级；日韩真机抽测但不阻断；泰越仅记录质量；实验语言不得进入 v1 营销承诺 |
| D5 | 数据保留策略 | 历史默认永久保留；同传 `historyLimit=50` 同时截断 pane 与 transcript；会议 2 万字硬停；无自动清理 | **历史永久保留，v1 不做自动清理**；同传 50 条仅显示窗口，任务文字稿保存全部已 settled 行，导出取全量；v1 修复「50 条同时截断 transcript」的缺陷（P0-2） | 1 小时模拟文字稿内存稳定；结束后历史能读回全部行；同传不因显示窗口丢早期 settled 行 |
| D6 | Apple 智能范围 | 代码只在 `availability == .available` 时调用 summarizer；不可用时无总结、无 digest；可用但失败时 digest 可能被误标为 Apple 智能生成 | **总结仅在 Apple Intelligence 可用时提供**；不可用三态（`deviceNotEligible` / `appleIntelligenceOff` / `modelNotReady`）只说明原因，仍可导出；生成失败/空结果说明本次暂不可用，不展示 digest、不冒充 AI；iPhone 13 无总结但可导出；Apple 智能只用于总结；删除 01/03 的 digest 回退表述 | iPhone 13 明确「本机不支持总结」；任何非 AI 结果不得显示「由 Apple 智能生成」 |
| D7 | 长会策略 | 会议 2 万字符按内存 transcript 累计；达到上限停听并标记 `isLengthLimited`；清屏会复位计数；无续集关联 | **2 万字是分段边界，不是产品上限**；v1 实现「结束并继续」，用组 ID 关联续集任务；计数按任务累计（含清屏前内容），清屏不复位；单段导出 + 组内跳转，整组合并导出留 v1.x。该续集关联是 Q1 功能冻结中唯一**新增产品行为**的例外 | 长会不丢内容；续集任务可在历史中组内跳转；达到 2 万后不静默截断 |
| D8 | 字幕/文字稿的 utterance identity | C04 前：`Utterance.id` 由 `UtteranceAssembler` 维护；投影层仍有跨 ID 文本相似度合并（`PaneState` + 三份 `upsertTranscript` + `TranslationPipeline` alias） | **`Utterance.id` 即 caption 行与 transcript 条目的唯一身份；assembler 独占新 ID 判定；同一 ID 同一行，新 ID 新行；不引入 `continuesFrom` / `groupID`；跨 ID 文本相似度只保留在 assembler 内部；投影 module 用单一有序 record store 派生显示窗口与全量 transcript**（C04 spec [#27](https://github.com/DavidTeam2008/mybuddy/issues/27)） | C04 Wave 3；assembler 认不出的修订成为独立行，各自翻译；删除 alias 与跨 ID 合并；行为变更测试按 spec 记录 |

| D9 | ASR `.fastResults` 默认 | P1-3 360 s 同音频 A/B：fast 40 行/覆盖 98.35%/WER 3.82–3.69%；no-fast 73 行/95.67%/WER 7.38%，行碎片化；no-fast+context 71 行/95.80%/WER 6.62% | **Release 保持 `.fastResults` 开启**；`-duiyi.asrFastResults` 只作 DEBUG 实验开关。关闭 fast 必须重新做 p95/预览延迟与行稳定性 A/B，不能只为个别词恢复 | P1-3 A/B 默认 fast；no-fast 不进入产品 |
| D10 | ASR `contextualStrings` 默认 | `AnalysisContext.contextualStrings[.general]` 在 360 s A/B 有小幅 WER 收益（3.31% vs 3.69–3.82%），但 Cameron/Lidia/Design/`white men` 仍随机失败；full context 两次 WER 2.01/2.83% vs baseline 2.08%，无稳定收益；词表是夹具专用，产品无来源 | **不默认启用 contextualStrings**；只保留 DEBUG 实验开关。若后续做“用户可提供名称/术语”的显式设置，需新增产品决策、隐私与存储设计，并证明不引入专名过拟合/延迟/串词 | P1-3 不因夹具词表改变 Release；用户词表功能另立决策 |

## v1 冻结口径（非 D 编号）

> 本节只记录 D1–D8 之外、本次冻结的产品口径；涉及 D 的内容只引用编号，不复制。冻结日期：2026-11-23。

### 目标与范围

- **目标用户**：中文母语个人用户（出境游、涉外商务、留学/海外生活）；中↔英为主轴，日/韩/泰/越为覆盖场景。
- **v1 边界**：三模块（面对面 / 同声传译 / 会议记录）+ 共享能力（历史、引导、设置、总结、导出、权限与模型准备）。不新增首页入口或第六个模块；新增用户可见功能视为范围变更。
- **功能冻结例外**：唯一**新增产品行为**是 D7 的续集任务组；Q20–Q25 的其余改动均为修缺陷或收窄承诺。
- **品牌**：对外 MyBuddy；「对译」为中文副标题；Duiyi 保留为工程 target/历史名。发布前完成用户可见品牌串走查（`DUIYI` → `MyBuddy`）。
- **界面语言**：承诺简体中文 + English；日/韩/泰/越 UI 与实验现场语言同档，不做发布阻断；不做繁体中文市场。
- **首发区域**：见 D2。

### 交互与数据

- **清屏**：只清当前视图（pane / 字幕 / 翻译 / 总结显示），不停听、不结束任务；清屏前 flush 并 cancel 250ms pending persist；空稿删除改为「内存与 store 都无可用条目才删除」；任务数据、历史、导出始终以全量为准；不做「清屏 = 分段 / 删除」。会议 2 万字计数见 D7，清屏不复位。
- **同传 TTS**：只读 final / 已切从句，不读 volatile；删除运行时不可达的 volatile 分支与对应单测。队列硬上限 10，超限先丢最短确认语（compact ≤4 字），再丢最旧任务；暂停 / 换方向 / 结束立即清空。`prefersAssistiveTechnologySettings = true`；语速仍以系统默认 ×1.28 为基线；不新增语速 / 音色设置。
- **能力门禁**：所有语言选择入口使用同一可观察能力快照；启动后台刷新一次（回到前台可再刷新）。可选条件 = 听写可用且翻译可用；TTS voice 缺失只门禁「读出译文」。已选语言变为不可用时保留并提示，不自动改语言；会议多语言在 defaultPeer 不可用时禁用并说明。pair 级翻译可用性 v1 不做全量建模，运行时给出明确错误与换语言入口。
- **面对面历史窗口**：每侧 live + 最多 3 条历史；裁 `PaneState.history`，transcript 全量；恢复只回填最近 3 条。统一 `01` §3.2 / §9 口径。
- **任务生命周期**：新任务先停旧听写流再结束 / 新建；恢复任务还原 `sourceLanguage/targetLanguage` 并显示继续提示；标题按 `userLanguage` 本地化；空稿删除 store-aware（见清屏）；历史左滑删除在 v1 发布前补确认弹窗（当前一次点击即删除，属数据完整性修复）。v1 已知限制：首页点按只打开该 feature 最新一条未完成任务；启动不自动对账 stale running / pausedListening；同一 feature 多条未结束任务暂不逐条管理。
- **存储失败**：不静默降级内存。首页 / 历史显示「本机存储不可用」并提供重试；允许继续使用模块，但明确标记「本次内容不会保存」，结束不写入历史，导出可从内存生成；存储恢复后新任务正常保存，已丢失内存任务不补写。

### 质量与发布

- **发布阻断**：数据不丢；iPhone 13 上连续 60 分钟中↔英会话无崩溃 / 静音卡死 / 识别暂停误报；飞行模式下三模块全链路可用且无网络请求；无障碍底线（VoiceOver 只读用户侧、可点区域 ≥44pt、字号三档不截断关键操作、Reduce Motion 生效、深色画布对比度）；现有单元与 UI 测试全绿且不新增 skip（模拟器无 `SpeechTranscriber` 的既有 skip 除外）；隐私合规见下。
- **翻译与字幕质量**：连续 5 分钟不积压（第 5 分钟 p95 ≤ 第 1 分钟 p95 + 500ms，无旧 job 后到）；final p95 ≤ 3s、正常语速覆盖率 ≥ 99%（crosstalk 抑制的短确认语除外）；不串侧；会议 2 万字内不丢行；TTS 不读半句；中英混读不承诺准确率，但不得崩溃 / 串侧 / 整句丢弃。
- **性能与功耗**：启动见 D1；电池 / 发热 / 包体不设硬 SLA；iPhone 13 连续 60 分钟不热关机、不降频到听写中断；记录电量与温度作为 v1.x 基线；保持无第三方依赖。
- **隐私合规**：App Store 隐私标签 Data Not Collected；隐私政策 URL；`PrivacyInfo.xcprivacy`；无第三方分析 / 广告 / 崩溃 SDK；权限文案中英双语、拒绝后可去设置；单条任务删除 + 详情页删除；不做「一键清空全部数据」。

### 非目标

- 账号 / 登录、云同步 / iCloud、自建后端、API Key、分析 SDK。
- 音频保存 / 回放、说话人分离 / 声纹、后台持续听写、外放朗读、会议记录实时 TTS。
- iPad / 横屏 / Mac Catalyst / Apple Watch / Android。
- 六语同等发布承诺、繁体中文市场、日 / 韩 / 泰 / 越进入发布阻断。
- 云 LLM、实时 / 滚动总结、不可用时的 digest 回退。
- 历史自动清理、音频留存、整组会议导出（v1 为单段导出 + 组内跳转）。
- 启动微优化 / 架构级启动改造、用模拟器证明性能。
- 大陆首发（第二阶段）、企业分发。
- 以「先选当前说话人」作为面对面 / 同传的操作前提。
- 一键清空全部数据。

### 文档对齐清单

> 本次审计发现文档与代码不一致；以下各项已于 2026-11-23 对齐，记录备查；不新建计划文件，排期仍以 [`04-roadmap.md`](04-roadmap.md) 为准。

- `01-product-design.md`：删除「本地 digest 回退」表述；清屏改为「只清视图 + 防丢失」；面对面历史改为 live + 3；标题示例统一为界面语言；44pt 承诺按发布阻断补齐；会议导出「语种徽标」改为文字前缀 `[中文] `；历史左滑删除补确认弹窗（当前一次点击即删除）。
- `02-architecture.md`：`StaticLanguageCatalog` 改为生产注入的 `SystemLanguageCatalog`（探针缓存）；`beginNew()` 契约改为「各 VM 先 finish 再 beginNew」；清屏语义；同传 50 条只裁显示；TTS 只读 final。
- `03-tech-choices.md`：语言目录现状；TTS volatile 分支不可达；删除 digest 回退承诺。
- `04-roadmap.md`：P2-6 状态与语言目录实现对齐；P2-9 按本次决策更新；P0-2 验收改为「显示窗口 + 全量落盘」；失效的 `Makefile` / `harness` / `references` 引用改为仓库内实际入口。
- `Duiyi/**/AGENTS.md` 与 `README.md`：清理 `make` / `harness` / `references` / `test-baseline` 失效引用；品牌 MyBuddy；`Order/` 保留说明与 Release `ORDER_FILE` 对齐。
- 术语：统一用「总结」而非「摘要」；「现场语言 / 界面语言 / 我看的语言」按 [`GLOSSARY.md`](../GLOSSARY.md) 使用。
