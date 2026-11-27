# 真机测试（iPhone）

> 触发：需要在物理 iPhone 上构建、跑 UI 测试、验证语音/翻译/TTS，或把真机矩阵结果写回票面时先读本页。
> 模拟器入口见 [`README.md`](../../README.md) 与 [`DuiyiTests/AGENTS.md`](../../DuiyiTests/AGENTS.md)；本页只写真机增量。

## 1. 前置检查（每轮先过一遍）

| 检查 | 命令 / 位置 | 通过标准 |
| --- | --- | --- |
| Mac 开发者工具安全 | `DevToolsSecurity -status` | `enabled`；未开启时由用户执行 `sudo DevToolsSecurity -enable` |
| iPhone Developer Mode | 设置 → 隐私与安全性 → 开发者模式 | 开启 |
| iPhone UI 自动化 | 设置 → 开发者 → 启用 UI 自动化 | 开启 |
| 屏幕 | 解锁，测试期间保持常亮（设置 → 显示与亮度 → 自动锁定 → 永不） | runner 能启动并 background |
| 连接方式 | `xcrun xcdevice list` | 目标设备 `interface: usb`；Wi-Fi 会出现 “IDE disconnection” |
| Xcode | `pgrep -x Xcode` | 跑 runner 前完全退出（⌘Q）；开着 GUI 时 runner 可能直接 code 74 |
| 签名 | `security find-identity -v -p codesigning` | 有 Apple Development 身份 |
| 本地签名配置 | `Config/Local.xcconfig` | 含 `DEVELOPMENT_TEAM` 与 `DEVICE_UDID`；`tools/device.sh check` 会读 |

设备、UDID 与应用清单：

```bash
xcrun devicectl list devices
xcrun xcdevice list
xcrun devicectl device info apps --device <DEVICE_UDID>
```

## 2. 签名、设备与免费账号槽位

签名与设备信息只放在本机、不进仓库：

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
# 编辑 Config/Local.xcconfig：
#   DEVELOPMENT_TEAM = <team id>
#   DEVICE_UDID = <device udid>
```

- `Config/Shared.xcconfig` 是工程的 base configuration；`Config/Local.xcconfig` 被它可选包含，并已加入 `.gitignore`。**Xcode 手动真机调试与 `tools/device.sh` 读取的是同一份本地配置**，不需要每次在 Signing & Capabilities 里重设 Team。
- 本仓库不提交 `DEVELOPMENT_TEAM`（`tools/check-static.sh` 会拦截）；`project.pbxproj` 不再保存空 Team 设置。
- 从本机证书取 Team ID（`OU=`）：

```bash
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject -nameopt RFC2253
xcrun devicectl list devices   # 取 DEVICE_UDID
```

- 免费开发者账号每台设备最多安装 3 个 App。装不下 agent-device / XCUITest runner 时，先卸载可再生的测试 runner：

```bash
xcrun devicectl device uninstall app --device <DEVICE_UDID> com.david.DuiyiUITests.xctrunner
```

- Xcode 仍可能把 `DEVELOPMENT_TEAM` 写回 `project.pbxproj`，或在 `Localizable.xcstrings` 里加空 key；提交前用 `tools/check-static.sh` 检查并还原这两类噪音。

## 3. 路径 A：agent-device（物理设备推荐）

Maestro 的 `list_devices` 只列模拟器；物理 iPhone 用 agent-device。仓库把它收敛到 `tools/device.sh`：

- **版本固定**：`agent-device@0.21.13`（通过 `npx --yes` 运行；首次下载到 npx 缓存）。
- **签名/设备固定**：读 `Config/Local.xcconfig` 的 `DEVELOPMENT_TEAM` / `DEVICE_UDID`。
- **状态目录固定**：`.device-state/`（gitignored），session 默认 `mybuddy-device`。
- **runner bundle**：`com.david.agentdevice.runner`（可用 `AGENT_DEVICE_IOS_BUNDLE_ID` 覆盖）。

```bash
tools/device.sh check          # DevToolsSecurity / 设备 / USB / Xcode 状态
tools/device.sh open           # 打开 com.david.Duiyi
tools/device.sh snapshot
tools/device.sh click @eN
tools/device.sh press <x> <y>
tools/device.sh wait 4000
tools/device.sh screenshot /tmp/<name>.png
tools/device.sh close
tools/device.sh ui-tests       # 设备上的 XCUITest（已知 code 74 风险）
tools/device.sh agent <args>   # 直通 agent-device
```

要点：

- `DEVICE_IN_USE` 表示设备被另一个 session 持有：复用它的 `--session`（`DEVICE_SESSION=...`），或先 `tools/device.sh close`。
- mutation 后 ref 会重排；下一步目标从新的 `snapshot` 取，不沿用旧 ref。
- 面对面倒字侧对无障碍隐藏，快照里没有；用 `screenshot` 后读图（文字旋转 180°）。
- 第一次 `open` 会构建/签名 runner，耗时几分钟；之后再开会复用。
- 需要绕过脚本调试时，等价环境变量是 `AGENT_DEVICE_IOS_TEAM_ID` / `AGENT_DEVICE_STATE_DIR` / `AGENT_DEVICE_IOS_BUNDLE_ID`，值来自 `Config/Local.xcconfig`。

## 4. 路径 B：设备上的 XCUITest

```bash
xcodebuild test -project Duiyi.xcodeproj -scheme Duiyi \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -derivedDataPath /tmp/duiyi-device-dd \
  DEVELOPMENT_TEAM=<TEAM_ID> -allowProvisioningUpdates \
  -only-testing:DuiyiUITests -parallel-testing-enabled NO \
  -resultBundlePath /tmp/duiyi-device-ui.xcresult
