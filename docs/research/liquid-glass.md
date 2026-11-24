# Liquid Glass 研究与 MyBuddy 适配建议

> 研究日期：2026-11-25
> 目标工程：MyBuddy（工程 target `Duiyi`），iOS 26.4 deployment target，Xcode 27.1，iPhone-only portrait，SwiftUI，无第三方依赖
> 来源口径：优先 Apple 一手资料（Human Interface Guidelines、developer.apple.com 文档、WWDC 逐字稿、Apple sample code）。引用格式为 `[编号 §章节]`，完整 URL 见 §6。只出现在二手报道里的信息会明确标注「未验证」。
> 标注约定：`[编号 §章节]` 为 Apple 一手来源；「工程推断」是本报告基于代码与平台行为的判断，不代表 Apple 官方结论。
> 本文只做研究与建议，不修改任何 App 源码或测试。

**目录**：[§0 结论](#0-结论摘要) · [§1 设计原则](#1-apple-官方设计原则) · [§2 API 目录](#2-swiftui--uikit-api-目录) · [§3 组件映射](#3-应用到-mybuddy逐组件映射) · [§4 无障碍与性能](#4-无障碍与性能硬约束) · [§5 待决策](#5-待决策事项) · [§6 书目](#6-一手来源书目) · [附录 A](#附录-a已核对的-api-可用性) · [附录 B](#附录-bmybuddy-关键对比度本报告计算) · [附录 C](#附录-c未验证项)

## 0. 结论摘要

1. Liquid Glass 是**控制层/导航层**的材质，不是内容层背景。Apple 明确要求「Don’t use Liquid Glass in the content layer」，并建议只在最重要的功能元素上少量使用 `[H1 §Liquid Glass]`。MyBuddy 的模块卡片、字幕 pane、历史列表、语言 chips 都属于内容层，默认应保持不透明。
2. 真正值得评估的自定义玻璃表面只有两个：**中央麦克风/聆听控制**（语义上最强，但当前 72 pt 不透明控制带会让玻璃效果很弱）和**偶尔出现的浮动 CTA**（次候选）。顶部 chrome/task bar 属于导航层，但当前是扁平文字按钮，玻璃化收益低、风险高；要做也应整条 bar 做一个玻璃容器，而不是每个按钮各做一层。
3. Liquid Glass 不会修复 MyBuddy 现有的无障碍缺口。`01-product-design.md` §9 已承认 `DirectionBar` / `VoiceOutControl` / `TaskBar` 尚未全部达到 44 pt；此外 `LanguageChipGrid`、`HomeSettingsSheet` 字号 chips、`HistoryView` 过滤 chips 的点击高度也低于 44 pt。玻璃只是视觉材质，不能替代 hit target、对比度和 VoiceOver 修复 `[R1 §9]` `[R2]`。
4. 比「要不要加玻璃」更紧迫的是 **Xcode 27 重建后的系统外观迁移**：用 Xcode 27 编译后，`UIDesignRequiresCompatibility` 会被忽略，App 不能再选择旧设计 `[A18]`；标准组件（`List`、`sheet`、`confirmationDialog`、`ShareLink`、`NavigationStack`）会自动采用 iOS 26/27 的新外观和尺寸 `[T1 §Visual refresh]`。MyBuddy 虽然大部分自绘，但这些系统组件仍会变。
5. iOS 27 对 Liquid Glass 的改进是**自动生效**的：材质更会扩散背景内容、增加暗边和更亮的高光，并提供「从 ultra clear 到 fully tinted」的用户滑杆；已采用 Liquid Glass 的 App 不需要重新编译即可获得这些改进 `[W4]`。核心 API 仍是 iOS 26.0+，没有发现必须新增的玻璃 API。

---

## 1. Apple 官方设计原则

### 1.1 Liquid Glass 是什么，用在哪一层

Apple 的定义：

> “Interfaces across Apple platforms feature a new dynamic material called Liquid Glass, which combines the optical properties of glass with a sense of fluidity. This material forms a distinct functional layer for controls and navigation elements.” `[T1 §Visual refresh]`

HIG 进一步说明它「floats above the content layer」，用于在功能元素和内容之间建立清晰的视觉层级，并让内容从下方透出 `[H1 §Liquid Glass]`。WWDC25 的设计系统 session 把它描述为「a new functional layer in the UI, floating above your content to bring structure and clarity, without ever stealing focus」`[W2 §Structure]`。

由此得到两条硬规则：

- **内容层不要用 Liquid Glass。** Apple 原文：“Don’t use Liquid Glass in the content layer… Instead, use standard materials for elements in the content layer, such as app backgrounds.” 唯一例外是内容层里的瞬态交互控件（例如 slider/toggle 被操作时短暂呈现玻璃感）`[H1 §Liquid Glass]`。
- **玻璃要少用。** “Use Liquid Glass effects sparingly… Limit these effects to the most important functional elements in your app.” `[H1 §Liquid Glass]`；Adopting 指南也重复了「Avoid overusing Liquid Glass effects」`[T1 §Visual refresh]`。

对 MyBuddy 的含义：首页模块卡片是内容入口，字幕 pane 是内容本体，历史行是内容列表，语言 chips 是表单控件——都不应默认玻璃化。中央麦克风是「最重要的功能元素」之一，才是合理候选。

### 1.2 光学：lensing、折射、regular / clear

Liquid Glass 的核心视觉特征是 **lensing**：它不是像旧材质那样散射光，而是实时弯曲、塑形、汇聚光线，从而在不遮挡内容的前提下勾勒出自身形状 `[W1 §Dynamics]`。玻璃元素出现/消失时也不是简单淡入淡出，而是通过调制 lensing 来「materialize」`[W1 §Dynamics]`。玻璃变大时会模拟更厚的材质：更深阴影、更强 lensing/折射、更柔和的光散射 `[W1 §Adaptivity]`。

SwiftUI 的 `Glass` 有两个正式变体 `[A4]`：

| 变体 | API | 行为 | 使用条件 |
| --- | --- | --- | --- |
| Regular | `Glass.regular` | 模糊并调整背景亮度，保证文字和前景可读；大多数系统组件使用它 | 背景可能造成可读性问题，或组件有大量文字（alert、sidebar、popover 等）`[H1 §Liquid Glass]` |
| Clear | `Glass.clear` | 高度透明，不具自适应行为，优先展示下方内容 | 只用于媒体丰富背景（照片/视频）；需要压暗层；上方内容粗大明亮 `[H1 §Liquid Glass]` `[W1 §Principles]` |

Clear 的三个条件在 WWDC25 中被明确列为同时满足才可使用：元素位于 media-rich 内容之上；内容层不会被压暗层破坏；玻璃上方的内容粗大且明亮 `[W1 §Principles]`。Regular 与 Clear **不应混用**，因为它们的光学特征和使用场景不同 `[W1 §Principles]`。

压暗层：HIG 建议在明亮背景上给 clear 玻璃加 **35% 不透明度的深色压暗层**；如果背景本身足够暗，或使用 AVKit 自带压暗的播放控件，则不需要 `[H1 §Liquid Glass]`。SwiftUI 文档给出的写法是 `.glassEffect(.clear)` 后加 `.background(.black.opacity(0.3))` `[A5 §clear]`。

另一个关键限制：**玻璃不能采样玻璃**（“glass can not sample other glass”）。相邻的多个玻璃元素如果放在不同容器里，会得到不一致的采样结果；应使用 `GlassEffectContainer` 让它们共享采样区域 `[W3 §Liquid Glass effects]`。这也是「不要 glass-on-glass」的技术原因之一。

对 MyBuddy 的含义：深色画布 `#12141A` 本身是均匀平面，regular 玻璃几乎没有可折射的内容，视觉上会退化成轻微 tint/阴影；clear 玻璃则完全不适合（没有照片/视频背景，且会破坏字幕对比度）。如果要在深色画布上做玻璃，必须接受「效果很弱、成本仍在」的现实。

### 1.3 自适应：明暗、tint、背景、iOS 27 滑杆

Liquid Glass 由多层组成，每一层会根据背后的内容持续调整：阴影在文字滚过时变强，tint 和动态范围变化以保持按钮可读，必要时还能独立切换 light/dark `[W1 §Adaptivity]`。小元素（导航栏、tab bar）会随背景翻转明暗；大元素（菜单、sidebar）也会自适应，但不会整体翻转，因为面积太大、翻转会分散注意力 `[W1 §Principles]`。

Tint 不是简单的半透明色块。Apple 描述它会根据玻璃下方的内容亮度生成一组色调，模拟真实彩色玻璃的 hue/brightness/saturation 变化，从而同时提高强调和可读性 `[W1 §Principles]`。但 tint 必须克制：

- 只给真正需要强调的主操作/状态使用 `[W1 §Principles]`；
- 不要给所有元素 tint，否则没有重点 `[W1 §Principles]`；
- HIG 建议把颜色加在玻璃背景上而不是 symbol/text 上（prominent button 的做法）`[H3 §Liquid Glass color]`。

iOS 27 的新变化：系统设置里新增了一个滑杆，让用户把 Liquid Glass 从 **ultra clear 调到 fully tinted** `[W4]`；SwiftUI 会在不写代码的情况下响应这个滑杆调整 tint `[W5 §Refreshed look and feel]`。这意味着自定义玻璃上的文字/图标必须在整个滑杆范围内都可读，不能只在 Apple 默认值下成立。

HIG 还有一条对 MyBuddy 很关键：即使 App 只提供单一外观（例如只做深色），也应提供 light/dark 两套颜色，并为每套提供 increased contrast 变体，以支持 Liquid Glass 的自适应 `[H3 §Best practices]`。MyBuddy 目前是固定 hex token、强制 `.preferredColorScheme(.dark)`，这是迁移风险（见 §3.5）。

### 1.4 形状与同心性（concentricity）

Apple 用三种形状构建同心布局 `[W2 §Design Language]`：

- **固定形状**：固定圆角；
- **Capsule**：圆角半径等于容器高度的一半；
- **同心形状**：内层圆角半径 = 父容器半径减去 padding，自动计算。

Capsule 天然支持同心性，因此系统大量使用它（slider、switch、bar、button、grouped table view 的圆角）`[W2 §Design Language]`。自定义视图应使用 `ConcentricRectangle`，或 `.rect(corner: .containerConcentric)`，让系统根据容器自动算圆角，避免硬编码导致「太尖或太外翻」`[W2 §Design Language]` `[A16]` `[W3 §Controls]`。

对 MyBuddy 的含义：现有 12/16/22 pt 圆角是固定值；如果做玻璃，应优先用 Capsule（麦克风、浮动 CTA）或与容器同心的圆角，而不是把 16 pt 圆角直接套到所有尺寸上。

### 1.5 运动与弹性

Apple 把 Liquid Glass 的视觉和运动作为一体设计：它会对交互瞬时「flex and energize with light」，具有 gel-like 的弹性，传达 transient/malleable 的性质 `[W1 §Dynamics]`。元素还可以在交互时临时「lift up into Liquid Glass」，让静止状态保持安静、触摸时再活起来 `[W1 §Dynamics]`。菜单会从按钮处「pop open」，转场则是在同一个浮动平面上的 shape-shift `[W1 §Dynamics]`。

这些弹性是系统材质行为，不需要 App 自己写 spring。对自定义玻璃，`Glass.interactive(_:)` 会带来与 toolbar button/slider 一致的缩放、回弹、闪烁反馈 `[A8 §Apply and configure]` `[W3 §Liquid Glass effects]`。但 App 自己用 `withAnimation` 驱动的 morph/transition 仍要自己遵守 Reduce Motion（见 §1.7）。

### 1.6 克制：glass-on-glass、层数、文字可读性

Apple 的约束可以归纳为「三不要」：

1. **不要在内容层用玻璃** `[H1 §Liquid Glass]`。
2. **不要 glass-on-glass**。WWDC25 原文：“always avoid glass on glass… Stacking Liquid Glass elements on top of each other can quickly make the interface feel cluttered and confusing.” 如果确实要在玻璃上放元素，应使用 fills、transparency、vibrancy，让上层看起来像材质的一部分，而不是第二层玻璃 `[W1 §Principles]`。
3. **不要在静止状态让内容与玻璃相交**。App 启动等稳定状态下，应 reposition 或 scale 内容，保持内容与玻璃的分离 `[W1 §Principles]`。

文字可读性方面：

- 有大量文字的组件用 **regular**，不要用 clear `[H1 §Liquid Glass]`；
- 小元素和其上的 symbol/glyph 会随背景翻转明暗以最大化对比 `[W1 §Principles]`；
- tint 只用于强调，不要给所有元素上色 `[W1 §Principles]`；
- scroll edge effect 用来在内容滚到 bar 下方时保持可读性，它是「clarify where UI and content meet」，不是装饰；每个 view 只应有一个 scroll edge effect，不要叠加 soft/hard `[W2 §Structure]`。

### 1.7 无障碍

Apple 明确说 Liquid Glass 自带三类无障碍适配，且在使用新材质时**自动生效** `[W1 §Principles]`：

| 设置 | 对玻璃的影响 |
| --- | --- |
| Reduce Transparency | 玻璃变得更「frostier」，遮挡更多背后内容 `[W1 §Principles]` |
| Increase Contrast | 元素主要变成黑/白，并加对比边框 `[W1 §Principles]` |
| Reduce Motion | 降低部分效果强度，并禁用材质的弹性属性 `[W1 §Principles]` |

此外：

- HIG 的对比度基线：17 pt 及以下文字至少 **4.5:1**；18 pt 或粗体至少 **3:1** `[H2 §Vision]`。
- 支持更大文字：理想情况下允许放大至少 200%；使用 Dynamic Type 或自定义 UI 均可 `[H2 §Vision]`。
- VoiceOver：玻璃不会自动给控件增加语义。每个 icon 都要有 accessibility label `[T1 §Menus and toolbars]`；界面和内容要能被 VoiceOver 描述 `[H2 §Vision]`。
- 自定义颜色要提供 light/dark 和 increased contrast 变体，即使 App 只发布单一外观 `[H3 §Best practices]`。

MyBuddy 现有无障碍基线（发布阻断项）包括：VoiceOver 只读用户侧、可点区域 ≥44 pt、字号三档不截断关键操作、Reduce Motion 生效、深色画布对比度 `[R2 §v1 冻结口径]`。玻璃化必须在不破坏这些基线的前提下评估。

### 1.8 性能

Apple 的性能指导是定性的，没有公开「最多几个玻璃元素」的数字：

- 多个玻璃效果应放进 `GlassEffectContainer`；容器会把效果一起渲染，**improving rendering performance**，并允许形状互相 morph `[A2 §Overview]` `[A8 §Combine]`。
- “Creating too many Liquid Glass effect containers and applying too many effects to views outside of containers can degrade performance. Limit the use of Liquid Glass effects onscreen at the same time.” `[A8 §Optimize performance]`
- 玻璃不能采样玻璃，因此相邻元素放在不同容器里不仅视觉不一致，也失去共享采样区域的优化 `[W3 §Liquid Glass effects]`。
- `backgroundExtensionEffect()` 会把视图复制、镜像并模糊，Apple 明确说「use with discretion… with consideration of visual clarity and performance」`[A9]`。
- Apple 没有公布玻璃的 GPU/offscreen 成本模型或每台设备的预算；任何「iPhone 13 最多几个」的说法都只能来自工程实测，不能冒充 Apple 指导。

### 1.9 平台可用性与 iOS 26 → iOS 27 变化

**引入版本。** Liquid Glass 随 iOS 26 / iPadOS 26 / macOS 26 等 2025 平台引入 `[W1 §Introduction]` `[T2 §Introduction]`。本文涉及的所有核心 SwiftUI 玻璃 API 的文档可用性都是 **iOS 26.0+**：`glassEffect(_:in:)`、`GlassEffectContainer`、`glassEffectID(_:in:)`、`Glass`、`GlassButtonStyle`、`GlassProminentButtonStyle`、`backgroundExtensionEffect()`、`scrollEdgeEffectStyle(_:for:)`、`tabBarMinimizeBehavior(_:)`、`ToolbarSpacer`、`safeAreaBar`、`GlassEffectTransition`、`glassEffectUnion`、`ConcentricRectangle` 均如此 `[A1]` `[A2]` `[A3]` `[A4]` `[A6]` `[A7]` `[A9]` `[A10]` `[A11]` `[A12]` `[A13]` `[A14]` `[A15]` `[A16]`。

**iOS 27 的变化（与采用相关）：**

- 材质本身被重新调校：更有效地扩散背后的复杂内容；增加暗边（darkened edge）和更亮的 specular highlights，以建立更深的层次 `[W4]`。
- 新增用户滑杆，范围从 ultra clear 到 fully tinted `[W4]`；SwiftUI App 自动响应滑杆调整 tint，无需改代码 `[W5 §Refreshed look and feel]`。
- 已采用 Liquid Glass 的 App 在 iOS 27 上**不需要重新编译**就能获得这些改进 `[W4]`。
- 用 Xcode 27 重新编译后，App 会自动使用新设计；Apple 将移除「使用旧设计」的 opt-out `[W4]`。`UIDesignRequiresCompatibility` 文档也确认：该 key 在 build for iOS 27 / iPadOS 27 / macOS 27 / tvOS 27 或更高版本时会被系统忽略 `[A18]`。
- App 图标继续演进：更锐利、更立体，支持折射效果和 Icon Composer 的多层 Liquid Glass 设计 `[W4]`。
- HIG 的 Liquid Glass 指引本身也在更新：Materials 页在 2025-06-09 新增、2025-09-09 更新；Tab bars 页在 2025-07-28 / 2025-12-16 更新，并在 2026-06-08 更新术语与配图 `[H1 §Change log]` `[H6 §Change log]`。

**没有发现 iOS 27 必须新增的玻璃 API。** 核心 API 仍是 iOS 26.0+；iOS 27 主要是材质实现和用户偏好的变化。唯一在 WWDC26 逐字稿里出现、但本文未纳入推荐的 27-only 工具栏 API 是 `.toolbarMinimizeBehavior(..., for: .navigationBar)`，对应文档页未取到，见附录 C「未验证项」。

---

## 2. SwiftUI / UIKit API 目录

> 本节所有 API 名称都已对照 developer.apple.com 文档核对；未核对的项目会标注「未验证」。代码片段按 Apple 文档和 WWDC 示例改写，能直接用于 iOS 26.4 deployment target。

### 2.1 核心自定义玻璃

#### `glassEffect(_:in:)`

```swift
nonisolated func glassEffect(
    _ glass: Glass = .regular,
    in shape: some Shape = DefaultGlassEffectShape()
) -> some View
```

- 作用：在视图背后渲染一层 Liquid Glass 形状，并在视图上叠加玻璃的前景效果 `[A1 §Discussion]`。
- 默认：`.regular` + `Capsule` `[A1 §Discussion]`。
- 可以指定形状，例如 `.rect(cornerRadius: 16)` `[A8 §Apply and configure]`。
- 通常与 `GlassEffectContainer` 配合，把多个玻璃形状合并、morph `[A1 §Discussion]`。
- **顺序**：`glassEffect` 会捕获视图内容交给容器渲染，应放在其他影响外观的 modifier 之后 `[A8 §Combine]`；同时它画在内容背后，不透明 `.background` 会遮住玻璃，使用前要移除或改为 `.tint` `[T1 §Visual refresh]`。

```swift
Text("Hello, World!")
    .font(.title)
    .padding()
    .glassEffect()                       // regular + capsule
    .glassEffect(in: .rect(cornerRadius: 16))
```

#### `Glass`

`Glass` 是材质配置结构 `[A4]`：

| 成员 | 签名 | 说明 |
| --- | --- | --- |
| `.regular` | `static var regular: Glass` | 默认、最通用、带自适应 `[A5 §regular]` |
| `.clear` | `static var clear: Glass` | 高度透明，需要压暗层 `[A5 §clear]` |
| `.identity` | `static var identity: Glass` | 不施加任何玻璃效果，内容保持原样 `[A5 §identity]` |
| `.tint(_:)` | `func tint(_ color: Color?) -> Glass` | 设置 tint 色 `[A5 §tint(_:)]` |
| `.interactive(_:)` | `func interactive(_ isEnabled: Bool = true) -> Glass` | 开启触摸/指针交互反馈 `[A5 §interactive(_:)]` |

`.identity` 非常适合做「条件关闭」：性能降级、A/B、或用户选择减少效果时，直接把 glass 换成 `.identity`，不需要改视图结构 `[A5 §identity]`。

```swift
let glass: Glass = isGlassEnabled
    ? .regular.tint(Tokens.listen).interactive()
    : .identity

MicButton()
    .glassEffect(glass, in: Circle())
```

#### `GlassEffectContainer`

```swift
@MainActor @preconcurrency
struct GlassEffectContainer<Content: View>
init(spacing: CGFloat?, content: () -> Content)
```

- 把多个玻璃形状合并成一组渲染，提升渲染性能，并允许形状互相 morph `[A2 §Overview]`。
- `spacing` 控制形状接近到什么距离开始融合；spacing 越大，越早融合 `[A2 §Overview]` `[A8 §Combine]`。
- 容器内的多个 `glassEffect` 共享采样区域；玻璃不能采样玻璃，所以相邻玻璃应放在同一容器 `[W3 §Liquid Glass effects]`。

```swift
GlassEffectContainer(spacing: 20) {
    HStack(spacing: 20) {
        MicButton().glassEffect()
        VoiceOutButton().glassEffect()
    }
}
```

#### `glassEffectID(_:in:)` 与 morph

```swift
nonisolated func glassEffectID(
    _ id: (some Hashable & Sendable)?,
    in namespace: Namespace.ID
) -> some View
```

- 给玻璃效果一个 identity，SwiftUI 在视图层级变化/转场时据此把形状 morph 到彼此 `[A3 §Discussion]`。
- 必须与 `GlassEffectContainer` + `glassEffect` 一起用 `[A3 §Discussion]`。
- `GlassEffectTransition` 可选择 `.matchedGeometry`、`.materialize`、`.identity` `[A14]`；默认在容器 spacing 内是 `.matchedGeometry` `[A8 §Morph]`。

```swift
@Namespace private var namespace

GlassEffectContainer(spacing: 40) {
    HStack(spacing: 40) {
        MicButton()
            .glassEffect()
            .glassEffectID("mic", in: namespace)

        if isExpanded {
            VoiceOutButton()
                .glassEffect()
                .glassEffectID("voiceOut", in: namespace)
                .glassEffectTransition(.matchedGeometry)
        }
    }
}
```

#### `glassEffectUnion(id:namespace:)`

- 让多个视图的玻璃几何贡献给同一个统一形状，即使它们不在同一个 layout 容器里 `[A8 §Combine]` `[A15]`。
- 适用于动态生成、或跨越 `HStack`/`VStack` 的元素；普通相邻元素优先用 `GlassEffectContainer`。

Apple 的 Landmarks 示例用 `glassEffect(_:in:)` 做活动徽章，并用 `GlassEffectContainer` + `glassEffectID(_:in:)` 做徽章的展开/收回 morph，可作为最小参考实现 `[A17]`。

### 2.2 玻璃按钮样式

| API | 说明 | 可用性 |
| --- | --- | --- |
| `.buttonStyle(.glass)` | 标准玻璃按钮，按上下文应用 Liquid Glass `[A6 §glass]` | iOS 26.0+ `[A6]` |
| `.buttonStyle(.glassProminent)` | 强调玻璃按钮，类似 `borderedProminent` `[A7 §glassProminent]` | iOS 26.0+ `[A7]` |
| `GlassButtonStyle(Glass)` | 用自定义 `Glass` 配置玻璃按钮 `[A6]` | iOS 26.0+ |
| `GlassProminentButtonStyle()` | 强调玻璃按钮样式 `[A7]` | iOS 26.0+ |

```swift
Button("Learn More") { }
    .buttonStyle(.glass)

Button("Get Started") { }
    .buttonStyle(.glassProminent)
    .tint(Tokens.listen)
```

Apple 建议优先用这些系统按钮样式，而不是自己用 `glassEffect` 拼一个按钮 `[T1 §Controls]`；HIG 也建议用 prominent 样式突出最可能的操作，并控制一屏内 prominent 按钮的数量 `[H5 §Best practices]`。`glassProminent` 的强调色通过 tint/accent 作用在背景上，HIG 也建议把颜色加在背景而不是文字/图标上 `[H3 §Liquid Glass color]` `[A7 §glassProminent]`。

### 2.3 工具栏、导航、滚动边缘、sheet

#### `ToolbarSpacer` 与 `sharedBackgroundVisibility`

- `ToolbarSpacer(.fixed)` 把 toolbar items 分成不同背景组；`.flexible` 可推开项目 `[A12 §ToolbarSpacer]` `[T1 §Menus and toolbars]`。HIG 建议按功能和频率分组，不要把 symbol 和文字混在同一组 `[H4 §Item groupings]`。
- `ToolbarContent.sharedBackgroundVisibility(_:)` 控制 toolbar item 是否共享玻璃背景；`.hidden` 会让该项目单独成组、没有背景 `[A12 §sharedBackgroundVisibility]` `[W3 §Toolbars]`。

```swift
.toolbar {
    ToolbarItem { ShareLink(item: url) }
    ToolbarSpacer(.fixed)
    ToolbarItem { FavoriteButton() }
    ToolbarItem { CollectionsButton() }
        .sharedBackgroundVisibility(.hidden)
}
```

#### `safeAreaBar(edge:alignment:spacing:content:)`

- 把自定义 bar 锚定到水平边缘，并自动调整 safe area 与 scroll edge effect `[A13 §Discussion]`。
- 适合「自定义 bar + 内容在其下滚动」的结构；Adopting 指南把它列为自定义 bar 注册 scroll edge effect 的 SwiftUI 方式 `[T1 §Controls]`。

#### `scrollEdgeEffectStyle(_:for:)`

```swift
nonisolated func scrollEdgeEffectStyle(
    _ style: ScrollEdgeEffectStyle?,
    for edges: Edge.Set
) -> some View
```

- 默认是 `.automatic`；可选 `.hard`（线性、几乎不透明的边界）和 `.soft`（微妙模糊过渡）`[A10 §ScrollEdgeEffectStyle]`。
- 每个 view 只应有一个 scroll edge effect，不要叠加 `[W2 §Structure]`。
- 需要完全移除时用 `scrollEdgeEffectHidden(_:for:)` `[A10 §ScrollEdgeEffectStyle]`。

```swift
ScrollView { ... }
    .scrollEdgeEffectStyle(.soft, for: .all)
```

#### `backgroundExtensionEffect()`

- 把视图复制、镜像到 safe area 边缘，并加 blur，制造「内容延伸到 sidebar/inspector 下方」的错觉 `[A9]`。
- Apple 说是给 `NavigationSplitView` 的 detail 列、sidebar/inspector 场景用的；iPhone-only 的 MyBuddy 没有 split view，**不应使用** `[A9]` `[T1 §Navigation]`。
- 使用时要有节制：通常只对一个背景内容实例使用，并考虑视觉清晰度和性能 `[A9]`。

#### `tabBarMinimizeBehavior(_:)`

```swift
nonisolated func tabBarMinimizeBehavior(_ behavior: TabBarMinimizeBehavior) -> some View
```

- 取值：`.automatic`、`.never`、`.onScrollDown`、`.onScrollUp`；iPhone 上支持 tab bar 最小化 `[A11 §TabBarMinimizeBehavior]`。
- 用法：`TabView { ... }.tabBarMinimizeBehavior(.onScrollDown)` `[A11 §Discussion]`。
- MyBuddy 没有 `TabView`（导航是 `NavigationStack` + 自定义入口），因此这条 API **当前不适用**；只有未来改成 tab 结构才需要。

#### `NavigationStack`

- 标准 `NavigationStack` 会自动采用新的 navigation bar/toolbar 外观；Apple 建议移除自定义背景，让系统决定 bar 的外观 `[T1 §Visual refresh]`。
- MyBuddy 在首页、历史、详情和三个模块页都通过 `.toolbar(.hidden, for: .navigationBar)` 隐藏系统导航栏，改用自定义 `ModuleChrome` `[R14]` `[R16]`；因此大部分系统导航栏变化被抑制，但 `HomeSettingsSheet` 内部的 `NavigationStack` 仍会显示新的玻璃 toolbar `[R3]`。
- 如果未来改用系统 toolbar，应使用 `ToolbarSpacer` / `sharedBackgroundVisibility` 管理分组，不要给 toolbar item 加自定义背景 `[A12]` `[T1 §Menus and toolbars]`。

#### Sheet、detent、confirmation dialog

- 系统 `sheet` 自动采用 Liquid Glass；半高 sheet 默认内缩，底部圆角嵌入屏幕曲线；展开到全高时逐渐变得更不透明 `[T1 §Windows and modals]` `[W3 §App structure]`。
- 如果用过 `presentationBackground` 自定义 sheet 背景，Apple 建议移除，让系统材质生效 `[W3 §App structure]`。
- `confirmationDialog` / action sheet 会从触发它的控件处发起，而不是固定从屏幕底部升起 `[T1 §Windows and modals]`；SwiftUI 通过 `confirmationDialog(_:isPresented:titleVisibility:presenting:actions:)` 提供 source 语义 `[T1 §Windows and modals]`。
- `HomeSettingsSheet` 已经在用系统 `.sheet` + `.presentationDetents([.medium, .large])` `[R3]`，会直接受到这些变化影响。

#### 同心圆角

```swift
CustomControl()
    .background(.tint, in: .rect(corner: .containerConcentric))
```

- `ConcentricRectangle` 会根据容器形状自动计算每个角的半径 `[A16 §Overview]`。
- `.rect(corner: .containerConcentric)` 是 WWDC25 示例中的写法 `[W3 §Controls]`。

### 2.4 UIKit 等价物（仅供参考）

MyBuddy 是 SwiftUI-only；以下 UIKit API 只在未来引入 `UIViewRepresentable`、UIKit 托管或独立 UIKit 扩展时相关。

| UIKit API | 作用 | 可用性 |
| --- | --- | --- |
| `UIGlassEffect` | 渲染玻璃材质；`init(style:)`、`isInteractive`、`tintColor` `[U1]` | iOS 26.0+ |
| `UIGlassContainerEffect` | 把多个玻璃元素合并渲染；`spacing` 控制融合距离 `[U2 §Overview]` | iOS 26.0+ |
| `UIScrollEdgeEffect` | 某条边的 scroll edge effect；`isHidden`、`style` `[U3]` | iOS 26.0+ |
| `UIScrollEdgeElementContainerInteraction` | 给覆盖在 scroll view 边缘的容器注册 edge effect；`scrollView`、`edge` `[U3 §UIScrollEdgeElementContainerInteraction]` | iOS 26.0+ |
| `UITabBarController.MinimizeBehavior` | `.automatic` / `.never` / `.onScrollDown` / `.onScrollUp` `[U4]` | iOS 26.0+ |
| `UIBackgroundExtensionView` | 把内容延伸到 sidebar/inspector 下方 `[U5 §Overview]` | iOS 26.0+ |
| `UIButton.Configuration.glass()` / `.prominentGlass()` | 玻璃按钮配置 `[U6]` `[U7]` | iOS 26.0+ |

### 2.5 最低部署版本与 SDK 注意事项

- **部署目标 26.4 ≥ 26.0**：本文所有玻璃 API 都不需要 `if #available(iOS 26.0, *)`。工程当前 `IPHONEOS_DEPLOYMENT_TARGET = 26.4` `[R4]`。
- 如果未来下调 deployment target 到 26.0 以下，必须给所有玻璃 API 加 `#available`，并为旧系统提供不透明 fallback。
- **Xcode 27.1 使用 iOS 27 SDK**：标准 SwiftUI 组件会自动采用 iOS 27 的新设计；自定义绘制不会自动变成玻璃，只有调用上述 API 才会 `[R29]` `[T1 §Visual refresh]` `[W5 §Refreshed look and feel]`。
- **`UIDesignRequiresCompatibility` 不可依赖**：用 Xcode 27 构建时系统会忽略它，App 会直接使用新设计 `[A18]`。不要把它写进迁移计划。
- **iOS 27 不需要提高 deployment target**：玻璃 API 仍是 26.0+；iOS 27 的材质改进是运行时行为 `[W4]` `[W5 §Refreshed look and feel]`。
- **示例代码的可用性可能高于 API**：Landmarks 示例页标注 iOS 27.0+ / Xcode 27.0+，说明 Apple 已把示例更新到 27 SDK；这不代表 `glassEffect` 本身要求 27 `[A17]` `[A1]`。

---

## 3. 应用到 MyBuddy：逐组件映射

### 3.1 当前视觉系统速览

| 项 | 当前值 / 实现 | 来源 |
| --- | --- | --- |
| 画布 | `Tokens.canvas = #12141A` | `[R5]` |
| 用户侧 pane | `#161920` | `[R5]` |
| 对方侧 pane | `#1A1714` | `[R5]` |
| 正文 | `#F4EFE6`；次要文字为同色 58% | `[R5]` |
| 主操作/聆听 | `#E8B86D`（listen） | `[R5]` |
| sheet / chip | `#23262F` / `#2F3340` | `[R5]` |
| 卡片圆角 | 16 pt continuous | `[R6]` |
| sheet 卡片圆角 | 22 pt continuous | `[R7]` `[R8]` |
| 语言 chip 圆角 | 12 pt continuous | `[R9]` |
| 水平 padding | 22 pt | `[R10]` |
| 中央控制带 / 麦克风 / 热区 | 72 / 64 / 88 pt | `[R10]` |
| 字幕最大字号 | 32 pt cap + `UIFontMetrics` | `[R5]` `[R10]` |
| 安全区 | `ScreenSafeArea` 读取 key window 的 `safeAreaInsets`；无值时 top 54 / bottom 20 | `[R27]` |
| 画布对比度 | textPrimary 16.07:1、textSecondary 6.01:1、listen 10.09:1（按 WCAG 公式计算） | `[R5]`（本报告计算） |

界面现状：首页是四张不透明 tint 卡片 `[R6]`；模块页用自定义 `ModuleChrome` + `TaskBar` 扁平文字按钮 `[R11]`；中央 `ListeningControl` 是 64 pt 圆形按钮、88 pt 热区、聆听时金色并带脉冲 `[R12]`；字幕 pane 是不透明背景，对方侧整体旋转 180° 并 `accessibilityHidden` `[R13]` `[R14]`；设置/总结是自定义底部卡片，首页设置是系统 sheet `[R7]` `[R8]` `[R3]`。这些结构与 `docs/images/home.png`、`conversation.png`、`interpretation.png`、`settings.png` 的截图一致 `[R32]`。

架构上，`docs/02-architecture.md` §1 规定 Features 只依赖 Domain / DesignSystem / 注入的协议，DesignSystem 只依赖 SwiftUI `[R31]`。因此玻璃相关的视觉封装应落在 `DesignSystem/` 或 `Features/Shared/`，不要进入 Domain/Services；更不要在模块 View 里复制一套玻璃 token。

### 3.2 映射总表

图例：**系统玻璃（自动）** = 用系统组件后自动获得；**自定义玻璃（候选）** = 可用 `glassEffect`/`.glass` 但需评估；**保持不透明（推荐）** = 不建议玻璃化。

| # | 表面 | 文件 | 所属层 | 建议 | 理由 |
| --- | --- | --- | --- | --- | --- |
| 1 | 首页模块卡片 | `Duiyi/DesignSystem/HomeModuleCard.swift` `[R6]` | 内容层 | **保持不透明（推荐）** | HIG 明确禁止内容层玻璃 `[H1 §Liquid Glass]`；卡片已经有品牌 tint，玻璃会削弱识别；深色均匀画布上玻璃几乎无可折射内容（工程推断，基于 `[W1 §Adaptivity]` 的「随背后内容自适应」） |
| 2 | 顶部 chrome + task bar | `Features/Shared/ModuleChrome.swift`、`TaskBar.swift` `[R11]` | 导航/状态层 | **保持不透明（v1 推荐）**；若要改，整条 bar 做一个玻璃容器 | 导航层可以玻璃 `[W2 §Structure]`，但当前是扁平文字按钮，逐按钮玻璃会形成多个小玻璃层、违反 restraint `[H1 §Liquid Glass]`；且 44 pt 未达标 `[R1 §9]` |
| 3 | 中央麦克风/聆听控制 | `Features/Conversation/ListeningControl.swift` `[R12]` | 控制层 | **自定义玻璃（语义强候选，视觉收益受控制带限制）** | 它是「最重要的功能元素」之一 `[H1 §Liquid Glass]`；单个圆形、可交互，适合 `.regular.interactive()` `[A8 §Apply and configure]`；但当前 72 pt 控制带是不透明 `Tokens.canvas`，玻璃采样不到 pane 内容，效果会退化为轻微 tint/阴影。必须保留 88 pt 热区、状态色和 Reduce Motion |
| 4 | 语言 chips / 方向徽章 / pane 语言徽章 | `LanguageChipGrid.swift`、`DirectionBar.swift`、`CaptionPaneView.swift` `[R9]` `[R15]` `[R13]` | 内容/表单层 | **保持不透明（推荐）** | 单个网格 6 个 chip，设置页同时出现两组（最多 12 个），玻璃化会过载 `[H1 §Liquid Glass]`；选中态用金色实底已经有清晰层级；44 pt 也需要先补 |
| 5 | 字幕 pane（用户侧） | `CaptionPaneView.swift` `[R13]` | 内容层 | **保持不透明（推荐）** | 文字是主体；玻璃会降低/波动对比度 `[H2 §Vision]`；Live 文本持续更新，玻璃 blur 在更新路径上增加成本 `[A8 §Optimize performance]` |
| 6 | 倒字侧 peer pane | `ConversationView.swift` 中 `rotationEffect(180°)` + `accessibilityHidden` `[R14]` | 内容层 | **保持不透明，且不要加玻璃** | 内容层 + 文字主体；旋转会连带旋转玻璃的高光/阴影方向，与设备光源/几何不一致（工程推断，Apple 未专门讨论旋转玻璃）；VoiceOver 已隐藏，玻璃没有语义收益 |
| 7 | 设置 / 总结底部卡片（自定义 overlay） | `Features/Settings/SettingsSheet.swift`、`Features/Shared/SummarySheet.swift` `[R7]` `[R8]` | 内容层/模态 | **保持不透明（推荐）**；或整体迁移到系统 `.sheet` 以获得系统玻璃 | 卡片内有大量文字，应使用 regular 或标准材质 `[H1 §Liquid Glass]`；自定义 overlay 不是系统 sheet，玻璃需要自己维护，收益低 |
| 8 | 首页设置 sheet | `Features/Home/HomeSettingsSheet.swift` `[R3]` | 系统 sheet | **系统玻璃（自动）** | 已经是 `.sheet` + `NavigationStack` + `.presentationDetents([.medium, .large])`，会自动获得 iOS 26/27 的 sheet 玻璃 `[T1 §Windows and modals]` `[W3 §App structure]`；应移除内部自定义背景以露出系统材质 |
| 9 | 历史列表 / 历史行 | `Features/History/HistoryView.swift`、`DesignSystem/HistoryRow.swift` `[R16]` `[R17]` | 内容层 | **保持不透明（推荐）** | 列表是内容层；系统会在 iOS 26/27 改变 List 行高、padding、section 圆角 `[T1 §Organization and layout]`，但不需要也不应该加玻璃 |
| 10 | 引导流程 / 场景示意图 | `Features/Onboarding/OnboardingView.swift`、`WelcomeSceneIllustration.swift` `[R18]` `[R19]` | 内容层 | **保持不透明（推荐）** | 引导是内容与品牌叙事；CTA 用实底金色已经清晰；示意图画的是两台不透明 pane，玻璃化反而误导产品形象 |
| 11 | 浮动 CTA（总结 / 去设置 / 重下模型） | `ConversationView.swift`、`InterpretationView.swift` `[R14]` `[R20]` | 控制层 | **自定义玻璃（次候选）** | 一次只出现一个、悬浮在内容之上，适合 `.glass` 或 `.glassEffect(.regular.tint(...).interactive())` `[T1 §Controls]`；但下方是字幕，玻璃会局部模糊内容，需确认不遮挡关键句 |
| 12 | 存储/未保存警告横幅 | `Shared/StorageUnavailableBanner.swift`、`NotSavedBanner.swift` `[R21]` `[R22]` | 状态内容 | **保持不透明（推荐）** | 警告色和对比度是功能性的；玻璃会降低警示感和可读性 `[H2 §Vision]` |
| 13 | 历史/详情/任务栏里的系统分享 | `Shared/ExportShareButton.swift` `[R23]` | 系统分享 | **系统玻璃（自动）** | `ShareLink` 打开系统 share sheet，会自动采用新设计 `[T1 §Visual refresh]`；自定义按钮本身可保持实底 |
| 14 | 确认对话框 | 各模块 `.confirmationDialog` `[R14]` | 系统模态 | **系统玻璃（自动）** | 系统 action sheet 会自动玻璃化并从触发控件处发起 `[T1 §Windows and modals]`；不要自定义背景 |
| 15 | `TranslationHostView` | `Shared/TranslationHostView.swift` `[R24]` | 不可见基础设施 | **无影响** | 0×0 `Color.clear` + `accessibilityHidden`，不参与视觉；不要给它加任何玻璃或背景 |
| 16 | 会议记录 transcript + 语言 chip | `Features/Meeting/MeetingView.swift` `[R30]` | 内容层 | **保持不透明（推荐）** | 会议 transcript 是纯文本内容；`languageChip` 只是识别模式的入口，点击后打开设置；没有浮动控制语义，玻璃会降低长文可读性 `[H1 §Liquid Glass]` |

### 3.3 重点表面的具体建议

#### 3.3.1 首页模块卡片：保持不透明

`HomeModuleCard` 现在是：

```swift
.background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
```

`[R6]`

建议保留这个不透明 tint 背景。原因有三：

1. HIG 明确说内容层不要用 Liquid Glass `[H1 §Liquid Glass]`；卡片是内容入口，不是浮动控制。
2. 卡片背景（`#1A1714` / `#161920` / `#1C1824`）与画布（`#12141A`）本身差异很小 `[R5]`；玻璃在均匀深色背景上几乎没有可折射的内容，效果会退化成轻微阴影，却仍要付渲染成本（工程推断；材质随背后内容自适应见 `[W1 §Adaptivity]`，性能约束见 `[A8 §Optimize performance]`）。
3. 品牌识别目前靠每张卡片的 tint（面对面暖棕、同传青、会议紫）`[R5]`；玻璃会让颜色随背景变化，削弱这种识别 `[W1 §Principles]`。

如果未来一定要「让卡片浮起来」，优先用轻微 shadow/stroke 或标准 material（例如 SwiftUI `Material`），而不是 Liquid Glass；HIG 明确把 standard materials 留给内容层，用于在内容内部建立层次 `[H1 §Standard materials]`。

#### 3.3.2 顶部 chrome + task bar：v1 保持扁平，未来整条 bar 做一层

`ModuleChrome` 和 `TaskBar` 是文字按钮，直接放在 `Tokens.canvas` 上，没有背景 `[R11]`。它们属于导航/状态层，理论上可以玻璃化；但它们背后同样是均匀的深色 canvas，玻璃没有内容可采样，效果会很弱（工程推断，基于 `[W1 §Adaptivity]`），还要额外付渲染成本 `[A8 §Optimize performance]`。此外：

- 逐按钮玻璃会产生 4–6 个独立玻璃层，违反「use sparingly」和「avoid glass on glass」`[H1 §Liquid Glass]` `[W1 §Principles]`。
- 当前按钮没有 44 pt frame，玻璃不会修复 hit target；应先加 `.frame(minWidth: 44, minHeight: 44)` / `.contentShape(Rectangle())` `[R1 §9]` `[H2 §Vision]`。
- 内容目前不是滚到 bar 下方，而是 `VStack` 顺序布局；没有 scroll edge effect 的需求 `[R14]` `[R20]`。如果未来改成 overlay/scroll-under，应使用 `safeAreaBar` + 一个 `.soft` scroll edge effect，而不是给每个按钮加玻璃 `[A13]` `[A10 §ScrollEdgeEffectStyle]`。

若必须做，推荐结构：

```swift
VStack(spacing: 0) {
    ModuleChrome(...)
    TaskBar(...)
}
.padding(.vertical, 4)
.glassEffect(.regular, in: .rect(cornerRadius: 0)) // 整条 bar 一层
```

但请注意：这会让 bar 覆盖在画布上，视觉收益仍然有限；v1 建议保持现状。

#### 3.3.3 麦克风：语义上最强，视觉收益受控制带限制

`ListeningControl` 现在是 64 pt 圆形、88 pt 热区、聆听时 `Tokens.listen` 金色、失败时 `Tokens.danger`、带脉冲环 `[R12]`。它是全屏最重要的操作，符合「most important functional elements」`[H1 §Liquid Glass]`。

推荐的实验写法（不修改现有代码，仅示意）：

```swift
// 仅在 isGlassEnabled 时启用；保留 88 pt hit frame 和外层 72 pt 不透明控制带。
// 注意：玻璃是“背景”，不能再给同一个圆叠加不透明 fill，否则 fill 会盖住玻璃。
Image(systemName: symbolName)
    .font(.system(size: 22, weight: .semibold))
    .foregroundStyle(isListening ? Color(hex: 0x1C1915) : Tokens.textPrimary)
    .frame(width: Tokens.micSize, height: Tokens.micSize)
    .glassEffect(
        .regular
            .tint(isListening ? Tokens.listen : nil)
            .interactive(),
        in: Circle()
    )
    .frame(width: Tokens.micHitSize, height: Tokens.micHitSize)
    .contentShape(Circle())
```

要点：

- **玻璃是背景**：`glassEffect` 在视图内容之后绘制玻璃；如果保留现有的 `Circle().fill(...)`，不透明 fill 会遮住玻璃。实现时必须二选一：玻璃作为背景（去掉 fill，用 `.tint` 表达状态），或保留不透明 fill 但不加 `glassEffect`。Apple 也要求减少 controls/navigation 上的自定义背景，避免遮挡系统材质 `[T1 §Visual refresh]`。
- **只给 64 pt 圆加玻璃**，外层 72 pt 控制带继续保持 `Tokens.canvas` 不透明，避免玻璃污染上下两个 pane `[R12]`。
- **保留状态色**：聆听金色、失败红色是功能语义；玻璃 tint 只能强化，不能替代 `[W1 §Principles]`。失败态应退回不透明 `Tokens.danger` 圆。
- **`interactive()` 只在 iOS 上对自定义控件使用** `[W3 §Liquid Glass effects]`；它会带来缩放/回弹/闪烁，需与现有脉冲一起测试 Reduce Motion `[R12]`。
- **失败态不建议玻璃**：danger 需要最高对比度，玻璃会削弱警示 `[H2 §Vision]`；可以在 `sessionState.isFailed` 时退回不透明。
- **性能**：这是屏幕上唯一的玻璃元素之一，成本可控；但仍需在 iPhone 13 上实测（见 §4.3）。
- **视觉前提**：当前 `ListeningControl` 整条 72 pt 控制带是 `Tokens.canvas` 不透明背景 `[R12]`。玻璃采样的是它背后的内容；在均匀的 `#12141A` 上几乎没有 lensing/折射可看，效果会退化成「带 tint 的圆」。如果希望玻璃真正有层次，必须让控制带半透明或让麦克风覆盖在上下 pane 的交界上，但这会与现有 pane 分隔、字幕可读性和「不要内容与玻璃相交」的原则冲突 `[W1 §Principles]`。因此更保守的 v1 建议是：**保持不透明麦克风**；只有在产品接受「玻璃主要是语义/触感，而不是视觉奇观」时才做实验。

#### 3.3.4 语言 chips / 徽章：保持不透明

`LanguageChipGrid` 单个网格一次渲染 6 个 chip，3 列 2 行，选中金色实底、未选中 `sheetChip` `[R9]`；设置页会同时出现两组（我看的语言 + 对方语言），最多 12 个 chip `[R7]`。`DirectionBar` 有两个徽章 + 一个 40 pt 交换圆钮 `[R15]`；`CaptionPaneView` 有一个语言徽章 `[R13]`。

建议全部保持不透明：

- 6–12 个 chip 同时玻璃化会让界面变成「玻璃网格」，违反 restraint `[H1 §Liquid Glass]`。
- 选中态的金色实底已经提供清晰层级；再加玻璃 tint 会重复表达 `[W1 §Principles]`。
- `DirectionBar` 的交换钮只有 40×40，低于 44 pt；先修 hit target，再谈材质 `[R15]` `[R1 §9]`。
- 语言徽章的描边颜色是语言识别色（ZH 金、EN 青等）`[R5]`；玻璃会让这些颜色随背景变化，降低识别 `[W1 §Principles]`。
- `VoiceOutControl` 是底部胶囊按钮，约 36 pt 高，打开/关闭「读出译文」`[R25]`；它属于控制层，但尺寸低于 44 pt，且状态色（金色/红色）本身已经承担语义，建议先补 hit target，暂不玻璃化。

#### 3.3.5 字幕 pane 与倒字侧：绝对不要玻璃

`CaptionPaneView` 的背景是 `Tokens.userPane` / `Tokens.peerPane`，文字是 `textPrimary` / `textSecondary`，live 字号可到 32 pt `[R13]` `[R5]`。字幕是 App 的核心内容，HIG 明确要求内容层不要玻璃 `[H1 §Liquid Glass]`；而且文字对比度在玻璃上会随背后内容变化 `[H2 §Vision]`。

倒字侧更特殊：整个 pane 被 `rotationEffect(.degrees(180))` 旋转，并对 VoiceOver 隐藏 `[R14]`。给旋转容器加玻璃会带来两个问题：

1. 玻璃的高光/阴影/折射是按视图几何计算的；旋转后这些方向相对设备光源会反过来，视觉上不自然（工程推断；Apple 未专门讨论旋转玻璃）。
2. 它仍然是文字内容，玻璃只会降低可读性，没有语义收益 `[H1 §Liquid Glass]`。

结论：两个 pane 都保持不透明；中央控制带也不要加玻璃，否则会模糊上下字幕的边缘。

#### 3.3.6 设置 / 总结：自定义卡片保持不透明，或迁移到系统 sheet

`SettingsSheet` 和 `SummarySheet` 是自定义底部卡片：`RoundedRectangle(cornerRadius: 22)` + `Tokens.sheet` 背景 + `.transition(.move(edge: .bottom))` `[R7]` `[R8]`。它们不是系统 `.sheet`，所以不会自动获得 Liquid Glass。

两个选项：

- **保持自定义 + 不透明（v1 推荐）**：卡片内有大量文字和 chips，使用 regular 或标准材质更合适 `[H1 §Liquid Glass]`；不透明 `#23262F` 的对比度已经很好（textPrimary 13.19:1，textSecondary 5.44:1，本报告计算）`[R5]`。
- **迁移到系统 `.sheet`**：可以获得自动玻璃、半高内缩、全高变不透明、系统无障碍模态语义 `[T1 §Windows and modals]` `[W3 §App structure]`。迁移时要移除自定义 `Tokens.sheet` 背景和 `presentationBackground`，让系统材质显示 `[W3 §App structure]`；HIG 还要求 resizable sheet 提供 grabber，并支持下滑关闭 `[H7 §iOS, iPadOS]`。同时要重新评估 `transition`、背景可交互性、UI 测试。

`HomeSettingsSheet` 已经是系统 sheet，会自动玻璃化；它内部的 `.background(Tokens.canvas)` 可能盖住系统材质，建议改为标准背景或移除 `[R3]` `[W3 §App structure]`。

#### 3.3.7 浮动 CTA：次候选

`ConversationView` / `InterpretationView` 底部的「总结」「去设置」「重下模型」是 `Tokens.listen` 实底 Capsule，深色文字，`.padding(.bottom, 96/120)` `[R14]` `[R20]`。它们悬浮在字幕内容之上，属于控制层，适合玻璃。

推荐优先级：

1. 保持现状（实底金色）——对比度最高、品牌最明确。
2. 如果要做玻璃，使用 `.buttonStyle(.glassProminent).tint(Tokens.listen)` 或 `.glassEffect(.regular.tint(Tokens.listen).interactive(), in: Capsule())` `[A7 §glassProminent]` `[A8 §Apply and configure]`。注意先移除现有的 `.background(Tokens.listen, in: Capsule())`；不透明背景会盖住玻璃，这与 Apple「减少 controls/navigation 自定义背景」的要求一致 `[T1 §Visual refresh]`。
3. 不要给文字硬编码深色（当前是 `Color(hex: 0x1C1915)`）；玻璃按钮的 label 颜色应由系统 vibrant 处理，否则在深色/浅色玻璃上可能不可读 `[W1 §Principles]` `[H3 §Liquid Glass color]`。
4. 一次只显示一个 CTA `[R14]`；不要同时出现多个玻璃 CTA。

#### 3.3.8 历史、引导、警告横幅：保持不透明

- 历史 `List` 是内容层；iOS 26/27 会自动增加行高、padding、section 圆角 `[T1 §Organization and layout]`，但不需要玻璃。`listRowBackground(Tokens.userPane)` 和 separator tint 继续保留 `[R16]`。
- 引导是内容与品牌叙事；`WelcomeSceneIllustration` 画的是两台不透明 pane，玻璃化会与产品实际界面不一致 `[R19]`。
- 警告横幅（存储不可用、未保存）是状态内容，必须保持高对比度 `[R21]` `[R22]` `[H2 §Vision]`。

### 3.4 玻璃会在哪里伤害 MyBuddy

#### 3.4.1 可读性

- **字幕**：正文 32 pt 上限、次要文字 58% 不透明度 `[R5]` `[R13]`；玻璃会引入变化的背景亮度，破坏当前 6.01:1 的次要文字对比度（本报告计算）`[H2 §Vision]`。
- **倒字侧**：旋转 + 玻璃高光方向不一致（工程推断）；且 VoiceOver 已隐藏，玻璃没有语义价值 `[R14]`。
- **语言徽章**：描边颜色是语言识别色，玻璃会让颜色随背景变化，降低识别 `[W1 §Principles]`。
- **iOS 27 滑杆**：用户可以把玻璃调到 ultra clear，文字对比度进一步下降；自定义玻璃必须在整个范围内测试 `[W4]` `[W5 §Refreshed look and feel]`。

#### 3.4.2 无障碍基线

- 44 pt 未达标：`ModuleChrome`、`TaskBar`、`DirectionBar` 交换钮（40 pt）、`VoiceOutControl`（约 36 pt）、`LanguageChipGrid`（约 40 pt）、`SettingsSheet`/`HomeSettingsSheet` chips（约 40 pt）、`HistoryView` 过滤 chips（约 27 pt）`[R11]` `[R15]` `[R25]` `[R9]` `[R7]` `[R3]` `[R16]` `[R1 §9]`。玻璃不会改变这些数字。
- VoiceOver：倒字侧已隐藏 `[R14]`；如果玻璃包装改变了元素层级（例如把 `ListeningControl` 从 gesture-based `otherElement` 变成 `Button`），UI 测试的 `app.buttons` / `app.otherElements` 兜底需要同步 `[R26]`。
- Reduce Motion：现有 `ListeningControl` 脉冲和字幕滚动已经用 `ReduceMotion.allowed` 门控 `[R12]` `[R13]`；如果新增 `glassEffectID` morph，App 自己驱动的 `withAnimation` 也要门控；系统只会自动降低玻璃材质自身的弹性 `[W1 §Principles]`。
- Increase Contrast：当前固定 hex token 没有 increased contrast 变体；HIG 要求即使单一外观也提供 light/dark + increased contrast 版本 `[H3 §Best practices]`。

#### 3.4.3 性能与 iPhone 13

- 字幕 live 更新是高频路径：每次 partial 都会更新 SwiftUI 文本；在这条路径上叠加 blur/lensing 会放大 GPU 成本（工程推断；Apple 只给「limit onscreen」的定性指导 `[A8 §Optimize performance]`）。
- iPhone 13 是发布阻断设备，要求连续 60 分钟中↔英会话稳定 `[R2 §v1 冻结口径]`；玻璃实验必须在这台设备上跑完整 60 分钟，而不是只在模拟器或新 Pro 上看效果。
- Apple 没有公布玻璃的 offscreen 渲染成本或设备上限；不要引用「iPhone 13 最多 N 个玻璃」这类没有出处的数字。可执行的预算建议是：**同时最多 1–2 个自定义玻璃效果；相邻元素放同一 `GlassEffectContainer`；不在滚动/高频更新内容上加玻璃** `[A2 §Overview]` `[A8 §Optimize performance]`。

### 3.5 迁移风险清单

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| Xcode 27 重建自动换设计 | `UIDesignRequiresCompatibility` 被忽略；标准组件自动采用 iOS 26/27 外观 `[A18]` `[T1 §Visual refresh]` | 先在 Xcode 27.1 下跑全量 UI 测试和截图对比；不要试图用兼容 key 锁旧外观 |
| 系统 List 尺寸变化 | 行高、padding、section 圆角变大 `[T1 §Organization and layout]`；`HistoryView` 的 `listRowBackground` / separator 可能显得拥挤 `[R16]` | 用真机截图审查历史页；必要时调整 row padding，但不要加玻璃 |
| 系统 sheet 变化 | 半高 sheet 内缩、全高变不透明、圆角变大 `[T1 §Windows and modals]`；`HomeSettingsSheet` 的 `.background(Tokens.canvas)` 可能盖住系统材质 `[R3]` | 移除内部自定义背景；在 iPhone 13 上检查 medium/large detent |
| 自定义深色画布 vs 系统背景 | 玻璃会随背后内容切换明暗；深色画布上玻璃效果弱，系统 sheet 上又可能变亮 `[W1 §Adaptivity]` | 明确「自定义内容保持不透明、系统模态交给系统」的边界；不要跨边界叠玻璃 |
| 品牌 token 不自适应 | 固定 hex 没有 light/dark / increased contrast 变体 `[R5]`；HIG 要求提供 `[H3 §Best practices]` | 为关键 token 增加语义色和 `@Environment(\.colorSchemeContrast)` 变体 |
| glass-on-glass | 自定义 chrome 玻璃 + 麦克风玻璃 + 系统 sheet 玻璃叠加 `[W1 §Principles]` | 制定「一屏最多一层自定义玻璃」规则；系统 sheet 内不再放玻璃卡片 |
| 字幕对比度 | 玻璃会让文字背景变化；当前 6.01:1 的次要文字不再有保证 `[H2 §Vision]` | 字幕 pane 永远不透明；不在字幕上覆盖玻璃 CTA，或把 CTA 移出字幕区域 |
| 倒字侧旋转 | 旋转会反转玻璃高光/阴影方向（工程推断）；内容层也不应玻璃 `[H1 §Liquid Glass]` | 倒字侧保持不透明；不在旋转容器内使用 `glassEffect` |
| UI 测试标识 | glass wrapper 可能改变 element type；系统 sheet 迁移会改变层级 `[R26]` | 保持 identifier 在原 Button 上；迁移 sheet 后跑 `DuiyiUITests`，更新 `app.buttons` / `app.otherElements` 兜底 |
| iPhone 13 性能 | 实时听写 + 翻译 + SwiftUI 文本更新已经占用资源；玻璃增加 GPU 负担（工程推断） | 玻璃实验单独开关；60 分钟真机测试；Instruments 看 hitch/GPU |
| 安全区模拟 | `ScreenSafeArea` 用 54/20 pt fallback `[R27]`；如果改用 `safeAreaBar`/系统 toolbar，硬编码会失配 | 采用系统 bar 时改用真实 safe area，删除 fallback |
| iOS 27 滑杆极端值 | ultra clear 下文字对比度下降；fully tinted 下品牌色可能过重 `[W4]` `[W5 §Refreshed look and feel]` | 在滑杆两端和默认值下测试所有玻璃文字/图标 |
| App 图标 | 当前 `AppIcon.appiconset` 没有实际图片文件，只有 1024 占位条目 `[R28]` | iOS 26/27 需要分层图标；用 Icon Composer 产出 light/dark/clear/tinted 变体 `[T1 §App icons]` |

---

## 4. 无障碍与性能硬约束

### 4.1 MyBuddy 的发布阻断基线

来自 `docs/decisions.md` 的 v1 冻结口径 `[R2 §v1 冻结口径]`：

- 数据不丢；
- iPhone 13 连续 60 分钟中↔英会话无崩溃/静音卡死/识别暂停误报；
- 飞行模式下三模块全链路可用；
- 无障碍底线：VoiceOver 只读用户侧、可点区域 ≥44 pt、字号三档不截断关键操作、Reduce Motion 生效、深色画布对比度；
- 现有单元与 UI 测试全绿且不新增 skip。

玻璃化不能降低这些基线；它只能是在基线之上的可选视觉层。

### 4.2 玻璃专项验收矩阵

| 配置 | 要验证什么 | 相关来源 |
| --- | --- | --- |
| 默认（dark） | 玻璃文字/图标对比度；麦克风状态色；CTA 可读性 | `[H2 §Vision]` `[W1 §Principles]` |
| Reduce Transparency | 玻璃变「frostier」后是否遮挡字幕/状态；不透明 fallback 是否正常 | `[W1 §Principles]` |
| Increase Contrast | 玻璃是否变黑/白 + 边框；自定义 tint 是否仍有意义 | `[W1 §Principles]` |
| Reduce Motion | 脉冲、morph、CTA 出现动画是否降级；`glassEffectID` 的 `withAnimation` 是否门控 | `[W1 §Principles]` `[R12]` `[R13]` |
| 最大字号（Dynamic Type） | 玻璃按钮/Chip 是否随文字变大；是否截断 44 pt 目标 | `[H2 §Vision]` |
| VoiceOver | 倒字侧仍隐藏；玻璃控件仍有 label/hint；元素类型未变 | `[R14]` `[T1 §Menus and toolbars]` |
| iOS 27 滑杆两端 | ultra clear / fully tinted 下文字对比度、品牌色 | `[W4]` `[W5 §Refreshed look and feel]` |
| iPhone 13 60 分钟 | 玻璃是否引起掉帧/发热/听写中断 | `[R2 §v1 冻结口径]`（工程验收） |

### 4.3 性能验证计划（建议）

1. 用 Release 配置在 iPhone 13 上跑 60 分钟中↔英会话；同时开启玻璃实验开关。
2. 用 Instruments 的 Animation Hitches / GPU 模板对比「无玻璃 / 仅麦克风玻璃 / 麦克风 + CTA 玻璃」三组。
3. 记录 p95 hitch、平均/峰值 GPU、发热与电量；以「不触发听写中断」为硬门槛 `[R2 §v1 冻结口径]`。
4. 如果超标，优先把 `Glass` 换成 `.identity`（零效果、零结构改动）`[A5 §identity]`，而不是删除控件或改布局。
5. 不要在字幕滚动/live 更新路径上做玻璃；这是最高风险区域 `[A8 §Optimize performance]`。

### 4.4 硬性「不要」

- 不要在 `CaptionPaneView`、`HistoryRow`、`HomeModuleCard`、`LanguageChipGrid`、警告横幅上使用 `glassEffect` `[H1 §Liquid Glass]`。
- 不要在倒字侧旋转容器内使用玻璃 `[R14]`（工程推断 + 内容层规则）。
- 不要在系统 sheet 内再叠自定义玻璃卡片（glass-on-glass）`[W1 §Principles]`。
- 不要给所有 chips/按钮统一 tint；只给主操作/状态 `[W1 §Principles]`。
- 不要假设玻璃会自动满足 44 pt 或对比度；它不会 `[H2 §Vision]`。

---

## 5. 待决策事项

| ID | 问题 | 选项 | 建议 | 影响 |
| --- | --- | --- | --- | --- |
| LG1 | v1 是否引入任何自定义玻璃？ | A. 完全不引入；B. 仅麦克风实验；C. 麦克风 + 浮动 CTA | **B（保守）**：先做一个最小实验，验证 iPhone 13 性能和对比度，再决定是否扩大 | 影响 v1 范围与测试成本 |
| LG2 | 顶部 chrome/task bar 是否玻璃化？ | A. 保持扁平；B. 整条 bar 一层玻璃；C. 逐按钮玻璃 | **A**；若未来做，选 B，绝不选 C | 影响导航层视觉与 hit target |
| LG3 | 自定义 Settings/Summary 是否迁移到系统 `.sheet`？ | A. 保持自定义不透明；B. 迁移系统 sheet | **先评估 B 的无障碍收益，再决定**；迁移会改变模态语义和测试 | 影响设置/总结交互与 UI 测试 |
| LG4 | 品牌 tint 策略 | A. 仅主操作 tint；B. 所有控件 tint | **A**；金色只用于主操作/聆听状态 | 影响品牌识别与 HIG 合规 |
| LG5 | 是否采用 `.glass` / `.glassProminent` 按钮样式替代自定义胶囊？ | A. 保留实底金色；B. 玻璃按钮 + tint | **A（v1）**；B 需要验证 label 颜色和 iOS 27 滑杆 | 影响 CTA 对比度 |
| LG6 | 玻璃实验的开关与降级 | A. 编译开关；B. 运行时 feature flag；C. 跟随 Reduce Transparency | **B + C**：运行时开关便于 A/B 与性能回退；`.identity` 作为降级 | 影响可测试性与发布风险 |
| LG7 | 无障碍验收矩阵谁负责 | A. 仅模拟器；B. 真机 + Accessibility Inspector | **B**：必须覆盖 Reduce Transparency/Increase Contrast/Reduce Motion/VoiceOver/最大字号 | 发布阻断 |
| LG8 | 性能门槛 | A. 只看启动；B. 60 分钟会话 + Instruments | **B**：iPhone 13 Release 60 分钟，玻璃开启不得导致听写中断 | 发布阻断 |
| LG9 | UI 测试标识稳定性 | A. 现有 identifier 不动；B. 允许重命名 | **A**：玻璃包装不改变 identifier 所在元素；sheet 迁移单独评估 | 影响 `DuiyiUITests` |
| LG10 | App 图标 | A. 保持占位；B. Icon Composer 分层图标 | **B**：iOS 26/27 的图标体系需要 light/dark/clear/tinted 变体 `[T1 §App icons]` | 影响商店外观与品牌 |

建议落地顺序：

1. **先做 Xcode 27 系统外观审计**（不写玻璃代码）：全量 UI 测试 + 截图对比 `List`、`HomeSettingsSheet`、`confirmationDialog`、`ShareLink`。
2. **补 44 pt / 对比度 / increased contrast 基线**：这是发布阻断项，优先级高于玻璃 `[R2 §v1 冻结口径]`。
3. **再决定 LG1/LG2/LG3**：如果 v1 不引入玻璃，本文的其余内容作为 v1.x 设计输入保留。
4. **如果做玻璃实验**：只做麦克风，运行时 feature flag + `.identity` 降级，iPhone 13 Release 60 分钟验收。
5. **最后考虑图标和 CTA**：图标用 Icon Composer；CTA 在确认对比度和 iOS 27 滑杆后再玻璃化。

---

## 6. 一手来源书目

> 所有页面均在 2026-11-25 通过 developer.apple.com 访问；标注的章节名为页面内标题或 WWDC 章节标题。

### 6.1 Human Interface Guidelines

- `[H1]` **Materials** — https://developer.apple.com/design/human-interface-guidelines/materials
  - §Liquid Glass（定义、regular/clear、35% dimming、sparingly、content layer）
  - §Standard materials
  - §Change log（2025-06-09、2025-09-09）
- `[H2]` **Accessibility** — https://developer.apple.com/design/human-interface-guidelines/accessibility
  - §Vision（200% 放大、对比度 4.5:1 / 3:1、VoiceOver）
  - §Cognitive（Reduce Motion）
- `[H3]` **Color** — https://developer.apple.com/design/human-interface-guidelines/color
  - §Best practices（单一外观也要提供 light/dark + increased contrast）
  - §Liquid Glass color（tint 克制、背景着色）
- `[H4]` **Toolbars** — https://developer.apple.com/design/human-interface-guidelines/toolbars
  - §Best practices（减少自定义背景、scroll edge effect）
  - §Item groupings（分组、concentric）
- `[H5]` **Buttons** — https://developer.apple.com/design/human-interface-guidelines/buttons
  - §Best practices（prominent button、颜色克制）
- `[H6]` **Tab bars** — https://developer.apple.com/design/human-interface-guidelines/tab-bars
  - §Best practices、§iOS（floating tab bar、minimize）
  - §Change log（2025-07-28、2025-12-16、2026-06-08）
- `[H7]` **Sheets** — https://developer.apple.com/design/human-interface-guidelines/sheets
  - §iOS, iPadOS（detents、grabber、dismiss）

### 6.2 Technology Overviews

- `[T1]` **Adopting Liquid Glass** — https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
  - §Visual refresh（functional layer、standard components、sparingly、custom backgrounds）
  - §App icons（layers、Icon Composer、appearance variants）
  - §Controls（button styles、concentric、scroll edge effect、safeAreaBar）
  - §Navigation（tab bar/sidebar、background extension、tabBarMinimizeBehavior）
  - §Menus and toolbars（grouping、ToolbarSpacer、labels）
  - §Windows and modals（sheets、action sheets、corner radius）
  - §Organization and layout（list row height、section radius）
  - §Platform considerations（GlassEffectContainer performance、profile）
- `[T2]` **Liquid Glass** — https://developer.apple.com/documentation/technologyoverviews/liquid-glass
  - §Introduction、§Design principles、§Sample code

### 6.3 SwiftUI 文档

- `[A1]` `glassEffect(_:in:)` — https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- `[A2]` `GlassEffectContainer` — https://developer.apple.com/documentation/swiftui/glasseffectcontainer
- `[A3]` `glassEffectID(_:in:)` — https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)
- `[A4]` `Glass` — https://developer.apple.com/documentation/swiftui/glass
- `[A5]` `Glass.regular` / `Glass.clear` / `Glass.identity` / `Glass.tint(_:)` / `Glass.interactive(_:)`
  - https://developer.apple.com/documentation/swiftui/glass/regular
  - https://developer.apple.com/documentation/swiftui/glass/clear
  - https://developer.apple.com/documentation/swiftui/glass/identity
  - https://developer.apple.com/documentation/swiftui/glass/tint(_:)
  - https://developer.apple.com/documentation/swiftui/glass/interactive(_:)
