# 04 当前问题与优化路线

> 本文是**当前**的工程待办与风险清单，替代早期的 04/08/12 路线图与 13 的问题清单。
> 架构见 [`02-architecture.md`](02-architecture.md)，选型见 [`03-tech-choices.md`](03-tech-choices.md)。
> 每条都尽量给出代码依据；行号会漂移，以类型/函数名为准。
> **真源声明**：本文件的 P0/P1 验收判据与排期是唯一真源；[`decisions.md`](decisions.md) 的 D1–D8 / D-B* / D-AI* 只是决策记录，不影响排期判定；
> 所有待确认决策统一见 [`decisions.md`](decisions.md)（本文件 §7 只保留指针）。

## 0. 状态

| 项 | 状态 |
| --- | --- |
| 启动优化 | 已暂停；200 ms 目标判定不可达，见 [`case-startup-performance.md`](case-startup-performance.md) |
| 已结束任务译文回填 | 已修复（历史修复记录见 git 历史） |
| UI 测试“存在但不可点击” | 已闭环（回归测试在 `DuiyiUITests`） |
| 文档整理 | 2026-11-02 合并 01–13 为 01–04；05–13 已退休 |
| 死代码清理 | 2026-11-02 删除未引用函数/常量/本地化键（见 §5） |
| 导出竞态与内容刷新 | 已修复（2026-11-17；回归测试在仓库内；原归档证据未随提取保留） |
| 语言切换清态 | 已修复；当前实现与回归覆盖见 Conversation/Interpretation ViewModel 测试 |
| 语言目录实查 | 生产注入 `SystemLanguageCatalog`（探针缓存）；当前仅首页设置消费，v1 扩展到所有语言入口 |
| Wave 1 数据完整性 | 已合并到 `wave-1-data-integrity`（#2–#12，tip `fd820e4`）：TaskStoreV2、SpeechSessionGate、TaskLifecycle、显性存储降级、清屏/50 条/2 万字语义。iPhone 13 真机清单未验证 |
| P1-1 翻译队列积压 | 已完成（#22–#25，main `37f0a50`）；真机验证 2026-11-24 通过（用户确认）；#21/#26 已关闭 |
| 同传 P0-5 单语种 trusted locale | 已实现（2026-11-26，PR #77）：真单语种 `.trustedLocale`；双 locale 降级与会议保持 `.strict`；单测全绿；真机未验证 |
| 同传 P0-4 停止 finalize/drain | 已实现（2026-11-26，PR #78）：stop/reset/restart finalize（1 s 上限）+ 300 ms drain + 兜底 final；三个 VM 在 end/stop/新建任务前 drain consumer（500 ms 上限）；单测全绿；真机未验证 |
| 同传 P0-1 outbound 无损队列 | 已实现（2026-11-26，PR #79）：单槽改为有界有序队列 + 每 utterance 防抖 + 单调 sequence + 结果去重；Host 按 `outboundRevision` drain；单测全绿；真机未验证 |
| 同传 P1-2 稳定单元 preview | 已实现（2026-11-26，PR #82；#80 自动关闭）：句末标点立即、≥4 estimated words 防抖、更短丢弃；首包有用 preview 也走防抖；final 旁路；单测全绿；真机未验证 |
| 同传 P0-6a 结束竞态回填 | 已实现（2026-11-26，PR #81）：endTask/新建任务后迟到的 final 译文经 `updateTranslations` 回填已结束任务；结束写入在途时暂存后回填；preview 不落库；单测全绿；真机未验证；P0-6b 重试/可见状态另开 |
| 同传 P1-4a 每任务诊断 | 已实现（2026-11-26，PR #84 / merge `1cc8df6`）：内存 ring buffer + 聚合 + DEBUG JSON 导出；ASR 记录 language/range/resultsFinalizationTime/synthetic/脚本不匹配，翻译记录 submit/apply/response/retry/失败类/U+FFFD/延迟；设置页 DEBUG 导出写入 Documents；单测全绿；真机回放（P1-4b）未执行。2026-11-28 新增 ASR confidence 只读聚合（runCount/字符加权 min/mean/10 桶），不参与接受/选词/丢 final；fixture 运行写 `run-meta.json`，可选 `--dump-asr-text` 拉取 fixture-only raw JSONL 并在设备上覆盖清空；2026-11-28 又加入 asr.drop/speech.preemption/speech.start 只读事件与 canary 归因，单测 575/610 |
| 同传 P1-1 range-aware 组装 | 已实现（2026-11-26，PR #84 / merge `1cc8df6`）：Result(range) 建模、finalized-prefix、range 连续（含 volatile）+ 标点定句界、空 volatile 撤销、静音 finalize(through:nil) + 350ms 等待 + synthetic 兜底、迟到同 range final 复用 ID，且只替换/合并其 range 的 phrase，保留已 final 前缀；换 phrase 时旧 volatile 先并入前缀（不依赖 volatile 会重发 final）；final 只在 range 覆盖原 phrase 时替换文本，更窄/严重截断的 final 不缩短已有文本；纯标点结果忽略；关闭行后扩展 range 的 late volatile / 不含旧 tail 的 late final 在新行为空或当前行重叠时开/续新行；源文本剥离开头续句标点/折叠超长点串，译文按目标语言规范省略号（2026-11-27 两轮回归修复，单测覆盖静音/间隔/换语种关闭、连续短句、首句预览结算、暂停恢复、纯标点、标点拼接）；D8/crosstalk/name-swap 保持；单测全绿；2026-11-27 iPhone 13 同传英→中真机复测通过（包含暂停恢复、首句结算、标点显示）。2026-11-27 面对面回归补丁：尾随 `...` 不再关行，同一行后续 phrase 去掉省略号后按正常词距拼接，新增 3 条 range 测试；待真机复测。2026-11-27 断句修复（R0/R1/cap）：Apple result 是 phrase 不是 sentence，标点不再决定 `Utterance.id`；行边界只由 range gap >0.75 s、语言/name swap、静音和 max cap（12 s/120 字，仅无 volatile 时）决定；final-only 行由静音关闭；单测 521/556 全绿；研究见 [`research/speech-transcriber-segmentation.md`](research/speech-transcriber-segmentation.md)；真机待复测。手动步骤：iPhone 13 同传英→中，连续说两个无标点短语应同行增长；带句号但无停顿的连续句子也应同行；>0.75 s 停顿或 1.1 s 静音后换行；诊断 JSON 的 `asr.result` 应显示相同 utterance 的 `revision` 与 range 重叠。2026-11-27/28 夹具回归：R0/R1 后短句被两种机制吞掉（finalized range 被 volatile 尾部膨胀 + longer-wins；边界关行只关状态、不发布 open volatile）；已修复（tight range、same-phrase/same-window、disjoint 文本按 range 保留、boundary pending finals；reviewer 补齐同音频误听替换/partial volatile tight range），单测 565/600、identity verifier clean（含 row82 2 条回归）；全量中间 85 行/97.92%/WER 3.46%；全量 pending-final 82 行/98.99%/WER 2.45%；180 s 边界硬化 98.98%；全量边界硬化 84 行/98.81%/WER 2.64%（row 82 修复前，0 行内重复）；row 82 修复后全量 85 行/99.43%/精确 97.99%/WER 2.08%，requiredCues 10/10、0 行内重复、2 次 `corruptedOutput`（row 47 preview/final，store preview 完整）。2026-11-28 [LLM 语义评审](research/fixture-semantic-review-2026-11-28.md) 5 critical/16 major（24 行源缺陷：23 ASR、1 组装器），row 82 已修复并真机验证（`sameVolatilePhrase` start/text guard + `shouldReplaceSameAudio` 文本长度 guard）；剩余为 ASR/翻译层；P1-1 另有双 locale 抢占丢 open volatile、closed-range late volatile 两风险，先诊断不改策略，根因/方案见 [`research/asr-accuracy-root-cause-2026-11-28.md`](research/asr-accuracy-root-cause-2026-11-28.md)。2026-11-28 已实现零行为变更的 `asr.drop`（empty/punctuationOnly/purity/suppression/lateVolatileClosedRange/preemption）、`speech.preemption`（双方语言/长度/confident/visible/queuedFinal/applied）与 `speech.start`（requested/active/usingDual）诊断；`--preemption-publish` DEBUG 实验在双 locale Conversation 夹具（1 s 英文 + 日文）A/B：A 仅留非 final preview、0 final rows，B 保留 `They also cause us` final + 日文行、2 final rows，两次交错复现。Release 默认仍 no，真实 Conversation/Meeting A/B 通过前不改默认；P1-1 不标完成 |
| 同传 P1-4b TED 真机回放 | 已具备夹具注入（2026-11-27）：`tools/fixture-run.sh` 可在无安静房间下跑 13 分钟 TED（DEBUG-only `AudioCapturing` 替身，ASR/翻译/落库为真）。首跑 158 行/158 有译文/覆盖 93.33%/前缀重复 0/final p95 61 ms；比调研基线 99.12% 低，重复从 5.7% 降到 0，质量差异待同音频 A/B（旧版或声学路径）。2026-11-27/28 同夹具复跑：R0/R1 问题跑 90.44%/91 行 → 内容保留修复 97.92%/85 行（WER 3.46%）→ pending-final 全量 98.99%/82 行 → 边界硬化全量 98.81%/84 行（0 行内重复）；详见 segmentation §8.1。安静房间声学冒烟只保留给麦克风/路由/TTS/回声。2026-11-28 新增默认相对基线 `tools/fixtures/ted-baseline.json`：覆盖/精确/WER 各允许 1 个百分点回退，≤5 词短句保留率允许 2 个百分点回退；91 行问题跑会在四项全部失败，`fix-full-final` 的 `For four days, silence.` 缺失也会被短句门限拦下；`requiredCues` canary 进一步抓 row 82 的 8 词长句丢失。`tools/test-unit.sh` 同时运行 4 条 Python 工具测试。row 82 修复后全量 85 行/99.43%/精确 97.99%/WER 2.08%、requiredCues 10/10；84 行/98.81% 是修复前对照。新增 `TranslationFallback` 后 `corruption-fallback-full-1` 为 84 行/99.25%/精确 97.86%/WER 2.39%、0 permanent failures、0 重复，但 ASR 漏 `days` 使 requiredCue/短句门限失败；`full-3` 为 84 行/99.25%/97.92%/WER 2.26%、0 permanent failures、短句 42/45，requiredCues 8/10（ASR 漏 `days` 与 row 82 的 `life`）；`full-2` 因 Xcode 外置卷/设备中断未产出证据。基线是机械门限，不是语义签收。2026-11-28 新增 `missingCueAttribution`（有 raw dump 时区分 assemblerLoss/surfaceVariant/asrMiss，无 raw 时 unavailable）与非阻断 `nameCues`；`fixture-run.sh` 自动把 `asr-raw.jsonl` 交给 scorer。详见 [`research/fixture-injection.md`](research/fixture-injection.md) 与 [`research/asr-accuracy-root-cause-2026-11-28.md`](research/asr-accuracy-root-cause-2026-11-28.md) §6 |
| 同传 P1-3 ASR 精度 A/B（research） | 进行中（2026-11-28）：等 P1-4b 同一夹具；`.fastResults` 去留、`AnalysisContext.contextualStrings`、`transcriptionConfidence` 只诊断，不因低置信度丢 final。2026-11-27 补面对面双 locale 实验方案：见 [`research/face-to-face-dual-locale-quality.md`](research/face-to-face-dual-locale-quality.md)，先 A/B 隔离双模型并发成本，再决定单活跃 locale 策略；DEBUG 单路开关已实现（首页设置 DEBUG 区，`ConversationViewModelTests` 覆盖）；首轮真机 A/B（2026-11-27）：双路末尾 English stream 停止、红按钮，单路未全面差于同传，见 research §6；下一步同摆放 single vs simultaneous 对照 + 手动 turn/单活跃 locale 评估。2026-11-28 语义评审归因：24 行源缺陷中 23 ASR、1 组装器（row 82 已修）；meaning-bearing ASR 包括 `white men`、`she's→he's`、`he's→you's`、`him→them`、`past→pastor`、`designs→Dess`、`break→bring`；`Fernando` 在 full-edge row 59 已正确。2026-11-28 360 s ASR A/B（见 segmentation §8.4）：baseline fast 40 行/98.35%/WER 3.82/required 1/6；no-fast 73 行/95.67%/WER 7.38/required 3/6（不采用）；fast+context 40 行/98.35%/WER 3.31/required 3/6（Cameron/days 表面恢复但属 ASR 波动；Lidia/Design/white men 仍错）；重复 C2 38 行/98.35%/WER 3.31/required 2/6（days 表面恢复，Cameron 变成 Rushell；均属 ASR 波动）；A2 baseline 40 行/98.35%/WER 3.69/required 2/6（days 恢复，专名仍错）；full context 1 为 83 行/99.43%/98.11%/WER 2.01/required 10/10/0 permanent，短句 41/45 未过；full context 2 为 85 行/99.18%/97.67%/WER 2.83/required 10/10/短句 43/45（手动计分通过；脚本 stop-app SIGPIPE 已修）。两次 full WER 2.01/2.83 vs baseline 2.08，无稳定收益，不作默认；no-fast+context 为 71 行/95.80%/WER 6.62%/required 3/6（恢复 White men/Design，但 Cameron/Lidia 仍错，不采用）；row 82 `life` 96 s：baseline 11 行/100%/100%/required 1/1，context 10 行/98.84%/98.26%/required 1/1；两者都保留完整 clause，full-run 的 life 丢失是随机/长窗 ASR 波动。Release 决策见 [`decisions.md`](decisions.md) D9（保持 fast）与 D10（不默认 contextualStrings）。**重要更正（Apple 一手资料）**：`SpeechTranscriber` 当前不消费 `contextualStrings`（DocC 只写 DictationTranscriber；论坛 811083），因此 C/C2/D/full context 的差异是 ASR 随机波动，不是偏置效果；根因与安全方案见 [`research/asr-accuracy-root-cause-2026-11-28.md`](research/asr-accuracy-root-cause-2026-11-28.md)；2026-11-28 已补 `asr.drop`/`speech.preemption`/`speech.start` 与 canary 归因，P1-3 仍无确定性 ASR 修复，不签收 |
| 面对面手动换手（默认） | 已实现（2026-11-27，PR #92）：`ConversationListeningMode.manual` 默认，点一侧启动该侧单路、切 turn 停/排空/重启，行固定到听者 pane；turn bar/说话色/设置；自动语种路由为备选；单测全绿；真机待验证（切 turn 延迟/首词/后台恢复） |
| 同传 P0-6b 重试/可见状态 | 部分实现（2026-11-27，PR #91）：双路 transcriber 失败写 `speech.failure`（language/errorDomain/errorCode/recovery）并自动把失败语种重启为单路 `.trustedLocale`（meetingNotes 仍 `.strict`）；重启失败记 `restartFailed` 后结束，单路/停止保持原 fail；单测全绿，真机未验证。翻译取消/资源未就绪/不支持语言对/瞬时 2 次退避 + `permanentFailure` 可见状态仍待 P1-4 设备数据。2026-11-28 全量夹具 row 48（`I was astounded, proud, liberated, and confused.`）的 preview/final 各两次 `corruptedOutput`，旧 preview 被保留；语义评审列为 major。60 s row 48 片段复现后新增 `TranslationFallback`：同一源文重试一次仍坏时，按逗号连词/`and`/`but`/`or`/分号拆成两个 clause 分别翻译并按目标语言拼接；片段验证 preview/final 各用 1 次 fallback、0 permanent failures，译文恢复 `...并且困惑。`。全量 `corruption-fallback-full-1` 同样 0 permanent failures、row 48 译文完整；该跑因 ASR 漏 `days`（`for four` + `Silence.`）使 requiredCue/短句门限失败。`full-2` 因 Xcode 外置卷/设备中断 marker timeout；`full-3` 为 84 行/99.25%/精确 97.92%/WER 2.26%、0 permanent failures、0 重复、短句 42/45，但 ASR 又漏 `days` 与 row 82 的 `life`，requiredCues 8/10（baselineRegressions 0）。门限抓到的是 ASR 漏词，不是 fallback 回退。可见失败状态仍未实现 |
| Wave 3 C04 字幕/文字稿投影 | 已完成（#28–#31，PR #33–#36；#32 清理+文档+iPhone 13 真机矩阵，用户确认 2026-11-25）；候选台账见 [05-architecture-backlog.md](05-architecture-backlog.md) |
| 测试基线 | 只增不减；入口为 `DuiyiTests` / `DuiyiUITests`；原 harness 基线未随提取保留 |