```

已知问题：Xcode 27.1 + iOS 27.2.1 下 runner 可能以 code 74 退出（`failed to background` / `IDE disconnection`）。先按 §1 检查锁屏、UI 自动化、Xcode 退出与 USB；仍失败则改用 §3 的 agent-device。

失败时导出设备侧诊断，先看 `testmanagerd.log` 与 `StandardOutputAndStandardError.txt`：

```bash
xcrun xcresulttool export diagnostics \
  --path /tmp/duiyi-device-ui.xcresult --output-path /tmp/duiyi-device-diag
```

## 5. 声学冒烟（Mac 播放 → 手机识别/翻译）

用固定输入文本驱动，避免“听起来差不多”的模糊判断。

```bash
say -v '?' | grep -E 'en_US|zh_CN'      # Samantha / Tingting
osascript -e 'set volume output volume 85'
say -v Samantha "<English sentence>"
say -v Tingting "<中文句子>"
```

步骤：

1. 在 App 内新建任务并开始聆听（同传/会议需手动点 `listening-control`；面对面按偏好可能自动开始）。
2. `say` 播放一句；`agent-device wait 4000–6000` 等 ASR/翻译落定。
3. `snapshot -i` 读用户侧/会议文字稿；倒字侧用 `screenshot` 读图。
4. 与**已知输入**的预期译文做语义比对（内容词、数字、语种），不做逐字比对。

判定边界：

- 只把与输入强对应、语义一致的行计为通过；房间人声、混合误识别（如两句话被拼成一行）不计入证据。
- 能证明 ASR 抓到内容、翻译语义正确、字幕路由到正确 pane。
- 不能证明翻译地道程度、TTS 实际出声、延迟、长时稳定性；voiceOut 需要耳机 + 人耳，crosstalk 需要受控时序，2 万字需要长时连续语音。

## 6. 常见故障

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| runner 以 code 74 退出 / 无法 background | 锁屏、UI 自动化未开、Xcode 未退出、Wi-Fi 连接 | 按 §1 逐项处理 |
| `signing_provisioning_profile_missing` | agent-device 未拿团队 | 设 `AGENT_DEVICE_IOS_TEAM_ID`（必要时 `AGENT_DEVICE_IOS_BUNDLE_ID`） |
| 免费账号装不下 runner | 每设备 3 App 上限 | 卸载可再生的 `DuiyiUITests.xctrunner` |
| 测试 App 能启动、runner 不能 | Mac `DevToolsSecurity` 未开 | 由用户执行 `sudo DevToolsSecurity -enable` |
| TTS 播放了但无字幕 | 音量/输出设备不对，或句子太短 | 音量 ≥80、内置扬声器、换长句重试 |
| 设备原有未结束任务被恢复 | 模块 bootstrap 自动恢复 | 只读查看可；追加/结束任务前先询问用户 |

### 6.1 直接读取设备任务历史（runner 不可用时）

只想核对最新任务的原文/译文，不需要驱动 UI 时，直接拷 App 数据容器（只读，不改设备）：

```bash
xcrun devicectl device copy from --device <DEVICE_UDID> \
  --domain-type appDataContainer --domain-identifier com.david.Duiyi \
  --source "Library/Application Support" --destination /tmp/duiyi-appdata
