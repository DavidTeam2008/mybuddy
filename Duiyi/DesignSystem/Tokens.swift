import SwiftUI
import UIKit

/// A resolved sRGB color used by design tokens. Pure value type so contrast
/// checks can run without rendering SwiftUI.
struct TokenColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrastRatio(against other: TokenColor) -> Double {
        let first = relativeLuminance
        let second = other.relativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

enum TokenScheme: Sendable {
    case light
    case dark
}

enum TokenContrast: Sendable {
    case normal
    case high
}

/// Light/dark and increased-contrast variants for one semantic token.
struct TokenVariants: Equatable, Sendable {
    let light: TokenColor
    let lightHighContrast: TokenColor
    let dark: TokenColor
    let darkHighContrast: TokenColor

    init(
        light: UInt32,
        dark: UInt32,
        lightHighContrast: UInt32? = nil,
        darkHighContrast: UInt32? = nil
    ) {
        self.light = TokenColor(hex: light)
        self.dark = TokenColor(hex: dark)
        self.lightHighContrast = TokenColor(hex: lightHighContrast ?? light)
        self.darkHighContrast = TokenColor(hex: darkHighContrast ?? dark)
    }

    init(hex: UInt32) {
        self.init(light: hex, dark: hex)
    }

    func resolve(scheme: TokenScheme, contrast: TokenContrast) -> TokenColor {
        switch (scheme, contrast) {
        case (.light, .normal): return light
        case (.light, .high): return lightHighContrast
        case (.dark, .normal): return dark
        case (.dark, .high): return darkHighContrast
        }
    }

    var color: Color {
        Color(uiColor: UIColor { traits in
            let scheme: TokenScheme = traits.userInterfaceStyle == .dark ? .dark : .light
            let contrast: TokenContrast = traits.accessibilityContrast == .high ? .high : .normal
            let resolved = resolve(scheme: scheme, contrast: contrast)
            return UIColor(
                red: CGFloat(resolved.red),
                green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue),
                alpha: 1
            )
        })
    }
}

/// Semantic palette. Text/accent colors are chosen to clear WCAG 4.5:1 on
/// their documented surfaces in both appearances and in increased contrast;
/// `DuiyiTests/TokensTests` pins those pairs.
enum TokenPalette {
    static let canvas = TokenVariants(
        light: 0xF2F2F7,
        dark: 0x0B0C10,
        lightHighContrast: 0xFFFFFF,
        darkHighContrast: 0x000000
    )
    static let userPane = TokenVariants(
        light: 0xFFFFFF,
        dark: 0x161920,
        lightHighContrast: 0xFFFFFF,
        darkHighContrast: 0x000000
    )
    static let peerPane = TokenVariants(
        light: 0xFFF8F0,
        dark: 0x1A1714,
        lightHighContrast: 0xFFFCF8,
        darkHighContrast: 0x000000
    )
    static let textPrimary = TokenVariants(
        light: 0x1C1C1E,
        dark: 0xF4EFE6,
        lightHighContrast: 0x000000,
        darkHighContrast: 0xFFFFFF
    )
    static let textSecondary = TokenVariants(
        light: 0x5F5F66,
        dark: 0xA9A49B,
        lightHighContrast: 0x3A3A40,
        darkHighContrast: 0xD6D1C8
    )
    /// Brand fill; pair it with `onAccent` text.
    static let listen = TokenVariants(hex: 0xE8B86D)
    /// Readable accent used for text, icons, and links.
    static let accentText = TokenVariants(
        light: 0x8A5A12,
        dark: 0xE8B86D,
        lightHighContrast: 0x6B4308,
        darkHighContrast: 0xF0C987
    )
    static let onAccent = TokenVariants(hex: 0x1C1915)
    static let danger = TokenVariants(
        light: 0xB42318,
        dark: 0xEE8A8A,
        lightHighContrast: 0x8A1A12,
        darkHighContrast: 0xFF9A9A
    )
    /// Symbol/text on a `danger` fill; white on light red, dark on dark red.
    static let onDanger = TokenVariants(
        light: 0xFFFFFF,
        dark: 0x1C1915,
        lightHighContrast: 0xFFFFFF,
        darkHighContrast: 0x000000
    )
    static let blockedBackground = TokenVariants(
        light: 0xFDECEA,
        dark: 0x2A2424,
        lightHighContrast: 0xFAD9D5,
        darkHighContrast: 0x3A3030
    )
    static let warningText = TokenVariants(
        light: 0x7A4B00,
        dark: 0xF0D9B0,
        lightHighContrast: 0x5A3600,
        darkHighContrast: 0xFFE9C8
    )
    static let warningBackground = TokenVariants(
        light: 0xFFF4E0,
        dark: 0x2A2420,
        lightHighContrast: 0xFFE7C2,
        darkHighContrast: 0x3A2E24
    )
    static let controlIdle = TokenVariants(
        light: 0xE5E5EA,
        dark: 0x2A2E38,
        lightHighContrast: 0xD1D1D6,
        darkHighContrast: 0x3A3F4A
    )
    static let sheet = TokenVariants(
        light: 0xFFFFFF,
        dark: 0x23262F,
        lightHighContrast: 0xFFFFFF,
        darkHighContrast: 0x15171C
    )
    static let sheetChip = TokenVariants(
        light: 0xE9E9EE,
        dark: 0x2F3340,
        lightHighContrast: 0xDCDCE2,
        darkHighContrast: 0x3A3F4A
    )
    static let cardFaceToFace = TokenVariants(
        light: 0xFFF3E5,
        dark: 0x1A1714,
        lightHighContrast: 0xFFE8CC,
        darkHighContrast: 0x241F1A
    )
    static let cardSimultaneous = TokenVariants(
        light: 0xE9F7F5,
        dark: 0x161920,
        lightHighContrast: 0xD8F2EE,
        darkHighContrast: 0x101412
    )
    static let cardMeeting = TokenVariants(
        light: 0xF5EEFC,
        dark: 0x1C1824,
        lightHighContrast: 0xEDE0FA,
        darkHighContrast: 0x181322
    )

