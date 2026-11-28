# 真机音频夹具注入：评估与原型（2026-11-27）

> 目标：把“Mac 播放 → 功放 → iPhone 麦克风采集”的真机测试换成文件注入，让 ASR → 组装 → 翻译 → 字幕/落库自动跑完，不依赖安静房间。P1-4b 的 TED 回放此前因房间人声污染暂停（`docs/04-roadmap.md:30`）。

## 0. 结论

- **可行。** DEBUG 构建在 `AudioCapturing` 接缝注入 `FixtureAudioCapturer`，按生产 tap 的 1024 帧/48 kHz 单声道喂 WAV；`BilingualSpeechEngine.ingest`、`BufferConverter`、`SpeechAnalyzer`、`SpeechTranscriber`、`UtteranceAssembler`、翻译、字幕、SwiftData 均未改。
- 30 秒冒烟：8–9 行、全部有译文、0 空译、0 U+FFFD；`sentFrames` 精确 1,440,000（30 s × 48 kHz）。
- 13 分钟 TED：158 行、158 行有译文、0 空译、0 U+FFFD、0 前缀重复；源文覆盖 **93.33%**、精确 91.70%、WER 8.87%；final 延迟 p95 **61.3 ms**；`sentFrames` 精确 37,680,000；`endTask` 正常 ended。
- 房间外放人声时重跑，字幕仍是 TED 内容，没有“quick brown fox”噪音句；注入路径不使用麦克风。
- **质量注意**：93.33% 低于调研基线 99.12%（`docs/research/simultaneous-translation-quality.md`），但重复前缀从 5.7% 降到 0。这不是注入路径失败，而是当前 ASR/组装在该音频上的真实缺口；需要同音频 A/B（旧版或声学路径）再归因，不能把夹具 PASS 当作质量签收。
- 1× 实时是常规口径；30 s 全速（`max`）只有 2 行/30.1% 覆盖，证明不能用于句界/质量结论。
- 10 秒静音负对照：0 行、`discardedEmpty`，没有伪造字幕。
- 13 分钟内有 2 次 `corruptedOutput`（1 次 final），被 U+FFFD 完整性闸门拒绝；158 行仍有译文（失败 final 的行保留先前结果），0 U+FFFD。诊断 ring buffer 丢弃 467 个旧事件；summary 计数完整。

## 1. 原型

- `Duiyi/Services/Audio/FixtureAudioCapturer.swift`（`#if DEBUG`）：`AVAudioFile` 读文件，1024 帧、原生格式、按音频时间 1× 节拍 yield；EOF 后 `stats.finished=true`。
- `Duiyi/App/DebugAudioFixture.swift`：`-duiyi.fixtureAudio` 等 launch args；路径相对 `Documents` 或绝对；`-duiyi.fixturePacing realtime|max`；`-duiyi.fixtureDeleteAfterRun`。
- `Duiyi/App/DebugFixtureRun.swift`：导航到同传 → 权限/资源/语言对预检 → 新建任务 → `start()` → 等 EOF → settle → `endTask()` → 导出诊断 → 写 `fixture-run-done.json`。
- `Duiyi/App/AppEnvironment.swift` / `RootView.swift`：DEBUG-only 注入与启动；Release 不编译。
- `tools/fixture-run.sh` / `tools/fixture-score.py` / `tools/fixtures/ted-cue132-331.tsv`：构建/安装/推送/跑/取证/计分；证据在 `.device-state/fixture-runs/<run-id>/`。

## 2. 设备实测

### 2.1 30 秒冒烟

| run | fixture | 环境 | 行数 | 有译文 | 覆盖 | 精确 | WER | 说明 |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| smoke-2 | WAV | 安静 | 8 | 8 | 81.9% | 75.9% | 24.1% | 30 s 截断，尾部 cue 不完整 |
| smoke-5 | WAV | 安静 | 8 | 8 | 83.1% | 75.9% | 24.1% | 前 7 行与 smoke-2 完全一致，尾行在截断点不同 |
| smoke-4 | WAV | Mac 外放人声 | 9 | 9 | 86.7% | 80.7% | 19.3% | 字幕全是 TED；无噪音句 |
| smoke-3 | M4A | 安静 | 9 | 9 | 83.1% | 79.5% | 20.5% | AAC 往返改变分词；不作为保真口径 |