- `[A6]` `GlassButtonStyle` / `PrimitiveButtonStyle.glass`
  - https://developer.apple.com/documentation/swiftui/glassbuttonstyle
  - https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass
- `[A7]` `GlassProminentButtonStyle` / `PrimitiveButtonStyle.glassProminent`
  - https://developer.apple.com/documentation/swiftui/glassprominentbuttonstyle
  - https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glassprominent
- `[A8]` **Applying Liquid Glass to custom views** — https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
  - §Apply and configure Liquid Glass effects
  - §Combine multiple views with Liquid Glass containers
  - §Morph Liquid Glass effects during transitions
  - §Optimize performance when using Liquid Glass effects
- `[A9]` `backgroundExtensionEffect()` — https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect()
- `[A10]` `scrollEdgeEffectStyle(_:for:)` / `ScrollEdgeEffectStyle`
  - https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)
  - https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle
- `[A11]` `tabBarMinimizeBehavior(_:)` / `TabBarMinimizeBehavior`
  - https://developer.apple.com/documentation/swiftui/view/tabbarminimizebehavior(_:)
  - https://developer.apple.com/documentation/swiftui/tabbarminimizebehavior
- `[A12]` `ToolbarSpacer` / `ToolbarContent.sharedBackgroundVisibility(_:)`
  - https://developer.apple.com/documentation/swiftui/toolbarspacer
  - https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:)
