import XCTest
import AppKit
@testable import OwnList

final class HTMLAndSideNotesTests: XCTestCase {
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
    private func imagePNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 4,height: 4)); image.lockFocus(); NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(x: 0,y: 0,width: 4,height: 4)).fill(); image.unlockFocus()
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png,properties: [:]))
    }
}
