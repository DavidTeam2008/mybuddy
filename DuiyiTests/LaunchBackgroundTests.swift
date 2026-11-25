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

        let cases: [(TokenScheme, TokenContrast, UIUserInterfaceStyle, UIAccessibilityContrast)] = [
            (.light, .normal, .light, .normal),
            (.dark, .normal, .dark, .normal),
            (.light, .high, .light, .high),
            (.dark, .high, .dark, .high),
        ]

        for (scheme, contrast, style, accessibilityContrast) in cases {
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: style),
                UITraitCollection(accessibilityContrast: accessibilityContrast),
            ])
            let actual = launch.resolvedColor(with: traits)
            let expected = TokenPalette.canvas.resolve(scheme: scheme, contrast: contrast)

            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            #expect(actual.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            #expect(abs(Double(red) - expected.red) < 0.001, "\(scheme)/\(contrast) red")
            #expect(abs(Double(green) - expected.green) < 0.001, "\(scheme)/\(contrast) green")
            #expect(abs(Double(blue) - expected.blue) < 0.001, "\(scheme)/\(contrast) blue")
            #expect(abs(Double(alpha) - 1) < 0.001, "\(scheme)/\(contrast) alpha")
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
}