- `[A13]` `safeAreaBar(edge:alignment:spacing:content:)` — https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:)
- `[A14]` `GlassEffectTransition` / `glassEffectTransition(_:)`
  - https://developer.apple.com/documentation/swiftui/glasseffecttransition
  - https://developer.apple.com/documentation/swiftui/view/glasseffecttransition(_:)
- `[A15]` `glassEffectUnion(id:namespace:)` — https://developer.apple.com/documentation/swiftui/view/glasseffectunion(id:namespace:)
- `[A16]` `ConcentricRectangle` — https://developer.apple.com/documentation/swiftui/concentricrectangle
- `[A17]` **Landmarks: Building an app with Liquid Glass** — https://developer.apple.com/documentation/swiftui/landmarks-building-an-app-with-liquid-glass
- `[A18]` `UIDesignRequiresCompatibility` — https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility

### 6.4 UIKit 文档

- `[U1]` `UIGlassEffect` — https://developer.apple.com/documentation/uikit/uiglasseffect
- `[U2]` `UIGlassContainerEffect` — https://developer.apple.com/documentation/uikit/uiglasscontainereffect
- `[U3]` `UIScrollEdgeEffect` / `UIScrollEdgeElementContainerInteraction`
  - https://developer.apple.com/documentation/uikit/uiscrolledgeeffect
  - https://developer.apple.com/documentation/uikit/uiscrolledgeelementcontainerinteraction
