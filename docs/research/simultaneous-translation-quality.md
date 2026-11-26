# 同传质量调研：TED 演讲对照与改进方案

> 日期：2026-11-25。对照材料：用户 iPhone 同传导出（2026-11-25 08:58–10:13，English → 中文，175 条）；TED 官方 transcript（Lauren Weinstein, *Don't believe everything you think*, TEDxPaloAlto）。代码基线：`main` = `0b1c626`（Xcode 27.1 / iOS 27.1 SDK）。逐条对照数据与脚本留在本机 `/tmp/simultaneous-comparison.md`，未入库。
>
> 落地状态（2026-11-26）：P0-2b 合并前缀 final → #70 / PR #73；P0-2 final 权威 → #71 / PR #74；P0-3 U+FFFD 完整性闸门 → #72 / PR #75；P0-5 trusted locale → PR #77；P0-4 停止 finalize/drain → PR #78；P0-1 outbound 无损队列 → PR #79；P1-2 稳定单元 preview → PR #82（#80 因基线分支删除自动关闭，内容相同）；P0-6a 结束竞态回填 → PR #81；P1-4a 每任务诊断 ring buffer + DEBUG 导出（分支 `feat/p1-4-diagnostics`，待合并）。P1-4b 设备回放、P1-1、P0-6b、其余 P1/P2 未开始。

## 0. 结论

1. **不是漏听，是翻错。** 8:31–21:36 的 1,592 个 TED 词中 99.12% 在 App 源文里出现过；但 44/175 条译文（25.1%）有实质语义错误，其中 20 条（11.4%）会直接改变意思——平均每 18 秒一次实质错误、每 39 秒一次 critical 错误。source coverage 只是护栏，不是质量指标。
2. **最大错误来源是分句。** 10 条（5.7%）把同一 final 的前缀重复存成独立条目；12 条有害断句。34% 的实质错误属于分句/错误解析，25% 属于习语直译，16% 属于术语/隐喻。
3. **重复 final 已定位到机制**：1.1 s 静音把当前前缀 final 化并清空 assembler 上下文；转写器随后的完整 final 拿到新 ID，前缀被重复存储和翻译。同时 App 完全忽略了 `SpeechTranscriber.Result` 的音频 range、`resultsFinalizationTime`、`volatileRange` 与空文本撤销语义。
4. **final 不是权威，且有三层**：同传的 `.dropShorterAny` 会丢弃更短的 final；投影层 `preferredTranslation` 会在 final 更短时保留 partial；`preferredSource` 还会保留更长的旧源文，`accept` 随后翻译的是这个合并源文而不是真实 final。另有一条：final 之后迟到的 volatile 可以把已 settled 的行降回 streaming。
5. **乱码不是 App 代码产生的**：全仓没有 lossy decode、字节切片或构造 U+FFFD 的路径；导出是合法 UTF-8，两个替换字符是“存进去的数据”。最可能是框架结果（优先怀疑 `TranslationSession.Response.targetText`，其次是 ASR）在流式边界损坏，而管线没有完整性闸门，且“更短的干净 final 可能被丢弃/拒绝”，于是坏 preview 被永久保留。需要打点确认到层。
6. **还有几条“丢句/丢译文”的代码级风险（本次导出未成为主因，但违反无损要求）**：单个 `outboundJob` 槽位 + 单个防抖任务会在 host 读取前覆盖 final；`stop()` 直接 `cancelAndFinishNow()`，从不 finalize analyzer，暂停/结束/切模块/进后台会丢掉最后一句；单语种同传仍走脚本纯度门，含一个汉字或纯数字的英文结果会被整句丢弃；翻译失败与结束任务竞态没有重试/回填。
7. **iPhone 13 没有 Apple 智能**：`.highFidelity` 翻译与 Foundation Models 后编辑在参考机上不可用（框架会回退），不能作为本次问题的解；P0/P1 的确定性改进必须能在 iPhone 13 上生效。
8. **建议执行顺序**：P0-2b（合并重复 final）→ P0-2（final 权威）→ P0-3（U+FFFD 闸门）→ P1-2（按稳定单元翻译）→ P1-3（ASR 精度选项）→ P1-1（range-aware 组装）→ P0-1/P0-4/P0-5/P0-6（其余丢译文路径）→ P2 实验。前三项小、可单测、直接打击这次测到的错误。

## 1. 对照结果

### 1.1 口径

- 对照窗口：TED 官方 cue 132–331（08:31–21:36），去掉 `(Laughter)` 等非语音 cue 后共 195 条。
- 方法：把 App 的 175 条源文按顺序拼接，与 TED 文本做 token 级 Levenshtein 对齐（NFKC、小写、去标点、展开缩写）；统计匹配/替换/删除/插入。
- 局限：导出没有逐条时间戳、raw ASR 事件、置信度或音频；能判断“存了什么”，不能证明“屏幕上何时显示了什么”。TED 官方字幕自身也有拼写错误（如 cue 139 的 “it’d diagnostic”），已单独排除。

### 1.2 覆盖与 ASR

| 指标 | 数值 |
| --- | --- |
| TED 词数（08:31–21:36） | 1,592 |
| App 源文词数（归一化） | 1,634 |
| 存在性覆盖 `(N−D)/N` | **99.12%** |
| 精确匹配 `M/N` | 97.42% |
| 原始 WER | 6.09% |
| 去掉 54 个重复 final 插入后的 WER | **2.70%** |

