# 面对面双 locale 听写质量：A/B 实验方案

> 日期：2026-11-27。触发：iPhone 13 面对面播放同一条 TED 片段（BV1aFHh6FE1v，起点相同）时，英文词被切到两行、翻译出错，整体明显差于同传。对照任务：面对面 task 9（12:58:16–12:59:36）与同传 task 8（12:48:55–12:53:20），两份 DEBUG 诊断 JSON 由用户从设置页导出。
>
> 本文只定义实验，不改听写策略。P0（尾随 `...` 不关行）已作为独立修复处理；本实验回答的是“为什么面对面的英文识别本身更差”，尤其是双 locale 并发的成本。

## 0. 结论与边界

- 现有数据能证明两件事：① 面对面的英文 range 在同一词中间断开（`...is di` / `nostic...`），P0 修的是“两行”；② 面对面 80 秒产生 648 条 ASR 结果，其中 427 条来自中文路、417 条被 `.strict` 拒绝，总拒绝率 74%，而英文路拒绝率（约 29%）与同传（约 28%）接近。**不能**从这一次数据证明双 locale 导致了丢音：两次运行的手机摆放、声学环境、时长都不同。
- 因此本实验先隔离“双模型并发成本”，再决定是否改引擎策略；不要在证据不足时直接把面对面切到单路。

## 1. 已知数据

### 1.1 任务对比

| 指标 | 同传 task 8 | 面对面 task 9 |
| --- | --- | --- |
| 时长 | 4 分 25 秒 | 1 分 20 秒 |
| ASR 结果 | 739 | 648 |
| 英文结果 / 拒绝 | 739 / 209（28.3%） | 221 / 65（29.4%） |
| 中文结果 / 拒绝 | — | 427 / 417（97.7%） |
| 总拒绝率 | 28.3% | **74.4%** |
| final / settled 行 | 61 / 54 | 17 / 17 |
| translation submit / apply | 310 / 156 | 106 / 54 |

### 1.2 同一短语的边界

面对面：

```text
row 5  range 20.44–22.90  Lead a group of men to believe an athletic task is di...
row 6  range 22.90–25.06  nostic of sports intelligence.
```

同传：

```text
row 4  range 14.98–17.30  Lead a group of men to believe in athletic task...
row 5  range 17.72–20.30  diagnostic of sports intelligence.
```

面对面的英文路丢了 `diagnostic` 中间的 `ag`；同传保留了完整单词。P0 能把两行合成一行，但无法补回丢掉的音。这是本实验要回答的核心差异。

### 1.3 混杂因素

- 两次不是同一摆放：面对面手机平放，麦克风指向、距离、桌面反射与同传不同。
- 两次时长不同（80 秒 vs 4 分 25 秒），样本量不对等。
- 每次只跑了一遍，ASR 本身有随机性。
- 诊断 JSON 不含正文/音频，词级判断要配合文字稿导出。

## 2. 假设

| 编号 | 假设 | 可观察信号 | 若成立 |
| --- | --- | --- | --- |
| H1 | 双 transcriber + detector 并发争用算力，英文流丢帧/迟到/边界丢音 | 面对面英文 final 延迟更高、边界丢音更多；固定英文单路后改善 | 优先做单活跃 locale 或降低第二路成本 |
| H2 | `.strict` 语言纯度/锁定让英文 volatile 被延迟或丢弃 | 英文拒绝率显著高于同传；final 延迟高 | 调整锁定/纯度策略，而不是改模型 |
| H3 | 声学/摆放差异是主因 | 同一摆放下双路 vs 单路差异消失；不同摆放差异很大 | 先改产品摆放指引/音频处理，不急着改引擎 |
| H4 | range 边界 + `...` 关行是主因 | P0 后两行变一行，但丢音仍在 | P0 已处理；剩余问题归 H1/H2/H3 |

H2 目前证据偏弱：面对面英文拒绝率 29.4%，同传 28.3%，几乎一样。H1 和 H3 是本实验的重点。

