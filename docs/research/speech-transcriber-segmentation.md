# SpeechTranscriber 分段语义与假句界修复研究

> 日期：2026-11-27。触发：iPhone 13 上同传单路与面对面单路（DEBUG 单路开关）对同一段 TED 英文音频，间歇出现 `The shame of not believing.` / `We deserve it.` 两个 final、两个 `Utterance`、两条翻译；两个 range 为 139.64–142.10 与 142.10–143.12，首尾相接，间隔 0.00 s。同一句在另一些轮次能保持一行。
>
> 本文只研究 API 语义与修复方案，不改代码。除特别标注「社区」外，引用均来自 Apple 官方文档、WWDC session 或本机 SDK；所有链接于 2026-11-27 访问。

**一句话建议**：不要让句号决定 `Utterance.id`；先做 R0（删除标点关行），再做 R1（静音关闭 final-only 行），行边界只由 range gap、语言/说话人变化、静音和 max cap 决定；标点只用于显示/TTS。

## 0. 结论（TL;DR）

1. **Apple 把结果定义为 phrase，不是 sentence。** `SpeechTranscriber.Result` 的摘要原文是 “A phrase or passage of transcribed speech. The phrases are sent in order.” [S1]。`range` 是 “The audio input range that this result applies to.”；`isFinal` 是 “Whether this result is final at the time it is produced.”，等价于 `resultsFinalizationTime >= range.end`，只保证该 range 不会再有后续结果，不保证该 range 是句子。`isFinal == false` 甚至不保证会重发 final（[S2]、[S3]）。
2. **`SpeechTranscriber` / `SpeechAnalyzer` 没有句界、标点控制或句子分段 API。** `ReportingOption` 只有 volatile/fast/alternatives；`ResultAttributeOption` 只有 audioTimeRange/confidence；`TranscriptionOption` 只有 etiquetteReplacements；`AnalysisContext` 只做词表偏置；`finalize(through:)` 是 flush，不是切句；`SpeechDetector` 是 VAD，且文档明确其 `results` 序列 “may throw an error, but will otherwise remain empty”。`DictationTranscriber` 有 `.punctuation`，但那是另一个模块，且仍不提供句界（[S5]–[S17]）。
3. **本次假句界的直接原因是 app 自己的 `endsSentence` 规则。** 两个 final 的 range 间隔为 0.00 s，不满足 0.75 s gap；语言相同、没有静音；唯一触发关行的是第一段文本以句号结尾。用真实 `UtteranceAssembler` 对这两条 range 做确定性 replay，得到两个不同 ID（见 §1.2）。标点在这里是模型对 phrase 的标点，不是声学句界。
4. **建议规则：句号只影响显示/TTS，不影响 `Utterance.id`。** 行只由真实边界关闭：range gap > 0.75 s、语言切换/name swap、静音计时器、max row 保险丝。分两步落：**R0** 删除标点关行，直接修复本次假拆分；**R1** 把静音计时器改为能关闭“只有 final phrase、没有 volatile”的行，否则长停顿且下一 range 连续时仍会合并。`isFinal` 先保持 F0（现状，所有 phrase final 就发 final）；F1（关行才 final）另开 ticket。优先合并而不是拆开：假合并的伤害（一行两句、一次翻译、语义保留）小于假拆分（两个 ID、两条翻译、语义断裂）。
5. **D8 决定了不能事后合并。** `Utterance.id` 是行/文字稿条目的唯一身份；`CaptionProjection` 一 ID 一条记录、不删除，`TranslationPipeline` 一 ID 一个 job。D8 只定义同一 ID 原地更新、新 ID 新行，没有“把两个已发布 ID 合并/删除”的语义；必须在发布第二个 ID 之前决定不拆（[D8]）。
6. **最大未决风险是 range gap 是否可信。** 社区报告 per-word time ranges 背靠背、停顿会被下一个词的首个 range 吸收；如果 result 级 range 也如此，0.75 s gap 可能漏掉真实停顿。需要静音计时器兜底，必要时在 app 侧对已采集 PCM 做能量 VAD。真机验证项见 §8。
7. **2026-11-27 夹具回归补丁**：R0/R1 让行身份正确，但短句被两种独立机制吞掉：finalized phrase 的 range 被 volatile 尾部膨胀后被当成短 final 的 revision（`preferredPhraseText` 更长者胜），以及 gap/language/cap 关行只关状态、不发布 open volatile。修复见 §8.1：tight range、same-phrase/same-audio-window 合并、disjoint 文本按 range 保留、boundary pending finals，以及 reviewer 发现的同音频误听替换/partial volatile tight range。单元 561/596、identity verifier clean（含 row82 回归 2 条）；全量中间跑 85 行/97.92%、全量 pending-final 82 行/98.99%、180 s 边界硬化 17 行/98.98%、全量边界硬化 84 行/98.81%（旧跑 93.33%、问题跑 90.44%）。row 82 修复后全量 85 行/99.43%/精确 97.99%/WER 2.08%，requiredCues 10/10；语义评审 5 critical/16 major（row 82 已修，余下为 ASR/翻译层）。P1-1 仍因 ASR、翻译语义和 row 47 corruptedOutput 不签收。

## 1. 观测证据

### 1.1 同一句被拆成两个 final

四轮真机测试覆盖同传单路与面对面单路（均只跑一个英文 `SpeechTranscriber`）；两种模式都间歇出现过同一现象，同一句在另一些轮次保持一行。因此这不是双 locale 纯度、语言抢占或中文路串音造成的，而是所有单英文 transcriber 路径共有的组装规则问题。

| 轮次 | 文本 | range（音频秒） | 与上一条的间隔 | 结果 |
| --- | --- | --- | --- | --- |
| 同传单路 / 面对面单路 | `The shame of not believing.` | 139.64–142.10 | — | final，行 A，翻译 A |
| 同上 | `We deserve it.` | 142.10–143.12 | **0.00 s** | final，行 B，翻译 B |

真实句子是 `The shame of not believing we deserve it.`；ASR 在 `believing` 后插入了句号，但这个句号不对应声学停顿。

关键事实：

- 第二条 range 的 `start` 恰好等于第一条 range 的 `end`，没有重叠，也没有 gap。
- 两条都是 `isFinal == true`；第二条不是第一条的 volatile 修订，而是新 range 的 final。
- 两段文本都属于同一个英文 transcriber，语言没有变化。
- 第一段以 `.` 结尾，正好命中 `UtteranceAssembler.endsSentence`；第二段到达时，第一行已经被 `beginNextUtterance` 关掉，无法再续。

### 1.2 用真实 assembler 复现

为确认不是阅读代码的误判，用仓库源码在 `/tmp` 编译了一个只读探针（不修改 app 代码），把上述两条结果按真实 `ingest` 路径传入：

```text
first:  <UUID-A> The shame of not believing.
second: <UUID-B> We deserve it.
same ID: false
```

同一探针还确认：把第二条 range 改成 143.20–144.20（gap 1.10 s）也会得到两个 ID；再用**合成 range**（10.0–12.0、12.0–13.5、13.5–16.0，非真机观测值）传入三条带句号的连续文本（`We don't always know how to hope.` / `Or say yes, or choose.` / `big thing. Even when it's right in front of us.`），得到三个 ID。前者是 gap 规则在起作用，后者是标点规则在起作用。

### 1.3 其他真机样本

| 现象 | 样本 | 类型 |
| --- | --- | --- |
| 词被 range 边界切断 | `How you see yourself and yourself.` + `Cirstances will affect what you see...`（`circumstances` 被截断） | range 边界 + 假句界 |
| 一句拆三行 | `We don't always know how to hope.` / `Or say yes, or choose.` / `big thing. Even when it's right in front of us.` | 每段都以句号结尾；未记录 ranges，疑似标点假句界 |
| 两句并一行 | `Highlight her female identity Lead a group of men should believe an athletic task is diagnostic of sports intelligence.` | 真实句界没有标点，标点规则无能为力 |

前两类是“假拆分”，第三类是“假合并”。任何只依赖标点的规则都只能在这两类错误之间取舍；音频边界（gap/静音）才是更接近“说话人是否停”的信号。产品应优先避免假拆分：假合并至少保留完整语义，假拆分会产生两个独立翻译和两条 TTS。

注意：合并行只能修复行身份，不能补回 range 边界已经丢掉的音（`Cirstances` 缺的 `cir`/`cum`）；那属于 ASR/range 内容损失，是另一个问题（P0-6b / P1-3），不要用本修复的指标掩盖它。如果两个真实句子之间既没有停顿、也没有标点，音频边界规则同样无法区分；此时合并是可接受的残余错误，max cap 负责限制行长度。

### 1.4 在临时副本上验证“删除标点关行”

为确认推荐规则不是纸上推演，把 `UtteranceAssembler.swift` 复制到 `/tmp`，**只删除** §6.3 第 1 条说的 `endsSentence` 关行 block（app 代码未改；保留 F0 的 `isFinal` 语义），再用同一探针 replay：

```text
observed same ID: true
observed text: The shame of not believing. We deserve it.
observed isFinal/revision: true true
gap (143.20–144.20) same ID: false
silence after final-only row returned: nil
next same ID after final-only + silence: true
next text: Hello there. Next sentence.
three contiguous sentences same ID: true true
three text: We don't always know how to hope. Or say yes, or choose. big thing. Even when it's right in front of us.
```

四个结论：

- 只删除标点关行，本次假句界就变成同一 ID、完整文本；gap 1.10 s 仍然正常拆行。
- 仅删除 block 时，`silenceTimedOut()` 对“只有 final phrase、没有 volatile”的行返回 `nil`，而且下一段连续 range 仍复用同一行（`Hello there. Next sentence.`）。这证明 **R1 是必要的**：静音必须能关闭 final-only 行，否则长停顿会被 range 连续性掩盖，合成一行。
- 三条连续带句号的句子会合并成一行（R0 的预期结果）；这是“优先合并”的代价，需要 max cap 兜底。
- 该验证是临时副本，不是产品改动；真机行为仍需按 §7.3 验证。

## 2. Apple API 语义（一手资料）

### 2.1 `Result` 是 phrase，不是 sentence

`SpeechTranscriber.Result` 页面：

> “A phrase or passage of transcribed speech. The phrases are sent in order.” [S1]

> “If the transcriber is configured to send volatile results, each phrase is sent one or more times as the interpretation gets better and better until it is finalized.” [S1]

WWDC25 session 277 对同一个对象的描述：

> “This is your transcription result for a segment of audio.” [S18]

> “Eventually, the result will be as good as it can be, and the transcriber delivers one last finalized result. Once it does that, the transcriber won’t deliver any more results for this range of audio, and it moves on to the next range.” [S18]