> **下一步（2026-11-28）**：row 82/fallback 真机回放已完成（`row82-fix-full-1` requiredCues 10/10；fallback 全量 0 permanent failures；ASR canary 在复跑中漏 `days`/`life`）→ P1-1 抢占 DEBUG 双 locale A/B 已完成（A 丢非 final preview，B 保留 incumbent final；Release 默认仍 no）→ P0-6b 可见失败状态 → 真实 Conversation/Meeting 麦克风 A/B 决定是否提升抢占修复 → P1-3 词表/alternatives/DictationTranscriber spike。P1-5/P2 仍暂缓，见 research §4。

### Wave 1 测试调整说明（2026-11-23）

- #2–#12 期间既有单元测试为适配 async setter 与 `TaskStoreV2` 结果接口做了机械迁移（改为 `await` 与结果分支），断言与用例语义未改；没有删除测试，也没有新增 skip。
- 新增的 `storage-retry`、`*-not-saved-banner`、`*-resume-prompt` 标识中，`meeting-resume-prompt` 有模拟器 UI 回归（新建任务 → 重启 → 恢复）。存储失败横幅需要启动期 store 失败注入钩子，暂由 ViewModel 单测覆盖，未新增 UI 用例或 skip。

---

## 1. P0：会丢数据或卡死主链路

