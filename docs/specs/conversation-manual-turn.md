# 面对面手动说话人切换（Manual Turn）

> 状态：规格（2026-11-27）。触发：面对面自动语种路由在真实对话里仍会出现串音、错误分侧和双路故障；单路 A/B 已证明单语言识别足以对齐同传。产品决定：**手动模式作为默认，自动模式作为备选**。
>
> 关联：`docs/research/face-to-face-dual-locale-quality.md`、`docs/research/speech-transcriber-segmentation.md`、PR #88（DEBUG 单路开关）。

## 1. 目标

让面对面在两人轮流说话时，由用户显式指定“现在谁在说”，从而：

- 一次只跑**当前说话人的语言**（单活跃 locale），与同传的识别路径对齐；
- 不依赖语种检测/串音逻辑决定 pane 和翻译方向；
- 避开双 locale 的额外成本与“一个 transcriber 失败导致整条流红按钮”的故障模式；
- 保留自动模式作为备选（同一语言对、用户不想手动点时使用）。

## 2. 模式

| 模式 | 听写请求 | 路由 | 默认 |
| --- | --- | --- | --- |
| 手动（Manual） | 单路 `[activeLanguage]` | `activeSpeaker` 决定听者 pane；无 `LanguageRouter`/crosstalk | **是** |
| 自动（Automatic） | 当前双路 `[userLanguage, peerLanguage]` | 现有 `LanguageRouter` + `routedSideByUtterance` + crosstalk | 否（备选） |

- 模式存在 `PreferencesStore`，新任务/重启后保留。
- 模式切换在**下一次开始听写**时生效；若正在听写，先停流并提示用户点一侧重新开始，避免热切语言。
- 自动模式保持现有行为，不因手动模式改动而回归。

## 3. 状态机

```text
manual, task active, activeSpeaker == nil
  → 显示「谁先说话，点一下自己这边」
  → 点 user 侧：activeSpeaker = .user, listener = .peer, 开始 [userLanguage]
  → 点 peer 侧：activeSpeaker = .peer, listener = .user, 开始 [peerLanguage]

manual, listening, activeSpeaker == A
  → 点 A 侧：no-op
  → 点 B 侧：activeSpeaker = B
       → pause 当前流 → drain final → start 单路 [B 的语言]
       → 任务不结束、transcript 不清空、pane 历史保留
  → 暂停（中间按钮）：保留 activeSpeaker；恢复时用同一语言
  → 新任务：activeSpeaker = nil；回到「点一侧开始」
  → 结束任务：清空 activeSpeaker
```

- 第一下点击即开始；手动模式**覆盖** `autoStartListening`，没有 activeSpeaker 时不自动启动。
- 点中间收听按钮时，若 `activeSpeaker == nil`，默认视为 user 并开始；这是键盘/辅助功能的兜底，不改变 pane 点击的主路径。
- 切 turn 的停/启顺序必须复用现有 `pauseListening` → `drainSpeechTask` → `start`；旧流 final 先落地，再开新流。不能 `beginTask`/`endTask`。
- `routedSideByUtterance` 仍需按 utterance ID pin 住听者侧，迟到 final 保持在原 pane。

## 4. 听写与翻译

- `makeListeningRequest()`：
  - manual + activeSpeaker → `languages: [activeLanguage]`, `fallbackLanguage: activeLanguage`, `.liveCaptions`, `.faceToFace`。
  - manual + activeSpeaker == nil → 不启动（返回 ready/paused）。
  - automatic → 现有双路（DEBUG 单路开关在此期间仍可覆盖，方便 A/B；手动模式落地后可以移除/保留为实验）。
- `accept(_:)`：
  - manual：`speaker = activeSpeaker`，`listener = activeSpeaker.opposite`；`projection.ingest(utterance, pane: listener, speaker: speaker)`；翻译 target = listener 的语言。跳过 `shouldIgnoreCrosstalk` 与 `LanguageRouter`。
  - automatic：现有逻辑不变。
- `isFinal`/`isRevision`/late-final 复用 ID 的规则不变。
- 单路请求下 `Utterance.language` 是当前 transcriber 的语言；若用户说错语言/串音，文本可能变差，由用户点另一侧纠正；不新增自动语言判定。

## 5. UI

### 5.1 两侧 turn 控制

- 每个 pane 顶部放一个全宽 turn 条（在 caption 内容上方，避开语言 chip/滚动）：
  - 未激活：「我来说」/「对方说」（按视角）；
  - 激活：显示「我在说」/「对方在说」+ mic 图标 + 说话色背景；
  - 点击：调用 `setActiveSpeaker(side)`；有 haptic；有 accessibility identifier：
    - `conversation-turn-user`
    - `conversation-turn-peer`
