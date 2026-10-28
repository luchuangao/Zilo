import XCTest
import AppKit
@testable import OwnList

final class HTMLAndSideNotesTests: XCTestCase {
    func testNotesGlassFallsBackToSolidAndProtectsEditingContrast() {
        XCTAssertEqual(SideNotesAppearance(stored: "unknown"),.frosted)
        for style in SideNotesAppearance.allCases {
            for expanded in [false,true] {
                for editing in [false,true] {
                    XCTAssertFalse(style.usesGlass(reduceTransparency: true))
                    XCTAssertEqual(style.tintOpacity(expanded: expanded,editing: editing,reduceTransparency: true),1)
                }
            }
            XCTAssertEqual(SideNotesAppearance.solid.tintOpacity(expanded: true,editing: false,reduceTransparency: false),1)
            guard style != .solid else { continue }
            let folded = style.tintOpacity(expanded: false,editing: false,reduceTransparency: false)
            let expanded = style.tintOpacity(expanded: true,editing: false,reduceTransparency: false)
            let editing = style.tintOpacity(expanded: true,editing: true,reduceTransparency: false)
            XCTAssertLessThan(folded,expanded)
            XCTAssertLessThan(expanded,editing)
            XCTAssertGreaterThanOrEqual(editing,0.85)
        }
        XCTAssertLessThan(SideNotesAppearance.clear.tintOpacity(expanded: true,editing: false,reduceTransparency: false),
                          SideNotesAppearance.frosted.tintOpacity(expanded: true,editing: false,reduceTransparency: false))
    }
    func testLinkedTaskDestinationResolvesContainerAndAncestorsWithoutChangingTasks() throws {
        let list = UUID(); var root = TaskItem(); root.listID = list
        var child = TaskItem(); child.parentID = root.id; child.listID = list; child.completed = true
        var grandchild = TaskItem(); grandchild.parentID = child.id; grandchild.listID = list
        let route = try XCTUnwrap(MacTaskDestination(id: grandchild.id,tasks: [root,child,grandchild]))
        XCTAssertEqual(route.selection,"list:" + list.uuidString)
        XCTAssertEqual(route.ancestors,[root.id,child.id]); XCTAssertEqual(route.rootID,root.id)
        root.completed = true
        XCTAssertEqual(MacTaskDestination(id: grandchild.id,tasks: [root,child,grandchild])?.selection,"completed")
        XCTAssertEqual(MacTaskDestination(id: grandchild.id,tasks: [root,child,grandchild])?.completedRoot,true)
        root.completed = false; root.archived = true
        XCTAssertEqual(MacTaskDestination(id: root.id,tasks: [root])?.selection,"archived")
        root.archived = false; root.abandoned = true
        XCTAssertEqual(MacTaskDestination(id: root.id,tasks: [root])?.selection,"abandoned")
        root.abandoned = false; root.isTemplate = true
        XCTAssertEqual(MacTaskDestination(id: root.id,tasks: [root])?.selection,"templates")
        root.deleted = true
        XCTAssertEqual(MacTaskDestination(id: root.id,tasks: [root])?.selection,"trash")
        XCTAssertNil(MacTaskDestination(id: UUID(),tasks: [root]))
        root.deleted = false; root.parentID = child.id
        XCTAssertNil(MacTaskDestination(id: child.id,tasks: [root,child]))
    }
    func testLongMindMapLabelsUseIdenticalLinesAndEnoughNodeHeight() throws {
        let labels = ["即时查询 (Instant Query)","范围查询 (Range Query)","指标名称可以放到大括号里作为筛选条件",String(repeating: "long_identifier_",count: 10),"第一行<br>第二行"]
        let diagram = try MindMapDocument.parse("mindmap\n  PromQL\n" + labels.map { "    " + $0 }.joined(separator: "\n"))
        for node in diagram.nodes {
            XCTAssertEqual(node.lines.joined(),node.title.replacingOccurrences(of: "\n",with: ""))
            XCTAssertGreaterThanOrEqual(node.rect.height,CGFloat(node.lines.count)*20+24)
            for line in node.lines { XCTAssertLessThanOrEqual((line as NSString).size(withAttributes: [.font:NSFont.systemFont(ofSize: 14)]).width,170) }
        }
        let svg = MindMapDocument.svg(diagram)
        XCTAssertTrue(svg.contains("<title>即时查询 (Instant Query)</title>"))
        XCTAssertFalse(svg.contains("foreignObject"))
        XCTAssertNotNil(MindMapDocument.png(diagram))
    }
    func testNotesDockShrinksWithContentAndStaysOnRightOfScreen() {
        let screen = NSRect(x: -1440,y: 20,width: 1440,height: 880)
        let small = SideNotesDockLayout.frame(screen: screen,contentHeight: 265)
        XCTAssertEqual(small.width,320); XCTAssertEqual(small.height,265); XCTAssertEqual(small.maxX,screen.maxX)
        let large = SideNotesDockLayout.frame(screen: screen,width: 400,contentHeight: 3000)
        XCTAssertLessThanOrEqual(large.height,screen.height-32); XCTAssertGreaterThanOrEqual(large.minY,screen.minY)
    }
    @MainActor func testHTMLPreservesDocumentStructureWithoutAppControlsOrScripts() throws {
        var task = TaskItem(); task.title = "标题 <script>alert(1)</script> & 中文"
        task.documentMode = .markdown
        task.notes = """
        ## 项目计划
        **加粗**与[链接](https://example.com)
        - [x] 已完成
        - [ ] 未完成

        | 项目 | 状态 |
        | --- | --- |
        | 发布 | 准备中 |

        ```swift
        print("你好 <世界>")
        ```

        ```mermaid
        mindmap
          项目
            发布
        ```

        <script>evil()</script>
        [恶意](javascript:alert(1))
        """
        task.checks = [CheckItem(title: "检查 <内容>",done: true)]
        let child = TaskItem(title: "子任务 & 验收",completed: true)
        let html = String(decoding: try HTMLDocument.data(task: task,children: [child]),as: UTF8.self)
        XCTAssertTrue(html.hasPrefix("<!doctype html>")); XCTAssertTrue(html.contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(html.contains("<table>")); XCTAssertTrue(html.contains("<strong>加粗</strong>"))
        XCTAssertTrue(html.contains("<svg")); XCTAssertTrue(html.contains("hljs-string")); XCTAssertTrue(html.contains("type=\"checkbox\" disabled checked"))
        XCTAssertTrue(html.contains("href=\"https://example.com\"")); XCTAssertTrue(html.contains("子任务 &amp; 验收"))
        XCTAssertTrue(html.contains("&lt;script&gt;")); XCTAssertFalse(html.contains("<script>")); XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertFalse(html.contains("zilo-copy:")); XCTAssertFalse(html.contains("zilo-language:")); XCTAssertFalse(html.contains("<script "))
        XCTAssertTrue(html.contains("default-src 'none'")); XCTAssertTrue(html.contains("base-uri 'none'"))
        if let folder = ProcessInfo.processInfo.environment["ZILO_HTML_QA"] { try FileManager.default.createDirectory(atPath: folder,withIntermediateDirectories: true); try Data(html.utf8).write(to: URL(fileURLWithPath: folder).appendingPathComponent("HTML导出验收.html")) }
    }
    @MainActor func testHTMLMarkdownManagedImageIsEmbeddedAndMissingImagesFailClearly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Attachments"),withIntermediateDirectories: true)
        let png = try imagePNG(); try png.write(to: root.appendingPathComponent("Attachments/example.png"))
        var task = TaskItem(); task.documentMode = .markdown; task.notes = "![截图](Attachments/example.png)"
        let html = String(decoding: try HTMLDocument.data(task: task,baseURL: root),as: UTF8.self)
        XCTAssertTrue(html.contains("data:image/png;base64," + png.base64EncodedString())); XCTAssertFalse(html.contains("zilo-image:")); XCTAssertFalse(html.contains("file://"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Attachments/example.png"))
        XCTAssertThrowsError(try HTMLDocument.data(task: task,baseURL: root))
    }
    @MainActor func testHTMLRichTextRetainsCodeTablesMindmapAndEmbeddedImage() throws {
        var task = TaskItem(); task.title = "富文本导出"; task.documentMode = .markdown
        task.notes = "## 标题\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```python\nprint(1)\n```\n\n```mermaid\nmindmap\n  主题\n    子项\n```"
        TaskDocument.switchMode(&task,to: .richText)
        let rich = NSMutableAttributedString(attributedString: try XCTUnwrap(task.richText.flatMap(RichDocument.decode)))
        rich.append(try RichDocument.image(imagePNG())); task.richText = RichDocument.encode(rich)
        let html = String(decoding: try HTMLDocument.data(task: task),as: UTF8.self)
        XCTAssertTrue(html.contains("<table>"),"table"); XCTAssertTrue(html.contains("<svg"),"mindmap"); XCTAssertTrue(html.contains("hljs-number"),"highlight"); XCTAssertTrue(html.contains("data:image/png;base64,"),"image")
        if let folder = ProcessInfo.processInfo.environment["ZILO_HTML_QA"] { try Data(html.utf8).write(to: URL(fileURLWithPath: folder).appendingPathComponent("富文本HTML.html")) }
    }
    func testHTMLFilenameCannotEscapeChosenDirectory() {
        XCTAssertEqual(HTMLDocument.filename("a/b:c\\d\n"),"a-b-c-d-.html")
        XCTAssertFalse(HTMLDocument.filename("/../../你好").contains("/"))
    }
    @MainActor func testIndependentAndLinkedNotesPersistWithoutDuplicatingOrDeletingTasks() throws {
        let persistence = Persistence(inMemory: true); let store = Store(persistence: persistence)
        let standalone = try XCTUnwrap(store.createSideNote(text: "独立便签"))
        XCTAssertTrue(store.tasks.isEmpty)
        var task = TaskItem(); task.title = "原任务"; task.notes = "正文"; task.documentMode = .markdown
        task.priority = 3; task.checks = [CheckItem(title: "保持")]; XCTAssertTrue(store.save(task))
        let linked = try XCTUnwrap(store.linkSideNote(taskID: task.id))
        XCTAssertEqual(store.linkSideNote(taskID: task.id),linked)
        store.updateSideNoteDocument(linked,title: "通过便签改名",text: "通过便签编辑")
        let updated = try XCTUnwrap(store.tasks.first)
        XCTAssertEqual(updated.title,"通过便签改名"); XCTAssertEqual(updated.notes,"通过便签编辑")
        XCTAssertEqual(updated.priority,3); XCTAssertEqual(updated.checks,task.checks)
        store.mutate(task.id) { $0.notes = "从任务修改" }
        XCTAssertEqual(store.sideNotes.first { $0.id == linked }?.document(tasks: store.tasks)?.notes,"从任务修改")
        store.updateSideNote(linked) { $0.deleted = true }
        XCTAssertFalse(try XCTUnwrap(store.tasks.first).deleted)
        store.updateSideNote(linked) { $0.deleted = false }
        store.reload()
        XCTAssertEqual(try persistence.load(SideNote.self).count,2)
        XCTAssertEqual(store.sideNotes.first { $0.id == standalone }?.text,"独立便签")
    }
    @MainActor func testPermanentNoteDeletionRemovesContentAndHistoryWithoutDeletingLinkedTask() throws {
        let persistence = Persistence(inMemory: true); let store = Store(persistence: persistence)
        var task = TaskItem(); task.title = "Keep task"; task.notes = "Keep task body"; XCTAssertTrue(store.save(task))
        let linked = try XCTUnwrap(store.linkSideNote(taskID: task.id))
        XCTAssertFalse(store.permanentlyDeleteSideNote(linked),"Active notes must go to trash first")
        store.updateSideNote(linked) { $0.deleted = true }
        let stale = try XCTUnwrap(store.sideNotes.first { $0.id == linked })
        XCTAssertTrue(store.permanentlyDeleteSideNote(linked))
        store.reload()
        XCTAssertFalse(store.sideNotes.contains { $0.id == linked })
        XCTAssertEqual(store.tasks.first { $0.id == task.id },task)
        XCTAssertThrowsError(try persistence.save(stale),"Offline/stale edits cannot restore purged notes")
        let id = try XCTUnwrap(store.createSideNote(text: "private body"))
        store.updateSideNote(id) { $0.title = "private title"; $0.deleted = true }
        XCTAssertTrue(store.permanentlyDeleteSideNote(id))
        let history = try persistence.versions().filter { $0.owner == id }
        XCTAssertFalse(history.contains { $0.json.contains("private") })
        XCTAssertTrue(history.contains { $0.field == "permanentlyDeleted" && $0.json == "true" })
        XCTAssertFalse(try persistence.load(SideNote.self).contains { $0.id == id })
        XCTAssertFalse(store.permanentlyDeleteSideNote(id))
    }
    @MainActor func testNoteFoldersSearchPinningAndDeletionKeepNotesRecoverable() throws {
        let store = Store(persistence: Persistence(inMemory: true))
        let folder = try XCTUnwrap(store.createNoteFolder(" 工作 "))
        XCTAssertEqual(store.createNoteFolder("工作"),folder)
        let first = try XCTUnwrap(store.createSideNote(folderID: folder,text: "搜索正文"))
        let second = try XCTUnwrap(store.createSideNote(folderID: folder,text: "另外一条"))
        store.updateSideNote(first) { $0.pinned = true; $0.folded = true; $0.color = "purple" }
        XCTAssertEqual(SideNotesLibrary.visible(store.sideNotes,tasks: [],folderID: folder).map(\.id),[first,second])
        XCTAssertEqual(SideNotesLibrary.visible(store.sideNotes,tasks: [],search: "搜索").map(\.id),[first])
        store.updateSideNote(second) { $0.deleted = true }
        XCTAssertTrue(store.deleteNoteFolder(folder))
        XCTAssertTrue(store.sideNotes.allSatisfy { $0.folderID == nil })
        XCTAssertEqual(SideNotesLibrary.visible(store.sideNotes,tasks: [],trash: true).map(\.id),[second])
        store.updateSideNote(second) { $0.deleted = false }
        XCTAssertEqual(SideNotesLibrary.visible(store.sideNotes,tasks: []).count,2)
    }
    @MainActor func testNoteBackupRoundTripAndLegacyRestoreNeverEraseNewNotes() throws {
        let store = Store(persistence: Persistence(inMemory: true))
        let folder = try XCTUnwrap(store.createNoteFolder("灵感")); let id = try XCTUnwrap(store.createSideNote(folderID: folder,text: "保留正文"))
        let backup = try JSONDecoder().decode(Backup.self,from: JSONEncoder().encode(store.backup))
        XCTAssertEqual(backup.sideNotes?.first?.id,id); XCTAssertEqual(backup.noteFolders?.first?.id,folder)
        let restored = Store(persistence: Persistence(inMemory: true)); restored.apply(backup)
        XCTAssertEqual(restored.sideNotes,store.sideNotes); XCTAssertEqual(restored.noteFolders,store.noteFolders)
        let legacy = Backup(tasks: [],lists: [],filters: [],habits: [],focus: [],subscriptions: [])
        restored.apply(legacy); XCTAssertEqual(restored.sideNotes.count,1)
        var full = legacy; full.sideNotes = []; full.noteFolders = []
        restored.apply(full); XCTAssertTrue(restored.sideNotes.allSatisfy(\.deleted))
    }
    @MainActor func testPaperColorsPreserveStoredKeysAndRoundTripThroughBackup() throws {
        let store = Store(persistence: Persistence(inMemory: true))
        for key in ["none","yellow","blue","green","purple","pink","orange","teal"] {
            let id = try XCTUnwrap(store.createSideNote(text: "颜色 " + key))
            store.updateSideNote(id) { $0.color = key }
        }
        let restored = Store(persistence: Persistence(inMemory: true))
        restored.apply(try JSONDecoder().decode(Backup.self,from: JSONEncoder().encode(store.backup)))
        XCTAssertEqual(Set(restored.sideNotes.map(\.color)),Set(SideNotesLibrary.colors))
        XCTAssertEqual(SideNotePaper(stored: "future-color"),.none)
    }
    func testPaperBackgroundsHaveReadableTextInBothAppearances() {
        func luminance(_ hex: UInt32) -> Double {
            func linear(_ value: UInt32) -> Double { let v = Double(value)/255; return v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
            return 0.2126*linear((hex >> 16)&255) + 0.7152*linear((hex >> 8)&255) + 0.0722*linear(hex&255)
        }
        for paper in SideNotePaper.allCases {
            for dark in [false,true] {
                let background = luminance(paper.hex(dark: dark)),text = luminance(dark ? 0xECEEF4 : 0x242730)
                XCTAssertGreaterThanOrEqual((max(background,text)+0.05)/(min(background,text)+0.05),4.5,paper.rawValue)
            }
        }
    }
    func testRapidFoldReversalUsesIntendedHeightAndIgnoresStaleCompletion() {
        var resize = SideNotesFoldResize()
        let opening = resize.begin(height: 300,delta: 80)
        XCTAssertEqual(resize.target,380)
        let closing = resize.begin(height: 326,delta: -80)
        XCTAssertEqual(resize.target,300)
        XCTAssertFalse(resize.finish(opening)); XCTAssertEqual(resize.target,300)
        XCTAssertTrue(resize.finish(closing)); XCTAssertNil(resize.target)
    }
    func testHidingDrawerInvalidatesAnInFlightFoldCompletion() {
        var resize = SideNotesFoldResize()
        let old = resize.begin(height: 300,delta: 100)
        resize.cancel(); XCTAssertFalse(resize.finish(old)); XCTAssertNil(resize.target)
        _ = resize.begin(height: 250,delta: 60); XCTAssertEqual(resize.target,310)
    }
    @MainActor func testEdgeHoverDebouncesAndCancelsAfterPointerLeaves() async throws {
        let hover = SideNotesHoverBehavior(openDelay: 10_000_000,closeDelay: 10_000_000)
        var inside = true; var shows = 0
        hover.containsPointer = { inside }; hover.onShow = { shows += 1 }
        hover.enterEdge(); inside = false; hover.leave()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(shows,0)
        inside = true; hover.enterEdge()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(shows,1); hover.cancel()
    }
    @MainActor func testPointerTransferToPanelCancelsPendingAutoHide() async throws {
        let hover = SideNotesHoverBehavior(openDelay: 10_000_000,closeDelay: 10_000_000)
        var inside = false; var hides = 0
        hover.containsPointer = { inside }; hover.onHide = { hides += 1 }
        hover.leave(); inside = true; hover.enterPanel()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(hides,0)
        inside = false; hover.leave()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(hides,1)
    }
    @MainActor func testAutoHideWaitsForEditingAndMenusToFinish() async throws {
        let hover = SideNotesHoverBehavior(openDelay: 10_000_000,closeDelay: 10_000_000)
        var editing = true; var menu = false; var hides = 0
        hover.containsPointer = { false }; hover.canHide = { !editing && !menu }; hover.onHide = { hides += 1 }
        hover.leave(); try await Task.sleep(nanoseconds: 60_000_000); XCTAssertEqual(hides,0)
        editing = false; menu = true
        hover.leave(); try await Task.sleep(nanoseconds: 60_000_000); XCTAssertEqual(hides,0)
        menu = false
        try await Task.sleep(nanoseconds: 220_000_000); XCTAssertEqual(hides,1)
        hover.cancel()
    }
    private func imagePNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 4,height: 4)); image.lockFocus(); NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(x: 0,y: 0,width: 4,height: 4)).fill(); image.unlockFocus()
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png,properties: [:]))
    }
}