### P0-1 单引擎全局仲裁（已实现，Wave 1）

**状态**：已实现并合并（#3 gate、#4 lifecycle、#6–#8 三模块接入、#12 契约收口）。

**原现象（Wave 1 前，保留历史）**：三个常驻 ViewModel（面对面、同传、会议）共享同一个 `BilingualSpeechEngine` actor。快速切模块、前后台切换、或旧 `stop()` 晚到时，可能出现 A 已 `start`、B 的 `stop()` 后到，把 A 的流 finish 掉。

**已落地**：

- `SpeechSessionGate`（actor，`SpeechSessionGating`）持全局 generation + 当前 owner `FeatureID`。
- 新 `start` 立即取代旧 owner：旧流结束，旧 owner 的后续 stop 是 no-op；同一 owner 重复 start 也生成新 generation，避免 ABA。
- 三个 VM 经各自 `TaskLifecycle` 使用同一个 `environment.speechGate`，不直接调 engine。
- 流结束分类：`isCurrent` 为真 → `recognitionInterrupted`；被取代 → 静默 `pausedListening`，不误报。
- 启动失败只让新 owner 报错，旧 owner 保持 paused。

**验收状态**：

- 单元：`SpeechSessionGateTests` / `TaskLifecycleTests` 覆盖 A start → B start → A stop、幂等 stop、同 owner 重启、快速切换与前后台循环；全量单测绿。
- 真机：iPhone 13 三模块连续切换 + 前后台 10 次**未验证**，按 #13 真机清单执行。