- 上方 pane 旋转 180°；turn 条随 pane 旋转，物理上由对方点击。上方 pane 仍 `.accessibilityHidden(true)`（现有行为），VoiceOver 用户使用下方 turn 条/中间控制。
- 说话色：新增 `Tokens.speaking`（建议暖色/品牌色，不用 `danger`；与 `listen` 区分），背景用低透明度 tint，文字/图标用高对比前景；不能只靠颜色，必须有文字/图标。
- 未选 speaker 时：两侧 turn 条都显示「点我开始」提示；中间控制显示「谁先说话，点一下自己这边」的辅助文案（Copy 新增）。
- 切 turn 时：旧 pane 的 speaking 色退场，新 pane 入场；动画 150–200 ms；不要遮挡 caption。

### 5.2 设置

- 面对面设置里新增「说话方式」：手动（默认）/ 自动（备选）。
- 文案解释：
  - 手动：谁说话，点谁那一侧；识别更接近同传，适合轮流对话。
  - 自动：自动按语言分侧；适合不方便点屏幕的场景。
- 切换模式时：停止当前听写、清空 activeSpeaker（manual）或恢复自动请求；不结束任务。

## 6. 边界与风险

- **切 turn 延迟**：停/启动 transcriber 预计 0.5–1 s，第一词可能丢；用户先点再说。真机测量并记录；若不可接受，再评估双路保活/预启动（不作为首版）。
- **两人同时说话**：最后一次点击获胜，另一人的语音可能被当前语言识别成乱码；手动模式本质是 turn-taking。UI 提示「说完点对方」。
- **后台/恢复**：保留 activeSpeaker；恢复时若任务 active，按 active 语言重启或等待用户点。不要自动改为另一语言。
- **模式切换**：不热切；停流并提示。
- **新任务**：activeSpeaker 清空；手动模式不自动开始。
- **top pane 可访问性**：物理点击可用；VoiceOver 仍走下方控制。
- **语言对变化**：`setUserLanguage`/`setPeerLanguage`/`swapLanguages` 停流、清 activeSpeaker、回到「点一侧开始」；不自动用旧 active 语言。
- **调试开关**：DEBUG 单路开关保留到手动模式真机验证通过；之后可移除或仅用于 A/B。

## 7. 架构

- 先落在 `ConversationViewModel`：
  - `enum ConversationListeningMode { case manual, automatic }`（Domain 或 Features 内部）。
  - `var listeningMode`、`var activeSpeaker`。
  - `makeListeningRequest()`、`accept(_:)`、`setActiveSpeaker(_:)`、`setListeningMode(_:)`。
- 复用 `TaskLifecycle`/`SpeechSessionGate` 的停/启顺序；不新增引擎 API。
- 这正是之前评估的 `LiveSessionRuntime` + policy 的 candidate：后续可把 turn/restart 顺序收进 runtime，`ConversationTurnPolicy` 只提供 `activeSpeaker`/`listeningRequest`/`route`。首版不阻塞于 runtime 重构。
- 测试面：
  - 手动默认 + 无 active：新任务不自动启动；
  - 点 user/peer：请求 `[对应语言]`、fallback 对齐；
  - 切 turn：任务保持 active、transcript 不清空、旧流 drain、新请求单路；
  - manual 路由：行落到 listener pane，翻译 target 正确；
  - manual 模式不跑 crosstalk/LanguageRouter；
  - pause/resume 保留 active；新任务清空；
  - 自动模式请求/路由完全不变；
  - 模式切换停流/不结束任务。

## 8. 验收

- 手动模式默认；新任务后点一侧即开始单路识别；对方点另一侧后切到对方语言；翻译/字幕始终落在听者 pane。
- 同一段 TED 英文，面对面手动单路与同传的原文/译文质量对齐（以现有 research 的指标口径）。
- 双路故障（红按钮）在手动默认路径不再出现；自动备选仍可用，并另开 P0-6b 的 speech failure 诊断/回退。
- 单测全绿、`check-static`、D8 verifier、真机 3 轮（中英各说一段 + 连续 turn 切换 + 后台恢复）。

## 9. 不做

- 不做 on-device 说话人 diarization（无公开 API、无第三方依赖）。
- 不做事后合并/跨 ID 上下文翻译（D8 不允许）。
- 不把自动模式删除；它是备选，不是回退。
- 不在首版做双路保活/无缝 crossfade；先测手动单路的延迟。
