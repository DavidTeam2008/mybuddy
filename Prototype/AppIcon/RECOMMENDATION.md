# 对译 App Icon — Prototype Review Recommendation

**Status: PROTOTYPE — NOT PRODUCTION.** This document is an advisory synthesis of three independent reviews of four design-exploration candidates. Nothing here is an App Store asset, production artwork, or a frozen decision. **The human makes the final visual call.**

- Generated: 2026-11-26
- Inputs: four candidate SVGs and renders in `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon`, the gallery `renders/index.html`, and three independent reviews (small-size legibility; Apple HIG / Liquid Glass fidelity; brand and semantics)
- Evidence: 1024 / 180 / 120 / 60 px renders, 256 / 40 px preflight renders, and the simulated squircle tile crops

## 1. Decision context

`对译` is an end-to-end, on-device, real-time two-way translation app (iPhone portrait, no backend). The icon brief fixed in the prototype gallery is:

- 1024×1024 full-bleed, fully opaque deep ink (`#0B0C10` with a faint `#14161C` radial); no alpha channel.
- Palette: ink, amber (`#E8B86D` / `#C98F3F`), warm white (`#FFF4E0`), and a cool teal reflection (`#7EC8C3`) at 10–12% that is never load-bearing.
- Mark language: exactly two speech bubbles and one bidirectional exchange arrow; the arrow reads as exchange, not refresh, sync, or file transfer.
- Small-size hierarchy: silhouette first, arrow second. Tails, speculars, pane lines, and reflections may drop away; the bubble silhouette and arrow geometry may not.
- All mark geometry inside the centered 819×819 safe area; no text, globe, letter, or microphone.

The four candidates all clear the technical gates: 1024×1024, opaque RGB with no alpha channel (`sips` verified), no text, gradients/masks/strokes only (librsvg-safe), and measured content bounding boxes inside the 819×819 safe area (mirrored 636×515; overlapping 796×624 with the soft rim at x 107–916; asymmetric 707×713; waveform 790×591). The question is therefore semantic, small-size, and craft quality, not technical validity.

Scores below are 1–5 per lens and are averaged only to summarize. They do not replace looking at the renders on a device.

## 2. Score table

| Candidate | Legibility | Distinctiveness | Fidelity | Brand fit | Mean | Review verdicts (R1 / R2 / R3) | Triage |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| `overlapping-lens` | 4.67 | 3.67 | 4.17 | 4.17 | **4.17** | shortlist / shortlist / shortlist | **Top pick** |
| `mirrored-bubbles` | 4.00 | 3.17 | 4.00 | 4.00 | **3.79** | refine / refine / refine | **Runner-up** |
| `waveform-exchange` | 3.50 | 3.83 | 2.83 | 3.17 | **3.33** | refine / refine / reject | Not shortlisted |
| `asymmetric-listen` | 2.83 | 3.50 | 2.17 | 2.83 | **2.83** | reject / reject / reject | Rejected |

R1 = small-size legibility and distinctiveness (L / D / F / B). R2 = Apple HIG and Liquid Glass fidelity. R3 = brand and semantics. Fidelity is scored against the settled mark: two interlocking rounded speech bubbles, a negative-space bidirectional arrow, the amber/ink palette, and an opaque 819-safe-area canvas. Mean is the average of all 12 scores (3 lenses × 4 dimensions).

| Lens | `mirrored-bubbles` | `overlapping-lens` | `asymmetric-listen` | `waveform-exchange` |
| --- | --- | --- | --- | --- |
| R1 small-size | 3.0 / 3.0 / 4.5 / 4.5 — refine | 4.5 / 4.0 / 4.5 / 4.5 — shortlist | 2.5 / 4.5 / 2.5 / 4.0 — reject | 3.5 / 4.5 / 3.0 / 4.0 — refine |
| R2 HIG / Liquid Glass | 5.0 / 3.0 / 3.0 / 3.0 — refine | 5.0 / 4.0 / 4.0 / 4.0 — shortlist | 3.0 / 3.0 / 2.0 / 2.0 — reject | 4.0 / 4.0 / 3.0 / 3.0 — refine |
| R3 brand / semantics | 4.0 / 3.5 / 4.5 / 4.5 — refine | 4.5 / 3.0 / 4.0 / 4.0 — shortlist | 3.0 / 3.0 / 2.0 / 2.5 — reject | 3.0 / 3.0 / 2.5 / 2.5 — reject |