### P0-2 长会话的数据留存（显示窗口已完成，D7 续集组待后续）

**状态**：显示窗口与计数已实现（#9 会议清屏/计数、#10 同传 50 仅显示、#11 面对面 3 条窗口与恢复）。D7 的续集任务组**不在 Wave 1**，仍为后续 wave。

**原现象（Wave 1 前，保留历史）**：

| 模块 | 原问题 |
| --- | --- |
| 面对面 | `pane.history` 无上限，恢复回填无窗口 |
| 同传 | 显示窗口曾连带裁掉 transcript，早期内容从内存消失（Wave 1 #10 已修复） |
| 会议 | 20,000 字符计数按内存 transcript，清屏曾复位（Wave 1 #9 已改为累计）；无续集关联 |

**已落地**：

- 面对面 pane 保留 `live` + 最多 3 条历史（`ConversationLayout.paneHistoryLimit`），恢复只回填每侧 3 条，transcript 全量。
- 同传 50 条只裁 `pane.history` 显示与恢复回填，transcript / 落盘 / 导出全量；删除同时截断 transcript 的逻辑。
- 会议 20,000 字符按任务累计，清屏不复位；达到上限自动停听并标记 `isLengthLimited`，任务保持进行中。
- 清屏只清显示，先 `flush()`；transcript、总结数据与导出全量。