- `[U4]` `UITabBarController.MinimizeBehavior` — https://developer.apple.com/documentation/uikit/uitabbarcontroller/minimizebehavior
- `[U5]` `UIBackgroundExtensionView` — https://developer.apple.com/documentation/uikit/uibackgroundextensionview
- `[U6]` `UIButton.Configuration.glass()` — https://developer.apple.com/documentation/uikit/uibutton/configuration-swift.struct/glass()
- `[U7]` `UIButton.Configuration.prominentGlass()` — https://developer.apple.com/documentation/uikit/uibutton/configuration-swift.struct/prominentglass()

### 6.5 WWDC

- `[W1]` **Meet Liquid Glass** — WWDC25 session 219 — https://developer.apple.com/videos/play/wwdc2025/219/
  - §Dynamics（lensing、materialize、flex/energize、morph）
  - §Adaptivity（图层自适应、大小、light/dark）
  - §Principles（content layer、glass-on-glass、regular/clear、tint、accessibility）
- `[W2]` **Get to know the new design system** — WWDC25 session 356 — https://developer.apple.com/videos/play/wwdc2025/356/
  - §Design Language（fixed/capsule/concentric、光学平衡）
  - §Structure（functional layer、focus、bar grouping、scroll edge、background extension）
- `[W3]` **Build a SwiftUI app with the new design** — WWDC25 session 323 — https://developer.apple.com/videos/play/wwdc2025/323/
  - §App structure（sheets、detents、tab bar）
  - §Toolbars（ToolbarSpacer、sharedBackgroundVisibility、scroll edge）
  - §Controls（glass button styles、containerConcentric）
  - §Liquid Glass effects（glassEffect、interactive、GlassEffectContainer、glassEffectID）