sqlite3 "/tmp/duiyi-appdata/Application Support/default.store" \
  "select t.Z_PK, datetime(t.ZSTARTEDAT+978307200,'unixepoch','localtime') from ZTASKENTITY t order by t.ZSTARTEDAT desc;"
sqlite3 "/tmp/duiyi-appdata/Application Support/default.store" \
  "select ZSORTINDEX, ZISFINAL, ZSOURCETEXT, ZTRANSLATEDTEXT from ZTRANSCRIPTENTITY where ZTASK=<pk> order by ZSORTINDEX;"
```

- 必须同时拷 `default.store`、`default.store-wal`、`default.store-shm`；Core Data 时间戳是 Unix 秒减 `978307200`。
- 任务表 `ZTASKENTITY`，文字稿表 `ZTRANSCRIPTENTITY`（字段 `ZSORTINDEX` / `ZSOURCETEXT` / `ZTRANSLATEDTEXT` / `ZISFINAL`）。
- `Library/Caches/TranscriptExports/` 里是用户导出过的文字稿；`Documents/` 里可能有诊断 JSON。
- 诊断 recorder 是内存态；真机复测后要让用户先在设置页导出，再拷 `Documents`。

### 6.2 面对面单路 A/B（DEBUG）

1. 首页右上角齿轮 → 设置 → DEBUG 区「面对面单路听写（DEBUG）」，关闭 = 双路（A），开启 +「对方语言」= 单路（B）；改动在下一次开始听写时生效。
2. 同一台 iPhone、同一摆放、同一段音频；每臂跑 3 次并交错，导出诊断 JSON 时在文件名标注 `A` / `B-peer` / `B-user`。
3. 指标与判定见 [`docs/research/face-to-face-dual-locale-quality.md`](../research/face-to-face-dual-locale-quality.md) §3.3–3.4；Release 构建不包含该开关。

## 7. 记录与收口

- 先在模拟器跑 `tools/test-unit.sh` 与 `tools/check-static.sh`；真机矩阵只补模拟器覆盖不到的部分。
- 环境、通过项、未验证项与证据路径写回对应票（本轮见 [#32](https://github.com/DavidTeam2008/mybuddy/issues/32)）；证据是本机截图时注明“未上传”。
- 矩阵未完整通过前不要标“已完成”；跳过项要写“未验证”+原因/手动步骤。
- 结束后：`tools/device.sh close`；需要时卸载 runner 释放槽位；把自动锁定改回用户偏好；确认 `git status` 没有 Xcode 噪音。
- `.device-state/` 与 `.device-derived/` 都是本机产物，已 gitignore；不要提交 `Config/Local.xcconfig`。
