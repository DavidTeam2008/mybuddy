import Testing
@testable import Duiyi

/// Contract tests for the semantic palette. These are pure value checks:
/// every text/accent token must clear WCAG 4.5:1 on its documented surfaces
/// in light, dark, and increased contrast.
struct TokensTests {
    private let schemes: [TokenScheme] = [.light, .dark]
    private let contrasts: [TokenContrast] = [.normal, .high]

    private let surfaces: [(String, TokenVariants)] = [
        ("canvas", TokenPalette.canvas),
        ("userPane", TokenPalette.userPane),
        ("peerPane", TokenPalette.peerPane),
        ("sheet", TokenPalette.sheet),
        ("sheetChip", TokenPalette.sheetChip),
        ("controlIdle", TokenPalette.controlIdle),
        ("cardFaceToFace", TokenPalette.cardFaceToFace),
        ("cardSimultaneous", TokenPalette.cardSimultaneous),
        ("cardMeeting", TokenPalette.cardMeeting),
    ]

    private func assertContrast(
        _ foreground: TokenVariants,
        _ background: TokenVariants,
        _ label: String,
        minimum: Double = 4.5
    ) {
        for scheme in schemes {
            for contrast in contrasts {
                let ratio = foreground.resolve(scheme: scheme, contrast: contrast)
                    .contrastRatio(
                        against: background.resolve(scheme: scheme, contrast: contrast)
                    )
                #expect(ratio >= minimum, "\(label) \(scheme)/\(contrast): \(ratio)")
            }
        }
    }

    @Test("Primary, secondary, and accent text clear 4.5:1 on every surface")
    func textContrast() {
        for (surfaceName, surface) in surfaces {
            assertContrast(TokenPalette.textPrimary, surface, "textPrimary/\(surfaceName)")
            assertContrast(TokenPalette.textSecondary, surface, "textSecondary/\(surfaceName)")
            assertContrast(TokenPalette.accentText, surface, "accentText/\(surfaceName)")
        }
    }

    @Test("Module icons clear 4.5:1 on their brand cards")
    func iconContrast() {
        assertContrast(TokenPalette.accentText, TokenPalette.cardFaceToFace, "faceToFace icon")
        assertContrast(TokenPalette.languageEN, TokenPalette.cardSimultaneous, "simultaneous icon")
        assertContrast(TokenPalette.languageTH, TokenPalette.cardMeeting, "meeting icon")
    }

    @Test("Danger text clears 4.5:1 on surfaces and blocked backgrounds")
    func dangerContrast() {
        for (backgroundName, background) in surfaces {
            assertContrast(TokenPalette.danger, background, "danger/\(backgroundName)")
        }
        assertContrast(
            TokenPalette.danger,
            TokenPalette.blockedBackground,
            "danger/blockedBackground"
        )
    }

    @Test("Warning text clears 4.5:1 on its warning background")
    func warningContrast() {
        assertContrast(TokenPalette.warningText, TokenPalette.warningBackground, "warning")
    }

    @Test("Speaking turn text clears 4.5:1 on panes, canvas, and sheets")
    func speakingContrast() {
        for (surfaceName, surface) in surfaces {
            assertContrast(TokenPalette.speaking, surface, "speaking/\(surfaceName)")
        }
    }

    @Test("Every language badge clears 4.5:1 on panes, sheets, and canvas")
    func languageContrast() {
        let badges: [(String, TokenVariants)] = [
            ("zhHans", TokenPalette.languageZH),
            ("english", TokenPalette.languageEN),
            ("japanese", TokenPalette.languageJA),
            ("korean", TokenPalette.languageKO),
            ("thai", TokenPalette.languageTH),
            ("vietnamese", TokenPalette.languageVI),
        ]
        let backgrounds: [(String, TokenVariants)] = [
            ("userPane", TokenPalette.userPane),
            ("peerPane", TokenPalette.peerPane),
            ("sheet", TokenPalette.sheet),
            ("canvas", TokenPalette.canvas),
        ]

        for (badgeName, badge) in badges {
            for (backgroundName, background) in backgrounds {
                assertContrast(badge, background, "\(badgeName)/\(backgroundName)")
            }
        }
    }

    @Test("Apple Intelligence badge text clears 4.5:1")
    func intelligenceContrast() {
        assertContrast(
            TokenPalette.intelligenceText,
            TokenPalette.intelligenceBackground,
            "intelligence"
        )
    }

    @Test("Text on the failure fill clears 3:1 for a large symbol")
    func dangerFillContrast() {
        assertContrast(TokenPalette.onDanger, TokenPalette.danger, "onDanger/danger", minimum: 3.0)
    }

    @Test("Text on the brand fill clears 4.5:1")
    func accentFillContrast() {
        assertContrast(TokenPalette.onAccent, TokenPalette.listen, "onAccent/listen")
    }

    @Test("Brand fill and on-accent values are pinned")
    func brandPins() {
        let gold = TokenColor(hex: 0xE8B86D)
        let ink = TokenColor(hex: 0x1C1915)
        for scheme in schemes {
            for contrast in contrasts {
                #expect(TokenPalette.listen.resolve(scheme: scheme, contrast: contrast) == gold)
                #expect(TokenPalette.onAccent.resolve(scheme: scheme, contrast: contrast) == ink)
            }
        }
    }

    @Test("Increased contrast changes text and status tokens")
    func highContrastDiffers() {
        let tokens: [(String, TokenVariants)] = [
            ("textPrimary", TokenPalette.textPrimary),
            ("textSecondary", TokenPalette.textSecondary),
            ("accentText", TokenPalette.accentText),
            ("danger", TokenPalette.danger),
        ]
        for (name, token) in tokens {
            #expect(token.light != token.lightHighContrast, "\(name) light high == normal")
            #expect(token.dark != token.darkHighContrast, "\(name) dark high == normal")
        }
    }

    @Test("WCAG black and white contrast is 21:1")
    func blackWhiteContrast() {
        let ratio = TokenColor(hex: 0x000000)
            .contrastRatio(against: TokenColor(hex: 0xFFFFFF))
        #expect(abs(ratio - 21) < 0.01)
    }
}