- `[W4]` **Platforms State of the Union** — WWDC26 session 112 — https://developer.apple.com/videos/play/wwdc2026/112/
  - Liquid Glass refinements、user slider、automatic adoption、old design opt-out removal
- `[W5]` **What's new in SwiftUI** — WWDC26 session 269 — https://developer.apple.com/videos/play/wwdc2026/269/
  - §Refreshed look and feel（updated appearance、slider tint、no code changes）

### 6.6 本仓库来源

- `[R1]` `docs/01-product-design.md` §9 视觉与无障碍
- `[R2]` `docs/decisions.md`「v1 冻结口径」
- `[R3]` `Duiyi/Features/Home/HomeSettingsSheet.swift`
- `[R4]` `Duiyi.xcodeproj/project.pbxproj`（`IPHONEOS_DEPLOYMENT_TARGET = 26.4`、`SWIFT_VERSION = 6.0`、`TARGETED_DEVICE_FAMILY = 1`）
- `[R5]` `Duiyi/DesignSystem/Tokens.swift`
- `[R6]` `Duiyi/DesignSystem/HomeModuleCard.swift`
- `[R7]` `Duiyi/Features/Settings/SettingsSheet.swift`
- `[R8]` `Duiyi/Features/Shared/SummarySheet.swift`
- `[R9]` `Duiyi/Features/Shared/LanguageChipGrid.swift`
- `[R10]` `Duiyi/Domain/Models/ConversationLayout.swift`
- `[R11]` `Duiyi/Features/Shared/ModuleChrome.swift`、`Duiyi/Features/Shared/TaskBar.swift`
- `[R12]` `Duiyi/Features/Conversation/ListeningControl.swift`
- `[R13]` `Duiyi/Features/Conversation/CaptionPaneView.swift`
- `[R14]` `Duiyi/Features/Conversation/ConversationView.swift`
- `[R15]` `Duiyi/Features/Interpretation/DirectionBar.swift`
- `[R16]` `Duiyi/Features/History/HistoryView.swift`
- `[R17]` `Duiyi/DesignSystem/HistoryRow.swift`
- `[R18]` `Duiyi/Features/Onboarding/OnboardingView.swift`
- `[R19]` `Duiyi/Features/Onboarding/WelcomeSceneIllustration.swift`
- `[R20]` `Duiyi/Features/Interpretation/InterpretationView.swift`
- `[R21]` `Duiyi/Features/Shared/StorageUnavailableBanner.swift`
- `[R22]` `Duiyi/Features/Shared/NotSavedBanner.swift`
- `[R23]` `Duiyi/Features/Shared/ExportShareButton.swift`
- `[R24]` `Duiyi/Features/Shared/TranslationHostView.swift`
- `[R25]` `Duiyi/Features/Interpretation/VoiceOutControl.swift`
- `[R26]` `DuiyiUITests/SimultaneousFlowTests.swift`（identifier 与 `buttons` / `otherElements` 兜底）
- `[R27]` `Duiyi/DesignSystem/ScreenSafeArea.swift`
- `[R28]` `Duiyi/Assets.xcassets/AppIcon.appiconset/Contents.json`
- `[R29]` `README.md`「Requirements」（Xcode 26.4+，validated with Xcode 27.1；iOS 26.4+；iPhone 13 or later）
- `[R30]` `Duiyi/Features/Meeting/MeetingView.swift`
- `[R31]` `docs/02-architecture.md` §1 分层与依赖
- `[R32]` `docs/images/home.png`、`docs/images/conversation.png`、`docs/images/interpretation.png`、`docs/images/settings.png`