- 真正缺失只有 4 处：开场 4 个词（从 cue 中间开始听，非漏听）、“would just hurt him more”（12:05）、“I shouldn’t do”（15:28）以及一个冠词 “the”。**15:28 的缺失把演讲核心论点说反了**：原文是“我多年来认为自己不该做的事”，译文变成“我多年来所相信的事”。
- 27 处替换里有 8 处改变语义：`shared→Sheer`、`past→pastor`、`no→know`、`ropes→Rose`、`as→is`、`feeling→will`、`would→have`、`would→to`；另有 `she→he`、`him→them` 等指代错误。
- 结论：ASR 词级准确率足够好；危险的是**实词同音替换**与**从句边界**，翻译层没有上下文修复。

### 1.3 重复与断句

10 条（5.7%，54 个词）是“前缀 final + 完整 final”成对出现，前一条总是后一条的前缀，例如：

```text
They also cause us
They also cause us to bump into each other.
The best designs came
The best designs came only after multiple failed attempts.
```

两行都进了文字稿，也都各自翻译；前缀译文往往不完整（“他们也导致我们”“最好的设计来了”）。

12 条是有害断句（10 对），典型：

| 断点 | 后果 |
| --- | --- |
| `An award winning author, Lydia Yuknovich.` / `Sheer how she didn’t follow up…` | 主谓被句号切开；`shared` 听成 `Sheer`，译成“纯粹是” |
| `But if he’s feeling rejected, this will` / `rejected, I should, uh, my calls…` | 条件句丢失谓语；“up my calls”变成“我的电话” |
| `I still have ropes.` / `I’m working to break.` | 定语从句断开；`break` 译成“休息” |
| `That helps you see.` / `They were always yours to break.` | `see` 失去宾语；结尾隐喻失效 |

同时可见 14 条小写开头的源文、12 条无句末标点、18 条无句末标点的译文、6 个不该有的问号；18 条 ≤3 个词，8 条 >20 个词。分句完全由 ASR final 边界决定，而不是句子结构。

### 1.4 翻译质量

44 条实质错误（20 critical + 24 major）的分类：

| 类别 | Critical | Major | 合计 | 占实质错误 |
| --- | ---: | ---: | ---: | ---: |
| 分句 / 错误解析（FRAG） | 7 | 8 | 15 | 34.1% |
| 习语 / 固定搭配（IDIOM） | 8 | 3 | 11 | 25.0% |
| 术语 / 隐喻（TERM） | 0 | 7 | 7 | 15.9% |
| 指代错误（REF） | 3 | 1 | 4 | 9.1% |
| 语气 / 疑问句（MOOD） | 0 | 2 | 2 | 4.5% |
| 漏译（OMIT） | 1 | 1 | 2 | 4.5% |
| 乱码（MOJI） | 1 | 0 | 1 | 2.3% |
| 人名 / 事实（NAME） | 0 | 1 | 1 | 2.3% |
| 流畅度 / 片段（FLUENCY） | 0 | 1 | 1 | 2.3% |

最伤的 6 条（原文 → 现译文 → 应有意思）：

1. `...were the same things I believed for so many years I shouldn't do.` → “……都是我多年来所相信的。” → “……正是我多年来认为自己**不该做**的事。”（漏了后半句，论点反转）
2. `his insecurities got the best of him` → “他的不安全感使他**处于最佳位置**” → “不安全感**占据上风**”
3. `It was none of the things anyone had guessed.` → “这都不是任何人**拥有的东西**” → “都不是任何人**猜到的那样**”
4. `a past relationship` → “**牧师**的关系” → “**过去的一段感情**”（ASR `past→pastor` 被照翻）
5. `I'm working to break.` → “我正在努力**休息**” → “我正在努力**挣脱（绳索）**”
6. `They were always yours to break.` → “**他们**总是你打破的。” → “**它们**一直都属于你，等你去打破。”

### 1.5 隐喻与术语

| 术语 | 现译 | 次数 | 问题 |
| --- | --- | ---: | --- |
| `headset`（信念 = VR 头显） | 耳机 / 头戴式受话器 | 10 | “通过自己的耳机镜头”“戴着自己的耳机到处打乒乓球”完全失去比喻 |
| `ropes`（限制性信念） | 绳子 / 绳索 | 7+ | 与 `break`（挣脱）分开翻译后语义断裂 |
| `belief(s)` | 信仰 / 信念 | 3 / 5 | 演讲语境是“信念”，不是宗教“信仰” |
| `class` | 班级 | 2 | 这里指课程，不是班级 |

术语问题单独统计约影响 30–33 条（19%），与上面 44 条有重叠，不重复计数。

### 1.6 乱码

唯一一处：第 200/201 行，源文 `I was astounded, proud, liberated, and confused.`，译文 `我感到驚��然、骄傲、解放和困惑。`

```text
e9 a9 9a   ef bf bd   ef bf bd   e7 84 b6
驚          U+FFFD      U+FFFD      然
```

- 文件是合法 UTF-8，`EF BF BD` 是已经存进去的替换字符，不是读取时产生的。
- 源文干净、坏字在中文词中间，最像翻译输出/流式拼接把一个多字节字符切成两段各自解码（`驚…然` 之间残留两个 U+FFFD）。
- 全文只有这一个繁体字 `驚`，其余均为简体；不像整体编码错误，更像一次边界事件。
- 全仓代码审计没有找到能产生 U+FFFD 的路径；需要打点确认是 Translation 结果、ASR 结果还是后处理边界。

### 1.7 这次对照回答不了的问题