## 3. 实验设计

### 3.1 固定条件

- 设备：同一台 iPhone 13（iPhone14,5，iOS 27.2.1），同一 DEBUG 构建（含 P0 修复）。
- 音频：同一段 3–5 分钟 TED 英文片段（从同一 TED 起点播放，覆盖 task 8/9 的前 80 秒并延长到 3–5 分钟；确保有多个 range 边界），从同一设备、同一音量、同一位置播放。
- 摆放：手机平放桌面，麦克风朝向声源，距离固定；房间安静；每次开始前确认没有其他人声/脚步声。
- 运行：每臂 3 次，A/B 交错（A B A B A B），避免热降频只影响一臂；每次之间冷却 1 分钟。
- 记录：每次导出诊断 JSON + 文字稿；在文件名/表格里记录臂、轮次、构建 commit、房间/摆放备注。

### 3.2 实验臂

| 臂 | 识别计划 | 目的 |
| --- | --- | --- |
| A（对照） | 当前 `startDualPipeline`：英文 + 中文两个 `SpeechTranscriber` + `SpeechDetector`，`.strict` | 现状基线 |
| B（诊断上界） | 只跑英文单路 `SpeechTranscriber`，`.trustedLocale` | 隔离“双模型并发”的成本；不是最终产品方案（真实面对面需要双语） |
| C（产品候选） | 单活跃 locale + 语言切换：检测到另一语言后重启单路（复用 `restartSingle` 的思路） | 在保留双语能力的前提下降低并发成本 |
| D（可选） | 双路但第二路关闭 `.fastResults`/volatile，或延迟启动 | 如果 API 允许，验证“降低第二路报告频率”是否足够 |

执行顺序：先 A/B（便宜、能直接回答 H1）；若 B 明显优于 A，再做 C（需要改引擎/原型）；若 A≈B，优先查 H3（摆放/声学），D 可选。

### 3.2.1 DEBUG 单路开关（已实现）

- 位置：首页右上角齿轮 → 设置 → DEBUG 区「面对面单路听写（DEBUG）」。
- 关闭 = 臂 A（当前双路，生产默认）；开启 +「对方语言」= 臂 B（英文单路，用于英文 TED）；开启 +「我的语言」= 反向单路。
- 设置持久化；改变在**下一次开始听写**时生效，不会热切当前流。
- 导出诊断 JSON 时在文件名/记录表标注 `A` / `B-peer` / `B-user`；JSON 本身不含臂字段（若出现 `zhHans` ASR 事件，说明至少跑过双路，可辅助核对）。
- Release 构建不编译该开关，不影响生产请求。单测：`ConversationViewModelTests.debugSingleLocaleStartsPeerOnly` / `debugSingleLocaleStartsUserOnly`。

### 3.3 指标

主指标（词级质量）：

- **边界丢音数**：把文字稿与参考 transcript 对齐，统计“参考词在 ASR 行边界被切断或丢音”的次数；重点看 range 结束/开始处。
- **WER**：同一段参考文本的词级错误率；与 P1-3 的 ASR A/B 共用口径。
- **翻译错误数**：沿用 `simultaneous-translation-quality.md` 的实质错误/critical 错误口径，人工对照。

次指标（引擎行为）：

- ASR 结果/秒、各语言结果数、拒绝率、`scriptMismatch` 数；
- final 延迟：`at - 会话音频起点 - (rangeStart + rangeDuration)` 的近似值；音频起点用首条 ASR 事件校准；
- `finalJobCount` / `settledUtterances` / 行数；
- 每个多词短语被拆成多行的次数；
- Instruments：CPU、ANE、热状态；体验层的卡顿/延迟。

### 3.4 判定