**仍待后续**：

- D7 续集任务组：组 ID、「结束并继续」、组内跳转、整组合并导出（当前只能结束并手动新建；文案/术语表已冻结方向，但未实现）。
- 历史详情分页加载，避免一次渲染全量。

**验收状态**：模拟器单测覆盖清屏/计数/窗口；iPhone 13 模拟 1 小时文字稿、同传 50+ 条历史读回、会议 2 万字边界**未验证**，按 #13 真机清单执行。

### P0-3 持久化可靠性与写放大（降级/结果接缝已完成，写放大/迁移待后续）

**状态**：降级显性化与结果化接缝已实现（#2 TaskStoreV2、#5 首页/历史/详情横幅与安全删除、#12 契约收口）。写放大与迁移计划未在 Wave 1 范围。

**原现象（Wave 1 前，保留历史）**：

- 旧实现（Wave 1 已修复）：容器失败时退回内存 store，用户以为已保存。
- 旧实现（Wave 1 已修复）：SwiftData 自动保存与显式 save 叠加，错误被吞掉。
- 无 `SchemaMigrationPlan`，字段变更可能崩库/丢库。

**已落地**：

- 可用性显式（`opening` / `ready` / `unavailable(reason)`），接口提供 `prepare()` / `retry()`；组合根不再 downcast。
- 读结果区分「空」与「读失败」；写返回 `persisted` / `notPersisted(reason)`；`end` 返回 `ended` / `discardedEmpty` / `notPersisted`，先 append 再按 store 内容判空，失败保持运行中。
- 首页/历史/详情共享「本机存储不可用」横幅 + 重试；已加载内容不清空；模块标记「本次内容不会保存」，结束后可从内存导出；不自动回填 memory-only 任务。
- `SwiftDataTaskStore` 关闭 autosave，每个变更显式 `save()` 并 `rollback()`；写失败只自动重试一次，仍失败即停止。
- 删除任务返回结果，历史/详情确认弹窗与失败提示已上线。

**仍待后续**：

- 增量落盘：`append` 仍按传入快照 upsert，长会写放大尚未量化/优化。
- `SchemaMigrationPlan` v1→v2 演练与自动化测试（P3-1）。

**验收状态**：单元测试覆盖 open/read/write/delete 失败、重试、空稿三态与 v1 样例 round-trip；iPhone 13 注入打开失败看横幅/重试/导出**未验证**，按 #13 真机清单执行。