Apple 没有把 result 称为 sentence，也没有承诺 result 的边界与句子边界对齐。实际观测也支持这一点：行文本可以在中间包含句号（`big thing. Even when...`），说明句号不一定出现在 result 末尾；即使出现在末尾，也不一定是句子边界（`...not believing.` → `We deserve it.`）。

### 2.2 `range`、`isFinal`、`resultsFinalizationTime`

`SpeechModuleResult` 的三个核心属性：

> `range`: “The audio input range that this result applies to.” [S4]

> `isFinal`: “Whether this result is final at the time it is produced.” [S2]

> `resultsFinalizationTime`: “The audio input time up to which results from this module have been finalized (after this result). The module’s results are final up to but not including this time.” [S3]

`isFinal` 的完整 Discussion 非常重要：

> “If `true`, then this result is final. There will be no later result over its range.” [S2]

> “If `false`, then this result is volatile. There may or may not be a later result over this result’s range. In particular, there is no guarantee that this result will be reissued with this property set to `true`.” [S2]

> “Equivalent to `resultsFinalizationTime >= range.end`.” [S2]

`resultsFinalizationTime` 则是一个“已定稿水位”：

> “If `resultsFinalizationTime >= range.end` then this result is final. Additionally, all previously-provided results with a `range` predating `resultsFinalizationTime` are also final.” [S3]

结论：

- **答案：`isFinal` 只是该 result 覆盖的 audio range 的 finality，不是 sentence/utterance 边界。**
- `isFinal == true` 只说明这个 range 不会被后续结果替换；它没有说这个 range 是一个完整句子，也没有说下一段 audio 属于新句子。
- `isFinal == false` 不保证会收到同 range 的 final。这一点直接支持 `UtteranceAssembler` 现有的“旧 volatile 先并入 finalized 前缀”的设计：不能等一个可能永远不来的 final（[S2]；代码见 `UtteranceAssembler.swift:530-558`）。
- `resultsFinalizationTime` 可以用来判断“哪些结果已经不会再变”，但不能用来判断“句子在哪里结束”。

### 2.3 volatile 与 final 的消费方式

WWDC 的推荐模式是：

> “If it’s volatile, we’ll save it to volatileTranscript.” [S18]

> “Whenever we get a finalized result, we clear out the volatileTranscript and add the result to finalizedTranscript.” [S18]

> “If we don’t clear out our volatile results, we could end up with duplicates.” [S18]

`SpeechAnalyzer.volatileRange` 给出了“哪里还可能变”的边界：

> “Results within the volatile range may be replaced by updated results, but results that lie outside the volatile range will not be replaced. The application can safely consolidate results that lay outside the range.” [S10]（原文如此）

> “The volatile range includes pending analyses—audio that has been sent out but where no results have come back yet.” [S10]

`setVolatileRangeChangedHandler` 的文档还特别说明：如果要响应 finalization，更好的工具是 result 的 `resultsFinalizationTime`，而不是 handler：

> “You can also use this handler to respond to result finalization, but the better tool for that job is the `resultsFinalizationTime` property of a module’s results.” [S11]

这些 API 都只回答“哪些结果已经定稿”，不回答“这是一句还是两句”。App 把 `range` 当作 result 的音频范围、把 `isFinal` 当作该 result 的 finality，是对 Apple 语义的正确使用；错误出在“用 result 末尾的标点决定整行结束”。App 把“所有 phrase 都 final”直接映射为 `Utterance.isFinal` 是 app 层选择，其代价在 §6.3 的 F0/F1 讨论。

### 2.4 `finalize(through:)` 是 flush，不是切句

`SpeechAnalyzer.finalize(through:)` 的文档：

> “Finalizes the modules’ analyses.” [S9]

> “To deliver a result for a particular time-code, call `finalize(through:)`.” [S9]

参数说明：

> “If `nil`, finalizes up to and including the last audio the analyzer has consumed from the input sequence, and if the analyzer has not consumed any audio from the input sequence, this method does nothing.” [S9]

Discussion：

> “At the return of this method, input up to and including the given time will have been analyzed. Modules will have published the finalized results to their stream, but the application may not have consumed them from the results stream yet. `volatileRange` will post-date the given time.” [S9]

这正好解释了 app 的静音流程：`analyzer.finalize(through: nil)` 让模块把已消费的音频定稿，然后等 350 ms 让 consumer 收到 final；它并不会在音频里“切开一句”。因此不能用 `finalize(through:)` 来实现句界，除非已经知道句界在哪里；而“知道句界在哪里”正是当前缺失的信息。

### 2.5 `SpeechTranscriber` 没有句界/标点控制

逐项核对 Apple 文档与本机 iOS 27.1 SDK 的 `Speech.swiftinterface`：

| API 表面 | 实际内容 | 能否切句/控标点 |
| --- | --- | --- |
| `ReportingOption` | `volatileResults`、`fastResults`、`alternativeTranscriptions` [S5] | 否。volatile 是同一 range 的迭代结果；fast 只影响响应/精度权衡；alternatives 只是备选文本。 |
| `ResultAttributeOption` | `audioTimeRange`、`transcriptionConfidence` [S6] | 否。只把时间码/置信度写进 `AttributedString` 的 run 属性；`Result.range` 本身始终存在。 |
| `TranscriptionOption` | 只有 `etiquetteReplacements` [S7] | 否。没有 punctuation、没有 sentence、没有 paragraph。 |
| `Preset` | `transcription`、`transcriptionWithAlternatives`、`timeIndexedTranscriptionWithAlternatives`、`progressiveTranscription`、`timeIndexedProgressiveTranscription` [S8] | 否。`progressiveTranscription` 就是 volatile + fast；没有“按句输出”预设。 |
| `SpeechAnalyzer.Options` | `priority`、`modelRetention`（iOS 27 还有 `ignoresResourceLimits`） | 否。只影响资源/调度。 |
| `AnalysisContext` | `contextualStrings`（词表偏置）、`userData`（app 自定义）[S12] | 否。文档只说 “Words or phrases ... that should be recognized even if they are not in the system vocabulary”；不控制断句。 |
| `SpeechDetector` | VAD 模块；“is there speech?” [S13] | 否。它是 VAD，不是 endpoint/句子 API。 |
| `SpeechDetector.results` | “This sequence may throw an error, but will otherwise remain empty.” [S14] | 否，而且应用不能依赖它得到 `speechDetected` 事件。 |
| `finalize(through:)` | flush [S9] | 否。 |
| `DictationTranscriber.TranscriptionOption.punctuation` | “Automatically punctuates the transcription.” [S17] | 只控制标点，不提供句界；且是另一个 transcriber。 |
| `NLTokenizer` / `NLTagger` | 文本分词/句子 tokenization [S24][S25] | 只能对已有文本按标点/语言模型切句；不能恢复 ASR 没给出的标点，也不能判断标点是否假。 |
| `TranslationSession` | `translate(_:)`、batch/translations；`Request` 只有 `sourceText`/`clientIdentifier` [S26][S27] | 没有“上下文/上一句”参数；要保留上下文只能把文本放在同一个 job 里。 |

补充：`alternatives` 和 `transcriptionConfidence` 可以帮助选更可信的词，但 Apple 没有把它们与句界/标点控制关联；用 alternatives 的标点差异来推断句界是未文档化的启发式，不应作为 D8 的身份规则。`AnalysisContext.contextualStrings` 同样只影响识别词表，不影响断句/标点。

本机 SDK 核对：`/Volumes/DevDisk/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface`（iOS 27.1 SDK）。`SpeechTranscriber` 的 `Result` 内容属性只有 `range`、`resultsFinalizationTime`、`text`、`alternatives`、`isFinal`；`TranscriptionOption` 只有 `etiquetteReplacements`；`ResultAttributeOption` 只有 `audioTimeRange`、`transcriptionConfidence`；不存在 sentence/paragraph/utterance boundary API。`SpeechDetector` 在当前 SDK 已正式 conform `SpeechModule`（早期 beta 论坛里需要 retroactive conformance），但其 `results` 文档仍然是“otherwise remain empty”。

### 2.6 `DictationTranscriber` 的标点选项不是解

`DictationTranscriber` 的定位是：

> “A speech-to-text transcription module that’s similar to system dictation features and compatible with older devices.” [S16]

它的 `.punctuation` 选项：

> “Automatically punctuates the transcription.” [S17]

> “If omitted, only spoken punctuation is transcribed, as by the spoken phrase ‘hello comma there’.” [S17]

这能改善标点覆盖率，但不能保证句界正确；而且换模块是整条 ASR 链路的变更。社区实践报告 DictationTranscriber 更慢、精度更低（见 §4），不适合为了切句直接替换 live caption 的 `SpeechTranscriber`。它最多是一个独立 A/B 实验，不是本问题的修复。

### 2.7 旧 `SFSpeechRecognizer` 也没有句界

`SFSpeechRecognitionResult` 的 `isFinal`：

> “A Boolean value that indicates whether speech recognition is complete and whether the transcriptions are final.” [S20]

`SFTranscription` 对 “utterance” 的定义：

> “An utterance is a vocalized word or group of words that represent a single meaning to the speech recognizer.” [S21]

`SFTranscriptionSegment` 只提供 `timestamp`、`duration`、`confidence` 等 segment 级信息 [S22]；`SFSpeechRecognitionMetadata` 另有 `speechStartTimestamp`、`speechDuration`、`averagePauseDuration` 等整段请求的元数据 [S23]，但这些都不是句子边界。换句话说，旧框架的 “utterance” 也不是句子；社区围绕它发展出的“静音计时器 + 分段合并”模式，正是因为框架不提供句界（§4）。

## 3. Apple 对“怎么把结果变成行”的建议

Apple 没有给出 utterance/row grouping 的 API，也没有说“一个 final 就是一行”。官方材料给出两种消费模式和一组 finality 边界：

1. **WWDC 的 live caption 模式**：final 追加到 `finalizedTranscript`，volatile 覆盖 `volatileTranscript`；收到 final 时清空 volatile。示例 app 为了视觉效果，自己加了一个 “break up the sentences” 的方法：

   > “I’ve added a method to break up the sentences to make it visually less cluttered.” [S18]

   这是**显示层**的句子切分，不是 transcriber 的语义边界，也不是稳定的 utterance identity。

2. **iOS 27 sample code 的 range-keyed 模式**：`DictationTranscriber`（不是 `SpeechTranscriber`）的 sample 明确说：

   > “The transcriber module doesn’t accumulate an overall transcription. Instead, it provides a number of results for different audio time ranges. The app incorporates each update into an overall transcription and replaces the currently displayed transcription with the new one.” [S19]

   > “another common technique is to maintain two separate transcriptions: one containing finalized results that won’t be replaced, and another containing volatile results that are expected to be replaced.” [S19]

   它用 `AttributedString.rangeOfAudioTimeRangeAttributes(intersecting:)` 按 range 替换，而不是按句号换行。

