# Mac side-note appearance QA — Build 56

## Final scope

Keep only Solid / 纯色 and Clear / 通透. Frosted was removed at the user's explicit request; existing `frosted` preferences and unknown values resolve to Solid. Clear deliberately shows background content, matching the user's final direction. No note data or mobile palette migration.

## Visual evidence

Source: `.release/20261028-notes-transparency56/reference-muted.png` (reported gray appearance), `reference-color.png` (desired existing paper palette).
Implementation: `clear-delivery.png`, `menu-final.png` in the same directory. Combined source/implementation board: `comparison-delivery.png`, opened and compared.

All captures are native macOS windows at 2×. Sources are approximately 640px / 320pt wide; implementation is 640×568px / 320×284pt. No density scaling is needed. The source contains four folded production notes; isolated QA has three different notes and one expanded editor. Content/card count differences are expected; the comparison targets color quality and preserved card styling rather than matching content height. The yellow paper surface provides a shared palette reference. Full board and the 2× title/menu/footer regions were inspected.

## Findings and fixes

- Reported defect: full-strength system material with a very faint colored overlay produced gray, muted paper colors. Fixed by removing native material entirely from Clear and compensating the translucent overlay color for its alpha. Foreground opacity is unchanged.
- First corrected Clear version used genuine alpha transparency. User confirmed it was transparent, briefly requested background text hidden, then explicitly clarified that Clear may show text and finally removed Frosted. Final implementation follows the final request; no blur remains in Clear.
- Menu shows exactly Solid and Clear. Native screenshot confirms legacy Frosted selects Solid. Existing paper hues and stable stored color IDs are retained.
- No actionable P0/P1/P2 differences in the final inspected state.

## Fidelity surfaces

- Typography: existing system 14pt semibold title and 13pt editor, clear caret, single-line title truncation. No global opacity on text or controls.
- Layout: existing 12pt corners, 4pt gaps, compact header/footer preserved; no extra toolbar, titlebar or search. Editing/Preview stays lower-right. No clipped control in captured 320pt state.
- Colors: Solid uses exact existing opaque palette. Clear uses 50% folded / 58% expanded / 82% editing colored background; neutral-composition correction retains the paper hue. Background affects the final composite naturally. Reduce Transparency returns to opaque paper. Reduce Motion suppresses transitions.
- Assets: no new raster asset or custom icon. Existing native symbols and controls retained. System material background removed, so it cannot desaturate Clear.
- Copy: bilingual Solid/Clear labels retained; unused Frosted strings removed. No prompt or implementation terms added to UI.

## Validation

- Debug build and universal Release archive succeeded.
- 160 tests passed with zero failures (`tests-delivery.log`), including two-option menu model, legacy preference fallback, accessibility fallback, opacity order, palette composition in light/dark and existing note persistence/hover/link/deletion regression.
- Native UI: menu options and legacy selection checked; Clear selected; stable expanded editing state captured. A genuine-alpha Clear test was manually confirmed transparent by the user before the final removal of Frosted; that Clear renderer is retained.
- No production content was edited for QA. Separate QA data root used.
- Remaining manual gaps: final dark capture and 280/480pt native resizing were not repeated; geometry is unchanged and light/dark palette composition is tested. Desktop-specific appearance naturally varies.
- Developer ID signing, Apple notarization, notarization-ticket validation and Gatekeeper assessment passed for the final app. Build 56 was installed and its native menu was verified to contain only Solid and Clear. DMG checksum validation passed. Release evidence is in `.release/20261028-notes-transparency56` and `.release/20261028-mac56-delivery`.

final result: passed