---

## 附录 A：已核对的 API 可用性

| API | 文档可用性 | 文档页 |
| --- | --- | --- |
| `View.glassEffect(_:in:)` | iOS 26.0+ | `[A1]` |
| `GlassEffectContainer` | iOS 26.0+ | `[A2]` |
| `View.glassEffectID(_:in:)` | iOS 26.0+ | `[A3]` |
| `Glass`（含 regular/clear/identity/tint/interactive） | iOS 26.0+ | `[A4]` `[A5]` |
| `GlassButtonStyle` / `.glass` | iOS 26.0+ | `[A6]` |
| `GlassProminentButtonStyle` / `.glassProminent` | iOS 26.0+ | `[A7]` |
| `backgroundExtensionEffect()` | iOS 26.0+ | `[A9]` |
| `scrollEdgeEffectStyle(_:for:)` / `ScrollEdgeEffectStyle` | iOS 26.0+ | `[A10]` |
| `tabBarMinimizeBehavior(_:)` / `TabBarMinimizeBehavior` | iOS 26.0+ | `[A11]` |
| `ToolbarSpacer` | iOS 26.0+ | `[A12]` |
| `ToolbarContent.sharedBackgroundVisibility(_:)` | iOS 26.0+ | `[A12]` |
| `safeAreaBar(edge:alignment:spacing:content:)` | iOS 26.0+ | `[A13]` |
| `GlassEffectTransition` / `glassEffectTransition(_:)` | iOS 26.0+ | `[A14]` |
| `glassEffectUnion(id:namespace:)` | iOS 26.0+ | `[A15]` |
| `ConcentricRectangle` | iOS 26.0+ | `[A16]` |
| `UIDesignRequiresCompatibility` | iOS 27+ build 时被忽略 | `[A18]` |
| `UIGlassEffect` / `UIGlassContainerEffect` | iOS 26.0+ | `[U1]` `[U2]` |
| `UIScrollEdgeEffect` / `UIScrollEdgeElementContainerInteraction` | iOS 26.0+ | `[U3]` |
| `UITabBarController.MinimizeBehavior` | iOS 26.0+ | `[U4]` |
| `UIBackgroundExtensionView` | iOS 26.0+ | `[U5]` |
| `UIButton.Configuration.glass()` / `.prominentGlass()` | iOS 26.0+ | `[U6]` `[U7]` |