- **B 显著优于 A**（边界丢音更少、final 延迟更低，且差异大于轮间方差）：H1 成立，进入 C 的原型/实现；C 需要同时验证真实双语对话（中英各说一段）不退化。
- **A≈B**：双模型并发不是主因，优先做 H3 的摆放/声学对照（同一构建、不同摆放各 3 次）；不要改引擎。
- **C 与 A 质量相当，但拒绝率/延迟明显更低**：把 C 作为面对面候选策略，落到引擎的 `SpeechRecognitionPlan`（单路/双路是策略，不是 ViewModel 分支）。
- **任何臂**：P0 后的行数应下降；若边界丢音仍多，记录具体词和 range，回到 H1/H3。

### 3.5 风险与约束

- `SpeechDetector` 是否暴露可用的语言信号需要先确认；若不暴露，C 需要额外的语言判定/切换启发式，成本上升。
- 切换单路会有 0.5–1 秒的空窗，真实对话可能丢首词；实验要单独统计切换点。
- 3 次可能不足以压过 ASR 随机性；方差大时加到 5 次，或改用配对设计（同一段音频重复）。
- 实验期间不要改 `UtteranceAssembler` 行为；A/B/C/D 共享 P0 后的同一 assembler，否则指标不可比。
- 诊断 JSON 不含正文；词级指标必须用文字稿导出，不要从 JSON 的 `textLength` 推断内容。

## 4. 交付物

1. 一张 A/B（必要时 A/C）对比表：边界丢音数、WER、翻译错误数、拒绝率、final 延迟、行数。
2. 一段结论：H1/H2/H3 哪个成立；是否建议把面对面切到单活跃 locale；若不切换，给出音频/摆放或双路调优建议。
3. 若 C 胜出：在 `docs/02-architecture.md` §4.1 记录 `SpeechRecognitionPlan` 的单/双路选择，并开实现 ticket；不要在 ViewModel 里加 `isFaceToFace` 分支。

## 5. 关联

- 路线图：`docs/04-roadmap.md` P1-3（ASR 精度 A/B）与 P1-1（range 组装）。
- 同传质量基线：`docs/research/simultaneous-translation-quality.md`。
- 诊断导出：`docs/agents/device-testing.md` §6.1。

## 6. 2026-11-27 首轮 A/B 结果（单路 vs 双路）

> iPhone 13，面对面，同一段 TED；单路 task 12（07:19:27–07:22:01），双路 task 13（07:24:24–07:27:27）。单路开关：DEBUG「对方语言」。

| 指标 | 单路 | 双路 |
| --- | --- | --- |
| ASR 结果 | 470（全英文） | 1095（中文 687，全部被拒；英文 408） |
| English final | 35 | 37 |
| settled 行 | 29 | 34 |
| 拒绝率 | 23.4% | 英文约 29.9%，中文 100% |
| 结束 | 正常 | 英文 ASR 在 07:27:05 后停止，中文继续到 07:27:15，07:27:27 结束；收听按钮红（`.failed(.recognitionInterrupted)`） |

观察：

- 单路开关生效：单路 JSON 没有任何 `zhHans` ASR 事件。
- 双路的 English stream 先停、中文流继续但全被拒；疑似一个 transcriber 失败后引擎结束了整条 utterance stream。诊断目前只记录 ASR 结果，没有 speech failure 事件（哪个 transcriber/什么错误），这是 P0-6b 的缺口。
- 单路与同传的 ASR 请求相同（`[english]`、`.trustedLocale`、`.liveCaptions`），final 率也接近（约 0.227/s vs 0.230/s）。文字稿并非全面退化：单路在 `Highlight her female identity`、`your circumstances`、`Cameron Russell`、`doctor's lab coat`、`They'll perform better` 等行更好；坏行集中在 `agstic`、`. of the painters coat`、`noich`、孤立的 `we`、末行合并。双路/同传也有自己的坏行。
- 结论：这次数据不支持“单路全面差于同传”；差异更像手机摆放/声学 + 单次波动。双路则明确更贵、更脆。下一步先做**同摆放**的 single vs simultaneous 对照，再决定是否把手动 turn + 单活跃 locale 作为面对面模式。
