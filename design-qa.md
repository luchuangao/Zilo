# Mac task preview and double-click editing QA — Build 57

## Requested behavior

Task text opens in Preview by default. Double-clicking the body switches to Edit and places keyboard focus in the native editor. Existing Edit/Preview and Markdown split-preview controls remain available. The same TaskDetailView default is used by the main sidebar, task windows and calendar detail sheets.

## Implementation

- Default preview for Markdown and rich text, including standalone task windows. Rich-text preview uses a selectable read-only native text view rather than converting the stored document.
- Double-clicks in the Markdown web preview use a trusted, main-frame gesture message; native rich text uses the text-view double-click callback. Neither path rewrites document content.
- Ordinary web/mail links distinguish single click from double click using the system double-click interval. A double click cancels pending navigation and begins editing. A single click follows the link. Keyboard activation and modified clicks retain normal navigation. Code copy/language controls keep their own behavior.
- The native editor stays mounted during Markdown preview, retaining selection, undo and input-method state. Editing requests are checked against the selected task before focusing.
- Preview gesture handlers and delayed link actions are cleaned up when their view is dismantled. Formatting and mind-map commands can explicitly enter editing.

## Evidence

User reference: `.release/20261028-preview-edit57/reference-task-preview.png` (task preview with links).
Native captures in the same directory: `markdown-preview.png`, `markdown-edit.png`, `rich-edit.png`, `window-preview.png`. These are window captures at 2× density. Content is isolated QA fixture data, not the user's production tasks. The task is named PromQL in QA but contains simple link paragraphs for the requested interaction test.

Functional UI verification:

1. Selected a Markdown task: Preview selected, source editor hidden.
2. Double-clicked the rendered first link at its observed screen coordinates: Edit selected, native task body focused; no browser activation interrupted editing.
3. Entered ASCII text and pasted Chinese content directly after the double click. Content persisted across task changes and rendered after returning to Preview. CUA's non-ASCII keystroke simulation was unreliable, so Chinese input was verified by paste instead of claiming a keyboard-composition test.
4. Selected a rich-text task: Preview selected and native body read-only. Double-clicked its body: Edit selected and editable body focused.
5. Switched back to the Markdown task: Preview restored, previously saved content retained.
6. Opened the task in a standalone window: Preview selected initially. Split Preview could still be selected and displayed source plus rendered content. Returned to Preview normally.
7. Installed the notarized app: existing restored production task opened with Preview selected. No production content was edited for QA.

## Validation and limits

163 tests passed with zero failures (`tests-verified.log`), including document/selection preservation on edit focus, injected gesture handling for text/links/interactive controls/keyboard actions, delayed single-link navigation and double-click cancellation. Existing document conversion, IME, formatting, persistence and side-note regression suites passed.

Debug and universal Release archive succeeded. Developer ID signing, Apple notarization, ticket validation and Gatekeeper assessment passed. Build 57 installed at `/Applications/Zilo.app`; previous Build 56 preserved. DMG checksum validation recorded in release logs.

The calendar sheet uses the same default TaskDetailView implementation but was not opened separately in this UI pass. Existing typography, spacing, colors, icons and content layout were preserved; this change alters presentation state and gestures, not the visual design. Mobile behavior was not changed by this Mac request.

final result: passed