- 延迟与实时性：没有逐条时间戳/音频对齐，无法算 p95。
- 现场 UI 到底显示了什么：导出是已 settled 的文字稿，不是 raw ASR/翻译事件。
- U+FFFD 的具体产生层：只能确定在导出之前、中文输出侧。
- 一次演讲、一次运行，25.1% 应视为这次运行的估计，不是全量基准。

## 2. 管线诊断

### 2.1 final 不是权威（三处 + 单调性）

1. `TranslationPipeline.accept`（`Duiyi/Features/Shared/TranslationPipeline.swift:144`）在同传 `.dropShorterAny` 下，只要新 job 的**源文**比上一次已应用的源文短就丢弃结果——包括 **final**（`:154-155`）。ASR final 修订经常比 partial 短（去重复词/填充词），这类 final 被静默丢弃。
2. 即使 final 被接受，`CaptionProjection.applyTranslation`（`Duiyi/Domain/Projection/CaptionProjection.swift:85`）仍调用 `SpokenText.preferredTranslation`（`Duiyi/Domain/Models/SpokenText.swift:35`）：partial 译文包含 final 译文、或 final 更短时会**保留 partial**。已有测试甚至把“短 final 不替换长 preview”写成了预期（`DuiyiTests/CaptionProjectionModuleTests.swift:347-357`）。
3. `CaptionProjection.ingest` 用 `preferredSource`（`Duiyi/Domain/Models/SpokenText.swift:28`）保留更长的旧源文；`InterpretationViewModel.accept`（`:542-566`）随后提交投影里的 `line.sourceText`，于是翻译的可能是“旧长源文”，而不是真实 final。

此外，`ingest` 无条件写 `record.isFinal = utterance.isFinal`（`CaptionProjection.swift:53`），final 之后迟到的 volatile 可以把已 settled 的行降回 streaming。最终语义被系统性地偏向“最长的早期猜测”，而不是“最好的 final”。

### 2.2 静音 final 与 ASR range

- `BilingualSpeechEngine.pingSilenceTimer`（`Duiyi/Services/Speech/BilingualSpeechEngine.swift:295`）在 1.1 s 静音后调用 `assembler.silenceTimedOut()`（`Duiyi/Services/Speech/UtteranceAssembler.swift:79`）；后者发布 final 并 `beginNextUtterance`（`:111`）清空 `texts`/`finals`/`lockedLanguage`。
- 转写器随后给出的完整 final 已无法与上一条比较（上下文被清空），于是生成新 ID；`publish` 只对**完全相同**的 final 做签名去重（`BilingualSpeechEngine.swift:313`），不处理“前缀相同、后面更长”的修订。
- Apple 的 `SpeechTranscriber.Result` 是**按音频 range** 的“该 range 最可能的文本”，不是累计转写；volatile 结果会替换同 range 的早期结果，final 结束该 range，空文本会撤销该 range 的 volatile 文本。App 完全忽略 `range`、`resultsFinalizationTime`、`volatileRange` 与撤销事件，只用文本前缀相似度猜“同一句/新句子”。
- 正确做法：静音时调用 `analyzer.finalize(through: nil)` 让转写器把打开的 range final 化（Apple WWDC25 277 明确要求在停止前 finalize），合成 final 只做超时兜底，并记住已关闭的 range/utterance ID，让迟到的 final 原位替换而不是新开一行。

### 2.3 其余丢句/丢译文路径（代码级风险）

| 路径 | 代码事实 | 影响 |
| --- | --- | --- |
| 单槽 outbound | 修复前 `TranslationPipeline` 只有一个 `outboundJob` 槽和一个 `scheduled` 防抖；任何新提交覆盖旧槽（原测试 `outboundJobIsASingleSlot`，现为 `outboundJobReflectsNewestQueuedJob`） | 连续两个 final 可能只有最后一个被 host 读到；bridge 的 final 优先逻辑救不了从未提交的 job |
| 停止不 finalize | `BilingualSpeechEngine.stop()` 取消消费者后直接 `cancelAndFinishNow()`（`:58-81`），`resetPipelineKeepingStream`/`restartSingle` 同样 | 暂停、结束、切模块、进后台、单语种漂移会丢掉最后一句（直到最后一个 final 之后的内容） |
| 脚本纯度门 | `UtteranceAssembler.ingest` 对英文要求 `han == 0`（`:230-251`），单语种同传也走这条路 | 含一个中文词/人名或纯数字的英文结果会被整句丢弃 |
| 翻译失败/结束竞态 | `failTranslation` 只清槽（`InterpretationViewModel.swift:586-588`）；`endTask` 不等在途翻译，`resetCaptions` 后迟到的 `fulfill` 找不到记录 | 文字稿可能留下有源文无译文的行；`TaskStoreV2.updateTranslations` 已支持回填但 live 路径没用 |

这些路径在本次 TED 导出中没有成为主因（源文覆盖 99.12%，也没有空译行），但它们直接违反“不丢句/不漏翻译”，必须作为正确性项修复。

> 2026-11-26：脚本纯度门（P0-5）、停止/结束/新建任务以及 `resetPipelineKeepingStream`/`restartSingle` 的 finalize+drain（P0-4）、单槽 outbound（P0-1：有界有序队列 + 每句防抖 + sequence/去重）、结束竞态的迟到 final 回填（P0-6a）已修；翻译失败重试与可见状态（P0-6b）仍未修，排在 P1-4 之后。

### 2.4 U+FFFD