3. **finality 的边界**：`volatileRange` 之外的 result 可以安全合并；`resultsFinalizationTime` 是模块级已定稿水位；`finalize(through:)` 用于在指定时间点催出 final。这三者都可用于“哪些结果不会再变”，但不能用于“句子在哪里结束” [S9][S10][S11]。

Apple 的 live-audio sample 在停止时用 `finalizeAndFinish(through:)`，并没有用 `SpeechDetector` 做 endpoint；`SpeechDetector` 的文档只把它作为 VAD gate [S13][S19]。因此，Apple 对“怎么分组”的实际答案是：**app 自己决定**。Apple 只保证 result 是 phrase、按顺序发送、一个 result 的 range 在 final 后不再被覆盖，不保证句子。

## 4. 社区与第三方证据（非官方，单独标注）

> 以下不是 Apple 官方规范，只用于交叉验证行为与工程模式。可信度按来源标注；论坛/博客结论需真机复核。

### 4.1 `SpeechDetector` 的 `results` 实际上是空的

Apple Developer Forums 帖 “There's wrong with speech detector ios26” 中，Apple_Agent 的回复：

> “`SpeechDetector` only provides a result if there is an error (and if you also specify `reportResults: true`).” [C1]

同一帖里开发者报告 `for try await result in detector.results` 没有任何输出；DTS Engineer 在 beta 期还指出 `SpeechDetector` 当时没有正式 conform `SpeechModule`，需要用 retroactive conformance 才能编译（当前 iOS 27.1 SDK 已正式 conform）。Apple 文档本身也写着 `results` “will otherwise remain empty” [S14]，`Result` “currently only support error handling from the VAD model” [S15]。

对本项目的含义：`BilingualSpeechEngine` 里 `consume(detector:)` → `handleVoiceActivity` 这条路径（`BilingualSpeechEngine.swift:320-334`、`:451-458`）在真机上很可能从不触发。当前所谓“静音”实际上是“1.1 s 没有新的 ASR result”，不是 VAD 的 acoustic silence；单路模式甚至没有挂 Detector。Detector 仍可能作为 analyzer 内部的 VAD gate 省电/降负载，但它的 `speechDetected` 事件不能作为 endpoint 信号。这是本次研究最意外的发现，建议单独验证并记录。

### 4.2 final 延迟与静音计时器

Apple Developer Forums 帖 “SpeechTranscriber/SpeechAnalyzer being relatively slow compared to FoundationModel and TTS” 中，开发者测得“最后一帧高于噪声底 → final transcript”：

> “n: 11, avg: 2.2s, Var: 0.75” [C2]

调用 `prepareToAnalyze` 后：

> “n: 11, avg: 1.45s, Var: 1.305” [C2]

帖中另一位开发者（非 Apple）建议：

> “Use volatileResults aggressively for UI feedback, but trigger your downstream action ... on the volatile transcript as soon as it stabilizes — don't wait for the finalized event.” [C2]

这解释了为什么 app 需要 1.1 s 静音计时器 + `finalize(through: nil)` + 350 ms 等待：final 本身可能比说话结束晚 1–2 s。它也说明，靠“等 final 再判断句界”不会让句界更准；final 只保证 range 定稿。

### 4.3 `SFSpeechRecognizer` 的经典静音/分段模式

Stack Overflow “SFSpeechRecognizer - detect end of utterance” 的最高票答案：`isFinal` 在用户停止说话后可能一直为 false；建议在每次新 transcription 到达时重置一个约 2 s 的 timer，timer 到期就结束当前 session [C4]。其他答案用 `bestTranscription.segments[0].confidence > 0`、`speechRecognitionMetadata` 是否非 nil、或 segment timestamp/duration 作为 finality 代理 [C4][C5]。

这与本项目的 range + 静音计时器思路一致：**框架不给句界，应用自己用“结果活动 + 时间”推断 endpoint**。

### 4.4 `SFSpeechRecognizer` 的 pause 丢字 bug

Apple Developer Forums 帖 731761 与 Stack Overflow 79005416 报告：iOS 17/18 的 on-device 识别在说话人短暂停顿后会把之前的 `bestTranscription` 清空，`isFinal` 仍为 false；有人用 segment 的 `confidence > 0` 识别“final partial”，再用 `speechStartTimestamp` 排序拼接 [C3][C5]。这是旧框架的实现缺陷，不应直接套到 `SpeechAnalyzer`；但它说明“把 partial 当最终文本”很危险，和本项目的 `isFinal`/volatile 处理是同一类问题。

### 4.5 `SpeechAnalyzer` 结果的 phrase 粒度与 range 吸收停顿

一篇实际做 iOS 26 视频字幕的工程博客报告：

> “Each result is roughly one phrase.” [C6]

> “Every run in the result's `AttributedString` carries its start and end time.” [C6]

> “the per-word time ranges are back to back, with no gaps” [C6]

> after a pause, “the first word absorbs the pause into its own range.” [C6]

作者还报告：标点并不可靠，最终选择从用户提供的 script 取标点；`DictationTranscriber` 的标点方案更慢（2.74 s vs 0.86 s）且更差 [C6]。这篇是社区实践，不是 Apple 规范，但它直接警示：**result 级 range 的 `start` 不一定暴露真实停顿**，因为停顿可能被下一个 phrase 的首词吸收。若本项目的 0.75 s gap 在真机上经常为 0，就需要静音计时器或音频能量 VAD，而不能只靠 range gap。

### 4.6 volatile/final 的 UI 模式

另一篇 live mic 实践文章总结：

> “Show volatile dimmed, replace it on a final, persist only finals.” [C7]

> “`isFinal` marks committed text.” [C7]

这与 WWDC 的示例一致；但两篇社区文章都没有给出“如何把一个 final 变成一句”的答案，说明社区也没有可依赖的框架级句界 API。

### 4.7 句子 tokenization 只能处理已有文本

`NLTokenizer(unit: .sentence)` 的文档示例就是对一段已经带句号的字符串做 tokenization：

> “Use this linguistic unit to tokenize text into sentences” [S24]

`NLTagger` 也支持 “segment natural language text into paragraph, sentence, or word units” [S25]。它们能处理**已经有标点**的文本，不能判断 `The shame of not believing.` 后面的句号是不是假句界，也不能恢复 `Highlight her female identity Lead a group...` 缺失的句号。把 `NLTokenizer` 放在 assembler 后面只会把同样的假标点再切一次，不解决问题。

### 4.8 翻译上下文

`TranslationSession` 的 API 是 `translate(_:)` / batch / `translations(from:)`；`Request` 只有 `sourceText` 和 `clientIdentifier`，没有“上一句/上下文”参数 [S26][S27]。因此“保留两个 ID，但在翻译时把前一句作为上下文”没有官方 API 支持；最直接且受支持的做法是让相关文本进入同一个 `Utterance` / 同一个翻译 job。手动把前一句拼进 source 会改变翻译输出和行身份，不推荐。这与“不要拆假句界”的结论一致。

### 4.9 社区结论汇总

- 没有找到任何可信来源声称 `SpeechTranscriber` 有句界/段落 API；社区一致做法是 app 侧按 silence/range/标点自行分组。
- `isFinal` 被普遍理解为“该 range/该次请求的 finality”，不是句子结束。
- 标点可以作为显示提示，但不能作为 utterance identity 的唯一依据；这在 `SFSpeechRecognizer` 时代就已经如此。

### 4.10 模式可信度分级

| 模式 | 证据等级 | 说明 |
| --- | --- | --- |
| 按 `range` 连续/重叠合并，按 gap 拆行 | **Apple 有 API 语义支撑，credible** | `range`/`isFinal`/`volatileRange` 是官方定义；gap 阈值是 app 策略。 |
| 静音计时器分组 | **社区共识，credible** | SFSpeechRecognizer 社区实践广泛使用；SpeechAnalyzer 的 final 延迟数据（C2）支持保留静音兜底；阈值需真机校准。 |
| 按句末标点关行 | **app 启发式，不可靠** | Apple 没有把标点/句号定义为句界；本次真机假拆分就是证据。 |
| `NLTokenizer`/`NLTagger` 句子 tokenization | **Apple API，但只处理已有文本** | 不能判断假标点、不能恢复缺失标点；只能做显示/TTS 辅助。 |
| max row 时长/字符数 | **工程惯例，credible** | 无 Apple API；作为保险丝，需按 UI/翻译延迟校准。 |
| 用 `DictationTranscriber.punctuation` 恢复标点 | **Apple 有选项，但用途不同；speculative** | 社区报告更慢/更差；仍不保证句界；换模块风险大。 |
| 用 `audioTimeRange` per-word 时间找停顿 | **API 存在，但效果 speculative** | 社区报告首词吸收停顿、ranges 背靠背；需真机验证。 |
| app 侧 PCM 能量 VAD | **可行但未验证，speculative** | 无 Apple endpoint API；需要自己实现/调阈值；不引入第三方依赖。 |
| 跨 ID 翻译上下文合并 | **无 Apple API，unsupported** | `TranslationSession.Request` 只有 `sourceText`/`clientIdentifier`；D8 不引入跨 ID alias/groupID。 |

## 5. 方案对比

> 下文 **R0/R1** 指规则落地的两步（R0 删除标点关行；R1 静音关闭 final-only 行，见 §0/§6.3）；**F0/F1** 指 `Utterance.isFinal` 的两种语义（F0 所有 phrase final 就发 final，现状；F1 行关闭才发 final，见 §6.3）。

