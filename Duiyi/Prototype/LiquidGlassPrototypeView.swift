#if DEBUG
import SwiftUI
import UIKit

// Throwaway UI prototype. Never shipped; gated by the -liquidGlassPrototype
// launch argument in DEBUG builds only.

enum LiquidGlassPrototypeVariant: String, CaseIterable, Identifiable {
    case compliant = "A"
    case systemChrome = "B"
    case maximal = "C"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compliant: return "A · Apple 合规"
        case .systemChrome: return "B · 系统原生"
        case .maximal: return "C · 玻璃拉满"
        }
    }

    var detail: String {
        switch self {
        case .compliant: return "内容不透明，玻璃只在控制层"
        case .systemChrome: return "NavigationStack/toolbar 自动玻璃"
        case .maximal: return "对照用，违反内容层规则"
        }
    }
}

enum LiquidGlassPrototypeScreen: String, CaseIterable, Identifiable {
    case home = "home"
    case faceToFace = "f2f"

    var id: String { rawValue }
    var title: String { self == .home ? "首页" : "面对面" }
}

struct LiquidGlassPrototypeView: View {
    @State private var variant: LiquidGlassPrototypeVariant
    @State private var screen: LiquidGlassPrototypeScreen

    init() {
        let args = ProcessInfo.processInfo.arguments
        let variantValue = Self.value(after: "-lgVariant", in: args) ?? "A"
        let screenValue = Self.value(after: "-lgScreen", in: args) ?? "home"
        _variant = State(initialValue: LiquidGlassPrototypeVariant(rawValue: variantValue) ?? .compliant)
        _screen = State(initialValue: LiquidGlassPrototypeScreen(rawValue: screenValue) ?? .home)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ProtoPalette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                Picker("Prototype screen", selection: $screen) {
                    ForEach(LiquidGlassPrototypeScreen.allCases) { screen in
                        Text(screen.title).tag(screen)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                Group {
                    switch screen {
                    case .home:
                        ProtoHomeScreen(variant: variant)
                    case .faceToFace:
                        ProtoConversationScreen(variant: variant)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 62)
            }

            VariantSwitcher(variant: $variant)
                .padding(.bottom, 8)
        }
        .accessibilityIdentifier("liquid-glass-prototype")
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }
}

// MARK: - Palette

private enum ProtoPalette {
    static let canvas = Color.protoAdaptive(light: 0xF2F2F7, dark: 0x0B0C10)
    static let surface = Color.protoAdaptive(light: 0xFFFFFF, dark: 0x161920)
    static let peerSurface = Color.protoAdaptive(light: 0xFFF8F0, dark: 0x1A1714)
    static let textPrimary = Color.protoAdaptive(light: 0x1C1C1E, dark: 0xF4EFE6)
    static var textSecondary: Color { textPrimary.opacity(0.6) }
    static let listen = Color(hex: 0xE8B86D)
    static let simultaneous = Color(hex: 0x7EC8C3)
    static let meeting = Color(hex: 0xC49BE8)
    static let faceToFaceCard = Color.protoAdaptive(light: 0xFFF3E5, dark: 0x1A1714)
    static let simultaneousCard = Color.protoAdaptive(light: 0xE9F7F5, dark: 0x161920)
    static let meetingCard = Color.protoAdaptive(light: 0xF5EEFC, dark: 0x1C1824)
    static let historyCard = Color.protoAdaptive(light: 0xFFFFFF, dark: 0x23262F)
    static let danger = Color.protoAdaptive(light: 0xC0392B, dark: 0xE07070)
    static let ctaText = Color(hex: 0x1C1915)
    static let maximalBackground = LinearGradient(
        colors: [
            Color(hex: 0xE8B86D).opacity(0.35),
            Color(hex: 0x7EC8C3).opacity(0.28),
            Color(hex: 0xC49BE8).opacity(0.32),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private extension Color {
    static func protoAdaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

// MARK: - Home

private struct ProtoHomeScreen: View {
    let variant: LiquidGlassPrototypeVariant

    var body: some View {
        ZStack {
            if variant == .maximal {
                ProtoPalette.maximalBackground.ignoresSafeArea()
            }

            switch variant {
            case .systemChrome:
                NavigationStack {
                    ScrollView {
                        ProtoHomeCards(variant: variant)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .navigationTitle("MyBuddy")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Image(systemName: "clock.arrow.circlepath")
                                .accessibilityLabel("历史")
                            Image(systemName: "gearshape")
                                .accessibilityLabel("设置")
                        }
                    }
                }
            case .compliant, .maximal:
                VStack(spacing: 12) {
                    ProtoHomeHeader(variant: variant)
                    ScrollView {
                        ProtoHomeCards(variant: variant)
                            .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }
}

private struct ProtoHomeHeader: View {
    let variant: LiquidGlassPrototypeVariant

    private var glass: Glass {
        variant == .maximal
            ? .regular.tint(ProtoPalette.listen.opacity(0.22))
            : .regular
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("MyBuddy")
                .font(.title2.weight(.semibold))
                .foregroundStyle(ProtoPalette.textPrimary)
            Spacer(minLength: 0)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityLabel("历史")
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityLabel("设置")
        }
        .foregroundStyle(ProtoPalette.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(glass, in: Capsule())
    }
}

private struct ProtoHomeCards: View {
    let variant: LiquidGlassPrototypeVariant

    private var glass: Bool { variant == .maximal }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("未结束的任务")
                .font(.footnote.weight(.medium))
                .foregroundStyle(ProtoPalette.listen)

            ProtoUnfinishedRow(glass: glass)

            if glass {
                GlassEffectContainer(spacing: 18) {
                    VStack(spacing: 14) {
                        cards
                    }
                }
            } else {
                cards
            }
        }
    }

    @ViewBuilder
    private var cards: some View {
        ProtoModuleCard(
            title: "面对面",
            subtitle: "两人隔桌，字幕打到各自一侧",
            symbol: "person.2.fill",
            accent: ProtoPalette.listen,
            background: ProtoPalette.faceToFaceCard,
            glass: glass
        )
        ProtoModuleCard(
            title: "同声传译",
            subtitle: "一人听现场，单栏实时译文",
            symbol: "waveform",
            accent: ProtoPalette.simultaneous,
            background: ProtoPalette.simultaneousCard,
            glass: glass
        )
        ProtoModuleCard(
            title: "会议记录",
            subtitle: "单人记一场会的单栏文字稿",
            symbol: "doc.text.fill",
            accent: ProtoPalette.meeting,
            background: ProtoPalette.meetingCard,
            glass: glass
        )
        ProtoModuleCard(
            title: "历史",
            subtitle: "查看已结束的任务",
            symbol: "clock.arrow.circlepath",
            accent: ProtoPalette.textSecondary,
            background: ProtoPalette.historyCard,
            glass: glass
        )
    }
}

private struct ProtoUnfinishedRow: View {
    let glass: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ProtoPalette.listen)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("2026年11月25日 同声传译")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ProtoPalette.textPrimary)
                Text("English → 中文 · 进行中 · 2 分钟")
                    .font(.caption)
                    .foregroundStyle(ProtoPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !glass {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(ProtoPalette.surface)
            }
        }
        .glassEffect(
            glass ? .regular.tint(ProtoPalette.simultaneous.opacity(0.16)) : .identity,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

private struct ProtoModuleCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let accent: Color
    let background: Color
    let glass: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ProtoPalette.textPrimary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(ProtoPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !glass {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(background)
            }
        }
        .glassEffect(
            glass ? .regular.tint(accent.opacity(0.24)) : .identity,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

// MARK: - Face-to-face

private struct ProtoConversationScreen: View {
    let variant: LiquidGlassPrototypeVariant

    var body: some View {
        ZStack {
            if variant == .maximal {
                ProtoPalette.maximalBackground.ignoresSafeArea()
            }

            switch variant {
            case .systemChrome:
                NavigationStack {
                    ZStack(alignment: .bottom) {
                        VStack(spacing: 0) {
                            ProtoSamplePane(isPeer: true, glass: false)
                                .rotationEffect(.degrees(180))
                                .accessibilityHidden(true)
                            Rectangle()
                                .fill(ProtoPalette.textPrimary.opacity(0.08))
                                .frame(height: 1)
                            ProtoSamplePane(isPeer: false, glass: false)
                        }
                        ProtoMic()
                            .padding(.bottom, 18)
                    }
                    .navigationTitle("面对面")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Image(systemName: "house")
                            Image(systemName: "clock.arrow.circlepath")
                            Image(systemName: "plus")
                            Image(systemName: "stop.fill")
                                .foregroundStyle(ProtoPalette.danger)
                        }
                    }
                }
            case .compliant:
                VStack(spacing: 0) {
                    ProtoTaskBar(variant: variant)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    ProtoSamplePane(isPeer: true, glass: false)
                        .rotationEffect(.degrees(180))
                        .accessibilityHidden(true)
                    ProtoCenterControl(variant: variant)
                    ZStack(alignment: .bottom) {
                        ProtoSamplePane(isPeer: false, glass: false)
                        ProtoCTA(variant: variant)
                            .padding(.bottom, 20)
                    }
                }
            case .maximal:
                VStack(spacing: 10) {
                    ProtoTaskBar(variant: variant)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    ProtoSamplePane(isPeer: true, glass: true)
                        .rotationEffect(.degrees(180))
                        .accessibilityHidden(true)
                    ProtoCenterControl(variant: variant)
                    ZStack(alignment: .bottom) {
                        ProtoSamplePane(isPeer: false, glass: true)
                        ProtoCTA(variant: variant)
                            .padding(.bottom, 20)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct ProtoTaskBar: View {
    let variant: LiquidGlassPrototypeVariant

    private var glass: Glass {
        variant == .maximal
            ? .regular.tint(ProtoPalette.listen.opacity(0.18))
            : .regular
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left")
                .accessibilityLabel("首页")
            Text("面对面")
                .font(.headline)
            Spacer(minLength: 4)
            Text("进行中 · 2 分钟")
                .font(.caption)
                .foregroundStyle(ProtoPalette.textSecondary)
            Image(systemName: "plus")
                .accessibilityLabel("新任务")
            Image(systemName: "stop.fill")
                .foregroundStyle(ProtoPalette.danger)
                .accessibilityLabel("结束任务")
        }
        .foregroundStyle(ProtoPalette.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(glass, in: Capsule())
    }
}

private struct ProtoCenterControl: View {
    let variant: LiquidGlassPrototypeVariant

    var body: some View {
        switch variant {
        case .compliant:
            HStack {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ProtoPalette.textSecondary)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("对调双方语言")
                Spacer()
                ProtoMic()
                Spacer()
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ProtoPalette.textSecondary)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("设置")
            }
            .padding(.horizontal, 22)
            .frame(height: 72)
            .background(ProtoPalette.canvas)
        case .maximal:
            HStack(spacing: 20) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ProtoPalette.textSecondary)
                    .frame(width: 44, height: 44)
                SolidMic()
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ProtoPalette.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .glassEffect(
                .regular.tint(ProtoPalette.listen.opacity(0.2)),
                in: Capsule()
            )
            .padding(.horizontal, 40)
        case .systemChrome:
            EmptyView()
        }
    }
}

private struct ProtoMic: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(ProtoPalette.listen.opacity(0.18))
                .frame(width: Tokens.micHitSize, height: Tokens.micHitSize)
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(ProtoPalette.ctaText)
                .frame(width: Tokens.micSize, height: Tokens.micSize)
                .glassEffect(
                    .regular.tint(ProtoPalette.listen).interactive(),
                    in: Circle()
                )
        }
        .frame(width: Tokens.micHitSize, height: Tokens.micHitSize)
        .accessibilityLabel("聆听")
    }
}

private struct SolidMic: View {
    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(ProtoPalette.ctaText)
            .frame(width: 54, height: 54)
            .background(ProtoPalette.listen, in: Circle())
            .accessibilityLabel("聆听")
    }
}

private struct ProtoSamplePane: View {
    let isPeer: Bool
    let glass: Bool

    private var liveText: String {
        isPeer
            ? "See you at three. Please bring the contract."
            : "三点见。请带上合同。"
    }

    private var historyLines: [String] {
        isPeer
            ? ["Let's meet downstairs.", "I'll bring the signed copy."]
            : ["我们在楼下见。", "我会带签好的副本。"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProtoLanguageBadge(
                language: isPeer ? "EN" : "ZH",
                color: isPeer ? ProtoPalette.simultaneous : ProtoPalette.listen,
                glass: glass
            )
            Text(liveText)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(ProtoPalette.textPrimary)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(historyLines, id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(ProtoPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, isPeer ? 24 : 20)
        .padding(.bottom, isPeer ? 24 : 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if !glass {
                isPeer ? ProtoPalette.peerSurface : ProtoPalette.surface
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: glass ? 28 : 0, style: .continuous))
        .glassEffect(
            glass ? .regular : .identity,
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .padding(.horizontal, glass ? 12 : 0)
    }
}

private struct ProtoLanguageBadge: View {
    let language: String
    let color: Color
    let glass: Bool

    var body: some View {
        Text(language)
            .font(.system(size: 13, weight: .medium))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay {
                if !glass {
                    Capsule().stroke(color, lineWidth: 1)
                }
            }
            .glassEffect(
                glass ? .regular.tint(color.opacity(0.18)) : .identity,
                in: Capsule()
            )
    }
}

private struct ProtoCTA: View {
    let variant: LiquidGlassPrototypeVariant

    private var isGlass: Bool { variant == .maximal }

    var body: some View {
        Button(action: {}) {
            Text("总结这次对话")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isGlass ? ProtoPalette.textPrimary : ProtoPalette.ctaText)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background {
            if !isGlass {
                Capsule().fill(ProtoPalette.listen)
            }
        }
        .glassEffect(
            isGlass ? .regular.tint(ProtoPalette.listen.opacity(0.5)) : .identity,
            in: Capsule()
        )
    }
}

// MARK: - Switcher

private struct VariantSwitcher: View {
    @Binding var variant: LiquidGlassPrototypeVariant

    var body: some View {
        HStack(spacing: 12) {
            Button {
                cycle(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("prototype-variant-prev")
            .accessibilityLabel("上一个变体")

            VStack(spacing: 1) {
                Text(variant.title)
                    .font(.caption.weight(.semibold))
                Text(variant.detail)
                    .font(.caption2)
                    .opacity(0.75)
                    .lineLimit(1)
            }
            .frame(minWidth: 150)

            Button {
                cycle(1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("prototype-variant-next")
            .accessibilityLabel("下一个变体")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.86), in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                .white.opacity(0.3),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .accessibilityIdentifier("prototype-variant-switcher")
    }

    private func cycle(_ delta: Int) {
        let all = LiquidGlassPrototypeVariant.allCases
        guard let index = all.firstIndex(of: variant) else { return }
        let next = (index + delta + all.count) % all.count
        withAnimation(.easeInOut(duration: 0.2)) {
            variant = all[next]
        }
    }
}
#endif