Unanimous outcomes: all three lenses rank `overlapping-lens` first and reject `asymmetric-listen`. `mirrored-bubbles` is the only other candidate with zero reject verdicts. `waveform-exchange` splits 2 refine / 1 reject.

## 3. Shortlist

Two candidates are carried forward.

### 3.1 Top pick — `overlapping-lens`

The only candidate all three reviewers shortlisted and the only one whose at-a-glance read at 60 and 40 px is still "two speech bubbles + exchange."

- At 60 px: two offset amber lobes, a pale overlapping lens, and one bold horizontal black double arrow (~17 px long, 3.5 px shaft). At 40 px the arrow is still unambiguous (~11.6 px, 2.3 px shaft).
- The horizontal double arrow reads as turn-taking conversation rather than the vertical refresh/sync/transfer read of `mirrored-bubbles`.
- It is the only candidate with convincing Liquid Glass layering: translucent overlapping lobes, a lit vesica lens, a thin rim plus controlled specular arcs, soft depth, and the cool reflection held at 0.12.
- It satisfies the settled negative-space arrow: the arrow is carved through every glass layer by a mask to the ink canvas.
- Fidelity is strong: two equal bubbles, one lens, one bidirectional arrow, amber/ink palette, no literal globe/letter/microphone.

Known defects, all addressed or bounded below:

- The lens core is `#FFF4E0` across its inner 34% radius and the right lobe's fill starts at `#FFF4E0` across its top 20%. At 60 px these two cream fields fuse, so the lens stops being a differentiator and the icon drifts toward generic consumer chat.
- The lens's 12 px `#C98F3F` under-rim at 0.35 opacity renders brown/muddy at 1024.
- The 5.7-degree arrow tilt and the 60-unit shaft are slightly under-built, and the tails are stubby, but these are explicitly deferred so this recommendation remains one pass.
- The mark sits near the safe-area edge (soft rim x 107 / 916 against an 819 boundary of 102.5 / 921.5). Do not enlarge it; a proposed 6% scale-up from one review conflicts with the HIG mask margin.

### 3.2 Runner-up — `mirrored-bubbles`

The best-built and most brand-calm alternative, and the strongest arrow at small size (5.2 px shaft at 60; HIG legibility 5.0). Its negative-space construction and mirrored two-pane glass are the purest expression of the settled mark.

It is not ship-ready because at icon size it fails the two-bubble requirement: the two amber panes fuse into one gold plaque/open book, and the vertical up/down arrow reads as sync, currency exchange, or file transfer rather than human conversation. The tails become torn fins and the depth reads as a sticker die-cut. Repairing it means structural geometry rework (open the seam, stagger the panes vertically, make the arrow horizontal or diagonal, rebuild the tails and the shared light direction), not a polish pass. It remains the right fallback if the human rejects the lens metaphor or prioritizes maximum arrow legibility over the lens idea.

### 3.3 Not shortlisted

- `waveform-exchange`: distinctive and on-message for voice translation at 1024, but the two-cycle sine resolves to an equalizer/squiggle at 40 px, and the right lobe's cream field dominates. Its repair (straighten the arrow, recolor the right lobe, simplify the rim) deletes the waveform differentiator and converges on `overlapping-lens`, so there is no path that keeps its identity and passes.
- `asymmetric-listen`: rejected by all three lenses. The dark listener is background-colored and disappears at 60/40, the 20 px warm-white rim reads as a grey plastic gasket, the 45.8-degree positive white arrow reads as resize/send, and the one-way speaker-to-listener hierarchy contradicts mutual translation. Fixing it is a new concept, not a refinement.

## 4. The one refinement for the top pick

**One contrast/value-separation pass — no geometry, no path edits, no new layers.**

Goal: keep the lens as the distinctive pale-glass vesica while restoring amber to both speech lobes, so at 60 and 40 px the icon reads as three values (amber lobe / pale lens / ink arrow) instead of one cream mass.

Edits in `candidates/overlapping-lens.svg`:

1. **Right lobe fill — `fillRight` gradient (lines 15–20).** Change the first stop from `#FFF4E0` to `#E8B86D`. Keep `0.2 #E8B86D`, `0.82 #E8B86D`, `1 #C98F3F` unchanged. The existing `glowWarm` ellipse at (700, 370), 150×95, peak 0.34, becomes the only warm-white specular on the right lobe. No new highlight is added.
2. **Lens fill — `fillLens` radial (lines 22–27).** Cap the cream core and add a tinted glass mid-layer:
   - `0` → `#FFF4E0`
   - `0.22` → `#FFF4E0`
   - `0.50` → `#F2D6A0`
   - `0.78` → `#E8B86D`
   - `1` → `#C98F3F`
   Keep the `#7EC8C3` arc at 0.12 opacity unchanged.
3. **Lens under-rim (line 66).** Replace the muddy `stroke-width="12"`, `stroke-opacity="0.35"` `#C98F3F` stroke with `stroke-width="6"`, `stroke-opacity="0.5"`. Keep the 3.5 px `#FFF4E0` at 0.70 inner rim (line 67) unchanged.

Acceptance checks for the render pass:

- Re-render at 1024 / 180 / 120 / 60 plus the 40 px preflight and a squircle tile crop; do not judge from the SVG alone.
- At 60 and 40 px, the lens must read as a distinct pale vesica against two amber lobes; no cream field may merge into the right bubble.
- At 1024, the lens rim must read as a thin amber glass edge, not a brown/muddy halo; the right lobe must be amber-bodied with a small warm specular.
- Grayscale/tinted check: the lens must remain lighter than both lobes, and the black arrow must remain the highest-contrast element.
- The content bounding box and safe-area margins must not change (796×624; do not grow the mark).

This is deliberately a single axis. It is a gradient and stroke-parameter edit that a renderer can apply in one pass without touching any bubble, tail, arrow, or mask geometry.

## 5. Tradeoffs

- **Purity vs. legibility.** Choosing `overlapping-lens` gives up the purer negative-space construction and the stronger 5.2 px arrow shaft of `mirrored-bubbles` (the lens candidate's shaft is 3.5 px at 60). If the human's first criterion is maximum arrow legibility at 40 px, `mirrored-bubbles` after geometry rework is the alternative to test.
- **Lens brightness.** Capping the lens at `#F2D6A0` and restoring amber on the right lobe favors the small-size two-bubble read, but it makes the 1024 icon less "white liquid glass" than the current render. A brighter lens variant can be re-tried later, but it risks restoring the 60 px cream merge.
- **Size and safe area.** The mark is already at the safe-area margin (soft rim x 107 / 916 against 102.5 / 921.5). The brand reviewer's proposed 6% enlargement should not be applied without re-checking the iOS corner mask. The HIG reviewer's instruction not to grow the mark wins here.
- **Deferred items.** The arrow's 5.7-degree tilt, the 60-unit shaft, and the stubby tails are not part of this refinement. If the arrow still feels thin at 40 after the contrast fix, a separate geometry pass (shaft 60→72, head height 156→172, axis exactly horizontal) is the next lever. Bundling it now would make the result impossible to attribute to one change.
- **Uncertainty.** All reviews are visual assessments of static renders. There is no real-device install, no dynamic tint/dark-mode check, no icon-grid context, and no acoustic/product context in this prototype. The 40 px renders and tile crops are observational, not deliverables.
- **Reversibility.** The refinement is three parameter changes; it is easy to render an A/B pair and compare before committing anything to the production asset.

## 6. Human decision

This synthesis recommends `overlapping-lens` as the top pick and `mirrored-bubbles` as the runner-up, with the contrast pass above as the only next change to the top pick. That is a recommendation, not a decision: **the human owns the final visual call**, ideally after viewing the 1024, 60, and 40 px renders and the squircle tile crop on an actual iPhone home screen. The prototype sources are untouched by this document.

## 7. Artifacts

- This recommendation: `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/RECOMMENDATION.md`
- Prototype notes: `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/NOTES.md`
- Gallery: `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/index.html`
- Contact sheet: `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/contact-sheet.png`
- Top pick source: `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/candidates/overlapping-lens.svg`
- Top pick renders: `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/overlapping-lens-1024.png`, `overlapping-lens-180.png`, `overlapping-lens-120.png`, `overlapping-lens-60.png`
- Top pick preflight: `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/preflight/overlapping-lens-256.png`, `overlapping-lens-40.png`
- Runner-up source and render: `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/candidates/mirrored-bubbles.svg`, `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/mirrored-bubbles-1024.png`
- Squircle tile evidence: `/tmp/duiyi-app-icon-prototype/Prototype/AppIcon/renders/preflight/tile-crop.png`, `tile-crop-3x.png`