| 方案 | 规则 | 优点 | 代价/风险 | D8/投影 | 结论 |
| --- | --- | --- | --- | --- | --- |
| A. 现状：句末标点关行 | final 文本按 `endsSentence` 判定为句末（`.?!。？！`，可带收尾引号/括号）→ `beginNextUtterance` | 翻译早、行短、实现简单 | 假句界直接产生两个 ID/两条翻译；本次真机问题 | 合法，但语义错 | 不保留 |
| B. 标点只影响显示；真实音频边界关行 | 只有 gap > 0.75 s、语言切换/name swap、静音、max cap 才关行 | 假句界消失；语义完整；一个翻译 job 看到完整上下文 | 行可能变长；完整句的 final 翻译等到停顿/静音（F0 下可能有被替换的早期 final）；连续 speech 时预览是否停更取决于 F0/F1（F0 下下一段 volatile 可能被投影丢弃，F1 下继续 streaming） | 合法；同一 ID 原地增长/修订 | **推荐** |
| C. 标点后等下一个 range 确认 gap 再关 | 句号 final 先挂起，下一个 range 有 gap 才关；无 gap 则续行 | 保留标点作为“更早检查”的提示；可用更短 gap 阈值 | 需要额外 pending 状态；默认阈值仍需真机校准；身份效果与 B 同类（都由音频边界决定，阈值可能不同） | 合法 | B 的可选调参版 |
| D. 先发两行，事后再合并 | 两个 ID 都发布后按 range 连续合并 | 理论上保留早期翻译 | D8 只定义“同一 ID 同一行，新 ID 新行”，没有两个已发布 ID 的合并/删除语义；`CaptionProjection` 无删除；`TranslationPipeline` 两个 job；还要撤回已显示译文 | **不符合 D8** | 拒绝 |
| E. 换 `DictationTranscriber` + `.punctuation` + `NLTokenizer` | 用 dictation 模型出标点，再按句 tokenization 切 | 标点可能更全 | 换整条 ASR；社区报告更慢/更差；仍不保证句界；iPhone 13 无 Apple Intelligence，无法用模型补救 | 仍可合法，但风险大 | 仅作为独立 A/B，不作为修复 |
| F. 只加 max row 长度/时长 | 行太长就强制关 | 防极端长行 | 不解决假句界；仍会在句号处拆 | 合法 | 只能作为 B 的保险丝 |
| G. 用 `volatileRange`/`resultsFinalizationTime` 代替句界 | 按“哪些结果已定稿”关行 | 能准确知道 finality | 不知道句子边界；会把每个 phrase final 当行 | 合法但语义错 | 不能替代 B |
| H. 保留两行，但翻译时把前一句作为上下文 | 把前一句拼进 source 或另设 context | 可能改善跨句翻译 | `TranslationSession.Request` 只有 `sourceText`/`clientIdentifier`，没有 context 参数；D8 不引入跨 ID alias/groupID；会改变翻译输入和缓存键 | 不符合 D8/API | 拒绝 |

**为什么推荐 B 而不是 C**：B 的默认行为就是“标点不关行”，规则最少、最不容易回归；C 只是在 B 上增加一个可选阈值（例如句号后 0.35 s gap 就关），需要真机数据证明“句号后的短停顿更可信”。在证据不足时，C 只会把假句界换成另一种阈值赌博。

**是否漏掉了 Apple 的分段 API？** 本报告逐项核对了 `ReportingOption`、`ResultAttributeOption`、`TranscriptionOption`、`Preset`、`AnalysisContext`、`finalize(through:)`、`volatileRange`/`volatileRangeChangedHandler`、`SpeechDetector`、`DictationTranscriber.punctuation`、`NLTokenizer`/`NLTagger` 和 `TranslationSession`，没有发现可用的句界/段落 API。最接近的 `DictationTranscriber.punctuation` 只控制标点，`NLTokenizer` 只处理已有文本，`SpeechDetector` 的结果序列是空的；它们都不能替代“按音频边界决定行”。

## 6. 推荐规则改动（`UtteranceAssembler`）

### 6.1 什么应该关闭一行

| 触发 | 是否关行 | 说明 |
| --- | --- | --- |
| final 文本按 `endsSentence` 判定为句末（含收尾引号/括号） | **否** | 标点只留在文本里；不调用 `beginNextUtterance`。现状见 `UtteranceAssembler.swift:441-445`。 |
| 下一个 range 的 `start > 上一 phrase.end + 0.75` | 是 | 现有 `rangeGapLimit`（`UtteranceAssembler.swift:88`、`:407`）。建议保留 0.75 s 作为起点，真机校准。 |
| 语言变化（`latestFinal.language != language`） | 是 | 现有 `UtteranceAssembler.swift:380-386`；语言切换是真实边界。 |
| greeting name swap | 是 | 现有 `SpokenText.isNameSwap` 路径；不同说话人。 |
| 静音计时器触发（1.1 s 无结果；有 volatile 时 `finalize(through:)` + 350 ms，final-only 直接关闭） | 是 | 需要把“只有 final phrase、没有 volatile”的行也视为 open；现状 `silenceTimedOutForRanges` 只处理 volatile（`:660-686`）。 |
| 行时长/字符数超过 cap | 是 | 新增保险丝；在下一个 phrase 边界关，不切单个 phrase。起点建议 12 s / 120 字符（按语言可调）。 |
| `stop()` / 结束任务 | 是 | 现有 `finalizeAndFinishThroughEndOfInput()` + `silenceTimedOut()` 路径。 |
| 同一 range 的 volatile/final 修订 | 否 | 现有 `apply` 原地替换/合并；不能新 ID。 |
| 尾随 `...` / 句内标点 | 否 | 现有 ellipsis 续句逻辑；句内标点本来就不触发 `endsSentence`。 |

对应常量：静音 1.1 s 来自 `ConversationLayout.silenceCommitMilliseconds = 1100`（`Duiyi/Domain/Models/ConversationLayout.swift:12`）；finalize 后等待 350 ms 来自 `BilingualSpeechEngine.silenceFinalizeWindow`（`BilingualSpeechEngine.swift:28`）。

### 6.2 标点应该只做什么

- **保留在 `Utterance.text` 里**：它是 ASR 的输出，不应为了合并而删除或伪造。句号还可能是缩写、小数或引号内标点；identity 规则不应依赖它。
- **显示**：UI 照常显示句号；一行里有两句在视觉上是可以接受的。
- **TTS clause**：`ClauseSplitter` 仍可按标点切 clause；同一 ID 的后续 final 会用 `spokenPrefixes` 去重，不会把已读前缀再读一遍（`InterpretationViewModel.swift:850-880`）。
- **诊断**：可以记录“这是一个带句末标点的 final”作为 close reason 的候选，但不要让它直接决定 ID。
- **可选**：如果真机证明“句号后的短停顿”很可信，可以在 B 之上加一个更短的 `punctuatedGapLimit`（例如 0.35 s）；默认不启用。

### 6.3 具体改动点

1. **删除标点关行**：移除 `ingestRangeAware` 末尾的
   `if Self.endsSentence(winnerText) { closeCurrentRangeRow(...); beginNextUtterance(...); hold(...) }`（`UtteranceAssembler.swift:441-445`）。
   `endsSentence` 可以删除，或降级为诊断/显示辅助；不再影响 `utteranceID`。该 block 里的 `hold(winner, for: 0.8)` 也会被删除；引擎的 `acknowledgeFinal` 仍会在首个 non-revision final 后 hold 1.0 s，语言抑制不依赖这个 0.8 s block。
2. **新增 `hasOpenRow` 语义**：只要当前行有文本且尚未被上述边界关闭，就返回 true；不能只看 `volatile != nil`。把引擎 `finalizeFromSilence` 的 guard 从 `assembler.hasOpenRange` 改为 `assembler.hasOpenRow`；但**只有 `hasOpenRange`（存在 volatile）才调用 `analyzer.finalize(through: nil)` + 350 ms 等待**，final-only 行直接走 `silenceTimedOut` 关闭，避免每句都多一次 analyzer finalize。可以保留 `hasOpenRange` 表示“存在 volatile 尾部”，避免改变现有诊断/测试语义；如果直接把 `hasOpenRange` 改成新语义，则要按 §7.1 翻转 `silenceAfterTranscriberFinalIsNoOp`。
3. **让 `silenceTimedOutForRanges` 能关闭 final-only 行**：当前 guard 要求 `state.volatile != nil`（`:660-663`）；改为 `state.volatile != nil || !state.finalized.isEmpty`，然后 `closeCurrentRangeRow` + `beginNextUtterance`。返回值的两种实现：
   - **F0 且 `publishedFinalForCurrentID` 为 true、文本未变**：可以只关闭/推进并返回 `nil`（没有新的文本要发布），这样现有 `silenceAfterTranscriberFinalIsNoOp` 的 `silence == nil` 仍然成立；下一段 range 会得到新 ID。
   - **F1，或文本尚未发布/有更新**：返回 final（必要时 `isRevision`），由引擎发布。
   无论哪种，关闭状态必须推进；`publish` 的签名去重会避免重复 UI final。
4. **加 max cap**：在 `apply` 之前检查当前行 union range 的时长和 `SpokenText.compact(text).count`；超过 cap 且新 result 是不同 range 时，先 `closeCurrentRangeRow` + `beginNextUtterance`，再把新 phrase 放进新行。不要在一个 phrase 内部切。cap 只在当前行没有 volatile（所有 phrase 已 final）时触发；有 volatile 时等它 final 或静音，避免关闭一个未 final 的行。cap 造成的拆分是显式新 ID（不是 revision/merge），D8 仍成立；长句可能跨行，这是显示/延迟保险丝的产品取舍。
5. **保留 closedRange 表**：迟到 final 仍然按 range 重叠复用 ID（`:604-652`）；本次改动不改变 late-final 语义。
6. **`isFinal` 语义（建议分两步）**：
   - **最小改动（F0）**：保持现状——一个行的所有 phrase 都 final 就发 `isFinal: true`。同一 ID 的后续 final 是 revision，`CaptionProjection` 会覆盖文本，`TranslationPipeline` 会用同一 ID 的新 final 替换旧翻译；TTS 由 `ClauseSplitter` 去重。缺点是第一段 final 翻译可能短暂显示，随后被完整句翻译替换；第二段的 volatile 在投影层会被 `record.isFinal && !utterance.isFinal` 丢弃（`CaptionProjection.swift:53`），预览会“跳一下”。
   - **更干净的语义（F1，较大改动，不是首修）**：把 `Utterance.isFinal` 定义为“行已关闭”，行还开着时即使所有 phrase 都 final 也发 `isFinal: false`。这样投影层保持 streaming，翻译走 preview debounce，TTS 等到关行；关行时发一次 final。代价不只是改 `refreshTexts` 的 `finals` 计算、`hasOpenRow`、静音路径、`acknowledgeFinal`/language hold 的时机、language-change 对 `latestFinal` 的依赖和相关测试：当前 `ingest` 一次只返回一个 `Utterance?`，而 gap/language/cap 关行并在同一次 ingest 开始新行时，旧行的 final 和新行的首个 preview 需要两次发布。必须引入 assembler 内部的待发布队列、返回数组或引擎侧 drain，否则旧行 final 会丢。F1 应另开 ticket，先落 F0 + R0/R1 修复假句界。
7. **同步文档**：实现后更新 `docs/02-architecture.md` §4.2（目前写“句末标点决定换行”）和 `Duiyi/Services/AGENTS.md` §1 的 range-aware 描述；D8 本身不变。

**落地顺序**：R0 → R1 → max cap → F1（可选）。R0 可以单独 A/B，先确认假拆分下降；R1 再解决长停顿合并；max cap 最后按 UI/翻译延迟调；F1 是语义清理，不是修复必需品。

### 6.4 不要做什么

