# Xcode 27 系统外观审计（#42）

> 日期：2026-11-25
> 构建基线：`main` = `0eeda74`，Xcode 27.1（27A9275），Debug；模拟器 iPhone 17 Pro Max，iOS 26.4.1。
> 范围：不改代码、不加玻璃，记录当前构建下系统组件的绝对外观，供 #43/#44/#45–#48/#49 使用。
> 口径：**未使用 Xcode 26 基线，也未采集 iPhone 13（iOS 27.2.1）真机**；因此本文只记录当前运行时的观察，不声称 “Xcode 27 前后变化” 或 “iOS 27 行为”。仓库 `docs/images/*.png` 是产品旧截图，仅作视觉参照，不作前后对比证据。
> 数据限制：模拟器没有 `SpeechTranscriber`，App 也没有文本输入或种子数据入口；要产生 “已完成且有文字稿” 的任务需要真机数据或 store seeding。因此 History 行、详情、ShareLink/share sheet 留到 #49 真机补；浅色外观已在 #43（已合并）补齐，见 “浅色外观补充”。

## 观察

1. **HomeSettingsSheet**：系统 `.sheet`。当前 iOS 26.4.1 运行时渲染为 medium/large detent、顶部圆角 + grabber；内部 `.background(Tokens.canvas)` 把系统材质盖成纯色。
2. **confirmationDialog**（结束任务）：当前渲染为居中浮动卡片，约 240×124 pt（x 100–340，y 429–553），主按钮约 208×48 pt；卡片只显示 “结束任务”。代码声明了 `role: .cancel` 的 “取消”，但当前卡片中没有对应元素，系统提供 `PopoverDismissRegion`（点卡片外取消）。这是当前运行时的实际层级，需在 #49 真机/iOS 27 复核 VoiceOver 与取消可达性。
3. **HistoryView**：模拟器 store 为空，只观察自定义空态与筛选 chips；无 List 行。
4. **ShareLink/share sheet**：未触发；`ExportShareButton` 使用系统 `ShareLink`，外观未验证。
5. **强制暗色**：审计时 App 入口与各屏强制 `.preferredColorScheme(.dark)`；#43 已全部移除，App 跟随系统明暗（浅色证据见下节）。
6. **三模块**：`.toolbar(.hidden)` + `ModuleChrome`/`TaskBar` 自定义 chrome；系统导航栏被隐藏。
7. **兼容 key**：未使用 `UIDesignRequiresCompatibility`；Xcode 27 构建直接采用当前设计（研究文档 [A18] 说明该 key 在 iOS 27+ 构建被忽略；本审计未在 iOS 27 运行时验证）。

## 量测

| 项 | 值 | 来源 |
| --- | --- | --- |
| confirmationDialog 卡片 | 240×124 pt（100,429）–（340,553） | Maestro accessibility hierarchy |
| 对话框主按钮 | 208×48 pt（116,489）–（324,537） | 同上 |
| 设置 sheet medium 顶边 | ≈459 pt | 截图 `settings-medium-dark-17promax.png` |
| 设置 sheet large 顶边 | ≈62 pt | 截图 `settings-large-dark-17promax.png` |

圆角半径未由系统层级暴露，未虚构数值。

## 证据

| 截图 | 说明 |
| --- | --- |
| `xcode-27-appearance/home-dark-17promax.png` | 首页；强制暗色 |
| `xcode-27-appearance/settings-medium-dark-17promax.png` | HomeSettingsSheet medium detent |
| `xcode-27-appearance/settings-large-dark-17promax.png` | HomeSettingsSheet large detent |
| `xcode-27-appearance/confirmation-dialog-dark-17promax.png` | 结束任务对话框；仅主按钮可见 |
| `xcode-27-appearance/history-empty-dark-17promax.png` | 空历史与筛选 chips |

## 浅色外观补充（#43 合并后）

#43 移除了强制暗色并统一语义 token，按同一口径（iPhone 17 Pro Max 模拟器，iOS 26.4.1，Xcode 27.1 构建）补拍系统明暗两套截图，存放于 `docs/research/ui-tokens/`（14 张：home / settings / conversation / interpretation / meeting / history / onboarding × light / dark）。

对系统组件外观的直接观察：

- **HomeSettingsSheet（light）**：系统 `.sheet` 材质在浅色下呈现为半透明浅色层，可透出首页内容；#43 已移除内部 `.background(Tokens.canvas)`，材质不再被盖住。`settings-medium` / `settings-large` 两种 detent 的暗色证据仍见上表。
- **HistoryView（light / dark）**：空态与筛选 chips 在两种外观下均由 token 驱动；未新增 List 行证据（数据 seam 同前）。
- **confirmationDialog**：仅暗色证据；浅色未补拍，行为与尺寸记录见 “观察 2”。
- **引导页 / 三模块 / 详情外的共享 sheet**：随系统明暗切换；不属于本审计的系统组件清单，仅作为 #43 的回归证据。

## 对后续票的影响

- **#43（已合并）**：移除全局/各屏强制暗色与内部遮挡背景；补浅色截图与对比度测试；移除 `HomeSettingsSheet` 的内部 canvas 背景。
- **#44**：筛选 chips、语言 chips、TaskBar/ModuleChrome/DirectionBar/VoiceOut 的 44 pt 修复。
- **#45–#48**：系统导航/工具栏替换三模块与首页；保留系统 dialog/sheet/share 不动。
- **#49**：iPhone 13 上补 History 行、任务详情、share sheet、浅/深色、Reduce Transparency/Increase Contrast/Motion、VoiceOver、最大字号、60 分钟会话。

## 自定义背景清单（供 #43/#45–#48 移除或替换）

- ~~`HomeSettingsSheet`：`.background(Tokens.canvas)`~~（#43 已移除）
- `MeetingSettingsSheet`：`.background(Tokens.sheet, in: RoundedRectangle(cornerRadius: 22))`
- `InterpretationSettingsSheet`：同上
- `SettingsSheet`：同上
- `SummarySheet`：同上
- 系统 `.confirmationDialog` / `ShareLink` 没有自定义背景。

## 未验证 / 延后

- 浅色外观已由 #43 补齐（首页、设置、历史空态、三模块、引导）；`confirmationDialog` 浅色与 iOS 27 真机浅色仍留 #49。
- History List 行、任务详情、ShareLink/share sheet（模拟器无数据 seam；#49 真机）。
- iOS 27.2.1 真机与 iOS 27 材质细化（#49）。
- 三模块系统导航栏外观（#45–#48）。
- Cancel 按钮在真机/VoiceOver 下的可达性（#49）。