- 四组均 0 空译、0 U+FFFD、0 前缀重复；final 延迟 p95 51–76 ms；`sentFrames` 每次 1,440,000。
- 30 s 覆盖/精确/WER 受“从句子中间开始、在句子中间结束”影响，不是通过线；只用于对比同一夹具的运行间方差。

### 2.2 13 分钟 TED

夹具：`docs/media/TED.mp3` 的 08:31–21:36，48 kHz 单声道 WAV，785 s，72 MB；1× 实时；iPhone 13。

| 指标 | 值 |
| --- | --- |
| marker 行数 / 有译文 | 158 / 158 |
| 源文覆盖（token 存在性） | **93.33%**（matches 1458、substitutions 26、deletions 106、insertions 9） |
| 精确匹配 / WER | 91.70% / 8.87% |
| 前缀重复行 | 0 |
| 空译 / U+FFFD | 0 / 0 |
| 中文译文行 | 158 |
| settled / final jobs / final applied | 158 / 178 / 177 |
| permanent failures / rejected corruption | 2 / 2（均为 `corruptedOutput`） |
| synthetic finals / revisions | 5 / 18 |
| script mismatch（只记录，不丢句） | 24 |
| final 延迟 p95 | 61.3 ms（160 个 final apply 样本） |
| 诊断丢弃事件 | 467（ring buffer 4096；summary 完整） |
| `sentFrames` | 37,680,000（785 s × 48 kHz） |
| 运行时长 | 803.8 s |
| store / WAL | 120 KB；停止后 WAL 已 checkpoint |

### 2.3 质量发现（不是注入失败）

- 覆盖 93.33% 低于调研基线 99.12（`docs/research/simultaneous-translation-quality.md` §1），但重复前缀从 5.7% 降到 0。当前夹具是**真实 TED 音频**，基线来自另一次真机会话；没有同音频 A/B，不能把差异直接归因给注入。
- 文字稿可见缺口类型：
  - 行 6 把 “Give someone a white coat … In all of these cases, same people … different beliefs.” 合成一行，跨越多条 cue；
  - 行 11/12 在 “A headset that allows us to see things…” 处丢边界词；
  - 行 150/151 丢掉 “they were / to” 等尾词；
  - 行 92（`69D8B591-…`）的 final 翻译被完整性闸门拒绝，store 保留先前译文 “我感到很驚訝，很自豪，很解放了，”（缺 “and confused”，且混入繁体字，属于语义评审候选）。
- 这更像 P1-1 range-aware 组装的合句/边界问题 + P1-3 ASR 精度问题，而不是 `AudioCapturing` 注入问题。下一步：同一音频跑旧版/声学路径做 A/B，再决定是否调整组装。
- `permanentFailureCount=2` 是 integrity gate 的记录，不是静默丢行；final applied 177/178，store 158 行均有译文。

### 2.4 收口与稳定性

- EOF 在 785 s 到达；settle 12 s；`endTask()` 走 `finalizeAndFinishThroughEndOfInput()`，返回 `ended`，158 行进入 store；无超时。
- 13 分钟单次运行；更长会话的热/内存/续集组、以及同一夹具的第二次全量回放仍未验证。短夹具的 30 s 重复已验证喂入层确定性（帧数精确、前 7 行一致）；ASR 在截断点有运行间方差。
- 停止后 store 120 KB、WAL 已 checkpoint；运行期间的写放大/内存曲线未采样，P0-3 的写放大需要单独观测。

### 2.5 负对照与节奏

- **静音 10 s**：0 行、`discardedEmpty`、无错误、无伪造字幕；`sentFrames=480,000`。
- **30 s `max`**：2 行、覆盖 30.1%、7 次 revision、final p95 593 ms；证明全速喂入会破坏墙钟句界，只能做 ASR 文本筛选。
- **30 s 人声外放**：9 行、覆盖 86.7%，字幕全部是 TED，无噪音句。
- **30 s M4A**：9 行、覆盖 83.1%、精确 79.5%、WER 20.5%；分词与 WAV 不同，保真回归用 WAV。

## 3. 方案矩阵