- **不要事后合并两个已发布的 ID**：D8 定义 `Utterance.id` 即行身份、同一 ID 原地更新、新 ID 新行，没有合并/删除语义；`CaptionProjection` 一 ID 一条记录且没有删除/合并方法（`CaptionProjection.swift:49-89`），`TranslationPipeline` 按 `utteranceID` 合并 job（`TranslationPipeline.swift:184-196`）。两个 ID 已经产生两条翻译；撤回一条需要新的投影/翻译语义，超出本修复。
- **不要用 `continuesFrom` / `groupID` 绕过 D8**：D8 已明确不引入这些字段。
- **不要用 `NLTokenizer` 在投影层再切**：它不能判断假句号，切完还是两条翻译。
- **不要用第三方标点模型/服务端标点**：项目无第三方依赖、无后端，且 iPhone 13 无 Apple Intelligence；Foundation Models 与服务端模型都不可用。
- **不要为了标点切到 `DictationTranscriber`**：这是整条 ASR 链路的 A/B，不是 segmentation 修复。

### 6.5 对本次样本的预期行为

按 B 规则处理 `The shame of not believing.` + `We deserve it.`（139.64–142.10、142.10–143.12）：

- 第一段 final 不再关行；第二段 final 到达时，`range.start == 上一 end`，不满足 gap，继续同一 `utteranceID`。
- 行文本变为 `The shame of not believing. We deserve it.`。F0 下第二次 `isFinal == true`、`isRevision == true`；F1 下关行前仍 `isFinal == false`、`isRevision == false`，第一次真正 final 发生在静音/gap 关行时。
- 同一 ID 的翻译 job 会被新 final 替换，最终只保留一条完整译文；TTS 的 `ClauseSplitter` 只补读新增 clause，不重复 `The shame of not believing.`（F1 下则等关行一次读完整句）。
- 如果说话人在 `We deserve it.` 后停顿 1.1 s：按 R1 的 `hasOpenRow` 语义，静音计时器关行，下一句得到新 ID；若只做 R0，则该行已经 final，要等下一段 range 的 gap > 0.75 s 才关行。若下一句在 1.1 s 内到达，两种情况都继续同一行（短停顿合并，符合“优先合并”）。
- 如果第二段 range 与第一段之间有 >0.75 s gap，第一行在第二段到达前关闭，得到两个 ID；这是声学停顿边界，符合预期。

## 7. 测试计划

### 7.1 确定性 range fixtures（`DuiyiTests/UtteranceAssemblerRangeTests.swift`）

| 测试 | 输入序列（全部 `isFinal: true`，英文） | 期望 |
| --- | --- | --- |
| `contiguousPunctuatedFinalsKeepOneRow` | `The shame of not believing.` 139.64–142.10；`We deserve it.` 142.10–143.12 | 同一 ID；文本 `The shame of not believing. We deserve it.`；F0 下第二次 `isFinal == true`、`isRevision == true`；F1 下关行前第二次 `isFinal == false`、`isRevision == false` |
| `punctuatedFinalThenGapStartsNextRow` | 同上第一段；第二段 143.20–144.20（gap 1.10 s） | 两个 ID；第二行只有 `We deserve it.` |
| `contiguousVolatileThenFinalKeepsOneRow` | 第一段 final；`We deserve it.` 142.10–143.12 volatile；同 range final | 同一 ID；最终文本完整；F0 下 final/revision，投影层可丢弃中间 volatile |
| `punctuatedFinalThenSilenceClosesRow` | 第一段 final；`silenceTimedOut()`；第二段 143.20–144.20 | 第一行 final 且关闭；第二段新 ID |
| `threeContiguousSentencesStayOneRow` | `We don't always know how to hope.` 10.0–12.0；`Or say yes, or choose.` 12.0–13.5；`big thing. Even when it's right in front of us.` 13.5–16.0 | 同一 ID；三段文本按顺序拼接 |
| `threeContiguousSentencesSplitOnGap` | 第一段 10.0–12.0；第二段 12.9–14.0（gap 0.90 s）；第三段 14.1–16.0（gap 0.10 s） | 第一/第二之间拆成两个 ID；第二/第三之间继续第二行；共两个 ID |
| `noPunctuationContiguousStillOneRow` | 两个无标点连续 final | 同一 ID（现有行为） |
| `maxDurationCapClosesBeforeNextPhrase` | 7 条 2 s 连续 final，均带句号 | 至少两个 ID；所有 phrase 的 compact 文本按顺序出现在对应行，行时长不超过 cap + 单个 phrase |
| `maxCharacterCapClosesBeforeNextPhrase` | 多条短 range 累积到超过字符 cap | 同上 |
| `capDoesNotCloseVolatileRow` | 超过 cap 的行仍有 unstable volatile；再来一个新 range | 不因 cap 关闭未 final 行；等 final/静音 |
| `languageChangeStillCloses` | 英文 final；中文 final（`.strict` 下用合法中文文本） | 两个 ID（现有行为） |
| `lateFinalForClosedRangeKeepsID` | 第一段 final + 静音；同 range 的迟到 final | 复用第一行 ID，`isRevision == true`（现有行为） |
| `punctuationOnlyResultIgnored` | `.` / `...` range | 不产生行、不替换 volatile（现有行为） |
| `ellipsisContinuationStaysOneRow` | `...is di...` + `nostic...` | 同一 ID；去掉续句省略号后正常拼接（现有省略号续句行为） |
| `silenceClosesFinalOnlyRow` | 单条 final（无 volatile）；`silenceTimedOut()`；再 ingest 下一段 | 行被关闭（下一段新 ID）；F1 下 `silenceTimedOut()` 返回 final；F0 下可返回 nil（无新文本），但必须推进关闭状态 |
| `sameRangeVolatileAfterFinalDoesNotNewRow` | final 后同 range volatile | 同一 ID；投影层可丢弃该 volatile，但不得新 ID |

实现提示：复用现有 `RangeTestClock` 和 `range(_:_:)` helper；不要用真实时钟或 sleep。断言 `id`、`text`、`isFinal`、`isRevision`，不要断言私有状态。

现有测试的处置（这是方向性行为变更，不是修绿）：

- `UtteranceAssemblerRangeTests.punctuationFinalClosesRow` 断言两个 ID；新规则下应改为同一 ID/完整文本（或改名并入 `contiguousPunctuatedFinalsKeepOneRow`）。不要删除测试。
- `UtteranceAssemblerRangeTests.contiguousFinalsJoinUntilPunctuation` 用 `Thank you.` 在 5.5–7.0（gap 0.5 s）断言新行；新规则下 gap < 0.75 会合并。应把 fixture 改成 gap > 0.75 s（例如 5.8–7.0）以继续覆盖“真实停顿拆行”，并保留原测试名或改名说明语义。
- `UtteranceAssemblerRangeTests.silenceAfterTranscriberFinalIsNoOp` 断言 final-only 行 `hasOpenRange == false` 且 `silenceTimedOut() == nil`。若按 §6.3 第 2 条保留 `hasOpenRange` 的 volatile 语义、新增 `hasOpenRow`，并在 F0 下让静音关闭 final-only 行但返回 nil，这个测试可以继续通过；另加 `silenceClosesFinalOnlyRow` 验证下一段得到新 ID。如果直接把 `hasOpenRange` 改成 `hasOpenRow` 语义，或启用 F1，则应改写该测试并说明方向性翻转，而不是删除或改断言来“修绿”（F1 下该测试自然期望 final）。
- `lateFinalAfterSilenceReusesRow`、`lateFinalRevisesLateVolatileRow` 等使用 volatile 的静音用例应保持通过；R1 只扩大 `silenceTimedOut` 可关闭的行集合，不应改变迟到 final 复用 ID。
- 文本路径（无 range）的 `UtteranceAssemblerTests` 不受影响；如果 R1 改了 `hasOpenRange` 的公开语义，需要检查 `Silence`/engine 相关测试。
- PR 说明按 `DuiyiTests/AGENTS.md` §4 记录方向性翻转的理由。

### 7.2 有界穷举验证（D8）

`tools/verify-utterance-identity.sh` 已经对真实 `UtteranceAssembler` 做有界穷举 replay，覆盖 `finalized-text-identity`、`settled-language-identity`、`range-settled-language-identity` 三条性质（见 `.claude/skills/verify-utterance-identity/SKILL.md`）。本次改动建议：

1. 在 range alphabet 中增加：
   - 连续带句号 pair：`range(en, finalA, 0-1)` + `range(en, finalB, 1-2)`；
   - 带 gap pair：`0-1` + `2-3`；
   - final + `silenceTimedOut` + 下一段；
   - 两条相邻的 13 s / 1 s range 事件（第二条到达时触发 cap，而不是靠加深搜索）。
2. 增加一条 **text conservation** 性质：一行的所有 phrase compact 文本按顺序应能在行文本 compact 中找到（作为子序列）；关行不得丢 phrase。当前先由 §8.1 的确定性 range 回归覆盖已知形态；有界穷举版的 text conservation 尚未实现，不要把它当作已验证。
3. 保持 `silenceTimedOut` 事件至少 emit 一次，避免 alphabet 退化。
4. 改动后运行 `tools/verify-utterance-identity.sh --depth 5`（必要时 6），按 skill 的 baseline 更新预期；如果 depth 增加导致组合爆炸，优先增加针对性事件而不是盲目加深。

### 7.3 真机验证

同一台 iPhone 13、同一段 3–5 分钟 TED 英文、同一摆放、同一构建，至少 4 轮。诊断 JSON 已经记录 `rangeStartSeconds` / `rangeDurationSeconds` / `resultsFinalizationTimeSeconds`（`BilingualSpeechEngine.swift:305-307`、`:412-442`），可以直接用现有导出分析 final 水位，不需要新增正文日志：

1. **回归本次样本**：确认 `The shame of not believing.` + `We deserve it.` 合成一行、一条翻译；统计同类“句号 + 连续 range”拆分次数。
2. **停顿阶梯**：在句间人为插入 0.3 / 0.6 / 1.0 / 1.5 / 2.0 s 停顿，记录每个 phrase 的 range、gap、关行 ID；验证 0.75 s gap 与 1.1 s 静音的实际分界，确认没有把 1.5 s 停顿合并。
3. **ASR 停滞**：连续说话不停顿，确认 1.1 s 静音计时器不会在正常长句中间误关；如果会，记录 ASR result 间隔，考虑调大 `silenceCommitMilliseconds` 或改用音频能量 VAD。
4. **Detector 事件**：在诊断里记录 `SpeechDetector.results` 的到达次数（预期 0）；对比开/关 Detector 的识别质量和 CPU/耗电，决定它是否只作为内部 VAD gate。
5. **`fastResults` A/B**：保持 `.volatileResults`，分别开/关 `.fastResults`，统计假句界、final 延迟、预览流畅度；不要在无数据时直接去掉 fast。
6. **`audioTimeRange` 实验**：临时加 `.audioTimeRange`，记录 phrase 边界处 per-word range 是否显示真实停顿（社区说首词吸收停顿）。如果 per-word 也背靠背，说明只能靠静音/能量 VAD。
7. **长行 UI/翻译/预览**：确认 8–12 s 行在 pane 中不溢出、翻译质量不下降、TTS 不重复前缀；记录翻译 p50/p95 延迟；观察 F0 下 final 后的下一段 volatile 是否被投影丢弃、预览是否“跳一下”。
8. **中文/日文**：无空格语言的拼接、句号/问号、cap 字符数；确认不会因为合并产生缺空格或伪造词。
9. **双路回归**：同传双路和面对面双路各跑一轮，确认 `.strict` 纯度、语言切换、name swap 不受影响。