- 全仓没有 lossy decode、UTF-8 字节切片或构造 U+FFFD 的代码；导出 `Data(text.utf8)` 也不会产生替换字符。App 代码本身不是可信的产生者。
- 最可能来自 `TranslationSession.Response.targetText`（框架结果/流式边界）；ASR 结果先带坏字符再被翻译是次要可能。App 目前只读 `targetText`，没有记录 `Response.sourceLanguage`/`targetLanguage`，也没有任何完整性校验。
- 坏 preview 被保留的链条是成立的：`dropShorterAny` 可能丢弃更短/干净的 final → `preferredTranslation` 再保留更长的坏 preview → `fulfill` 落库。需要用 §5 的调试负载确认到层。

### 2.5 保真权衡

- `SpeechTranscriber` 启用了 `.fastResults`（Apple 文档：更快但更不准确）和 `.etiquetteReplacements`（把脏话打码，属于语义编辑）；没有用 `AnalysisContext.contextualStrings`（人名/术语提示），请求了 `transcriptionConfidence` 但没读。
- 翻译用 `preferredStrategy: .lowLatency`（传统模型、快）；`.highFidelity` 用 Apple Intelligence、更流畅，但参考机 iPhone 13 不支持，会回退。
- 同传对 volatile 片段也提交翻译（40/90 ms 防抖，voiceOut 25/50 ms）；Apple 的 `TranslationSession` 没有上下文/术语表/最短长度参数，对短片段没有质量承诺。
- 这些是这次 25.1% 语义错误的上游：片段翻译 + 无上下文 + 无术语约束。

## 3. 目标不变量

| ID | 不变量 |
| --- | --- |
| I1 | 同一 `utteranceID` 的源文状态单调：`streaming → settled`；迟到 non-final 不得降级已 settled 行；新的 **final** 可以替换源文并重新提交 final 翻译 |
| I2 | 已 settled 的 utterance 至少在 `finalApplied` 或 `permanentFailure` 之前保留一个 final 翻译 job；preview 不得取消/覆盖它 |
| I3 | final 译文永远替换 preview，即使更短；更新的 final 永远替换旧 final |
| I4 | preview 不得覆盖 final，也不得把 settled 行降级 |
| I5 | 含 U+FFFD（及其他被拒绝的损坏）的文本不得显示、落库或导出 |
| I6 | 每个 settled utterance 在任务结束/清屏前必须到达 `finalApplied` 或 `permanentFailure`，不存在静默的第三种结果 |
| I7 | TTS 只读 `finalApplied` 文本；preview 不朗读 |

实现上建议用一个纯 Swift 的 `UtteranceTranslationLedger`（按 utteranceID 记录 phase、最新 final sequence、已应用的 final sequence、失败原因），而不是把这些状态散落在 VM、pipeline、projection 三处。

## 4. 方案（按执行顺序）

### 第一批：P0 正确性（小改动、可单测）

**P0-2b. 合并静音前缀重复 final（先做）**

- `UtteranceAssembler` 保留最近一条 final 的 `utteranceID + text`（按语言，短窗口如 3 s）；新 final 是它的前缀扩展/refinement 时复用同一 ID，发布完整文本的 final 修订，而不是新开一行。
- 投影与存储都按 ID upsert（`CaptionProjection.ingest`、`SwiftDataTaskStore.append`），文字稿只留一行；完整 final 重新翻译，final 覆盖前缀译文。
- 单测：`They also cause us` → 完整句，断言一个 ID；非重叠 final 仍新开；窗口外不合并。设备上把重复 final 从 5.7% 降到 ≤1%。
- 权衡：voiceOut 可能已读了前缀；可在修订窗口内延迟 TTS，或接受重复（记入决策）。

**P0-2. final 文本处处权威**

- `StalePolicy`：`.dropShorterAny` 只对 preview 生效；`job.isFinal` 一律接受（空/损坏除外），并用单调 `sequence` 拒绝乱序结果，而不是按文本长度。
- `CaptionProjection.applyTranslation(settle: true)`：直接写 final 译文，绕过 `preferredTranslation`；`ingest` 在 `utterance.isFinal` 时直接替换源文，绕过 `preferredSource`；已 final 的 ID 忽略后续 non-final。
- `InterpretationViewModel.accept`：final 提交真实的 `utterance.text`，而不是投影里的合并源文；final 译文每次都要落盘，不依赖更早的 settled-source persist。
- 单测：长 preview + 短 final → final 赢；迟到 volatile → 行保持 settled；final 修订同 ID 更新原行。注意这会反转 `CaptionProjectionModuleTests:347-357` 的既有预期，需要 PR 说明与新增测试，不能只改断言。

**P0-3. 文本完整性闸门（U+FFFD）**

- 新增纯 Swift `TextIntegrity`：U+FFFD、可疑控制字符、目标语言匹配、粗略长度带、数字保留；硬失败先只含 U+FFFD + 目标语言不匹配，长度/数字作为重试/警告信号，避免误杀合法意译。
- final 含 U+FFFD：同一文本重试一次；仍失败则按句读切分重试；再失败保留源文、记录 `permanentFailure(.corruptTranslation)`，绝不持久化坏文本。
- 日志：阶段、job/utterance ID、源/目标长度、U+FFFD 数、`Response.sourceLanguage`/`targetLanguage`、策略、是否接受；正文用 `.private` 或 DEBUG-only。
- 单测：注入坏译文 → pane/transcript/导出均无 U+FFFD；重试与永久失败路径；合法中文不误杀。

### 第二批：P1 保真与连续性

**P1-2. 翻译稳定单元，而不是词片段**