## 附录 B：MyBuddy 关键对比度（本报告计算）

按 WCAG 相对亮度公式，对 `Tokens.swift` 的 sRGB 值计算 `[R5]`。这些是**不透明背景**下的静态值；玻璃化后不再成立。

| 前景 / 背景 | 对比度 | 判断 |
| --- | --- | --- |
| `textPrimary` #F4EFE6 / `canvas` #12141A | 16.07:1 | 通过 4.5:1 |
| `textSecondary`（58%）/ `canvas` | 6.01:1 | 通过 4.5:1 |
| `listen` #E8B86D / `canvas` | 10.09:1 | 通过 4.5:1 |
| `textPrimary` / `userPane` #161920 | 15.36:1 | 通过 |
| `textSecondary`（58%）/ `userPane` | 5.89:1 | 通过 |
| `textPrimary` / `sheet` #23262F | 13.19:1 | 通过 |
| `textSecondary`（58%）/ `sheet` | 5.44:1 | 通过 |

## 附录 C：未验证项

以下内容在本文中没有作为结论使用，或只在明确标注处出现：

1. **iOS 27 设置滑杆的精确路径**（例如 Settings → Appearance → Liquid Glass）。WWDC26 SOTU 只说「a new slider in settings」`[W4]`；精确路径来自二手报道，未在 Apple 文档中核实。
2. **`.toolbarMinimizeBehavior(_:for:)` 的 navigation bar 变体**。WWDC26「What's new in SwiftUI」逐字稿出现 `.toolbarMinimizeBehavior(.onScrollDown, for: .navigationBar)` `[W5]`，但 developer.apple.com 对应的 `View.toolbarMinimizeBehavior(_:for:)` 文档页未取到（404），因此不纳入 API 目录。
3. **`UIGlassEffect.Style` 的具体 case 名称**。文档只确认 `init(style:)` 和 `Style` 类型存在 `[U1]`；本文没有猜测 case 名。
4. **`GlassEffectContainer` 的默认 spacing 数值**。初始化器接受 `CGFloat?`，文档没有给出默认数值 `[A2]`。
5. **旋转 180° 对玻璃高光/阴影的精确影响**。这是工程推断，Apple 没有专门文档讨论旋转容器内的 Liquid Glass。
6. **`.glassProminent` 的 label 颜色与 `.tint` 的精确合成结果**。文档只说明它类似 `borderedProminent`、强调色作用于背景 `[A7]` `[H3 §Liquid Glass color]`；具体渲染需在设备上验证。
7. **iPhone 13 的玻璃性能数字**。Apple 没有公布按设备的玻璃成本；本文只给出工程验收方法，不给出虚构的数值上限。
