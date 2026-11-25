# App icon and launch screen: Apple's current requirements (Nov 2026)

> **中文摘要**
>
> 1. 图标用 Icon Composer `.icon`（`Duiyi/AppIcon.icon`）：`icon.json` + `Assets/*.svg`，无需改 `project.pbxproj`；空的 `AppIcon.appiconset` 会静默产出 0 个图标。
> 2. 启动图保留 `UILaunchScreen`，加 `UIColorName = LaunchBackground`，颜色集精确对应 `Tokens.canvas`（浅 `#F2F2F7` / 深 `#0B0C10` / 高对比 `#FFFFFF` / `#000000`）。
> 3. 启动图只放纯画布，不放图标 mark 或字标：HIG 要求它几乎等同首帧，mark 会变成 splash。
> 4. 验证：`actool` 的 partial plist 应含 `CFBundleIconName`/`CFBundleIconFiles`；`assetutil` 应看到 ≥3 个 icon rendition；再构建并在模拟器/真机看 Home Screen 与首帧。
> 5. 本文件是调研与决策记录；实现落在 `feat/app-icon-launch`。

> Researched 2026-11-26. Environment verified locally: Xcode 27.1 (27A9275), iOS SDK 27.1
> (`iphoneos27.1`), deployment target `26.4`, SwiftUI iPhone-only target `Duiyi`.
> This document is research only: no app code, project file, or commit was changed.
>
> Method: primary Apple sources (HIG, developer documentation, release notes, WWDC sessions) plus
> read-only inspection and scratch experiments with the installed Xcode 27.1 toolchain. Claims that
> come only from local experiments are marked **[local]**; claims Apple does not document are marked
> **[undocumented]**.

---

## Decision summary

1. **Use an Icon Composer `.icon` bundle as the primary icon** (`Duiyi/AppIcon.icon`), because the
   app targets iOS 26.4 and up only. Apple treats both formats as official, but explicitly prefers
   Icon Composer: "Provide your icon in the Icon Composer format for more flexibility and control"
   [1]. It is the only format that gives the system real foreground/background layers, so Liquid
   Glass, dark, tinted, and clear appearances are fully under your control instead of being
   inferred by segmentation [1]. Xcode compiles `.icon` with the same `actool` step as an asset
   catalog **[local]** [2][L2].
2. **A single 1024×1024 PNG is still fully supported.** Xcode generates all sizes from one image,
   and the system generates any dark/tinted/clear variants you don't supply [1][3]. It is the
   correct fallback if the team does not want to own an undocumented `icon.json`.
3. **Author the `.icon` reproducibly as `icon.json` + `Assets/*.svg`.** A hand-written bundle with
   one background fill and one SVG layer compiles with `actool` and renders through `ictool`
   **[local]**. Apple does not publish the `icon.json` schema **[undocumented]**, so treat the file
   as generated/checked-in source and re-save it in Icon Composer only when a designer needs the
   visual editor.