- **状态（2026-11-26）**：已实现 preview 门控于 PR #82（原 #80 因基线分支删除自动关闭）。`TranslationTrigger.action(for:language:)` 三选一：句末/从句标点（含仅看末字符时的 ASCII `.`；`ClauseSplitter` 本身不加 `.`，避免 TTS 小数分割）→ `.sendNow`；≥4 estimated words（英文按词数，越南语按音节/2，中/日/韩按脚本字符/2，泰语按字符/3）→ `.debounce`（沿用各 feature 的 40/90 ms，voiceOut 25/50 ms）；更短 → `.drop`，不形成 job。首包的有用 preview 过去立即发送，现在也走首包防抖；final 仍旁路。未做 `15:28` 的尾部补全（需要 range/volatile 尾部信息，归 P1-1）。单测覆盖三态、丢弃与短修订取消 pending preview；真机未验证，`有害断句 ≤2%` 指标不能由 preview 门控单独达成，仍需 P1-4 夹具 + P1-1。已知边界：末字符 `.` 会把 `Dr.`/`U.S.`/`3.` 之类当成稳定边界而提前 preview；只影响 preview 的额外成本，final 仍是整句权威，精确判定留 P1-1 的 range/标点组装。
- **真机手动步骤（待设备）**：iPhone 13 同传英→中；先说 2–3 个词后停顿，断言没有新增片段译文；继续说满 ≥4 词，断言首包防抖后出现译文、final 随后覆盖；说 `OK.` 这类句末标点短句，断言立即出现译文；结束任务后确认 final 完整。无法操作设备时保留单测证据并记录原因。
- final 是权威路径；preview 只在“足够有用”时发（完整从句/≥4–6 个英文词），2 个词的片段不翻译；长句可发从句级 preview，但标记为 preview，final 全句重译并覆盖。
- 保留句末标点（`.?!。？！`）作为稳定边界；逗号只用于 preview/TTS 分句。不要为“实时感”无限提高频率（roadmap 明确不做）。
- 对 15:28 这类“静音 final 丢尾巴”，优先用后续 volatile/final 的尾部补全再翻译，而不是全局延迟端点。
- 指标：有害断句 ≤2% 行；final p95 ≤3 s、覆盖率 ≥99%（`docs/decisions.md:45`）。

**P1-3. ASR 精度选项（在延迟预算内）**

- A/B 去掉 `.fastResults`（保留 `.volatileResults`）；用 `AnalysisContext.contextualStrings` 提示人名/术语；`transcriptionConfidence` 只做诊断，不因低置信度丢 final。`.etiquetteReplacements` 是否保留按“逐字保真”产品口径决定。
- 现实上限：本次 ASR 错误多是合法词替换（`shared→Sheer`、`past→pastor`），这些不会被 contextual strings 或更慢的 ASR 稳定修复，需要上下文修复（P2-1）或翻译模型本身带上下文。

**P1-1. Range-aware ASR 组装**

- **状态（2026-11-26，已实现，待真机）**：`UtteranceAssembler` 新增 range-aware `ingest`：每个 `SpeechTranscriber.Result` 以 `(text, range, isFinal)` 进入；当前行 = 已 final 的 phrase 前缀 + 开放 range 的 volatile 尾部，range 连续性决定“续上一条”，句末标点（`.?!。？！`）决定换行；range 间隔 >0.75 s（volatile 或 final）也开新行。空 volatile 撤销开放尾部：有 final 前缀时回退并发 final revision（投影才能覆盖已 settled 行）；无前缀时无法清空旧行，记录为已知限制。`range`/`resultsFinalizationTime` 只在引擎消费处读取并写诊断，文本启发式路径仅为无 range 的兼容/测试保留。静音时引擎先 `analyzer.finalize(through: nil)` 并等待 350 ms，转写器自己的 final 优先；超时才合成 final 并标 synthetic。合成/迟到 final 按 range 重叠匹配最近关闭的行（最多 8 行，不设时间窗）并复用 `Utterance.id`（`isRevision`）；迟到 final 的文本始终权威，即使比合成猜测短。D8 不变：ID 仍由 assembler 独占；dual-locale 的脚本纯度、抢占、crosstalk hold 与 greeting name-swap 保持（name-swap 不登记为可修订 range）。final 去重签名加入 utterance ID，同一句在新行重复时不会被丢弃。单测覆盖 volatile 增长、连续 final 合并、标点换行、空 volatile 撤销、静音后迟到 final 复用/覆盖更短、range 间隔、中英拼接空格、strict 串音与 name swap；真机未验证。
- 这是比 P0-2b 更彻底的方案，但改动共享 assembler（Conversation/Meeting 也用），必须保持 D8 与现有 crosstalk 行为。

**P1-4. 诊断与 TED 离线夹具**

