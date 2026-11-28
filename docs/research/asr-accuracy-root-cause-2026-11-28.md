# ASR 准确率根因与安全方案（P1-3 / P1-1，2026-11-28）

> 状态：研究结论与实施计划；不是 P1-3/P1-1 签收。Apple API 结论来自本机 iOS 27.1 SDK 与官方 DocC/论坛；夹具结论只适用于同一 WAV / iPhone 13 / 当前 OS，不外推为 API 语义。
>
> 相关决策：[D9/D10](../decisions.md)；夹具研究：[speech-transcriber-segmentation.md](speech-transcriber-segmentation.md) §8.4；语义评审：[fixture-semantic-review-2026-11-28.md](fixture-semantic-review-2026-11-28.md)。
>
> 实施状态（2026-11-28）：run-meta、ASR confidence 只读诊断、fixture-only raw ASR dump 已实现并在 iPhone 13 验证（raw dump 132 行，含 text/alternatives/confidence；拉取后设备文件为 0 字节）。30 s raw dump 的所有 final 文本里没有 `white men`，transcript 从 `perform better` 开始，直接证明这是 ASR 漏词而不是组装器丢句。assembler `dropReason`/`speech.preemption`/`speech.start` 诊断与 canary 归因已实现；`preemption-publish` DEBUG A/B 在双 locale Conversation 夹具上复现并验证 incumbent final 保留（§6）。用户术语表、alternatives 选词、closed-range 改造仍待实施。

## 0. 结论摘要

1. **专名错误发生在 ASR final 内部，组装器无法修。** Cameron/Lidia 的错拼在同一段音频、同一 187 字符 final 中随机切换（Rushell/Russell、Yuknovich/Yuknovic/Yuchnitz）；GT 的 `Lidia Yuknavitch` 从未出现。
2. **`contextualStrings` 不是 SpeechTranscriber 的修复。** Apple DocC 只把词表偏置写给 `DictationTranscriber`；Apple 工程师在论坛 811083 明确 `SpeechTranscriber` 当前不消费 `contextualStrings`。我们的 context A/B 因此是 **no-op + ASR 随机波动**，不能据此声称偏置有效；D10 不默认启用。
3. **`white men` 是 fast 模式 phrase 起始漏词；`Design thinkinging` 是 fast 相关解码口吃。** no-fast 能恢复部分词，但 40→73 行、覆盖 98.35→95.67%、WER 3.82→7.38%，D9 继续保留 fast。
4. **`days` / `life` 是随机 final 文本丢失。** 96 s row 82 片段两次都能完整识别；full run 同配置可漏。组装器只能存 ASR 给出的文本，不能补词。
5. **P1-1 仍有两个未签收风险：** 双 locale 抢占会丢 incumbent 的 open volatile；closed-range late volatile 路径未覆盖。二者都只能先诊断，不能无条件改。
6. **当前证据不足以区分 ASR miss / 表面变体 / 组装器丢句。** full run diagnostics 已丢 453–507 条早期事件，`white men` 在约 16 s 不可恢复；必须先补 fixture-only raw ASR 证据包。

## 1. 根因分层

| 问题 | 根因 | 证据 | 置信度 |
| --- | --- | --- | --- |
| Cameron/Lidia 专名错 | ASR final 内部解码；SpeechTranscriber 无 Apple 支持的词表/custom LM API；contextualStrings 对它 no-op | 同 187 字符 final，range 78.777–78.82 s；row 7 Rushell/Russell 切换；row 8 Yuknovich/Yuknovic/Yuchnitz；DocC + 论坛 811083 + SDK 无 contentHints | high（ASR 定位）；medium（未来 OS 是否仍 no-op） |
| `white men` 缺失 | fast 模式 phrase 起始漏词 | A/A2b/C/C2 全 miss；fast final 从 16.62–16.64 s、7 字符开始，18.30 s 的 80 字符 final 不含该词；no-fast 从 15.42–15.45 s、5 字符开始，18.06 s 的 59 字符 final 含该词 | high |
| `Design thinkinging` | fast 相关解码口吃 | fast 四跑均为 thinkinging/Bootamp；no-fast 为 Design Thinking Boot Camp；组装器只插空格，不会生成重复 token | high |
| `days` / `life` 随机丢失 | SpeechTranscriber 在同一音频上的 phrase 边界/final 文本不确定 | A 145.97 s/2.98 s/43 chars vs A2b 145.98 s/5.16 s/52 chars；corruption-fallback-full-3 row 82 来自 118 字符 final 且缺 life；96 s row82 单 final 124 字符含完整 clause | high |
| P1-1 双 locale 抢占丢 volatile | `preemptsIfNeeded` 直接 remove/clear，不 queue final；且在 incumbent 不 confident 时也会抢占 | `UtteranceAssembler.swift` preemptsIfNeeded；现有 strict dual 测试只断言 winner | high（机制）；medium（频率） |
| P1-1 closed-range late volatile | 只接受“扩展 closed range + 新行为空”的 late volatile，否则丢弃；closed state 保留 tail，贸然续行可能重复 | `UtteranceAssembler.swift` late-volatile guard；夹具 rejected events 全是 final+scriptMismatch，0 rejected volatile | high（机制）；unquantified（影响） |
| 证据无法归因 | run 不记录 flags/commit；diagnostics 设计不写正文且 ring buffer 丢事件；requiredCues 不含名字 | `fixture-run.sh`；`duiyi-diagnostics.json` droppedEventCount；360 名称基线未提交 | high |

