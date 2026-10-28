# Mac notes glass appearance QA — Build 55

Source visual truth: /Users/gaoluchuan/.codex/generated_images/01a10f28-c75e-7923-828d-dfc09d9526c1/exec-2be1ec02-b4a6-4cbb-a00c-b16768e7a75b.png
Implementation captures: /Users/gaoluchuan/Documents/Codex/2026-10-07/Zilo/.release/20261028-notes-glass/lighter-edit.png; lighter-folded.png; lighter-preview.png; lighter-dark.png; appearance-menu.png; solid.png.
Combined comparison: /Users/gaoluchuan/Documents/Codex/2026-10-07/Zilo/.release/20261028-notes-glass/comparison.png (opened and compared).

## Scope and normalization

The selected mockup is a 1024×1536 concept poster. The accepted brief explicitly retains the existing compact native card layout and reduces the poster's bright rim/refraction. It is a material/style target, not a replacement layout. Native drawer: 320pt wide, captured at 2× (640px). Editing capture: 640×568px. Reference card region cropped to 683px wide, normalized to the same 608px card width as implementation. Three existing QA notes instead of the poster's four; text and colors are fixture content. No webpage/device chrome is part of this implementation.

Full comparison evaluates material layering, independent cards, foreground clarity, header and footer placement. Focused inspection of the title/caret, lower-right segmented picker and card gaps is readable in the 2× captures; no extra magnification is needed. The window-only screenshots flatten the area outside the native cards and do not reproduce the poster's desktop wallpaper; backdrop variation is supplied by macOS, not a baked-in gradient/image.

## Findings and iteration history

- Initial implementation: native behind-window blur with popover material, folded tint .38, expanded .56, editing .90. The user requested a more transparent background after testing.
- Revised implementation: lighter sidebar material for frosted; folded tint .24, expanded .38, editing .85. Clear tint .12/.22. Final evidence: lighter-folded.png, lighter-edit.png, lighter-preview.png and lighter-dark.png. The requested change is implemented; no additional P0/P1/P2 visual finding in these captures.
- Expected deviations: compact 12pt corner radius, 4pt card gaps, native typography and segmented control preserved as requested; poster-only thick white rim, simulated refraction, larger fonts and decorative wallpaper are intentionally omitted.

## Required fidelity surfaces

- Typography: native system 14pt semibold title, 13pt body; clear caret and text; long title truncates in folded mode. English Edit/Preview fits existing wider picker. Dark foreground remains light and legible.
- Spacing/layout: no outer titlebar, search/header or footer added. Existing compact cards, stable header positions, bottom-right editor mode and content-driven height retained. The captured 320pt state has no clipped control. 280/480pt endpoints were not captured interactively in this pass; unchanged layout/clamping is covered by existing dock geometry tests and source review.
- Colors/tokens: stable note color IDs preserved. Native light/dark material plus note tint; only background opacity changes. White rim is 0.5pt and subdued. Editing increases fill opacity to .85. Reduce Transparency forces opaque fill and removes native blur; Reduce Motion suppresses new transitions.
- Asset quality: no new raster assets required for native blur. Existing SF Symbols and system typography retained. Reference wallpaper is environmental context, not an app-owned image asset.
- Copy/content: new bilingual menu is Note appearance / 便签外观, Solid / 纯色, Frosted / 磨砂, Clear / 通透. Existing note content is unchanged. No design instructions appear in product UI.

## Interaction and regression evidence

- Native UI: folded state, click expansion, editing focus/caret, Markdown preview without opaque rectangle, all three menu options, checkmark for default Frosted, solid fallback, Chinese light and English dark inspected.
- Appearance choice persisted as frosted in isolated QA app preferences after switching/reopening.
- Native hover detector and exclusive expansion logic remain unchanged. User exercised initial glass build and requested only more transparency; final automatic hover timing still uses the existing verified controller.
- Complete suite: 159 tests, zero failures (tests-final.log). After transparency revision: all 19 HTMLAndSideNotesTests pass (tests-lighter.log), including accessibility fallback and editing contrast checks, hover protection, linked tasks, persistence and permanent deletion regression.
- No production note was created, edited or deleted for QA. Separate QA data root used.

## Implementation checklist

- [x] Native per-card glass with clear outer panel.
- [x] Local persisted appearance menu; frosted default.
- [x] More transparent tint per user feedback.
- [x] Clear text/editing and transparent Markdown preview.
- [x] Reduced-transparency and reduced-motion handling.
- [x] Native visual comparison and relevant tests.
- [x] Developer ID signature verified and Build 55 installed at /Applications/Zilo.app; installed native note appearance menu checked.
- [ ] Public notarized distribution: blocked by three S3 multipart upload failures, including proxy retry. No Gatekeeper acceptance or notarization success is claimed for final Build 55. Local signed DMG includes an explicit notarization-status note. Previous notarized Build 54 retained as backup.

Residual manual gaps: direct 280/480pt captures and changing the OS Reduce Transparency setting were not performed; fallback logic was unit-tested. Wallpaper-specific appearance varies with the actual desktop and is not claimed to match the concept poster pixel-for-pixel.

final result: passed