---

## 2. P1：识别/翻译质量与数据一致性

### P1-1 翻译队列积压（已完成，真机验证通过）

**状态**：已完成并合并（#22–#25，代码评审修复合并于 `37f0a50`）：bridge 改为 per-`utteranceID` 合并队列 + final 优先 + generation-scoped `takeNext`；pump 一次唤醒 drain 到空并处理取消/requeue。单测覆盖合并、顺序、final 优先级、pre-pump wakeup、generation、latest-job requeue、drain/取消。真机验证已于 2026-11-24 通过（用户确认）；#21/#26 已关闭。

**原现象（P1-1 前，保留历史）**：`TranslationJobBridge` 只有 1 个 pending 槽位，但 host 就绪后 `AsyncStream` 无界；高频 volatile 会排队。`TranslationPipeline.accept` 用 `lastAppliedSourceCount` 丢弃过期结果，但积压仍占 session、抬高延迟。同传 voiceOut 档防抖更激进（25/50 ms）。

**已落地**（#22–#24）：

- 同一 `utteranceID` 最多保留一条 pending job，替换保留该 ID 首次出现的位置；不同 ID 保持 FIFO。
- 已排队 final 不被后续 non-final 覆盖；non-final 可互相覆盖；任何新 final 可覆盖旧 job。
- Host 未就绪时也按 ID 合并；`makeConsumer()` 在队列非空时立即补一次 wakeup。
- consumer generation-scoped `takeNext()`：旧 generation 返回 nil，旧 `onTermination` 不清新 continuation；`requeue` 接受任意 generation，只要该 job 仍是该句最新提交且无同 ID pending，插入队首并 wake 当前 consumer。
- pump 每次唤醒 `takeNext()` 到空；取消时该 job 已被同 ID 更新取代则丢弃，否则 requeue 到队首并退出；取消错误不触发 `onFailure`。非任务取消的 `CancellationError` 由下一次 `.translationTask` 重启的新 consumer drain。
- 时序不变：40/90 ms、voiceOut 25/50 ms、380 ms TTS settle、1.1 s 静音 final、crosstalk 与 emit（当时仍为单槽 `outboundJob`；该单槽已由 2026-11-26 的 P0-1 改为有序队列）。

**验收**：`check-static` PASS；模拟器回归单测 326 logical / 352 expanded，0 failed / 0 skipped；UI 5 logical / 4 expanded，0 failed / 1 既有模拟器语音 skip。真机口径（连续快速说话时最终译文延迟不随会话增长、无旧 job 后到）由用户在 2026-11-24 报告通过，未提供 p95 数值。

### P1-2 导出竞态与导出内容不刷新（已修复 2026-11-17）

**原现象（修复前，保留历史）**：

- `TranscriptExportService.cleanupOldExports` 每次导出删除全部 `Duiyi-*.txt`；`ShareLink` 还在读取时可能被删。
- `TaskDetailView` 的 `ExportShareButton` 用 `.task(id: task.id)` 准备文件；任务译文更新后 `task.id` 不变，分享 URL 可能仍是旧内容。

**已落地**：

- 快照按 task UUID 与完整导出内容 SHA-256 命名，已准备快照不可变；后续导出不得覆盖。
- 清理仅匹配本服务普通文件，mtime 严格超过 7 天且未被本进程准备时才可回收。
- 分享准备版本由完整导出内容和 language 计算；任务 ID 不变但译文、总结或语言变化时重新准备。

**验收**：仓库内单元与 UI 回归覆盖连续导出/分享与详情页译文更新后的内容刷新；原运行证据未随提取保留。真实 ShareSheet 读取按 P0 书面豁免保持未验证。

### P1-3 切换语言后的旧翻译状态

**现象**：语言对变化时 `ConversationView` / `InterpretationView` 用 `.id` 重建 Host，旧 session 取消；翻译态（outbound 队列、防抖、`sentSourceText`、`lastAppliedSourceCount`、`lastAppliedSequence`）现由 `TranslationPipeline` 持有，`reset()` 会一并清空，但 `setUserLanguage` / `handlePairChange` 的调用时序仍可能漏一句。

**目标**：`applyDirectionChange` / `setUserLanguage` / `handlePairChange` 在重建配置前统一调用 `pipeline.reset()`。

**状态**：Wave 2（#19）已统一 reset 接缝（`TranslationPipeline.reset()`）；P1-3 的时序行为修复尚未开始，不能据此宣称已修复。

**验收**：切换语言立即说话，不出现旧语言译文写入新行；无串行/重复。

### P1-4 中英混读与短句质量

**现象**：