### 7.4 验收标准

- 本次样本稳定一行、一条翻译；同类假拆分显著下降。
- 假合并不劣于基线；不允许为了减少拆分而把明显的长停顿合并。
- 无文本丢失：每行的 phrase 文本按顺序完整保留；`verify-utterance-identity` 绿。
- 翻译 p95 延迟有记录且可接受；TTS 不重复已读前缀。
- 真机上 `SpeechDetector` 的行为有明确记录（是内部 gate 还是完全无效）。

## 8. 未决问题与真机验证

1. **result 级 `range` 是否暴露真实停顿？** 社区报告 per-word ranges 背靠背、首词吸收停顿；如果 result 级也如此，0.75 s gap 会漏掉真实停顿。需要停顿阶梯实验；必要时改用 app 侧 PCM 能量 VAD（不引入第三方依赖）。
2. **静音计时器是“无 ASR 结果”而不是“无语音”。** ASR 在连续说话时也可能 >1.1 s 不出结果；当前 `finalize(through:)` + 350 ms 可能把长句中间切开。需要测量实际 result 间隔，决定是否调大阈值或加能量 VAD。
3. **`SpeechDetector` 是否只作为内部 VAD gate？** 文档说 `results` 为空 [S14][S15]，论坛 Apple_Agent 也确认只报错 [C1]；但 Detector 仍可能影响识别/省电。需要开/关 A/B，不能假设它提供了 `speechDetected`。
4. **`fastResults` 是否加剧假句界？** 没有官方文档把 fast 与 phrase 边界关联；只能真机 A/B。关闭 fast 可能减少碎片，但会增加预览延迟。
5. **`SpeechTranscriber` 的标点是否稳定？** Apple 没有为 `SpeechTranscriber` 文档化 punctuation 选项；实际输出有句号，但社区有人报告标点不可靠。不要把标点当作语义事实。
6. **`isFinal` 语义选 F0 还是 F1？** F0 改动小，但会出现“第一段 final 翻译短暂显示、随后被完整句翻译替换”；F1 更干净，但要改投影/翻译/TTS 的 final 时序，并解决“一次 ingest 只能返回一个 `Utterance?`”导致的旧行 final 发布问题（需要队列/返回数组/引擎 drain）。F1 不是首修，需要产品决定“早翻译”与“少假 final”的优先级。
7. **cap 取值**：12 s / 120 字符只是起点；需要按语言、TED 语速、pane 高度和翻译 p95 校准。
8. **iOS 26.4 与 27.x 差异**：本机 SDK 是 27.1；真机系统版本需在验证时记录（现有面对面研究记录为 iOS 27.2.1）。`SpeechDetector` conformance 和结果行为可能随版本变化，发布目标 iOS 26.4 需要单独验证。
9. **长行翻译质量**：一行两句是否真的比两行两句翻译更好？需要用本次 TED 片段做人工评分，而不是只假设“上下文更多一定更好”。
10. **UI 行高/滚动**：合并后行可能更长；需要真机看 pane 的 live + 3 条历史窗口是否仍然可读。
11. **gap 关闭时仍有 volatile 尾部**：现有 gap 路径会 `closeCurrentRangeRow` + `beginNextUtterance`；如果旧行还有 volatile，是否有 final 发布、投影会不会留下一个非 final 行？这是既有行为，本次不改，但实现 cap/R1 时要避免新增同类问题，真机/单测确认。
12. **一行内的假句号是否仍影响翻译**：合并后 `The shame of not believing. We deserve it.` 仍有一个内部句号；`TranslationSession` 可能按标点分句，但同一请求能看到完整上下文。若真机译文仍被切断，再评估 display-only 的标点归一化（例如把内部句号作为软分隔显示），不改 identity、不新增语义内容；不要默认删除 ASR 标点。

### 8.1 夹具回归：短句内容被合并吞掉（2026-11-27）

**触发**：main（含 #89 的 R0/R1/cap）跑 `tools/fixture-run.sh` 全量 785 s。夹具 sha256 与旧跑相同（`e3cde4b4…`），所以差异来自代码/运行，不是夹具。结果：

| 指标 | 旧跑（参照） | main（R0/R1） | 变化 |
| --- | ---: | ---: | ---: |
| final rows | 158 | 91 | −67 |
| 源文覆盖 | 93.33% | 90.44% | −2.89pp |
| 精确匹配 / WER | 91.70% / 8.87% | 89.06% / 11.07% | −2.64pp / +2.20pp |
| final applied | 177 | 155 | 全部应用 |
| revision finals | 18 | 72 | ×4 |

行身份方向是对的（连续 final 合并成长行，短句不再各自成行），但一批独立短句在最终文字稿中消失，例如 `She'll perform better.`、`She'll perform worse.`、`white men perform better.`、`We'll call him Ben.`、`Headset off.`。这不是“合并后语义仍在”的合句，而是内容丢失。

**首行的确定性事件序列（已证）**：

| 时刻 | 事件 | range（s） | 文本长度 | 说明 |
| --- | --- | --- | ---: | --- |
| 14:11:05.2 | volatile | 0–4.949 | 61 | `Highlight an Asian woman's… math test?` |
| 14:11:06.5 | final | 0.18–3.96 | 61 | 第一句 final |
| 14:11:06.5 | late volatile | 3.96–5.226 | 4→23 | `She'll perform better.` 的预览 |
| 14:11:08.2 | final | 4.14–5.88 | 23 | `She'll perform better.` |
| 14:11:11.1 | volatile | 5.88–9.749 | 31 | `Highlight her female identity.` |
| 14:11:12.0 | final | 6.24–8.76 | 31 | 第二句 final |
| 14:11:12.0 | late volatile | 8.76–10.78 | 21 | `She'll perform worse.` 的预览 |
| 14:11:12.9 | final | 8.76–9.78 | 21 | `She'll perform worse.` |
| 14:11:18.3 | final | 11.04–16.44 | 86 | `Lead a group of men…` |

根因链：

1. `apply` 把 volatile 与 final 合并时，把 finalized phrase 的 range 写成 `volatile.range.union(final.range)`。volatile 的 range 是“正在看的音频窗口”，常常比它的文本多出一截（0–4.949 的文本只覆盖到约 4.0 s）。
2. 第一句 finalized phrase 因此宣称覆盖 0–4.949，而不是 final 的 0.18–3.96。
3. 下一个短句的 volatile（3.96–5.226）和 final（4.14–5.88）都与这个膨胀 range 重叠，`apply` 的第一分支把它们当成“已 final phrase 的修订”。
4. `preferredPhraseText` 的“更长者胜”把 61 字的第一句留下，把 23 字的短句丢掉；短句的音频被永久划给第一句，后续结果也无法补回。
5. 第二个短句（8.76–9.78）与 `Highlight her female identity.` 的膨胀 range（5.88–9.749）重复同一模式，再丢一次。最终行只剩 61+31+86 三句，正是 store 中 178 字的第 0 行。

旧跑之所以没有暴露：标点关行让每个短句 final 在到达时成为独立 ID/独立行，膨胀 range 不会跨 ID 吞并。该问题在 range-aware 组装（PR #84/#87）里已经潜伏，#89 删除标点关行后第一次完整暴露；不是 #89 新增的 range union 代码，而是 #89 让它可见。

**第二个丢失路径（同样已证）**：gap/language/name swap/cap 关行时，旧行可能还有 open volatile；旧实现只把 state 放进 `closedRanges` 历史，随后 `beginNextUtterance` 清空，不发布任何 final。文字稿只存 final，于是这段文字在屏幕上出现过、却永远不进入 store。单元测试 `gapClosePublishesOpenVolatile` 在修复前会看到 `takePendingFinals()` 为空；新实现由 `queueFinalForBoundary` 生成旧行 final，引擎在发布新行前 drain。这个路径与 range 膨胀是独立的两个洞：前者丢“行尾还没等到 final 的预览”，后者丢“被膨胀 range 误判为 revision 的 final”。旧跑里 `silence.`、`How would you interpret this?`、`I still have ropes.` 这类独立短句的消失，形态更像这个路径；需要全量 A/B 逐条确认，不能全部归因。

**修复不变量**（`UtteranceAssembler`，2026-11-27）：

1. **finalized phrase 的 range 必须紧贴产生它的 final**：即使保留“比 final 更全的 volatile 文本”，也不把 volatile 的 speculative tail union 进 phrase；文本可以比 range 长，但 range 不能替文本宣称新音频。
2. **只有同一 phrase 的文本才能合并**：包含关系或 `SpokenText.isRefinement`；不同文本只有在 **same audio window** 且 final 覆盖该窗口时才替换为 final（同音频误听纠正），否则按 range 顺序同时保留，绝不使用“更长者胜”丢掉一段。
3. volatile 与 final/volatile 合并前要求 **same audio window**（重叠 ≥ 较短 range 的 50%）或文本包含；只有 padding 重叠不算同一 phrase。同一 audio window 内文本不同（`I scream` vs `ice cream`、`oh` vs `Okay`）是纠正，保留 final，不把两种拼写都放进字幕。
4. 新 phrase 到达前，旧 volatile 的尾端 **bounded 到新 range 的 start**，防止 speculative tail 吞下一句。
5. finalized phrases 按 range 排序拼接；gap 检测用所有 phrase 的最大 end，不再依赖数组最后一项。
6. **关行不能只关闭状态**：只要旧行还有 open volatile 或最终文本尚未发布，先 `queueFinalForBoundary` 生成 final；引擎在发布新行前 drain，保证旧行文字进入投影/文字稿。

**验证**：

