# Navigation responsiveness QA — Mac Build 59

## Scope and implementation

Keep the existing Core Data/SQLite schema and local data. Cache navigation queries by task/filter revision; selection and sync-status changes do not invalidate the cache. Share a task-ID lookup, list counts, tags and sorted child index across rows. Keep at most eight sorted/search results; invalidate date-dependent results on a day/calendar change and overdue searches on a minute change. Preserve all prior filter, pinning, sorting, hierarchy and collapse semantics.

CloudKit remote-store/event notifications are coalesced for 150ms. Read and resolve one history snapshot on a private Core Data context, restore downloaded attachments there, and return only value records. Apply only changed collections; unchanged snapshots emit no Store publications. Check both request identity and the local data revision before publishing. A concurrent local edit discards the older snapshot and schedules a fresh read. Reminder scheduling is limited to changed records.

Markdown preview parsing/highlighting runs on a serial background queue. Cancel queued work and reject stale completions when switching or dismantling previews. Keep native editing immediate and retain preview scroll position during content updates. Synchronous exports and native rich text rendering retain their existing behavior.

## Evidence

- 173 Swift package tests passed, zero failures (`tests-final.log`). Coverage includes legacy filter equivalence, date/overdue cache expiry, task/filter invalidation, selection cache reuse, indexed hierarchy order/collapse/cycles, unchanged remote snapshots, stale local-edit protection, background latest-field/tombstone resolution, rapid preview changes/cancellation and existing editor/undo/persistence regressions.
- Calculation-only workload: 1,500 tasks × 11 smart-list filters × 10 passes, including cache construction, approximately 185.65ms before and 15.63ms after in the recorded run. Earlier run: 118.46ms / 11.10ms. These are synthetic filter-calculation timings, not total click-to-frame latency or a whole-app speed multiplier.
- Time Profiler captured native task/list/calendar interactions before and after (`baseline.trace`, `optimized.trace`). The small three-task fixture and automated interaction pacing are insufficient for a reliable end-to-end latency ratio; total sample counts must not be presented as such a comparison.
- Isolated native QA at `/Users/gaoluchuan/Library/Caches/Zilo-QA/20261106-performance59`: rich/Markdown task selection, empty Work list and Inbox switching, calendar/matrix return, parent collapse/expand, Command-Shift-M editing and preview. Appended a QA-only marker and verified it in rendered preview. Production content was not changed.
- Mac Debug build and universal Release archive succeeded. Shared persistence/model code also compiled successfully for iOS Simulator (`mobile-build.log`); no phone installation is required for this Mac navigation update. All three Mac bundle plists validate.

## Delivery

The user confirmed the test build feels more responsive and restored the Xcode account. Final Developer ID export and notarization succeeded (`export-installed.log`). The stapled Build 59 passed strict codesign verification, ticket validation and Gatekeeper (Notarized Developer ID), then replaced `/Applications/Zilo.app`; Build 58 is retained at `/Applications/Zilo.app.build58-before-performance59`. Native installed-app verification confirmed version 1.0 (59), restored production list/task selection and loaded the existing document preview. The production sidebar displayed a completed iCloud sync after launch. No production content was edited. The compressed `Zilo-1.0-59.dmg` passed image verification.