- `UtteranceAssembler.matchesClaimedLanguage` 纯度要求较严（中文路要求 `han ≥ latin`，英文路要求无汉字等），中英混读句可能被两路同时丢弃。
- 面对面 final 后 1 秒内的非自信异语会被 `shouldIgnoreCrosstalk` 丢弃，快速 code-switch 会丢合法内容。
- 文档曾提的 `NLLanguageRecognizer` 第三票未实现。

**进展（2026-11-26）**：真正的单语种同传已改 `.trustedLocale`（P0-5），混合脚本与纯数字不再整句丢；双路 crosstalk、`resolvedLanguage` 重判与夹具仍未开始。

**目标**：混句不直接丢，按 `resolvedLanguage` 重判；crosstalk 窗口按置信度动态；用固定音频夹具做路由准确率回归。

**验收**：中英混读夹具命中率提升且不增加串音；快速切换说话人不丢整句。

### Wave 3：C04 字幕/文字稿投影（已完成）

**来源**：2026-11-23 架构审查候选 C04；完整台账见 [`05-architecture-backlog.md`](05-architecture-backlog.md)。

**原现象（C04 前）**：字幕/文字稿投影有 3 处 `upsertTranscript`（Conversation / Interpretation / Meeting），`PaneState.history` 可变，各 ViewModel 恢复时各自重新投影；显示窗口与文字稿全集的边界分散。

**目标**：把 live / history / archive / merge / restore 投影收敛到一个 module，保持显示窗口（面对面 3 条/侧、同传 50 条仅显示、会议 2 万字累计）与 transcript 全集分离；不改变 P1-1 的 40/90、25/50、voiceOut、crosstalk 与单槽 `outboundJob`（当时口径；该单槽已由 P0-1 改为有序队列）。**已达成**：`CaptionProjection` + `CaptionDisplayPolicy` 单一 record store，三 VM 全部迁移。

**验收**：现有三模块字幕/恢复/清屏/导出测试保持通过；新增投影 module 的边界测试；真机回归字幕窗口、恢复、清屏与导出。

**进展**：2026-11-24 完成 C04a–d（#28–#31，PR #33–#36）：新增投影模块与 28 条契约测试，三 VM 迁移，删除三份 `upsertTranscript` / alias / 跨 ID 文本合并；补齐 `UtteranceAssembler` 的 volatile greeting name swap 新 ID。C04e（#32）的清理与文档已回填：`PaneState` 仅保留派生快照，`TranslationPipeline` alias API 与 `SpokenText.isDistinctGreeting` 删除。完整 iPhone 13 真机矩阵由用户确认通过（2026-11-25）；#32 与父票 #27 已关闭，C04 收口完成。

---

## 3. P2/P3：可观测性、音频、TTS、国际化

| # | 问题 | 代码依据 | 建议 |
| --- | --- | --- | --- |
| P2-1 | Detector 失败静默 | `consume(detector:)` catch 只日志 | 降级提示或打点，切句退化可观测 |
| P2-2 | 单路漂移丢句 | `restartSingle` 全量 reset | 切 locale 时保留最后 final，或提示用户 |
| P2-3 | `BufferConverter` 非 float/int16 静默 nil | `copy` 双分支 | 加计数/日志 |
| P2-4 | 双头管理 AudioSession | Capturer 与 Policy 都 `setActive` | 统一走 Policy gate |
| P2-5 | TTS 参数写死 | `rate = default * 1.28` | v1 补 `prefersAssistiveTechnologySettings`；语速档/试听留 v1.x |
| P2-6 | 语言门禁仅覆盖首页设置 | 生产已注入 `SystemLanguageCatalog` 缓存；其余入口仍可选到不可用语言 | v1 扩展到所有语言入口（单语言能力） |
| P2-7 | 界面文案 `pick` 六参 | `Copy.swift` 遍布六参 | 迁移到 String Catalog，冻结新增 `pick` 参数 |
| P2-8 | MainActor 上的 LCS/compact | `SpokenText.isRefinement` 等在 VM 主线程 | 下沉后台纯函数，缓存 compact 结果 |
| P2-9 | 恢复任务不恢复语言对（已修复 Wave 1 #4/#6–#8） | `TaskLifecycle.restore()` 返回任务语言对，VM 应用并提示「继续任务」 | 已闭环；首页具体任务/启动对账仍留 v1.x |
| P3-1 | 无迁移计划 | `TaskEntity.schemaVersion` 只写不读 | 加 `SchemaMigrationPlan` 与演练 |
| P3-2 | 空稿/误触结束（已修复 Wave 1） | `TaskLifecycle.endTask` + `TaskStoreV2.end` 按持久化内容判空稿；历史/详情删除有确认与失败提示（#5/#12） | 已闭环，保持 |
| P3-3 | 重复能力检查/总结/胶囊样式 | 5 套能力检查、4 套总结、10+ 处 chip | 先抽 `ChipStyle` 与 `ModelPreparation` 协调器，再逐项迁移 |

