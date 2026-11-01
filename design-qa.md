# Mac document shortcuts QA — Build 58

## Scope

Add task-document shortcuts and show the actual bindings in Settings → Keyboard shortcuts. The new Documents menu and Settings use the same DocumentShortcut catalog: Command-B/I/K, Command-1…6, Command-F/G/Shift-G, and Command-Shift-M. Existing native text editing and Markdown list operations are documented alongside them. Global quick-add recording is preserved.

Command-F previously belonged to MainView task search. Task search now uses Command-Shift-F so document find can use Command-F. Existing New list (Command-Shift-L) and desktop note (Command-Option-N) remain listed accurately. Formatting shortcuts avoid mutating the body when another text field or a modal editor is active. Actions are scoped to the current task window.

## Functional and visual checks

166 tests passed with zero failures (`tests-delivery.log`). New cases cover unique key bindings, heading levels, existing heading replacement, Unicode cursor positions, indentation/multi-line/empty selections, invalid levels, and independent bold/italic combination/toggling. A backing-string mutation issue found during testing was fixed by computing selection offsets before native insertion.

Native isolated QA verified:
- Command-Shift-M from Preview enters Edit and focuses the native body.
- Command-B inserts bold Markdown; Command-I can combine with bold (`***shortcut58***`).
- Command-1 and Command-6 replace heading markers rather than stacking them.
- Command-K opens the existing link dialog with selected text and focuses the URL field; Escape cancels normally.
- Command-F from Preview opens the native document find bar and source editor. Query input highlights matches. Command-G and Command-Shift-G navigate matches.
- Command-Shift-F opens task search, without taking over Command-F.
- Standalone task windows can toggle editing and open the document find bar independently.
- Settings lists app keys, all document commands, native text operations, and Markdown list actions. Scrolling exposes every row. Chinese/light and English/dark captures were inspected; no new label or key clipping was observed.

Evidence: `.release/20261031-document-shortcuts58/find.png`, `settings-zh.png`, `settings-document-zh.png`, `settings-en-dark.png`. Settings captures are 1560px wide at 2×, corresponding to the existing 780pt settings window. Native main-window capture is 2560px wide at 2×. No visual redesign was requested; existing card, type and color styles are retained. All content changes used the separate `/Users/gaoluchuan/Library/Caches/Zilo-QA/20261031-shortcuts58` fixture root.

## Delivery status

Debug build and universal Release archive succeeded. Both localization files pass plutil validation. On 2026-11-01, Xcode account access recovered: final Developer ID export and notarization succeeded (`export-final.log`). The stapled Build 58 passed strict codesign verification, ticket validation and Gatekeeper (Notarized Developer ID), then replaced `/Applications/Zilo.app`; Build 57 is retained as `/Applications/Zilo.app.build57-before-shortcuts58`. Native installed-app verification confirmed version 1.0 (58), restored production task/list state and Settings → Keyboard shortcuts with the complete bindings. The compressed `Zilo-1.0-58.dmg` also passed image verification. Production content was not edited during installation verification.

final result: passed