## 2. Apple API 事实（一手来源）

- `SpeechTranscriber.ReportingOption` 只有 `.volatileResults`、`.alternativeTranscriptions`、`.fastResults`。`fastResults` 官方定义为“faster but also less accurate”，机制是更小 context window（[fastResults](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption/fastresults)）。
- `Preset.progressiveTranscription` = volatile + fast；alternatives presets 不含 volatile/fast。MyBuddy 当前配置等价于 progressive + confidence；live + alternatives 不是 Apple 提供的 preset（[Preset](https://developer.apple.com/documentation/speech/speechtranscriber/preset)）。
- volatile 是同一 audio range 的预览；`isFinal == false` 不保证会重发 final；finality 等价于 `resultsFinalizationTime >= range.end`（[volatileResults](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption/volatileresults)、[isFinal](https://developer.apple.com/documentation/speech/speechmoduleresult/isfinal)）。
- `Result` 只有 range、resultsFinalizationTime、text、alternatives；没有句界/词界 API（[Result](https://developer.apple.com/documentation/speech/speechtranscriber/result)）。
- `alternatives` 按 likelihood 降序；`text` 是 `alternatives[0]`；数组非空但可能含空字符串（表示该音频无转写）；必须请求 `.alternativeTranscriptions`（[alternatives](https://developer.apple.com/documentation/speech/speechtranscriber/result/alternatives)）。
- `transcriptionConfidence` 不是 Result 字段，而是 AttributedString 的 `ConfidenceAttribute`（Double 0–1）；**没有逐候选 confidence，也没有内置选词器**（[ConfidenceAttribute](https://developer.apple.com/documentation/foundation/attributescopes/speechattributes/confidenceattribute)）。
- `AnalysisContext.contextualStrings` 文档只描述 `DictationTranscriber` 的识别偏置；Apple 工程师在 [thread 811083](https://developer.apple.com/forums/thread/811083) 明确 `SpeechTranscriber` 当前不消费。真正 Apple 支持的词表路径是 `DictationTranscriber` + `ContentHint.customizedLanguage` / `SFSpeechLanguageModel`（[DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)）。
- iOS/visionOS 约 2 个并发识别实例；双语已用 2 个 SpeechTranscriber，detector 曾触发资源回退；**不能加第三个 transcriber**（[setModules](https://developer.apple.com/documentation/speech/speechanalyzer/setmodules(_:))）。
- 本机 SDK 核对：`.../iPhoneOS.sdk/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface`（ReportingOption 377–380；Result 427–433；contextualStrings 484–497；ContentHint 91–95）。

## 3. 安全方案（按 benefit/cost）

### now（不改 Release 行为）

1. **夹具证据归因包**（run-meta/raw 已实现；dropReason 待实施）
   - `run-meta.json`：git commit/dirty、fixture sha、window/codec/pacing、ASR flags、baseline、app/toolchain；`--skip-build` 记录安装包来源。已实现。
   - fixture-only raw ASR dump：仅 `#if DEBUG` + `-duiyi.fixtureAudio` + 显式 `-duiyi.dumpASRText`；记录 language/isFinal/range/text/alternatives/confidence 聚合；accepted/published/utteranceID 通过同 range/time 的 diagnostics 关联。脚本拉回后用空文件覆盖设备文件，不提交正文、不进 DiagnosticsRecorder/上传。已实现并真机验证（132 行，设备文件 0 字节）。
   - assembler dropReason：purity/suppression/lateVolatileClosedRange/preemption/empty/punctuationOnly；只观察，不改变接受/发布/identity。待实施。
   - 价值：把每个 missing cue 归因为 ASR miss / 表面变体 / 组装器丢句；解决 full run ring buffer 丢早期事件后无法解释 `white men` 的问题。

2. **置信度只读诊断**（已实现并真机验证）
   - 读取 `ConfidenceAttribute`，聚合 runCount、字符加权 min/mean、0.1 分桶；缺失记 nil；只写聚合，不写正文。
   - confidence 永不参与 accept/publish/assembler/translation；不设 Release 阈值；不因低置信度丢 final。
   - 真机 30 s/96 s 片段已出现 `confidenceRunCount/Min/Mean/Buckets`；仅 final 事件带属性（132 条 ASR 中 8 条有 confidence）。
   - 先验证 run 粒度（phrase 还是词）；final 全量、volatile 可采样。

3. **在 assembler HEAD 重跑 `verify-utterance-identity` 并推进 SKILL sync commit**
   - 当前 SKILL 记录停在 `ef166ff`，assembler 已到 `40d9aa7`；先跑 text/range 两 pass，只有 corpus 仍覆盖当前行为才更新记录。任何 violation 当回归，不改测试让绿。

### next（opt-in/实验，需产品决策）

4. **canary 归因（已实现）**：保留 coverage/exact/WER/短句/重复/空译/U+FFFD 单跑硬门禁；`missingCueAttribution` 区分 ASR miss / 表面变体 / assembler loss，无 raw dump 时明确 `unavailable`。`nameCues` 已加入基线但保持非阻断；只有确定性机制 + held-out 证据后才进 requiredCues；ASR-dependent canary 可要求连续两跑，best-of 不用于内容缺失。
5. **用户术语表（opt-in）**：设置页 per-language canonical + aliases（≤100 条、1–4 token、无正则、不自动学习）；纯 `SpeechTextCanonicalizer` 在 **assembler 之后**按同一 Utterance.id 做最长整词/整短语替换，只改匹配 span，不插入/删除/改数字否定；Release 默认 off，需产品/隐私/存储决策；held-out 音频测误替换率。只改源文，不保证中文译名（TranslationSession 无术语 API）。
6. **alternativeTranscriptions final-only 选词**：默认 off；只对有用户术语表的 locale 开；候选必须非空、含 canonical/alias、匹配 span 外前后缀逐字相等、token 数不变；空候选视为无语音/撤销；不选不含术语的候选；volatile 永远 alternatives[0]；iPhone 13 单/双 locale 测 p95/资源，超预算回退。不改 fast/volatile/assembler identity。
7. **P1-1 抢占先诊断（已实现 DEBUG 实验）**：`speech.preemption` 诊断记录双方语言、长度、是否 confident、是否可见、是否 queue final、是否 applied，无正文；`-duiyi.assemblerPreemptionPublish YES` 下仅当 incumbent 有可见文本且 isConfident 时发布 visible final（`queueVisibleFinalForPreemption`）+ `closeCurrentRangeRow`，绝不 merge 到 challenger。双 locale Conversation 夹具 A/B 已证实 A 只剩非 final preview、B 保留 incumbent final（§6）；真实麦克风 A/B 见 §6.4/§7.6，已完成；D12 已把 Release 默认改为 B。

### later

8. **closed-range late volatile 只计数**：区分 same-range vs extending、row empty/live、carries tail vs new words；没有真实新词证据不放开策略；closed row 文本不可变。
9. **DictationTranscriber + 自定义 LM DEBUG spike**：唯一 Apple 支持的词表路径；独立路径、顺序换引擎、不并发第三 transcriber；held-out 音频对比 coverage/WER/专名/final p95/预览延迟/资源；Release 编译剔除。
10. **iOS 27.1 contextualStrings 复测**：论坛是 iOS 26 时期，不能断言未来无效；只有预注册 A/B、用户来源词表、独立复现才重开 D10；不拿 `userData` 当后门。

## 4. 不要做

- 不关闭 `.fastResults`、不提供用户开关（D9）；no-fast 40→73 行、WER 3.82→7.38 已证伪。
- 不默认启用 `contextualStrings`，不把它接到 SpeechTranscriber 当已生效修复，不拿 `AnalysisContext.userData` 当后门（D10）。
- 不加第三个 transcriber / 并行高精度流；`ignoresResourceLimits` 不进生产。
- 不按 `transcriptionConfidence` 丢弃或改选 final；不设 Release 阈值。
- 不用 assembler/LLM/模板补出 ASR 未给出的词；`white men`/`days`/`life` 缺失就显示缺失。
- 不在 assembler 之前改写 volatile+final 做术语替换；不做默认模糊/edit-distance；不自动从 transcript 学习；不把 `SpokenText.isRefinement` 当内容保持门禁。
- 不无条件把被抢占的 incumbent volatile 升为 final；不把 loser 文本并入 winner；无双 locale A/B 不改 preemption。
- 不在没有真实新词证据时放宽 closed-range late volatile；不重开/改写 settled row。
- 不因单跑 canary 红绿改组装器或签收；requiredCues 不加夹具专用名字；best-of 不用于内容缺失。
- 不把翻译层 critical（rows 33/66/67、row 48 corruptedOutput）归因 ASR/assembler，或据此改组装器。
- 不标记 P1-1/P1-3 完成；D9/D10 不是完成。
- 不用 raw ASR dump 写麦克风/上传/提交正文；不绕过 fixture-only 门禁与 run 后删除。

## 5. 残余风险

- 专名与随机漏词仍在；没有确定性 ASR 修复；用户术语表只修显式 alias，未列变体（Yuchnitz）仍错；只改源文，不保证中文译名。
- `contextualStrings` 结论有时效；iOS 27.1 可能已改变，需 held-out 复测；不能用当前 A/B 证明偏置有效。
- alternatives 可能不含正确名；live+fast+alternatives 非 Apple preset，CPU/延迟/资源未文档化；双语接近 2 instance 上限。
- ConfidenceAttribute 未标定、粒度可能为 phrase；只能诊断。
- 用户术语表引入 UI/存储/隐私/v1 冻结范围变更；误替换风险。
- 抢占发布 final 可能固化低置信/幻觉；closed-range 放宽可能重复 tail。
- raw dump 与 Services 的不写正文规则冲突，必须 fixture-only 例外、run 后删除。
- verify-utterance-identity sync commit 过期；未在 HEAD 重跑前 P1-1 不能签收。
- 翻译层剩余 critical（rows 33/66/67、row 48）仍在。

## 6. 实施与 A/B 结果（2026-11-28）

### 6.1 已落地

- `UtteranceAssembler` 只读诊断：`SpeechDropEvent`（empty/punctuationOnly/purity/suppression/lateVolatileClosedRange/preemption）与 `SpeechPreemptionEvent`（incumbent utteranceID/双方语言/长度/confident/visible/queuedFinal/applied）。引擎写 `asr.drop` / `speech.preemption` / `speech.start`（requested/active/usingDual）；事件不含正文，不参与接受/发布/identity。
- `fixture-score.py`：`missingCueAttribution` 用 raw final 区分 `assemblerLoss` / `surfaceVariant` / `asrMiss`；无 raw dump 时 `unavailable`。`nameCues` 非阻断。
- `tools/fixture-run.sh`：`--module conversation`、`--user-language`/`--peer-language`、`--preemption-publish`；自动把 `asr-raw.jsonl` 传给 scorer。
- 单测 575 logical/610 expanded，0 failed/0 skipped；`verify-utterance-identity` 在文本/range 两 pass 均 clean；`check-static.sh` PASS。

### 6.2 双 locale 抢占 A/B

夹具：1 s 英文（截断）+ 日语 TTS，`ConversationViewModel` 自动双 locale（english/japanese），真实 ASR/assembler/翻译/落库，仅音频采集替换。用 en/ja 而非 zh/en 是因为中文 transcriber 会把英文 hallucination 与后续中文拼在同一 strict 结果里，常被 purity 拒绝而进不到抢占；en/ja 能在英文 open volatile 后产生可 preempt 的日文 challenger。A/B 只切 `-duiyi.assemblerPreemptionPublish`。

| 臂 | run | appFinalRows | preemption applied/queued | 结果 |
| --- | --- | --- | --- | --- |
| A（no） | `p11-preempt-ja-a-3`、`p11-preempt-ja-a-4` | 0 | 1 / 0 | 英文 `They also cause us` 只在非 final preview；文字稿无该行，结构性失败 |
| B（yes） | `p11-preempt-ja-b-1`、`p11-preempt-ja-b-2` | 2 | 1 / 1 | 英文 final 保留，日语行照常；PASS |

两次交错复现同一结果。结论：`preemptsIfNeeded` 的“直接 remove/clear 不 queue final”确实是可见内容丢失路径；DEBUG 条件修复能保留 incumbent 且不把 loser 并入 winner。限制：合成音频、固定 en/ja；真实麦克风 A/B 已完成（§6.4），但 Release 默认未改、P1-1 不签收。

### 6.3 Canary 归因记录

已把每次运行的机械归因写入**本机** `score.json`（`.device-state/fixture-runs/<run>/`，不提交）；可复核的结论如下：

| 运行 | 缺失 cue | 归因 | 证据 |
| --- | --- | --- | --- |
| `p13-raw-30-1` | `white men perform better.` | `asrMiss` | raw 7 条 final 无该连续短语；transcript 从 `perform better` 开始 |
| `p11-preempt-ja-a-2/a-3` | 日文长 cue | `asrMiss` | raw final 是英文 hallucination + 日文的混合串，不含 ground-truth 连续句 |
| `p11-regress-30-1` | `white men perform better.` | `unavailable` | 未开 `--dump-asr-text`，不能事后归因 |

实现修正：最初版本用“每个 cue token 在 raw 任意位置有近似拼写”判 `surfaceVariant`，会把 `white`、`men`、`perform better` 在**不同句子**里的出现误判为同一短语；已改为**同长度连续 raw 窗口**近似匹配，并加
`test_scattered_raw_words_are_not_a_surface_variant`。教训：canary 排查必须同时开 raw dump；没有 raw 只能记 `unavailable`，不能猜。

### 6.4 真机麦克风 A/B 与诊断 ID 修正

2026-11-28/29 补跑真实麦克风 Conversation en/ja 与 Meeting en/zh（无 `-duiyi.fixtureAudio`，Mac 扬声器脚本）。结果：Conversation A 干净保留 0/12、B 17/18；Meeting A 1/8、B 7/7；B 的 `queuedFinal` 18/19，B 唯一 preview 是非 confident incumbent 的旧回退路径。详见 [`face-to-face-dual-locale-quality.md`](face-to-face-dual-locale-quality.md) §7.6。

排查中发现并修复一个诊断归因 bug：`speech.preemption.incumbentUtteranceID` 在 `beginNextUtterance` 之后读取，实际记成 challenger 新 ID，导致第一次真机 A/B 无法 join 文字稿。已改为抢占前捕获，并在 `preemptionRecordsIncumbentLoss` / `preemptionExperimentPublishesIncumbent` 加 `incumbentUtteranceID == english.id` 断言。另一个实验路径问题：`queueFinalForBoundary` 会重新 join range state，可能把已 reconciliation 的短语重复发布；抢占改为发布用户可见的 `texts[locked]`，修后 B 无重复短语。教训：新增诊断 ID 必须在状态变更前捕获；A/B join 断言要写进单测，不能只靠肉眼。

## 7. 引用

### Apple 一手资料

- [SpeechTranscriber.ReportingOption](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption)
- [fastResults](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption/fastresults)
- [Preset](https://developer.apple.com/documentation/speech/speechtranscriber/preset)
- [volatileResults](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption/volatileresults)
- [SpeechModuleResult.isFinal](https://developer.apple.com/documentation/speech/speechmoduleresult/isfinal)
- [Result](https://developer.apple.com/documentation/speech/speechtranscriber/result)
- [Result.alternatives](https://developer.apple.com/documentation/speech/speechtranscriber/result/alternatives)
- [ConfidenceAttribute](https://developer.apple.com/documentation/foundation/attributescopes/speechattributes/confidenceattribute)
- [AnalysisContext.contextualStrings](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings)
- [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)
- [DictationTranscriber.ContentHint.customizedLanguage](https://developer.apple.com/documentation/speech/dictationtranscriber/contenthint/customizedlanguage(modelconfiguration:))
- [SpeechAnalyzer.setModules](https://developer.apple.com/documentation/speech/speechanalyzer/setmodules(_:))
- [Apple Developer Forums 811083](https://developer.apple.com/forums/thread/811083)（Apple_Agent：SpeechTranscriber 当前不消费 contextualStrings；iOS 26 时期，需复测）
- 本机 SDK：`.../iPhoneOS.sdk/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-ios.swiftinterface`（iOS 27.1）

### 仓库证据

- `Duiyi/Services/Speech/BilingualSpeechEngine.swift`（ASR config、contextualStrings no-op、confidence 丢弃）
- `Duiyi/Services/Speech/UtteranceAssembler.swift`（preemption、closed-range late volatile）
- `.device-state/fixture-runs/p13-a-baseline-360/transcript.tsv`、`p13-a2b-baseline-360/duiyi-diagnostics.json`
- `.device-state/fixture-runs/p13-c-context-360/transcript.tsv`、`p13-c2-context-360/transcript.tsv`
- `.device-state/fixture-runs/p13-b-nofast-360/transcript.tsv`、`p13-d-nofast-context-360/transcript.tsv`
- `.device-state/fixture-runs/row82-fix-full-1/transcript.tsv`、`corruption-fallback-full-3/transcript.tsv`
- `.device-state/fixture-runs/p13-full-context-1/score.json`、`p13-full-context-2/score.json`
- `tools/fixtures/ted-cue132-331.tsv`、`tools/fixtures/ted-baseline.json`
