# PROTOTYPE — NOT PRODUCTION

设计探索 / Design exploration only. These four icons are prototype candidates for the 对译 app icon. Nothing here is an App Store asset, a final pick, or production artwork.

- Root: `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon`
- Generated: 2026-11-26
- Tooling: `xmllint`, `rsvg-convert 2.63.2` (`/opt/homebrew/bin/rsvg-convert`), headless Google Chrome, `sips`

## Candidate table

| Slug | Name | Concept | Verdict |
| --- | --- | --- | --- |
| `mirrored-bubbles` | Mirrored Bubbles | Two equal amber glass speech bubbles mirror each other across the vertical axis and kiss at top and bottom, their enclosed central gap cut into a clean vertical double-headed exchange arrow. | pending |
| `overlapping-lens` | Overlapping Lens | Two rounded speech bubbles overlap into a luminous lens, and a carved bidirectional arrow turns their shared negative space into a single act of translation. | pending |
| `asymmetric-listen` | Asymmetric Listen | A large amber speech bubble speaks while a small clear, warm-white-rimmed glass bubble listens, and the gap between them holds one bold bidirectional exchange arrow. | pending |
| `waveform-exchange` | Waveform Exchange | A live sound waveform runs through two interlocking speech bubbles and resolves into a bold bidirectional exchange arrow, so the act of translating reads as one continuous signal. | pending |

All four candidates are included; none were excluded. Each SVG validated as well-formed XML and rendered without syntax or rendering breakage, so no source was modified.

## Files

Source SVGs and design JSON:

- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/candidates/mirrored-bubbles.svg`
- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/candidates/overlapping-lens.svg`
- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/candidates/asymmetric-listen.svg`
- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/candidates/waveform-exchange.svg`
- Matching `.json` design records in the same directory.

Deliverable renders (1024 / 180 / 120 / 60 px):

- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/mirrored-bubbles-{1024,180,120,60}.png`
- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/overlapping-lens-{1024,180,120,60}.png`
- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/asymmetric-listen-{1024,180,120,60}.png`
- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/waveform-exchange-{1024,180,120,60}.png`

Gallery and contact sheet:

- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/index.html`
- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/contact-sheet.png` (1400×2600)

Extra observation renders (not part of the size ladder):

- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/preflight/<slug>-256.png`
- `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/preflight/<slug>-40.png`

## Render commands

Preflight (256 px):

```sh
cd /tmp/duiyi-app-icon-prototype/Prototype/AppIcon/candidates
for f in *.svg; do
  slug="${f%.svg}"
  /opt/homebrew/bin/rsvg-convert -w 256 -h 256 "$f" \
    -o "/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/preflight/$slug-256.png"
done
```

Final size ladder:

```sh
cd /tmp/duiyi-app-icon-prototype/Prototype/AppIcon/candidates
R=/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders
for f in *.svg; do
  slug="${f%.svg}"
  for s in 1024 180 120 60; do
    /opt/homebrew/bin/rsvg-convert -w "$s" -h "$s" "$f" -o "$R/$slug-$s.png"
  done
done
```

Contact sheet:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
  --hide-scrollbars \
  --screenshot=/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/contact-sheet.png \
  --window-size=1400,2600 \
  file:///tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/index.html
```

## Verify commands

XML:

```sh
xmllint --noout /tmp/duiyi-app-icon-prototype/Prototype/AppIcon/candidates/*.svg
```

Dimensions and alpha:

```sh
cd /tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders
for f in *.png; do sips -g pixelWidth -g pixelHeight -g hasAlpha "$f"; done
```

Resolution of every gallery image reference:

```sh
cd /tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders
python3 -I -c "import re, os; h=open('index.html').read(); m=[s for s in re.findall(r'<img[^>]+src=\"([^\"]+)\"', h) if not os.path.exists(s)]; print('missing:', m)"
```

## Caveats

- Alpha channel: every candidate PNG is `space: RGB` with `hasAlpha: no` per `sips`; the visual background is fully opaque. There is no alpha channel to composite against, so the icon must never rely on transparency.
- Excluded candidates: none. All four SVGs passed `xmllint --noout` and rendered correctly at 256 px preflight; no syntax fixes or redesigns were needed.
- The SVG sources were not edited in this run.
- The gallery uses only relative image paths (`<slug>-<size>.png` in its own directory), UTF-8, inline CSS, and system fonts; it loads no external scripts, fonts, or network assets.
- The 40 px renders under `renders/preflight/` were produced only to check the small-size plans; the required deliverable ladder is 1024 / 180 / 120 / 60.
- The contact sheet is a 1400×2600 window screenshot of the full page; the page content fits with the footer visible.