4. **Launch screen: keep `UILaunchScreen` and add `UIColorName`.** An empty `UILaunchScreen` is
   valid and satisfies the new iOS 27 SDK requirement [11], but it renders
   `UIColor.systemBackground` (#FFFFFF light / #000000 dark) [7], not this app's canvas
   (#F2F2F7 / #0B0C10), so it flashes. Point it at a new `LaunchBackground` color set that matches
   `Tokens.canvas`.
5. **No build-setting changes are required.** `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` already
   matches the recommended `.icon` filename, and `INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE` defaults to
   `YES`, so `actool` merges `CFBundleIcons` / `CFBundleIconName` into the built Info.plist [L2].

---

## Verified project state

| Fact | Value | How verified |
| --- | --- | --- |
| Target / scheme | `Duiyi`, iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait only | `project.pbxproj`, `Info.plist` |
| Project layout | `Duiyi` is a `PBXFileSystemSynchronizedRootGroup`: new files under `Duiyi/` join the target with no pbxproj edit | `project.pbxproj` |
| Deployment target | `26.4` (`MinimumOSVersion` in built app = 26.4) | `xcodebuild -showBuildSettings`, built `Info.plist` |
| Icon setting | `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` | `project.pbxproj` |
| Accent setting | `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor` | `project.pbxproj` |
| Asset catalog | `Duiyi/Assets.xcassets` with only `AccentColor.colorset` and an **empty** `AppIcon.appiconset` | `find`, `Contents.json` |
| Icon artwork | none: the built app's `Assets.car` contains 1 color and 0 icon images; generated partial plist contains only `NSAccentColorName` | **[local]** build + `assetutil` |
| Built Info.plist icon keys | **none** (`CFBundleIcons` absent) → system shows the default blank icon, with **no build warning** | **[local]** build + `plutil` |
| Launch screen | `UILaunchScreen` present but empty (`<dict/>`); survives into the built app | `Info.plist`, built plist |
| Canvas color | light `#F2F2F7`, dark `#0B0C10`, high-contrast `#FFFFFF` / `#000000` | `Duiyi/DesignSystem/Tokens.swift` |

The current state is the "silent blank icon" failure mode described in Gotchas: `actool` compiles an
empty app icon set without a warning and emits an empty partial Info.plist **[local]**.

---

## 1. Format in Xcode 27 / iOS 26+: `.icon` vs `AppIcon.appiconset`

### 1.1 Both are official; Icon Composer is preferred

> "In iOS, iPadOS, macOS, and watchOS, you can provide icons in one of two formats: nonlayered
> bitmap images (such as PNG) or layered Icon Composer files." [1]

There is no deadline that deprecates `AppIcon.appiconset`. The Xcode 27.1 iOS app template still
sets `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` and ships no `.icon` resource **[local]**, so the
asset catalog remains the default for new projects. The HIG changelog entry "October 28, 2026 —
Added guidance for app icon format options" is what introduced the explicit two-format guidance [1].

Important difference in behavior, from Apple:

> "If you add an Icon Composer file to your Xcode project, it replaces any existing icon asset
> catalog that you previously used to represent your app icon." [2]

Verified locally: when both `Assets.xcassets/AppIcon.appiconset` and `AppIcon.icon` are passed to
`actool` with `--app-icon AppIcon`, the `.icon` wins and the catalog icon is ignored, with no warning
**[local]**.

### 1.2 A single 1024×1024 PNG still works

> "iOS, iPadOS, tvOS, and watchOS apps can auto-generate all icon variations from a single
> 1024×1024 pixel image. This is the default behavior when you create a new iOS ... app." [3]

The HIG specification table gives iOS/iPadOS/macOS a 1024×1024 px square, layered icon [1]. A flat
PNG is the "nonlayered bitmap" case; Apple describes what the system does with it in §1.5.

### 1.3 How each compiles (`actool`)

Xcode 27.1 treats `folder.iconcomposer.icon` as an input file type of the asset catalog compiler
(`AssetCatalogCompiler.xcspec`) **[local]**, i.e. the same `actool` invocation compiles both:

```
# shape of the command Xcode 27.1 actually ran for this project [local, from the build log]
actool <Assets.xcassets> [<AppIcon.icon>] \
  --compile <assetcatalog_output> \
  --output-format human-readable-text --notices --warnings \
  --export-dependency-info <deps> \
  --output-partial-info-plist <assetcatalog_generated_info.plist> \
  --app-icon AppIcon --accent-color AccentColor \
  --compress-pngs --enable-on-demand-resources YES --development-region en \
  --target-device iphone --minimum-deployment-target 26.4 \
  --platform iphonesimulator
```

Observed outputs **[local]**:

| Input | `Assets.car` icon renditions | Loose PNGs | Partial Info.plist |
| --- | --- | --- | --- |
| Empty `AppIcon.appiconset` (current repo) | 0 | none | `{}` → no icon in app |
| One 1024 PNG in `AppIcon.appiconset` | 1 (`UIAppearanceAny`) | 60@2x + 76@2x~ipad | `CFBundleIcons` + `CFBundleIconName` |
| `AppIcon.icon` (one SVG layer) | 3 classes: Any, Dark, `ISAppearanceTintable` (× phone/pad) | 60@2x + 76@2x~ipad | `CFBundleIcons` + `CFBundleIconName` |

`actool` emits `CFBundleIconFiles` / `CFBundleIconName` for the primary icon, and the build merges
that into `Info.plist` because `INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE` defaults to `YES` **[local]**
(confirmed in `CoreBuildSystem.xcspec`). The loose 60pt/76pt PNGs are a small subset for external
tools; `--standalone-icon-behavior` controls how many are emitted (`man actool`).

If `--app-icon` names nothing that exists, the build fails loudly:
`error: None of the input catalogs contained a matching stickers icon set, app icon set, or icon
stack named "AppIcon".` **[local]** — a *named but empty* set, by contrast, fails silently.

### 1.4 Appearance variants

Apple's current HIG defines six iOS appearances: **default, dark, clear light, clear dark, tinted
light, tinted dark** [1]. WWDC25 lists the same six [15]. Icon Composer exposes them as
Default / Dark / Mono (with Clear and Tinted options) per platform [2].

For an `.icon` bundle the compiled CAR stores three rendition classes — Any, Dark, and a tintable
rendition (three per idiom) — and the six user-facing appearances are produced from those rather
than from separate stored 1024 renditions **[local, `assetutil`]**. The legacy `appiconset` only has
three slots — Any, Dark, Tinted [3] — and the system generates anything missing:

> "You can design app icon variants for every appearance variant, and the system automatically
> generates variants you don't provide." [1]

Layer structure: iOS/iPadOS/macOS/watchOS icons have "a background layer and one or more foreground
layers" [1]; Icon Composer organizes foreground layers into "a maximum of four groups" which become
the layers the platform renders for depth [2]. WWDC25 adds that a group can hold one to four layers
[15].

### 1.5 What happens to a legacy flat icon under Liquid Glass

> "If you provide a bitmap image instead, the system attempts to segment your icon, isolating the
> foreground elements from the background to create an icon with two layers. These two layers help
> make your icon compatible with dark and tinted appearance variants ... When the system segments
> your icon, it applies Liquid Glass effects to foreground layers that feature large, simple shapes.
> It doesn't automatically apply Liquid Glass effects to smaller, more complex elements in an icon
> like text and thin lines." [1]

Also: "Irregularly shaped icons receive a system-provided background" [13]. So a flat 1024 PNG is
not merely masked — it is heuristically split, and glass is applied only to what the splitter
considers a large simple shape. A wordmark or thin-line glyph will not get the treatment.

---

## 2. HIG rules that constrain the design

| Rule | Apple's wording / requirement | Source |
| --- | --- | --- |
| Shape and masking | Icons are square; "the system applies masking to produce rounded corners that precisely match the curvature of other rounded interface elements". Do not pre-mask. | [1] |
| Pre-masked layers | "Providing layers with pre-defined masking negatively impacts specular highlight effects and makes edges look jagged." | [1] |
| Canvas / grid | 1024×1024 px for iOS/iPadOS/macOS. "Keep primary content centered to avoid truncation when the system adjusts corners or applies masking." Use the Apple Design Resources grid. | [1][14][21] |
| Numeric safe margin | **Apple publishes no numeric safe margin in the HIG.** Use the app-icon grid templates / Icon Composer's grid overlay. | [1][2] |
| Background | Prefer a simple solid or gradient background; "If you do import a background layer, make sure it's full-bleed and opaque." | [1] |
| Transparency | The HIG asks for an opaque, full-bleed background; it does not ask for an alpha channel in the delivered icon. (App Store validation rejects alpha — see Gotchas.) | [1] |
| Text | "Include text only when it's essential to your experience or brand. Text in icons doesn't support accessibility or localization, is often too small to read easily, and can make an icon appear cluttered." | [1] |
| Imagery | "Prefer illustrations to photos"; don't replicate UI, don't use Apple hardware. Avoid "extremely thin line weights and sharp corners". | [1] |
| Layer count | Background + one or more foreground layers; max four groups in Icon Composer. Simple > complex. | [1][2] |
| Effects | "Let the system handle blurring and other visual effects" — no baked highlights, drop shadows, bevels, glows. | [1] |
| Color | Simple palette; keep features consistent across appearances; dark icons more subdued; "Color backgrounds generally offer the greatest contrast in dark icons." Supported color spaces: sRGB, Gray Gamma 2.2, Display P3. | [1] |
| Small-size legibility | "An icon with fine visual features might look busy when rendered with system-provided shadows and highlights, and details may be hard to discern at smaller sizes." | [1] |
| Alternate icons | Every alternate icon needs its own dark, clear, and tinted variants and is subject to review. | [1] |

---

## 3. Authoring an `.icon` reproducibly

### 3.1 Bundle layout

An Icon Composer document is a package with extension `.icon` (UTI `com.apple.iconcomposer.icon`,
declared by Icon Composer.app) **[local]**:

```
AppIcon.icon/
├── icon.json          # document manifest (only required file)
└── Assets/            # imported layer images referenced by "image-name"
    ├── background.svg
    └── glyph.svg
```

Apple's own Xcode file template (`Icon Composer Icon.xctemplate`) contains **only** `icon.json`; no
`Contents.json`, no `Assets` folder **[local]**. The minimal template manifest is:

```json
{
  "fill" : { "automatic-gradient" : "extended-srgb:0.00000,0.53333,1.00000,1.00000" },
  "groups" : [],
  "supported-platforms" : { "circles" : ["watchOS"], "squares" : "shared" }
}
```

### 3.2 A minimal, verified `icon.json`

This hand-written manifest compiles with `actool` and renders all six renditions with `ictool`
**[local]**:

```json
{
  "fill" : { "solid" : "extended-srgb:0.043,0.047,0.063,1.0" },
  "groups" : [
    {
      "name" : "Foreground",
      "layers" : [
        { "image-name" : "glyph.svg", "name" : "Glyph" }
      ]
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
```

`glyph.svg` is a 1024×1024 `viewBox` SVG. Gradients also work
(`"fill": { "automatic-gradient": "extended-srgb:r,g,b,a" }`). Keys that exist in the binary and in
Icon Composer-written documents, but that Apple does not document, include `blend-mode`, `opacity`,
`hidden`, `glass`, `shadow`, `translucency`, `specular`, `refractivity`, `position`, `scale`, and
`*-specializations` variants for per-appearance overrides **[local, framework strings]**.

Because the schema is not published, **treat a hand-authored `icon.json` as an unstable interface**:
an Icon Composer save may rewrite it in a richer form, and a future Xcode may change it. It is
still the only non-GUI path that produces the official layered format.

### 3.3 Automation: GUI-only officially; one undocumented CLI exists

- Icon Composer.app has **no AppleScript dictionary** (no `.sdef` / script suite in the bundle)
  **[local]**. Apple documents no CLI or automation for it [2][15][16], and ships it only as a GUI
  app (in Xcode, or from the standalone download) [20].
- The bundle ships an undocumented command-line renderer:

  ```
  "/Volumes/DevDisk/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
  ```

  Usage (verified, Icon Composer 27.1 / build 129) **[local]**:

  ```
  ictool <input.icon> --export-image --output-file <out.png> --platform iOS \
      --rendition <Default|Dark|TintedLight|TintedDark|ClearLight|ClearDark> \
      --width 1024 --height 1024 --scale 1 \
      [--tint-color 0.25] [--tint-strength 0.75] [--design-generation <26|27>]
  ```

  It exports masked, **alpha-bearing** PNGs at 1024×1024 — previews/marketing only, not App Store
  artwork **[local]**. `--design-generation 26|27` reproduces the iOS 26 vs iOS 27 renderer, which
  matches the "Icon Composer 2.0 ... new sharper rendering mode for upcoming 2027 operating systems"
  note in the Xcode 27 release notes [12].
- **Trap:** `xcrun ictool` resolves to `<Xcode>/Contents/Developer/usr/bin/ictool`, which is a
  *different* actool-family binary that rejects `--export-image` **[local]**. Always use the full
  path inside Icon Composer.app.

### 3.4 Minimal artifacts to check in

```
Duiyi/AppIcon.icon/icon.json
Duiyi/AppIcon.icon/Assets/<layer>.svg      # one per foreground layer
```

No `Contents.json` is needed. The `Duiyi` folder in this project is a
`PBXFileSystemSynchronizedRootGroup` **[local, `project.pbxproj`]**, so dropping `AppIcon.icon` under
`Duiyi/` adds it to the target with **no pbxproj edit**; Xcode routes it to `actool` as an
asset-catalog input rather than copying it as a resource **[local, xcspec]**. Keep
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` [2], and delete
`Duiyi/Assets.xcassets/AppIcon.appiconset` once the `.icon` is in place (Apple says the `.icon`
replaces it anyway [2]).

### 3.5 PNG-based fallback that still follows the official style

If the undocumented manifest is unacceptable, use the documented path:

- `Duiyi/Assets.xcassets/AppIcon.appiconset/Contents.json` keeps the single `universal` /
  `platform: ios` / `1024x1024` slot, plus `"filename": "AppIcon-1024.png"`.
- Supply one 1024×1024, **opaque, sRGB, unmasked, full-bleed** PNG: no rounded corners, no drop
  shadow, no alpha, no text if it can be avoided [1][3].
- Optionally add a Dark 1024 image (transparent background allowed in this slot) and a grayscale
  Tinted 1024 image [3].
- Accept that the system will segment it and apply glass heuristically [1].

---

## 4. Launch screen

### 4.1 Official mechanism and exact key names

`UILaunchScreen` is an Info.plist dictionary (iOS/iPadOS 14+). Apple's documented child keys are
**`UIColorName`**, **`UIImageName`**, `UIImageRespectsSafeAreaInsets` [9], `UINavigationBar`,
`UITabBar`, `UIToolbar` [6]. (The names `BackgroundColor` / `ImageName` are not Apple's keys; the
real names are the `UI…` forms.)

- `UIColorName`: "the name of a color in your asset catalog ... the same string ... you might use
  when calling `UIColor(named:)`". If absent, "the system uses a default of `UIColor.systemBackground`,
  which varies according to whether the user has selected the light appearance or Dark Mode" [7].
- `UIImageName`: "the name of an image in your asset catalog"; background color shows through
  transparency [8].
- `UILaunchScreens` (plural) exists only for per-URL-scheme launch screens and needs
  `UILaunchScreenDefinitions` / `UIURLToLaunchScreenAssociations` / `UIDefaultLaunchScreen` [10].
  Not needed here.
- The storyboard alternative is `UILaunchStoryboardName` / `UILaunchStoryboards`; this project does
  not use it [5][6].

The SwiftUI default is an **empty** `UILaunchScreen` dictionary: the build setting
`INFOPLIST_KEY_UILaunchScreen_Generation = YES` is defined as "sets the value of the `UILaunchScreen`
key in the Info.plist file to an empty dictionary" **[local, `CoreBuildSystem.xcspec`]**. This repo
already has that exact state, hand-written.

### 4.2 iOS 26 / iOS 27 changes

- **iOS 27 SDK requirement (new, and the only documented change):** "iOS and iPadOS apps built with
  the 27.0 SDK or later are required to include a launch screen. Your app's `Info.plist` must
  contain one of the following keys: `UILaunchStoryboardName`, `UILaunchStoryboards`,
  `UILaunchScreen`, or `UILaunchScreens`. Apps that don't include a launch screen are rejected when
  the App Store begins accepting apps built with the 27.0 SDK." [11]

  The repo's empty `<key>UILaunchScreen</key><dict/>` satisfies this; no action is needed for
  compliance.
- No documented new `UILaunchScreen` keys, and no documented Liquid Glass API or transition for
  launch screens [6][11]. Anecdotal reports of an icon-to-app zoom on iOS 26 exist, but **no Apple
  documentation or API for it was found**; it is not configurable and is out of scope here.
- There is also no documented change to how the launch screen is rendered under Liquid Glass; it
  remains a static UIKit view hierarchy [5][6].

### 4.3 HIG rules

> "Design a launch screen that's nearly identical to the first screen of your app or game. ... If
> your app or game displays a solid color before transitioning to the first screen, create a launch
> screen that displays only that solid color. Also make sure that your launch screen matches the
> device's current orientation and appearance mode." [4]

> "Avoid including text on your launch screen ... Don't advertise. The launch screen isn't a
> branding opportunity." [4]

Portrait-only apps "launch in that orientation" [4] — this app declares only
`UIInterfaceOrientationPortrait`, so nothing extra is required.

### 4.4 Minimal correct configuration for this app

The first frame of `RootView` is `Tokens.canvas.ignoresSafeArea()`: **#F2F2F7 light / #0B0C10 dark**
(#FFFFFF / #000000 in Increase Contrast). The empty dictionary currently yields systemBackground
(#FFFFFF / #000000) [7], so the launch screen and frame one do not match — the exact flash the HIG
asks you to avoid [4].

Recommended:

1. Add `Duiyi/Assets.xcassets/LaunchBackground.colorset/Contents.json`:

```json
{
  "colors" : [
    { "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "0.969", "green" : "0.949", "red" : "0.949" } }, "idiom" : "universal" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "0.063", "green" : "0.047", "red" : "0.043" } }, "idiom" : "universal" },
    { "appearances" : [ { "appearance" : "contrast", "value" : "high" } ],
      "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "1.000", "green" : "1.000", "red" : "1.000" } }, "idiom" : "universal" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" }, { "appearance" : "contrast", "value" : "high" } ],
      "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "blue" : "0.000", "green" : "0.000", "red" : "0.000" } }, "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

(This exact file compiles cleanly with `actool` into four color renditions — any, dark, high
contrast, dark+high contrast — with no warnings **[local]**.)

2. Change `Duiyi/Info.plist`:

```xml
<key>UILaunchScreen</key>
<dict>
	<key>UIColorName</key>
	<string>LaunchBackground</string>
</dict>
```

Do **not** add `UIImageName` unless the first screen actually contains a fixed image; the HIG wants
the launch screen to look like frame one, and this app's first frame is a flat canvas [4].

`UIColorName` is not validated at build time (it is consumed at runtime by UIKit, not by `actool`),
so a typo is not caught by the compiler — verify by screenshot (below).

---

## 5. Verification

### 5.1 Compile the assets directly (fast, no full build)

```bash
ACT=$(xcrun --find actool)
rm -rf /tmp/ac && mkdir -p /tmp/ac
"$ACT" Duiyi/Assets.xcassets Duiyi/AppIcon.icon \
  --compile /tmp/ac \
  --platform iphoneos --minimum-deployment-target 26.4 --target-device iphone \
  --app-icon AppIcon --accent-color AccentColor \
  --output-partial-info-plist /tmp/ac/partial.plist \
  --output-format human-readable-text --notices --warnings --errors

plutil -p /tmp/ac/partial.plist          # expect CFBundleIconName + CFBundleIconFiles
xcrun assetutil --info /tmp/ac/Assets.car | grep -c '"AssetType" : "Icon Image"'   # expect >= 3
```

Expected partial plist for a working icon **[local]**:

```
CFBundleIcons -> CFBundlePrimaryIcon -> { CFBundleIconFiles: [AppIcon60x60], CFBundleIconName: AppIcon }
```

What failures look like **[local]**:

| Situation | Result |
| --- | --- |
| `AppIcon.appiconset` exists but has no image | no warning, empty partial plist, no icon in CAR |
| `AppIcon.appiconset` removed and no `.icon` | `error: None of the input catalogs contained a matching ... app icon set ... named "AppIcon"` |
| `--app-icon` name ≠ `.icon` filename | same hard error |
| App icon set has images but no 1024 | `warning: A 1024x1024 app store icon is required for iOS apps` (suppressed by `--skip-app-store-deployment`) |

### 5.2 Full build and inspect the product

```bash
xcodebuild -project Duiyi.xcodeproj -scheme Duiyi -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/dd build

APP=/tmp/dd/Build/Products/Debug-iphonesimulator/Duiyi.app
plutil -p "$APP/Info.plist" | grep -A6 -E 'CFBundleIcons|UILaunchScreen'
xcrun assetutil --info "$APP/Assets.car" | grep -c '"AssetType" : "Icon Image"'
```

> Observed during this research: after a full build, `project.pbxproj` (group ordering) and
> `Localizable.xcstrings` showed up modified in `git status`. Both were reverted. Check `git status`
> after building and revert unrelated files before committing.

### 5.3 Render appearances for design review

```bash
IC="/Volumes/DevDisk/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for r in Default Dark TintedLight TintedDark ClearLight ClearDark; do
  "$IC" Duiyi/AppIcon.icon --export-image --output-file "/tmp/icon-$r.png" \
    --platform iOS --rendition "$r" --width 1024 --height 1024 --scale 1
done
```

### 5.4 Simulator / device

```bash
xcrun simctl boot "iPhone 17 Pro Max"
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.david.Duiyi
xcrun simctl io booted screenshot /tmp/launch-light.png
xcrun simctl ui booted appearance dark
xcrun simctl terminate booted com.david.Duiyi  # then relaunch for the launch screen again
```

- Launch screen: screenshot immediately after `launch` (or record video) and compare the first frame
  with `RootView` in both appearances.
- Home screen icon / dark / tinted / clear: press Home (Simulator **Device > Home**, ⌘⇧H), then
  long-press the Home Screen and switch appearance via **Customize**. On a device, use Device Hub
  [2] and the Home Screen appearance picker.
- App Store icon: the icon that matters is the one compiled into the build; the 1024 rendition is
  generated by `actool` from the `.icon`, so there is no separate upload asset [2][17].

---

## 6. Gotchas

1. **A named-but-empty app icon set is silent.** The current repo compiles cleanly, emits no
   `CFBundleIcons`, and ships a blank icon **[local]**. Always check the partial plist or `Assets.car`
   after touching icon assets.
2. **A missing or misnamed icon set errors; an empty one does not.** `--app-icon Foo` with no
   matching set fails the build; an existing but empty `AppIcon.appiconset` passes silently. Prefer
   deleting the legacy set once the `.icon` is wired up.
3. **App Store icon must be 1024×1024 and opaque.** App Store validation rejects transparency /
   alpha with `ITMS-90717: Invalid App Store Icon ... can't be transparent nor contain an alpha
   channel` [18]. This is not stated in the current HIG or asset-catalog docs; it is only visible as
   a validation error. Pre-rounded corners are also rejected because the system masks them [1].
4. **Icon Composer + blur/translucency has produced alpha upload failures.** Apple-hosted forum
   reports (including an Apple staff reply) describe `ITMS-90717` for `.icon`-generated icons when a
   blurred SVG sits near the canvas edge; workarounds include disabling Blur on that group or
   flattening the artwork [19]. Treat as a known field issue, not documented behavior.
5. **`ictool` output is not App Store artwork.** It renders the masked shape with transparent
   corners at 16-bit RGBA **[local]**.
6. **Do not use `xcrun ictool`.** It resolves to a different actool-family binary; use the full path
   inside `Icon Composer.app` **[local]**.
7. **Icon caching.** SpringBoard caches icons aggressively. When iterating, uninstall and reinstall
   (`xcrun simctl uninstall` / `install`), or erase the simulator (`xcrun simctl erase`); on device,
   delete the app and reinstall. Apple does not document this; it is standard practice
   **[undocumented]**.
8. **iOS 18 vs iOS 26 appearances.** iOS 18 introduced the dark and tinted icon variants [1]; the
   asset catalog exposes three styles — Light, Dark, Tinted — with a grayscale tinted image and a
   transparent dark image [3]. iOS 26 adds Clear light/dark and system Liquid Glass layering, for six
   appearances total [1][15]. A legacy appiconset still only has three slots; clear variants are
   derived by the system.
9. **`INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE`.** If a target turns this off, `actool`'s icon keys never
   reach `Info.plist` and the app shows a blank icon. Default is `YES`; this project uses the default
   **[local]**.
10. **Back-deployment is automatic but not pixel-identical.** Apple says Xcode generates icon images
    for older releases from the `.icon` [2]; the Xcode 27 release notes call out a new 2027 rendering
    mode that must be previewed separately [12]. This app targets 26.4 only, so it is out of scope.
11. **Full-bleed, unmasked source art.** Do not export the rounded-rect mask from the design tool;
    Apple explicitly excludes it [1][15]. Pre-masked edges break specular highlights [1].

---

## 7. Recommended implementation path

### Icon (primary: Icon Composer format)

1. Create `Duiyi/AppIcon.icon/icon.json` (see §3.2) and `Duiyi/AppIcon.icon/Assets/*.svg`
   (1024×1024 viewBox, unmasked, text converted to outlines). No pbxproj edit: `Duiyi` is a
   synchronized folder.
2. Keep `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`; no new build settings.
3. Delete `Duiyi/Assets.xcassets/AppIcon.appiconset` (the `.icon` supersedes it [2]).
4. Leave `AccentColor` untouched; it is unrelated to the icon.
5. Verify with §5.1, then §5.2, then §5.4.

The `.icon` fill uses the brand ink `#0B0C10`, the same value as `TokenPalette.canvas.dark`. It is
part of the icon artwork, not a UI token: a future canvas change should not silently repaint the
app icon. The launch colorset, by contrast, must track `Tokens.canvas` and is pinned by
`LaunchBackgroundTests`.

### Icon (fallback: documented asset catalog)

1. Put `AppIcon-1024.png` (1024×1024, sRGB, opaque, unmasked) in
   `Duiyi/Assets.xcassets/AppIcon.appiconset/`.
2. Set `Contents.json` `images[0].filename = "AppIcon-1024.png"` in the existing single
   `universal` / `ios` / `1024x1024` slot.
3. Optionally add `appearances: [{"appearance":"luminosity","value":"dark"}]` and
   `[{"appearance":"luminosity","value":"tinted"}]` 1024 slots [3].
4. Verify with §5.1.

### Launch screen

1. Add `Duiyi/Assets.xcassets/LaunchBackground.colorset/Contents.json` (§4.4).
2. Set `UILaunchScreen` → `UIColorName` = `LaunchBackground` in `Duiyi/Info.plist`.
3. Build, launch in light and dark, screenshot the first frame and compare to `RootView`.

Expected source diff: `AppIcon.icon/` (manifest + SVG layers), `LaunchBackground.colorset`, one
`Info.plist` key, removal of `AppIcon.appiconset`, and one regression test
(`DuiyiTests/LaunchBackgroundTests.swift`); **no pbxproj edit** (synchronized folder) and no app
Swift changes.

---

## 8. Open decisions (visual design only)

These are judgement calls Apple's docs do not settle; they are not format questions.

1. **Icon concept.** A single abstract mark (two overlapping speech panes, a bidirectional arrow, a
   「译」 glyph) versus a literal translation metaphor. HIG discourages text, so a glyph should work
   without relying on the character being readable at 60pt [1].
2. **Palette.** Use the brand accent #E8B86D on the dark canvas #0B0C10, or invert it. Apple warns
   dark icons should be more subdued and that color backgrounds give the most contrast [1].
3. **Layer count.** One foreground group (simple, robust) versus two or three groups with opacity /
   glass to get depth. More groups = more Liquid Glass response but more risk at small sizes [1][2].
4. **Per-appearance art.** Rely on system-generated dark/tinted/clear, or hand-tune the dark and mono
   variants in Icon Composer. Hand-tuning is more work and must be redone if the icon changes [1].
5. **Launch background.** Match `Tokens.canvas` exactly (recommended, zero flash) versus a deliberate
   brand color. Matching is what the HIG asks for [4].
6. **Whether to keep the `.icon` as hand-written JSON or re-save it from Icon Composer** after the
   first design pass (affects diff noise and reproducibility, not rendering).

---

## 9. Citations

Apple primary sources:

1. Human Interface Guidelines — App icons. https://developer.apple.com/design/human-interface-guidelines/app-icons
2. Xcode — Creating your app icon using Icon Composer. https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
3. Xcode — Configuring your app icon using an asset catalog. https://developer.apple.com/documentation/xcode/configuring-your-app-icon
4. Human Interface Guidelines — Launching (incl. "Launch screens"). https://developer.apple.com/design/human-interface-guidelines/launching
5. Xcode — Specifying your app's launch screen. https://developer.apple.com/documentation/xcode/specifying-your-apps-launch-screen
6. Bundle Resources — `UILaunchScreen`. https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen
7. Bundle Resources — `UILaunchScreen.UIColorName`. https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen/uicolorname
8. Bundle Resources — `UILaunchScreen.UIImageName`. https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen/uiimagename
9. Bundle Resources — `UILaunchScreen.UIImageRespectsSafeAreaInsets`. https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen/uiimagerespectssafeareainsets
10. Bundle Resources — `UILaunchScreens`. https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreens
11. iOS & iPadOS 27 Release Notes (UIKit → launch screen requirement). https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes
12. Xcode 27 Release Notes (Icon Composer 2.0 / design generation 27). https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
13. Technology Overviews — Adopting Liquid Glass (App icons). https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
14. WWDC25 session 220 — Say hello to the new look of app icons. https://developer.apple.com/videos/play/wwdc2025/220/
15. WWDC25 session 361 — Create icons with Icon Composer. https://developer.apple.com/videos/play/wwdc2025/361/
16. WWDC26 session 8012 — Icon Composer for Beginners Group Lab. https://developer.apple.com/videos/play/wwdc2026/8012/
17. App Store Connect Help — Add an app icon. https://developer.apple.com/help/app-store-connect/manage-app-information/add-an-app-icon
18. Apple Developer Forums — "Invalid App Store Icon, can't be transparent nor contain an alpha channel" (ITMS-90717). https://developer.apple.com/forums/thread/96003
19. Apple Developer Forums — "Icon composer icon contains alpha channel upload error". https://developer.apple.com/forums/thread/795411
20. Icon Composer. https://developer.apple.com/icon-composer/
21. Apple Design Resources (icon templates and grids). https://developer.apple.com/design/resources/

Local (Xcode 27.1, build 27A9275) sources:

- L1. `man actool`; `actool --version` → 27.1 (25098). Flags `--app-icon`, `--standalone-icon-behavior`, `--skip-app-store-deployment`, `--output-partial-info-plist`.
- L2. `AssetCatalogCompiler.xcspec` (SwiftBuild/SWBApplePlatform): input file types include `folder.iconcomposer.icon`; `CoreBuildSystem.xcspec`: `INFOPLIST_KEY_UILaunchScreen_Generation` writes an empty `UILaunchScreen`; `INFOPLIST_ENABLE_CFBUNDLEICONS_MERGE` default `YES`.
- L3. `Icon Composer.app/Contents/Info.plist` (27.1, build 129, UTI `com.apple.iconcomposer.icon`); `Contents/Executables/ictool --help`.
- L4. `Xcode.app/.../Templates/File Templates/MultiPlatform/Resource/Icon Composer Icon.xctemplate` (template `icon.json`).
- L5. Scratch compiles/renders: empty appiconset, single-1024 appiconset, hand-authored `.icon`, both-named conflict, missing/mismatched name, `assetutil --info`, `ictool` six renditions, full simulator build of this repo.

---

## 10. What could not be verified

- **`icon.json` schema**: not published by Apple anywhere; derived from the Xcode template and
  Icon Composer framework strings, and validated only by compiling with this Xcode version.
- **Liquid Glass launch transition**: no Apple documentation or API was found describing a
  glass/zoom treatment for launch screens; not claimed here.
- **"No alpha" App Store rule**: documented only through the validation error and forum threads
  [18][19], not through current HIG/asset-catalog text.
- **Icon caching**: no Apple documentation; the uninstall/reinstall guidance is standard practice,
  not a cited rule.
- **End-to-end Xcode project integration of `.icon` in this repo**: verified at the `actool` and
  `xcspec` level; adding the file to the target was deliberately not performed (research-only task).
