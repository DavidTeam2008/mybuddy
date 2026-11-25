import Testing
import UIKit
@testable import Duiyi

/// The system launch screen must show the same canvas color as the app's first
/// frame; otherwise the user sees a flash between launch and `RootView`.
struct LaunchBackgroundTests {
    @Test("LaunchBackground resolves to Tokens.canvas in every appearance")
    func matchesCanvas() throws {
        let launch = try #require(
            UIColor(named: "LaunchBackground"),
            "LaunchBackground colorset is missing"
        )

        for scheme in [TokenScheme.light, .dark] {
            for contrast in [TokenContrast.normal, .high] {
                let actual = launch.resolvedColor(with: traits(scheme: scheme, contrast: contrast))
                let expected = TokenPalette.canvas.resolve(scheme: scheme, contrast: contrast)
                assertChannels(of: actual, equal: expected, "\(scheme)/\(contrast)")
            }
        }
    }

    @Test("UILaunchScreen names the LaunchBackground color")
    func launchScreenNamesColor() throws {
        let launch = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UILaunchScreen") as? [String: Any],
            "UILaunchScreen is missing"
        )
        #expect(launch["UIColorName"] as? String == "LaunchBackground")
    }

    private func traits(scheme: TokenScheme, contrast: TokenContrast) -> UITraitCollection {
        let style: UIUserInterfaceStyle
        switch scheme {
        case .light: style = .light
        case .dark: style = .dark
        }
        let accessibilityContrast: UIAccessibilityContrast
        switch contrast {
        case .normal: accessibilityContrast = .normal
        case .high: accessibilityContrast = .high
        }
        return UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: style),
            UITraitCollection(accessibilityContrast: accessibilityContrast),
        ])
    }

    private func assertChannels(of color: UIColor, equal expected: TokenColor, _ label: String) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), "\(label) getRed")
        #expect(abs(Double(red) - expected.red) < 0.001, "\(label) red")
        #expect(abs(Double(green) - expected.green) < 0.001, "\(label) green")
        #expect(abs(Double(blue) - expected.blue) < 0.001, "\(label) blue")
        #expect(abs(Double(alpha) - 1) < 0.001, "\(label) alpha")
    }
}