| 方案 | 执行的生产代码 | 绕过 | 能证明 | 不能证明 | 实测/成本 |
| --- | --- | --- | --- | --- | --- |
| A 文件 `AudioCapturing` | capture 接口之后全部：BufferConverter、SpeechAnalyzer、assembler、翻译、落库 | 麦克风/ADC/房间/真实路由 | ASR→翻译→落库可自动跑；环境无关；可重复 | 麦克风硬件、路由/回声、TTS 出声、真实噪声鲁棒性 | 已实现；30 s ×4 + 30 s max + 静音 + 13 min；WAV 72 MB / M4A 9.4 MB |
| B 直接 `AnalyzerInput` | ASR 之后全部；跳过 `BufferConverter` | A 的采集层 + BufferConverter | 只能再回答“ASR 本身是否接受文件输入” | 比 A 少测转换层；A 成功后无新增信息 | 未跑；A 已包含该结论，B 会降低覆盖 |
| C 测试专用 AVAudioEngine | 测试引擎 + analyzer | 生产 inputNode | 只能换一个引擎配置 | 不是生产采集路径，不增加保真 | 未跑；收益为负 |
| D 有线电学回环 | 真实麦克风/ADC/会话/路由 | 只去掉房间声学 | 保留 A 绕过的硬件层 | 仍需电平和受控环境；不是注入 | 按用户决定不采购；保留发布前安静房间声学冒烟 |

## 4. 推荐

1. 常规真机回归用 **A**：`tools/fixture-run.sh` 默认 WAV / 1× / TED 13:05；证据落 `.device-state/fixture-runs/<run-id>/`。
2. 发布前保留**安静房间声学冒烟**，只覆盖注入测不到的部分：麦克风、路由/回声、真实 TTS 出声、crosstalk；不再用它跑 ASR→翻译回归。
3. WAV 是保真口径；M4A 只用于快速筛选。`--pacing max` 只做 ASR 文本筛选，不做句界/延迟结论。
4. 每次改动跑：30 s ×3（确定性/环境无关）+ 13 min（覆盖/重复/延迟）；做质量对比时同一音频至少两次全量或旧版/声学 A/B。
5. DEBUG seam 默认关闭、Release 不编译；设备首次使用需：已授权麦克风/语音识别、已安装听写/翻译资源；否则 `TaskLifecycle` 的权限/资源门会挡住（本次实测 granted/installed）。
6. 翻译语义按用户决定做 LLM + 人工评审；`tools/fixture-score.py` 的覆盖/精确/WER 只是机械指标，不是语义质量。默认全量跑已加 `tools/fixtures/ted-baseline.json` 相对基线（覆盖/精确/WER 各 1 个百分点、≤5 词短句保留率 2 个百分点、`requiredCues` canary 长句零缺失），`--min-coverage 0.90` 仍只是夹具健全性下限；短句/长句检查都是 token 级机械检查，不替代语义评审，调研的 99% 质量目标另设。
7. 当前 93.33% 覆盖和行 6/11/12/150/151 的缺口，应作为 P1-1/P1-3 的后续证据；不要为了夹具数字回退注入方案，也不要把夹具 PASS 当成质量签收。

## 5. 未验证 / 边界

- 麦克风硬件、ADC、音频路由切换、耳机/回环、回声、crosstalk。
- 真实 TTS 出声（runner 关闭 voiceOut）。
- 麦克风权限 denied、听写资源未安装、翻译语言对 `.supported`（需首次下载）时的行为。
- B/C/D 未跑；D 无硬件。
- `max` 已证明不能用于句界/质量；没有逐句延迟的 `max` 结论。
- 13 min 是单次；更长会话的热/内存/持久化写放大、以及多轮重复的长时稳定性未验证。
- 翻译语义质量仅准备数据，未做完整评审；行 92 的繁体字/截断、2 次 corruptedOutput 是评审候选。

## 6. 复现

```bash
tools/fixture-run.sh                      # 13:05，1×，WAV
tools/fixture-run.sh --noise --run-id ted-noise
tools/fixture-run.sh --start 511 --duration 30 --ground-truth /tmp/gt-30s.tsv --min-coverage 0.5
```

证据目录包含：`fixture-run-done.json`、`fixture-run.log`、`duiyi-diagnostics.json`、`UITestStores/fixture-<id>.store`、`transcript.tsv`、`score.json`、`fixture-info.txt`、`fixture.sha256`、`build.log`、`install.log`。本次 13 分钟全量证据在本机 `/tmp/duiyi-fixture/evidence-full-1`（未入库）。