---

## 4. 明确不做 / 不再投入

- **不重启启动微优化**：200 ms 目标已被控制组地板否定；不要用模拟器证明性能；不要手写 `Order/App.order`。
- **不引入云后端/账号/同步**：违背本机优先与离线承诺。
- **不引入 TCA/RIBs**：三个模块体量不够。
- **不做外放朗读**：回声自激，产品明确禁止。
- **不做实时说话人分离**：当前以语种为路由键；声纹/分离只做技术 spike，不承诺 v1。
- **不在会议记录里做实时同传朗读**：会议目标是全文稿与会后总结。
- **不为了“实时感”无限提高翻译频率**：P1-1 的队列合并已完成（真机验证通过），仍不要用更高翻译频率换实时感。
- **不做本地 digest 回退总结**（D6）；Apple 智能不可用时不提供总结。
- **不做历史自动清理**（D5）；**不做整组会议导出**（D7）。
- **不做六语同等发布承诺 / 繁体中文市场**（D4）；**不做大陆首发**（D2，第二阶段）。

---

## 5. 已完成的清理（2026-11-02）

- 文档合并：`01` 产品、`02` 架构、`03` 选型、`04` 本文件；删除已完成的路线图与重复设计稿（05–13），git 历史仍可追溯。
- 删除未引用代码：`CaptionTypography.controlFont`、`Copy.exportHeader`、`Copy.languageUnavailable`、`Copy.summaryLocalFallback`、`TaskSession.characterCount`、`AppLaunchTracker.launchDurationToNow`、`UtteranceAssembler.isShort`、`UtteranceAssembler.finalizeCurrentIfNeeded`、`ConversationLayout.captionAnimationDuration` / `captionAppearOffset`、`DuiyiError.translationUnavailable`。
- 删除 8 个无引用的 `platform.*` 本地化键；保留被 `Text` 字面量使用的键。
- 合并 `ConversationViewModel` / `InterpretationViewModel` 中完全重复的 `failTranslation` 分支，删除仅用于该分支的取消错误分类；`BilingualSpeechEngine.fail` 去掉未使用参数（原 P2-2）。
- 删除仓库根目录已跟踪的过期 Instruments trace；本地 `build/`、`.hvigor/`、`.DS_Store`、未跟踪 trace 不进入版本库。
- 修正 `docs/02` 对 `.id` 重建、`DeferredTaskStore`、`modelRetention` 的描述；`tools/generate-order-file.sh` 指向现存文档。

---

## 6. 建议排期

> 本节是排期的唯一真源；[`decisions.md`](decisions.md) 的 D1–D7 已于 2026-11-23 确认，D8 于 2026-11-24 补充，本表按同一顺序导航，不重复预估。
> 架构候选台账见 [05-architecture-backlog.md](05-architecture-backlog.md)。

| 顺序 | 事项 | 依赖 | 状态 / 预估 |
| --- | --- | --- | --- |
| 1 | P0-1 `SpeechSessionGate` + `TaskLifecycle` + 三模块接入 + 测试 | 无 | 已完成 Wave 1（#3/#4/#6–#8） |
| 2 | P0-3 降级显性化 + 结果化接缝 + 显式 save | 无 | 已完成 Wave 1（#2/#5/#12）；增量落盘、迁移演练仍待后续（3–5 天） |
| 3 | P0-2 长会话显示窗口 + 计数 | P0-3 已完成部分 | 已完成 Wave 1（#9/#10/#11）；D7 续集任务组仍待后续（1–2 周） |
| 4 | P1-1 翻译队列合并 | 无 | 已完成（#22–#25，main `37f0a50`）；真机验证 2026-11-24 通过（用户确认） |
| 5 | P1-4 混读/短句质量 | 真机夹具 | 部分：单路 trusted locale 已修（P0-5，2026-11-26）；双路混读/crosstalk 与夹具未开始（1–2 周） |
| 6 | Wave 3 C04 字幕/文字稿投影 | 无（建议 P1-4 后） | 已完成（#28–#32；真机矩阵 2026-11-25 用户确认） |

同一失败检查修复 2 次仍失败，或同一子任务 3 轮修复-验证无进展时停止上报（团队规则）。

---

## 7. 交接前需要确认的产品/工程决策

决策已合并到 [`decisions.md`](decisions.md) 的 **D1–D8**（唯一真源，D8 于 2026-11-24 补充）；
本文件不再保留重复列表，只在此留指针。P0-2/P0-3 的产品侧行为按 D5–D7 与「v1 冻结口径」实现。