- **状态（2026-11-26，P1-4a 已实现，P1-4b 未完成）**：`DiagnosticsRecorder`（Services）提供每任务有界 ring buffer（默认 4096 事件）+ 增量聚合 + DEBUG JSON 导出；`TaskLifecycle` 在任务开始/恢复/结束时 begin/end 会话，结束后的迟到事件仍写入最近任务；同一活动任务重复 bootstrap/restore 不重置缓冲。ASR 事件在 `BilingualSpeechEngine` 消费 `SpeechTranscriber.Result` 处记录 language、`range.start/duration`、`resultsFinalizationTime`、text 长度、isFinal、synthetic、脚本不匹配、accepted/published、utterance/revision；合成 final 标 synthetic。翻译事件由 `TranslationPipeline` 记录 submit（含 sequence/isFinal/源目标/长度/策略/text hash）与 apply（applied/原因/U+FFFD/提交→应用延迟），`TranslationJobPump` 记录 Response 语言、translated 长度、U+FFFD、重试次数与失败类；聚合 settled 数、final job 数、final 应用数、永久失败数、被拒损坏数。JSON 只含 ID/长度/语言/时间/失败类/版本元数据，不含正文；设置页 `#if DEBUG` 的「导出诊断 JSON」写入 Documents 并走 ShareLink，不上传。单测覆盖计数、ring 淘汰、会话保留、语言字段、延迟、拒收原因与 JSON。**P1-4b 未执行**：真机已安装 Debug 构建并成功创建任务，但设备麦克风持续收到房间人声（回放前即出现无关英文行），会污染夹具指标；已暂停听写并保留任务，环境静音后需重新新建任务回放。手动步骤：① Mac 生成 13 分钟 TTS 夹具（cue 132–331，195 句，110 个 ≥1.1 s 间隔）并通过扬声器回放；② iPhone 13 同传英→中新建任务开始聆听，整段回放后结束任务；③ 设置 → 导出诊断 JSON，`devicectl` 拷出；④ 用诊断事件统计重复 final、settled/final 应用、U+FFFD 与 final 延迟，并与 `/tmp/simultaneous-comparison.md` 对照。
- 用同一段 TED 音频（或可授权夹具）回放真机 → 导出 → 跑本次的对齐脚本；指标见 §5。**这是把上面所有假设变成证据的唯一办法。**

**P1-5. `.highFidelity` 翻译评估（需决策）**

- `.highFidelity`（iOS 26.4+，Apple Intelligence）只用于 final-only 的独立 host；preview 仍用 `.lowLatency`。参考机 iPhone 13 会回退，必须保证回退路径可用。
- D6 目前限定 Apple 智能只用于总结；启用 highFidelity 需要改决策并做真机 A/B（流畅≠忠实，Apple 没有质量承诺）。

### 第三批：P0 其余丢译文路径

**P0-1. final 交付无损（队列 + ledger）**

- **状态（2026-11-26）**：已实现于 PR #79。`TranslationPipeline` 的单槽 `outboundJob` 改为有界有序 outbound 队列（同句最多一条、替换保留首位、final 不被迟到 preview 取代、preview 积压上限 64 且 final 不丢）；防抖按 `utteranceID` 独立；`TranslationJob` 加单调 `sequence`，`accept` 拒绝同句更旧 sequence、按 job ID 去重；`outboundRevision` + `takeNextOutboundJob()` 让 Host 每次渲染后 drain 到空。Bridge/pump 未改；final 对 preview 的权威规则不变。单测覆盖连续 final 双到达、跨句防抖互不取消、final 不被 preview 取代、旧 sequence 拒绝、重复结果拒绝、preview 上限；真机/真翻译验收**未执行**（需要 burst 说话与设备声学环境；待用户确认后执行）。真机手动步骤：iPhone 13 上连续快速说两句、在两句话之间**暂停**（Host 仍在），确认两句 final 译文都出现且不重复；结束任务时的在途译文回填归 P0-6，本票不承诺。再观察长会话 p95（当前无诊断数据，归 P1-4）。
- 实现要点：用有界有序 outbound 队列 + 每 utterance 防抖替代单槽；final 永不被 preview 取消；`TranslationJob` 加单调 `sequence`，`accept` 只拒绝更旧 sequence，并记录已应用 job ID 防重复。
- Bridge/pump 保持现状（它的 per-utterance 合并/final 优先是对的），只保证更多 job 能到达它。
- 这会修改 `Duiyi/Features/AGENTS.md` §3 与 `docs/02-architecture.md` §5.3 的“单槽”不变量，需要显式改文档。

**P0-4. 停止时 finalize，结束任务前 drain**

- **状态（2026-11-26）**：已实现于 PR #78。`stop()` 先停采集/输入，调用 `finalizeAndFinishThroughEndOfInput()`（1 s 上限），给消费者 300 ms 收 final，再用 `silenceTimedOut()` 做兜底；`resetPipelineKeepingStream`/`restartSingle` 走同样的 finalize；三个 VM 在 `endTask`/`stop`/`beginTask` 前 await `speechTask`（500 ms 上限），不再先 cancel consumer。单测覆盖 end/stop/新建任务三条路径；真机验收**未执行**（设备已连接，但需人工声学/暂停时序，且设备上可能有未结束任务；待用户确认后执行）。本票只保证 ASR final 进入快照；在途翻译的回填仍归 P0-6。
- **真机手动步骤（待设备）**：iPhone 13 上在同传/面对面/会议各说一句，在 final 到达前点暂停、结束或新建任务；断言最后一句进入文字稿/历史/导出且不重复；再验证暂停后继续不丢行。无法操作设备时记录原因并保留单测证据。
- `stop()`：先停采集/输入，`inputContinuation.finish()`，`analyzer.finalizeAndFinishThroughEndOfInput()`（或 `finalize(through:)` 再 finish），给消费者有限窗口（300–500 ms）收 final，再取消剩余任务；不要先取消消费者。
- 结束任务：在 `endTask` 前等待在途 final（有界超时），或让迟到的 final 通过 `TaskStoreV2.updateTranslations` 回填已结束任务；不要在 final 在途时 `resetCaptions()`。

**P0-5. 单语种信任 locale**