- 新增确定性回归（`UtteranceAssemblerRangeTests`）：`shortFinalBetweenLongPhrasesSurvives`（完整首行序列）、`disjointFinalsWithOverlappingRangesSurvive`、`similarConsecutiveFinalsWithPaddedOverlapSurvive`、`distinctFinalInsidePartialVolatileKeepsBoth`、`sameAudioMishearingReplaced`、`shortSameAudioCorrectionReplacesPreview`、`volatilePaddingDoesNotReplaceNextFinal`、`outOfOrderFinalKeepsAudioOrder`、`containedDisjointFinalIsAuthoritative`、`gapClosePublishesOpenVolatile`、`gapClosePublishesPrefixAndVolatile`。
- 单元：范围测试 63 条（含 `shortFinalInsideLongVolatileKeepsPreview`、`shortFinalCannotTruncateLongVolatile`）；全量 561 logical / 596 expanded，0 failed，0 skipped；`verify-utterance-identity` clean。关键回归用精确文本断言，不只 `.contains`，避免“同时保留误听和纠正”也通过。
- 真机夹具（同一音频起点）：

| 运行 | 行数 | 覆盖 | 精确 | WER | 空译/乱码/前缀重复 | final p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 旧跑（标点关行参照） | 158 | 93.33% | 91.70% | 8.87% | 0 / 0 / 0 | 61.3 ms |
| R0/R1 基线（问题跑） | 91 | 90.44% | 89.06% | 11.07% | 0 / 0 / 0 | 99.4 ms |
| 内容保留修复，全量 13 min（pending final 之前） | 85 | **97.92%** | 96.73% | 3.46% | 0 / 0 / 0 | 94.9 ms |
| 内容保留 + pending final，全量 13 min（边界硬化前） | 82 | **98.99%** | 97.92% | 2.45% | 0 / 0 / 0 | 91.3 ms |
| 上述 + reviewer 边界修复，180 s | 17 | **98.98%** | 96.68% | 3.32% | 0 / 0 / 0 | 153.1 ms |
| 上述 + reviewer 边界修复，全量 13 min（row 82 修复前） | 84 | **98.81%** | 97.48% | 2.64% | 0 / 0 / 0 | 100.5 ms |
| 上述 + row 82 修复，全量 13 min（2026-11-28） | 85 | **99.43%** | **97.99%** | **2.08%** | 0 / 0 / 0 | 94.4 ms |

- 全量中间跑的第 0 行包含 `She'll perform better.` 和 `She'll perform worse.`；180 s 边界硬化跑第 10 行把 `It's the shame we carry. The shame of not believing we deserve it.` 保持为一行，第 13 行包含 `we'll call him Ben.`，第 14 行包含 `How would you interpret this?`。这些都是旧问题跑丢失、修复后恢复的短句。全量边界硬化前跑 82 行、覆盖 98.99%、WER 2.45%；全量边界硬化后 84 行、覆盖 98.81%、WER 2.64%（row 82 修复前）；两次都是 0 空译/0 U+FFFD/0 前缀重复/0 行内重复。
- 残余漏词主要是 ASR：`white men perform better.` 在两次运行里都只识别成 `perform better.`（final 文本本身缺少主语）；`The shame…` 的 180 s 跑恢复完整，但全量中间跑仍受 ASR 变体影响。全量边界硬化跑里，`called Design Thinking Boot Camp` 被识别成 `called Design thinkinging Boot Camp`，`Recent graduates of kindergarten` 被识别成 `Recent graduates. of, of kindergarten`；`Fernando` 已在第 59 行正确出现。短句门限会把后两者标成 missing，需要按“ASR 表面变体”和“真漏词”分流，不能直接归因组装器。不要用组装器规则去补 ASR 没给的词。
- 全量中间跑有 2 次 `corruptedOutput`（同一行 47，`I was astounded, proud, liberated, and confused.`），完整性闸门保留了更早的 preview 译文（结尾停在“解放了，”）；旧跑在同一段文本也有 2 次损坏。这是 TranslationSession 的可靠性问题，不是行合并新引入的。
- row 82 修复后的 13 min A/B 见 `.device-state/fixture-runs/row82-fix-full-1/`（不提交）：85 行、覆盖 99.43%、精确 97.99%、WER 2.08%、requiredCues 10/10、短句 42/45、0 空译/0 U+FFFD/0 前缀重复、2 次 `corruptedOutput`（row 47 preview/final，store 保留的 preview 译文完整）、final p95 94.4 ms。`fix-full-edge` 是 row 82 修复前的 84 行版本，`fix-full-final` 是边界硬化前的 pending-final 版本。验收必须看“短句/required cue 是否保留”与相对基线，不以 `--min-coverage 0.90` 的 PASS 作为质量签收。

**翻译效果**：第 0 行的新译文包含恢复的两句；旧跑同段短句各自有译文。当前证据支持“这一轮译文变差主要是源文被吞”的下游结果，而不是翻译模块单独回退：155 个 final job 全部应用、无空译/U+FFFD/前缀重复。但 84 行语义评审仍发现 5 critical/16 major（含 row 82 组装器丢句和 `big one`/`working to break`/`and confused` 等翻译层错误），所以只能结论“本次回归不是翻译模块新引入”，不能结论“翻译语义质量已通过”。详见 §8.2。

**仍未解决（不要混入本修复）**：

- row 82 的 `There is the life that you can be living.` 已由 `sameVolatilePhrase`/`shouldReplaceSameAudio` 修复，但修复后尚未重跑 13 min 真机夹具；`requiredCues` canary 已能抓住修复前版本。
- ASR final 自身可能漏词：40 s 跑的第 1 行 final 以 `perform better.` 开头，`white men` 在 volatile/final 文本里就没有出现；组装器不能凭空补回。归 P1-3。
- “final 与已有 phrase 在同一音频窗口内、但文本完全不同”仍按 final authoritative 替换；这是同音频误听纠正的取舍（reviewer 的 `Headset off.` 案例已改为 tight range，不再由 speculative tail 触发替换），需更多真机样本校准。
- 乱序/重复 final 的插入顺序已按 range 排序；same-audio 纠正不再拆成两句，但只有 padding 重叠、文本又不同时仍可能重复而非丢失。
- 长行 cap 只在无 volatile 的 phrase 边界触发；连续 volatile 可暂时超过 12 s/120 字，需观察翻译 p95 和 pane 高度。
- 双 locale 的 `preemptsIfNeeded` 仍会在语言抢占时移除原语言 state，没有 pending final；reviewer 已用 `They also cause us` + 中文 final 复现，单路夹具不覆盖。这是 pre-existing 的 crosstalk/路由取舍，需要面对面双路 A/B 决定是否改为关旧行/发 final。
- 关闭 range 的 late volatile 若没有扩展，仍被忽略；如果它含有未发布的新词，旧行只保留旧文本，内容可能丢失。这是 closed-row 修订策略的残余风险，需要专门样本。
- pending final 在 gap 边界如果 volatile 文本已经包含了下一句（preview 跨越停顿），可能和新行重复；全量夹具要检查行内/相邻重复。
- 夹具 0.90 门限仍是健全性检查；2026-11-28 已加相对基线与 ≤5 词短句保留门（`tools/fixtures/ted-baseline.json`、`tools/fixture-score.py`、`tools/fixture-run.sh`）。91 行问题跑会在覆盖/精确/WER/短句四项全部失败，`fix-full-final` 的 `For four days, silence.` 缺失也会被短句门限拦下。该门限是机械回归检查，不是语义签收。

### 8.2 语义评审与 row 82 丢句修复（2026-11-28）

对 `fix-full-edge` 的 84 行做了逐行 LLM 语义评审（source vs translation vs TED ground truth；这是筛查，不是人工签收；完整表见 [`fixture-semantic-review-2026-11-28.md`](fixture-semantic-review-2026-11-28.md)）：

- 5 个 critical：row 0/1（`white men` 不在源文，ASR 侧）、row 33（`It seems a big one.` → “这看起来是个大人物。”）、row 66（`I'm working to break.` → “我正在努力休息。”）、row 67（`myself of the marshmallow challenge` → “我自己挑战棉花糖”）、row 82（组装器丢句，见下）。row 82 已在代码中修复，修复后剩余 4 个 critical 均为 ASR/翻译层；设备复跑前不更新评审计数。
- 16 个 major、38 个 minor、25 行无问题；24 行源文缺陷中 23 行归 ASR，1 行归组装器（row 82）。剩余翻译错误包括 `big one`、`working to break`、`and confused` 缺失、`pastor`/`got the best of him`、`ping ponging` 直译等；旧跑同段已存在，不是本次修复新引入。
- **row 82 的组装器根因已复现并修复**：41 字符 volatile `There is the life that you can be living.` 的 range 为 766.912–770.859；下一句 `If you break your ropes.` 的首个 volatile 片段 `you` 出现在 769.912，落在旧 volatile 的 padding 尾部。旧逻辑用 `sameAudioWindow` + 文本包含把 `you` 当成同一 phrase 的修订，覆盖了 41 字符 preview；最终 row 82 只剩前后两句。另一个同源路径是短 final（8 字符）在长 volatile 的同一音频窗口内通过 `shouldReplaceSameAudio` 的起始位置检查，把长 preview 截断。
- 修复：`sameVolatilePhrase` 要求新 volatile 的 start 仍在旧 phrase 的 `max(0.5 s, 25% duration)` 内才允许原地更新；`shouldReplaceSameAudio` 在 incoming 文本不足 existing 一半时拒绝替换，保留 preview 并插入 final。回归 `shortFinalInsideLongVolatileKeepsPreview`、`shortFinalCannotTruncateLongVolatile`；独立 Swift 断言复现 row 82 修复且 `I scream→ice cream`、`oh→Okay` 仍替换；`verify-utterance-identity` clean。
- 短句门限抓不到 row 82，因为该 clause 是 8 词；`tools/fixtures/ted-baseline.json` 因此增加了 `requiredCues` canary（含 `there is the life that you can be living if you break your ropes.`、silence、Ben、Headset off、I still have ropes 等）。用修复前的 `fix-full-edge` 计分时 `requiredCueMissing` 正好是该 clause，门限会失败；这是先验证门限能抓住已知回归，不是修复后的设备结果。
- **已验证**：2026-11-28 含修复的 13 min 夹具 `row82-fix-full-1` 为 85 行、覆盖 99.43%、精确 97.99%、WER 2.08%、requiredCues 10/10、短句 42/45、0 行内重复；row 83 已包含 `There is the life that you can be living.`。修复前的 `fix-full-edge` 84 行/98.81% 仍保留为对照。该 LLM 评审的 critical/major 仍需人工抽样校准，不能单独作为 P1-1 签收。

### 8.3 ASR 归因（P1-3 输入，2026-11-28）

逐行评审把 24 行源文缺陷拆成 23 ASR + 1 组装器（row 82）。按是否改变意思分层：