    static let languageZH = accentText
    static let languageEN = TokenVariants(
        light: 0x1F6F6B,
        dark: 0x7EC8C3,
        lightHighContrast: 0x0F5652,
        darkHighContrast: 0xA8E4DF
    )
    static let languageJA = TokenVariants(
        light: 0xA33B3B,
        dark: 0xE07A7A,
        lightHighContrast: 0x7F2626,
        darkHighContrast: 0xF0A0A0
    )
    static let languageKO = TokenVariants(
        light: 0x3457A8,
        dark: 0x7EA0E8,
        lightHighContrast: 0x24407F,
        darkHighContrast: 0xA8C4F5
    )
    static let languageTH = TokenVariants(
        light: 0x6E3F9E,
        dark: 0xC49BE8,
        lightHighContrast: 0x542A7C,
        darkHighContrast: 0xDCC0F5
    )
    static let languageVI = TokenVariants(
        light: 0x2F7A4F,
        dark: 0x7ECF9A,
        lightHighContrast: 0x1E5C39,
        darkHighContrast: 0xA8E8BF
    )
    /// Apple Intelligence status badge.
    static let intelligenceText = TokenVariants(
        light: 0x1D5C3E,
        dark: 0xB8E0C8,
        lightHighContrast: 0x0F3D28,
        darkHighContrast: 0xD8F5E4
    )
    static let intelligenceBackground = TokenVariants(
        light: 0xDFF3E6,
        dark: 0x1D2A24,
        lightHighContrast: 0xC9EBD7,
        darkHighContrast: 0x0F1F18
    )
}

enum Tokens {
    static let canvas = TokenPalette.canvas.color
    static let userPane = TokenPalette.userPane.color
    static let peerPane = TokenPalette.peerPane.color
    static let textPrimary = TokenPalette.textPrimary.color
    static let textSecondary = TokenPalette.textSecondary.color
    /// Brand fill; pair with `onAccent` text.
    static let listen = TokenPalette.listen.color
    /// Readable accent for text, icons, and links.
    static let accentText = TokenPalette.accentText.color
    static let onAccent = TokenPalette.onAccent.color
    static let danger = TokenPalette.danger.color
    static let onDanger = TokenPalette.onDanger.color
    static let blockedBackground = TokenPalette.blockedBackground.color
    static let warningText = TokenPalette.warningText.color
    static let warningBackground = TokenPalette.warningBackground.color
    static let controlIdle = TokenPalette.controlIdle.color
    static let sheet = TokenPalette.sheet.color
    static let sheetChip = TokenPalette.sheetChip.color
    static let cardFaceToFace = TokenPalette.cardFaceToFace.color
    static let cardSimultaneous = TokenPalette.cardSimultaneous.color
    static let cardMeeting = TokenPalette.cardMeeting.color
    static let languageZH = TokenPalette.languageZH.color
    static let languageEN = TokenPalette.languageEN.color
    static let languageJA = TokenPalette.languageJA.color
    static let languageKO = TokenPalette.languageKO.color
    static let languageTH = TokenPalette.languageTH.color
    static let languageVI = TokenPalette.languageVI.color
    static let featureMeeting = TokenPalette.languageTH.color
    static let intelligenceText = TokenPalette.intelligenceText.color
    static let intelligenceBackground = TokenPalette.intelligenceBackground.color

    static func languageBadge(_ language: AppLanguage) -> Color {
        switch language {
        case .zhHans: return languageZH
        case .english: return languageEN
        case .japanese: return languageJA
        case .korean: return languageKO
        case .thai: return languageTH
        case .vietnamese: return languageVI
        }
    }

    static func featureAccent(_ feature: FeatureID) -> Color {
        switch feature {
        case .faceToFace: return accentText
        case .simultaneous: return languageEN
        case .meeting: return featureMeeting
        }
    }

    static func featureCard(_ feature: FeatureID) -> Color {
        switch feature {
        case .faceToFace: return cardFaceToFace
        case .simultaneous: return cardSimultaneous
        case .meeting: return cardMeeting
        }
    }

    static let horizontalPadding = ConversationLayout.horizontalPadding
    static let midBarHeight = ConversationLayout.midBarHeight
    static let micSize = ConversationLayout.micSize
    static let micHitSize = ConversationLayout.micHitSize
    static let minHitTarget: CGFloat = 44
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum CaptionTypography {
    static func liveFont(size: CaptionFontSize, settled: Bool) -> Font {
        let metrics = UIFontMetrics(forTextStyle: .title1)
        let points = min(metrics.scaledValue(for: size.livePoints), ConversationLayout.liveFontCap)
        return .system(size: points, weight: settled ? .semibold : .regular, design: .default)
    }

    static func previousFont(size: CaptionFontSize) -> Font {
        let metrics = UIFontMetrics(forTextStyle: .callout)
        let points = min(metrics.scaledValue(for: size.previousPoints), size.previousPoints + 4)
        return .system(size: points, weight: .regular, design: .default)
    }

    static func badgeFont() -> Font {
        .system(size: 13, weight: .medium, design: .default)
    }

    static func sourceLineFont() -> Font {
        .system(size: 13, weight: .regular, design: .default)
    }
}