- **状态（2026-11-26）**：已实现于 PR #77；真正的单语种 live-caption 请求使用 `.trustedLocale`；请求了双 locale 但资源降级、以及 `meetingNotes` 保持 `.strict`。单测覆盖混合脚本、`OK`/纯数字（volatile 与 final）及 strict 对照；真机验收**未执行**（设备已连接，但触发单路需要人工准备；待用户确认后执行）。
- **范围说明**：Meeting 行级的 `resolvedLanguage` 过滤保持现状，本票未改。
- **真机手动步骤（待设备）**：在 iPhone 13 上让双 locale 资源预留失败、或选一个只有单语资源的语言对进入单路同传；说 `I studied 中文 at Tsinghua.` 与 `2024`，确认两行都出现且不整句丢弃；恢复双路资源后重跑，确认 Conversation/Meeting 双路仍按 `.strict` 拒绝明显异语、不串侧。若无法稳定触发单路，记录原因并保留单测证据。
- 给 assembler 加 `languagePurity`：单语种同传用 `.trustedLocale`（非空结果都接受，只记录脚本不匹配），双 locale 的 Conversation/Meeting 保持 `.strict`。
- 单测：`I studied 中文 at Tsinghua.`、`2024`、`OK` 等不能被丢；双 locale 行为不变。

**P0-6. 翻译失败重试与可见状态**

- **状态（2026-11-26，已按用户确认拆成两半）**：**P0-6a（PR #81）** 已实现结束竞态回填：`TaskLifecycle.endTask` 与 `prepareForNewTask` 都保留最近一个已结束任务的快照；结束/新建任务/重置后到达的 final 译文通过 `TaskStoreV2.updateTranslations` 回填（preview 不落库，损坏文本拒绝），`fulfill` 不再因为 projection 已 reset 而静默丢掉 final 译文。结束写入在途时到达的 final 由 `LateTranslationBackfill` 先暂存，写入返回后回填，避免快照与 projection 之间的竞态。单测覆盖迟到 final 回填、迟到/在途 preview 不回填、结束写入在途 final、新建任务结束路径、损坏文本、未知条目与只回填最近结束任务；真机未验证，手动步骤：说一句后立即结束任务，确认历史/导出中该行有译文且不重复。**P0-6b（未开始）**：重试分类（取消/资源未就绪/不支持语言对/瞬时错误）与 `permanentFailure` 可见状态，等 P1-4 诊断/设备数据后再做，避免在没有错误分布数据时猜 UI 与重试预算。
- 区分取消（不算失败）、语言包/下载/未就绪（提示并保留 job）、不支持语言对（不无限重试）、瞬时错误（2 次短退避）；耗尽后进入 `permanentFailure`，在 UI/文字稿可查，不静默丢。

### 实验（P2）

- **P2-1 Foundation Models 后编辑**：只对 final 译文做受限润色（保留数字/人名/否定/隐喻，输出仅中文），用于术语/上下文；4,096 token 上下文、3B/2-bit、非翻译引擎、无延迟承诺；**iPhone 13 不支持**；D6 需改。先做设备 A/B，不能作为 P0 依赖。
- **P2-2 不要把上一句拼进 `TranslationSession`**：单字符串、无 context 参数，拼接后无法可靠切回，可能静默丢/重；需要上下文就用 P2-1。
- **P2-3 批翻译**：只在诊断显示积压后考虑；`translate(batch:)` 乱序需 `clientIdentifier`，`translations(from:)` 保序但等最慢项；不要把 preview 和 final 混批。
- **P2-4 alternativeTranscriptions/confidence**：先诊断，不做默认；可用于低置信度 final 的修复候选。
- **P2-5 清理**：`ignoreTranscriptionUntil` 只声明未用；`preferredSource/preferredTranslation` 的 name-swap 合并与 D8 冲突（跨 ID 合并不该在投影层）；bridge 的 `latestJobIDByUtterance` 无上限；`BufferConverter` 静默丢格式要有计数。

## 5. 验证与指标

- 单测：final-wins（pipeline + projection source/translation）、迟到 volatile 不降级、重复 final 合并/非重叠不合并、U+FFFD 拒绝/重试/永久失败、单语种 trusted locale、结束任务 drain、结束任务后迟到 final 回填/迟到 preview 不回填、连续 final 双到达、跨句防抖互不取消、旧 sequence 与重复结果拒绝、preview 积压上限、preview 三态门控（立即/防抖/丢弃）。
- UI/真机：现有套件保持全绿；新增“回放固定音频 → 导出 → 对齐”的设备验证记录；语音/翻译最终验收按仓库规则写“未验证”或真机结果。
- TED 夹具指标（同一段音频，改动前后对比）：

| 指标 | 目标 |
| --- | --- |
| 源文覆盖（token 存在性） | ≥99%（护栏，本次 99.12%） |
| 重复 final 行 | ≤1%（本次 5.7%） |
| 有害断句行 | ≤2%（本次 12 行 / 10 对） |
| 实质语义错误率 | 先以 25.1% 为基线，目标 ≤10%（人工抽样口径固定） |
| U+FFFD | 0 |
| final 延迟 p95 | ≤3 s（`docs/decisions.md:45`） |
| 空译/永久失败 | 0 静默；全部可见 |

- 最小诊断负载（先于管线改动打上）：`asr.result`（utterance/range/isFinal/resultsFinalizationTime/text_len/synthetic/script_mismatch）、`translation.submit`（job/utterance/sequence/is_final/source_len/text_hash）、`translation.result`（response 语言/延迟/重试/失败类/U+FFFD 数）。这能一次性回答“U+FFFD 来自哪层”和“final 是在交接前丢还是被 stale policy 丢”。