| 类型 | 行 | 证据 | 归因 |
| --- | --- | --- | --- |
| 漏词/误听改变意思 | 0/1 | `white men perform better.` 不在源文，row 1 以 `perform better.` 开头；行 0–4 的 ASR 事件已被 4096 ring 淘汰，无法证明事件层，但三次全量跑都缺 | 可能 ASR，非组装器；不能补写 |
| 漏词/误听改变意思 | 17 | `she's afraid` → `he's afraid` | ASR |
| 漏词/误听改变意思 | 21 | `he's feeling` → `you's feeling` | ASR |
| 漏词/误听改变意思 | 22 | `invite him` → `invite them` | ASR |
| 漏词/误听改变意思 | 24 | `past relationship` → `pastor relationship` | ASR |
| 漏词/误听改变意思 | 43 | `designs` → `Dess` | ASR |
| 漏词/误听改变意思 | 67 | `I remind` 缺失 | ASR；该行 volatile 最长 36 字符，正好等于保留文本 |
| 漏词/误听改变意思 | 81 | `yours to break` → `yours to bring` | ASR |
| 表面变体（内容仍可懂） | 7/8/38/63/71/73/83 | Rushell/Russell、Yuknovic/Yuknavitch、thinkinging/Thinking、TedED/TED、`of, of`、kindergartners、`until` 缺失 | ASR，不改变主旨 |
| 组装器 | 82 | 41 字符 volatile 有 range、无 final，store 只剩前后两句；见 §8.2 | 已修复，待真机复跑 |

`Fernando` 在 `fix-full-edge` row 59 已正确出现，此前“for Nando”没有在该跑复现。P1-3 的下一步不是组装器补词，而是同一夹具 A/B：`.fastResults` 去留、`AnalysisContext.contextualStrings`（Cameron Russell、Lidia Yuknavitch、Fernando、Ben、TED、Design Thinking 等）与 `transcriptionConfidence` 诊断；任何低置信度丢 final 都不应默认开启。完整逐行 SD-A 标注见 [`fixture-semantic-review-2026-11-28.md`](fixture-semantic-review-2026-11-28.md)。

## 9. 引用

> 所有 Apple 文档/WWDC 链接于 2026-11-27 访问。社区来源单独标注，不能当作 API 规范。

### 9.1 Apple 一手资料

| 编号 | 来源 | 关键内容 |
| --- | --- | --- |
| S1 | [SpeechTranscriber.Result — Apple Developer Documentation](https://developer.apple.com/documentation/speech/speechtranscriber/result) | phrase/passage；volatile 迭代；`text`/`alternatives`/`range`/`isFinal`/`resultsFinalizationTime` |
| S2 | [isFinal — SpeechModuleResult](https://developer.apple.com/documentation/speech/speechmoduleresult/isfinal) | per-range finality；false 不保证重发 final；等价于 `resultsFinalizationTime >= range.end` |
| S3 | [resultsFinalizationTime — SpeechModuleResult](https://developer.apple.com/documentation/speech/speechmoduleresult/resultsfinalizationtime) | 已定稿水位；先前 range 也 final |
| S4 | [range — SpeechModuleResult](https://developer.apple.com/documentation/speech/speechmoduleresult/range) | “The audio input range that this result applies to.” |
| S5 | [SpeechTranscriber.ReportingOption](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption) | volatile/fast/alternatives 的原文 |
| S6 | [SpeechTranscriber.ResultAttributeOption](https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption) | audioTimeRange / transcriptionConfidence |
| S7 | [SpeechTranscriber.TranscriptionOption](https://developer.apple.com/documentation/speech/speechtranscriber/transcriptionoption) | 只有 etiquetteReplacements |
| S8 | [SpeechTranscriber.Preset](https://developer.apple.com/documentation/speech/speechtranscriber/preset) | 五种预设及 volatile/fast/alternatives/audioTimeRange 表 |
| S9 | [finalize(through:) — SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer/finalize(through:)) | flush 语义；nil 的含义；返回时 final 已发布但 app 可能未消费 |
| S10 | [volatileRange — SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer/volatilerange) | range 内可能变；range 外可安全合并；包含 pending analyses |
| S11 | [setVolatileRangeChangedHandler(_:) — SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer/setvolatilerangechangedhandler(_:)) | 响应 finalization 首选 `resultsFinalizationTime` |
| S12 | [AnalysisContext — Speech](https://developer.apple.com/documentation/speech/analysiscontext) | contextualStrings 是词表偏置；userData 是 app 自定义 |
| S13 | [SpeechDetector — Speech](https://developer.apple.com/documentation/speech/speechdetector) | VAD 模块；只与 transcriber 配合；有精度/省电权衡 |
| S14 | [results — SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector/results) | “may throw an error, but will otherwise remain empty” |
| S15 | [SpeechDetector.Result](https://developer.apple.com/documentation/speech/speechdetector/result) | 当前只支持 VAD 错误处理 |
| S16 | [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber) | 类似系统听写、兼容旧设备；与 SpeechTranscriber 不同模块 |
| S17 | [DictationTranscriber.TranscriptionOption.punctuation](https://developer.apple.com/documentation/speech/dictationtranscriber/transcriptionoption/punctuation) | 自动加标点；省略时只转写口述标点 |
| S18 | [Bring advanced speech-to-text to your app with SpeechAnalyzer — WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/) | result 是 audio segment；final/volatile 消费模式；示例 app 自己 break up sentences；结束时 finalize |
| S19 | [Recognizing speech in live audio — Apple sample code](https://developer.apple.com/documentation/speech/recognizing-speech-in-live-audio) | transcriber 不累积整体文本；按 audio time range 替换；final/volatile 两段式 |
| S20 | [SFSpeechRecognitionResult](https://developer.apple.com/documentation/speech/sfspeechrecognitionresult) | 旧框架 partial/final；isFinal 表示请求完成 |
| S21 | [SFTranscription](https://developer.apple.com/documentation/speech/sftranscription) | utterance = 词或词组，不是句子 |
| S22 | [SFTranscriptionSegment](https://developer.apple.com/documentation/speech/sftranscriptionsegment) | timestamp/duration/confidence 是 segment 级 |
| S23 | [SFSpeechRecognitionMetadata](https://developer.apple.com/documentation/speech/sfspeechrecognitionmetadata) | speechStartTimestamp / speechDuration / averagePauseDuration |
| S24 | [NLTokenizer](https://developer.apple.com/documentation/naturallanguage/nltokenizer) / [NLTokenUnit.sentence](https://developer.apple.com/documentation/naturallanguage/nltokenunit/sentence) | 文本句子 tokenization；只处理已有文本 |
| S25 | [NLTagger](https://developer.apple.com/documentation/naturallanguage/nltagger) | paragraph/sentence/word 级文本分段 |
| S26 | [TranslationSession](https://developer.apple.com/documentation/translation/translationsession) | 逐条/批量翻译；无上下文参数 |
| S27 | [TranslationSession.Request](https://developer.apple.com/documentation/translation/translationsession/request) | 只有 sourceText/clientIdentifier |

### 9.2 社区/论坛（非官方）

| 编号 | 来源 | 关键内容 | 可信度 |
| --- | --- | --- | --- |
| C1 | [Apple Developer Forums 794439 — “There's wrong with speech detector ios26”](https://developer.apple.com/forums/thread/794439) | Apple_Agent：`SpeechDetector` 只在出错时给 result；开发者实测 `detector.results` 无输出；DTS 提到早期 beta 需 retroactive conformance | 论坛官方回复，时间限于 beta；需真机复核 |
| C2 | [Apple Developer Forums 794720 — “SpeechTranscriber/SpeechAnalyzer being relatively slow...”](https://developer.apple.com/forums/thread/794720) | final 延迟 avg 2.2 s；prepareToAnalyze 后 avg 1.45 s；开发者建议在 volatile 稳定时提前触发下游 | 用户测量，非 Apple 规范 |
| C3 | [Apple Developer Forums 731761 — “SFSpeechRecognitionResult discards previous transcripts...”](https://developer.apple.com/forums/thread/731761) | iOS 17/18 on-device 停顿后清空 transcript；isFinal 仍 false；用 segment timestamp/confidence 做代理 | 多个用户复现，旧框架 |
| C4 | [Stack Overflow 42530634 — “SFSpeechRecognizer - detect end of utterance”](https://stackoverflow.com/questions/42530634/sfspeechrecognizer-detect-end-of-utterance) | isFinal 不在停止说话时变 true；2 s 静音 timer；confidence/metadata 代理 | 社区高票答案，旧框架 |
| C5 | [Stack Overflow 79005416 — “SFSpeechRecognitionResult discards previous transcripts when making long pauses”](https://stackoverflow.com/questions/79005416/sfspeechrecognitionresult-discards-previous-transcripts-when-making-long-pauses) | 用首 segment confidence + speechStartTimestamp 拼接 final partial | 社区 workaround |
| C6 | [On-Device Video Captions with SpeechAnalyzer on iOS 26 — DEV Community](https://dev.to/deskfox/on-device-video-captions-with-speechanalyzer-on-ios-26-what-worked-and-what-didnt-2g65) | result 约一个 phrase；per-word ranges 背靠背；停顿被首词吸收；标点从 script 取；DictationTranscriber 标点更慢更差 | 工程博客，需真机复核 |
| C7 | [iOS 26's SpeechAnalyzer on a live mic: the 5 things the docs don't tell you — DEV Community](https://dev.to/simple_memo/ios-26s-speechanalyzer-on-a-live-mic-the-5-things-the-docs-dont-tell-you-2ng5) | volatile 变暗、final 替换、只持久化 final；未讨论 endpointing | 工程博客 |
| C8 | [WWDC 2025 session 277 transcript index — nonstrict.eu](https://nonstrict.eu/wwdcindex/wwdc2025/277/) | 与 S18 相同的 transcript，便于检索 | 第三方 transcript，非官方 |

### 9.3 本机 SDK

- `/Volumes/DevDisk/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface`（iOS 27.1 SDK，2026-11-27 核对）。用于确认 `SpeechTranscriber` / `SpeechAnalyzer` / `SpeechDetector` 的公开 API 表面没有句界/段落/标点控制。

## 10. 关联

- D8 utterance identity：[`docs/decisions.md`](../decisions.md) D8。
- 当前组装契约：[`docs/02-architecture.md`](../02-architecture.md) §4.2、§4.3。
- Services 约束：[`Duiyi/Services/AGENTS.md`](../../Duiyi/Services/AGENTS.md) §1。
- D8 有界穷举验证：[`.claude/skills/verify-utterance-identity/SKILL.md`](../../.claude/skills/verify-utterance-identity/SKILL.md)、[`tools/verify-utterance-identity.sh`](../../tools/verify-utterance-identity.sh)。
- 相关研究：[`docs/research/simultaneous-translation-quality.md`](simultaneous-translation-quality.md)、[`docs/research/face-to-face-dual-locale-quality.md`](face-to-face-dual-locale-quality.md)。
- 本次样本的 range 组装回归背景：PR #84 / #87 / #88（range-aware 组装、ellipsis 续句、ellipsis range 连续）。