## 6. 约束与决策点

- 端侧、无后端、无第三方依赖（根 `AGENTS.md`）；iPhone 13 是发布阻断设备，且**不支持 Apple 智能**——P0/P1 必须能在 iPhone 13 上生效。
- D8：`Utterance.id` 是唯一身份，assembler 独占新 ID 判定；重复 final 的合并必须放在 assembler 内，不能恢复跨 ID 文本合并。
- D6：Apple 智能只用于总结；`.highFidelity`/Foundation Models 用于翻译/后编辑需要新决策，且不能成为 P0 依赖。
- D4：v1 只承诺中↔英；本次结论只针对英→中。
- 延迟 vs 保真：句子级翻译与 final 修订会增加最终译文延迟；用 p95 指标约束，不能为了实时感无限提高频率（roadmap 明确不做）。
- 修改单槽/`.dropShorterAny` 是显式架构变更，需要同步 `Duiyi/Features/AGENTS.md` §3 与 `docs/02-architecture.md` §5.3，不能当作顺手重构。

## 7. 一手来源

### Speech

- [WWDC25 session 277: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) — volatile/final 分离、不要追加 volatile、停止前 finalize、按音频 range 的结果、时间码。
- [SpeechTranscriber.Result](https://developer.apple.com/documentation/speech/speechtranscriber/result) / [Result.text](https://developer.apple.com/documentation/speech/speechtranscriber/result/text) — 每个 range 的“最可能文本”；空文本撤销该 range 的 volatile 结果。
- [SpeechModuleResult.isFinal](https://developer.apple.com/documentation/speech/speechmoduleresult/isfinal) — false 不保证之后会重发 final；等价于 `resultsFinalizationTime >= range.end`。
- [SpeechTranscriber.ReportingOption](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption) — `.fastResults` 更快但更不准确；`.alternativeTranscriptions` 成本更高。
- [SpeechAnalyzer.finalize(through:)](https://developer.apple.com/documentation/speech/speechanalyzer/finalize(through:)) / [volatileRange](https://developer.apple.com/documentation/speech/speechanalyzer/volatilerange) — finalize 后模块已发布 final；volatile range 之外的不会替换。
- [AnalysisContext](https://developer.apple.com/documentation/speech/analysiscontext) — `contextualStrings` 可提示系统词表之外的词。
- [SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector) — VAD；不要作为唯一端点信号。

### Translation

- [WWDC24 session 10117: Meet the Translation API](https://developer.apple.com/videos/play/wwdc2024/10117/) — `.translationTask` 绑定视图、`Configuration`、批量、`clientIdentifier`、`prepareTranslation`。
- [TranslationSession](https://developer.apple.com/documentation/translation/translationsession) / [Strategy](https://developer.apple.com/documentation/translation/translationsession/strategy) — `.lowLatency` 传统模型，`.highFidelity` 用 Apple Intelligence，不支持时自动回退。
- [TranslationSession.Request](https://developer.apple.com/documentation/translation/translationsession/request) / [translate(batch:)](https://developer.apple.com/documentation/translation/translationsession/translate(batch:)) — 单字符串/批量；无 glossary、无上下文参数；批量可能乱序。
- [SwiftUI translationTask(_:action:)](https://developer.apple.com/swiftui/view/translationtask(_:action:)) — session 在视图消失/配置变化后失效。

### Foundation Models（仅 P2 可行性）

- [WWDC25 session 286: Meet the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/286/) — 约 3B/2-bit、面向总结/抽取/分类、非世界知识或高级推理。
- [WWDC25 session 301: Deep dive into the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/301/) — 会话上下文与延迟、`exceededContextWindowSize`、`supportedLanguages`、greedy 采样。
- [TN3193: Managing the on-device foundation model's context window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window) — 4,096 token/会话；CJK 约 1 字/token。
- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) — availability/supportedLanguages/contextSize；iPhone 13 不满足设备要求。

### 仓库与对照

- `docs/decisions.md` D3（iPhone 13 发布阻断）、D6（Apple 智能仅总结）、D8（utterance identity）、§45 质量口径（覆盖率 ≥99%、final p95 ≤3 s）。
- `Duiyi/Features/AGENTS.md` §3；`docs/02-architecture.md` §4/§5/§7。
- [TED 官方 transcript](https://www.ted.com/talks/lauren_weinstein_don_t_believe_everything_you_think/transcript)（Lauren Weinstein, TEDxPaloAlto；本次解析 333 条 cue）。
- 用户导出的同传文字稿（本机文件，未入库）；逐条对齐脚本与数据在 `/tmp/simultaneous-comparison.md`。

## 8. 未验证与风险

- **U+FFFD 产生层未证实**：代码审计排除 App 自产；Translation 结果、ASR 结果或流式边界仍待打点区分。
- **重复 final 率**：5.7% 是这一次 13 分钟窗口；其他语速/端点行为需设备日志统计。
- **SwiftUI `.onChange` 合并**：单槽丢 job 曾是代码事实；P0-1 已改为 `outboundRevision` + drain 队列覆盖该路径，实际 burst 频率仍无设备诊断（P1-4）。
- **短片段翻译质量**：Apple 没有最短长度/质量承诺；本次 34.1% fragmentation 是强证据，但不是受控 A/B。
- **`.highFidelity`/Foundation Models 质量**：无 Apple 质量基准；iPhone 13 不可用；需真机 A/B，且 D6 需改。
- **单次基线**：25.1%、5.7%、99.12% 只作为回归基线，不是总体估计；延迟 p95 仍无数据。
