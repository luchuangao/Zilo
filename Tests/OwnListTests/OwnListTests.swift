import XCTest
import AppKit
import PDFKit
import WebKit
@testable import OwnList

final class OwnListTests: XCTestCase {
    @MainActor func testDeletedListRestoresContentsAndSupportsUndoRedo() throws {
        let store = Store(persistence: Persistence(inMemory: true))
        let list = try store.commitList(existing: nil,name: "项目",folder: "工作",color: "green",sections: "计划,完成",defaultView: "看板")
        let id = try XCTUnwrap(store.add("说明",listID: list.id))
        store.mutate(id) { $0.notes = "正文"; $0.completed = true; $0.tags = ["重要"]; $0.checks = [CheckItem(title: "检查")]; $0.documentMode = .markdown; $0.attachments = [Attachment(name: "图",relativePath: "Attachments/image.png")] }
        let child = try XCTUnwrap(store.add("子任务",listID: list.id,parentID: id))
        let original = store.tasks.first { $0.id == id }!
        XCTAssertTrue(store.deleteList(list.id))
        store.reload()
        XCTAssertEqual(store.trashEntryCount,1,"整份清单算一项，不重复计算随清单删除的任务")
        XCTAssertTrue(store.lists.first { $0.id == list.id }!.deleted)
        for task in store.tasks { XCTAssertTrue(task.deleted); XCTAssertEqual(task.listID,list.id); XCTAssertEqual(task.trashedWithList,list.id) }
        store.undo(); XCTAssertFalse(store.lists.first { $0.id == list.id }!.deleted)
        XCTAssertEqual(store.tasks.first { $0.id == id },original)
        store.redo(); XCTAssertTrue(store.lists.first { $0.id == list.id }!.deleted)
        XCTAssertTrue(store.restoreList(list.id)); store.reload()
        XCTAssertEqual(store.tasks.first { $0.id == id },original)
        XCTAssertFalse(store.tasks.first { $0.id == child }!.deleted)
        XCTAssertEqual(store.lists.first { $0.id == list.id },list)
        store.undo(); XCTAssertTrue(store.lists.first { $0.id == list.id }!.deleted)
        store.redo(); XCTAssertFalse(store.lists.first { $0.id == list.id }!.deleted)
    }
    @MainActor func testRestoringListDoesNotRevivePreviouslyDeletedTasks() throws {
        let store = Store(persistence: Persistence(inMemory: true))
        let list = TaskList(name: "测试"); store.save(list)
        let parent = try XCTUnwrap(store.add("父任务",listID: list.id))
        let child = try XCTUnwrap(store.add("已单独删除",listID: list.id,parentID: parent))
        store.mutate(child) { $0.deleted = true }
        let other = try XCTUnwrap(store.add("跨清单子任务",parentID: parent))
        XCTAssertTrue(store.deleteList(list.id)); XCTAssertEqual(store.trashEntryCount,2); XCTAssertTrue(store.restoreList(list.id))
        XCTAssertTrue(store.tasks.first { $0.id == child }!.deleted)
        XCTAssertFalse(store.tasks.first { $0.id == other }!.deleted)
        XCTAssertNil(store.tasks.first { $0.id == other }!.listID)
        // A task restored from a deleted list must have a visible active container.
        XCTAssertTrue(store.deleteList(list.id)); store.restoreTask(parent)
        XCTAssertFalse(store.lists.first { $0.id == list.id }!.deleted)
        XCTAssertFalse(store.tasks.first { $0.id == parent }!.deleted)
    }
    @MainActor func testLegacyDeletedListAndNameConflictRemainRecoverable() {
        let store = Store(persistence: Persistence(inMemory: true))
        var old = TaskList(name: "工作",folder: "项目"); old.deleted = true; store.save(old)
        store.save(TaskList(name: "工作",folder: "项目"))
        store.save(TaskList(name: "工作（恢复）",folder: "项目"))
        XCTAssertTrue(store.restoreList(old.id)); store.reload()
        XCTAssertEqual(store.lists.first { $0.id == old.id }?.name,"工作（恢复 2）")
        XCTAssertEqual(store.lists.first { $0.id == old.id }?.folder,"项目")
    }
    @MainActor func testListTransactionRollsBackBothListAndTasks() throws {
        let persistence = Persistence(inMemory: true)
        var list = TaskList(name: "原清单"); try persistence.save(list)
        var task = TaskItem(); task.listID = list.id; try persistence.save(task)
        enum Failure: Error { case simulated }
        XCTAssertThrowsError(try persistence.transaction {
            list.deleted = true; try persistence.save(list)
            task.deleted = true; task.trashedWithList = list.id; try persistence.save(task)
            throw Failure.simulated
        })
        XCTAssertFalse(try persistence.load(TaskList.self).first!.deleted)
        XCTAssertFalse(try persistence.load(TaskItem.self).first!.deleted)
        // The cache must also be rolled back; a subsequent identical change persists.
        try persistence.save(list)
        XCTAssertTrue(try persistence.load(TaskList.self).first!.deleted)
    }
    @MainActor func testDefaultDocumentModeIsCapturedOnlyForNewTasks() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "defaultDocumentMode")
        defer { if let previous { defaults.set(previous,forKey: "defaultDocumentMode") } else { defaults.removeObject(forKey: "defaultDocumentMode") } }
        let store = Store(persistence: Persistence(inMemory: true))
        defaults.set("markdown",forKey: "defaultDocumentMode")
        let markdown = try XCTUnwrap(store.add("Markdown 任务"))
        defaults.set("richText",forKey: "defaultDocumentMode")
        let rich = try XCTUnwrap(store.add("富文本任务"))
        store.reload()
        XCTAssertEqual(store.tasks.first { $0.id == markdown }?.editingMode,.markdown)
        XCTAssertEqual(store.tasks.first { $0.id == rich }?.editingMode,.richText)
        defaults.set("invalid",forKey: "defaultDocumentMode")
        XCTAssertEqual(DocumentEditingMode.defaultMode(),.richText)
        XCTAssertEqual(TaskItem().editingMode,.richText,"旧任务不能随全局设置改变正文解析方式")
    }

    @MainActor func testFittedLayoutIncludesTrailingEmptyLineAndReportsOnlyChanges() throws {
        let view = DocumentScrollView(frame: NSRect(x: 0,y: 0,width: 400,height: 200))
        let editor = DocumentTextView(frame: view.bounds)
        editor.isVerticallyResizable = true; editor.textContainerInset = NSSize(width: 0,height: 3)
        editor.textContainer?.lineFragmentPadding = 0; view.documentView = editor
        editor.textStorage?.setAttributedString(NSAttributedString(string: "第一行",attributes: MarkdownTyping.bodyAttributes))
        var heights: [CGFloat] = []; view.onHeight = { heights.append($0) }
        view.layout(); let oneLine = try XCTUnwrap(heights.last)
        for _ in 0..<5 { view.layout() }
        XCTAssertEqual(heights.count,1,"相同布局不能反复向 SwiftUI 报告高度")
        editor.insertText("\n",replacementRange: NSRange(location: editor.string.utf16.count,length: 0))
        view.layout(); let twoLines = try XCTUnwrap(heights.last)
        XCTAssertGreaterThan(twoLines,oneLine + 10,"最后一个空行也要留出光标空间")
        for _ in 0..<5 { view.layout() }
        XCTAssertEqual(heights.count,2)
    }

    @MainActor func testFixedDocumentViewportDoesNotResizeAfterReturns() {
        let view = DocumentScrollView(frame: NSRect(x: 0,y: 0,width: 340,height: 180))
        view.fitsContent = false
        let editor = DocumentTextView(frame: view.bounds)
        editor.isVerticallyResizable = true; editor.isRichText = false
        editor.textContainerInset = NSSize(width: 0,height: 3); view.documentView = editor
        editor.typingAttributes = MarkdownTyping.bodyAttributes
        var reports = 0; view.onHeight = { _ in reports += 1 }
        let viewport = view.frame
        for _ in 0..<60 {
            editor.insertText("中文🙂\n",replacementRange: NSRange(location: editor.string.utf16.count,length: 0))
            view.layout()
            XCTAssertEqual(view.frame,viewport)
            XCTAssertGreaterThanOrEqual(editor.frame.height,view.contentSize.height)
        }
        XCTAssertEqual(reports,0,"连续回车不能再改变外层正文高度")
        XCTAssertGreaterThan(editor.frame.height,view.frame.height)
    }

    @MainActor func testMarkdownModePreservesExactSourceAndExport() throws {
        let source = "# 中文🙂\n\n- 项目\n\n```swift\n\tlet value = \"**原样**\"\n\n```\n\n尚未完成 **"
        var task = TaskItem(); task.title = "源码"; task.documentMode = .markdown; task.notes = source
        let editor = DocumentTextView()
        var saved: (String,Data?)?
        let parent = DetailDocumentEditor(text: source,data: nil,rich: false,scrolling: true,controller: DocumentEditorController(),height: .constant(200)) { text,data in saved = (text,data) }
        parent.populate(editor); let coordinator = DetailDocumentEditor.Coordinator(parent: parent); coordinator.attach(editor)
        editor.insertText("\n",replacementRange: NSRange(location: source.utf16.count,length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification,object: editor))
        XCTAssertEqual(saved?.0,source + "\n"); XCTAssertNil(saved?.1)
        XCTAssertFalse(coordinator.textView(editor,doCommandBy: #selector(NSResponder.insertNewline(_:))))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("source.md")
        try DocumentExport.write(task: task,children: [],format: .markdown,to: output)
        XCTAssertEqual(try String(contentsOf: output,encoding: .utf8),"# 源码\n\n" + source)
        editor.delegate = nil
    }

    @MainActor func testModeSwitchPreservesCodeAndEmbeddedImage() throws {
        let body = NSMutableAttributedString(attributedString: MarkdownDocument.parse("# 标题\n\n**加粗**\n```\n\tlet x = \"中文🙂\"\n```\n").content)
        body.append(try RichDocument.image(documentImage()))
        var task = TaskItem(); task.notes = body.string; task.richText = RichDocument.encode(body)
        TaskDocument.switchMode(&task,to: .markdown)
        XCTAssertEqual(task.editingMode,.markdown); XCTAssertNil(task.richText)
        XCTAssertTrue(task.notes.contains("# 标题")); XCTAssertTrue(task.notes.contains("**加粗**"))
        XCTAssertTrue(task.notes.contains("\tlet x = \"中文🙂\"")); XCTAssertTrue(task.notes.contains("data:image/png;base64,"))
        let source = task.notes; TaskDocument.switchMode(&task,to: .markdown); XCTAssertEqual(task.notes,source)
        TaskDocument.switchMode(&task,to: .richText)
        let restored = try XCTUnwrap(task.richText.flatMap(RichDocument.decode))
        XCTAssertTrue(restored.string.contains("标题")); XCTAssertTrue(restored.string.contains("\tlet x = \"中文🙂\""))
        XCTAssertTrue(RichDocument.hasImages(restored))
    }

    @MainActor func testDocumentModePersistenceAndLegacyBackup() throws {
        let persistence = Persistence(inMemory: true); defer { try? FileManager.default.removeItem(at: persistence.root) }
        var task = TaskItem(); task.documentMode = .markdown; task.notes = "# 原始源码\n\n```\ncode\n```"
        try persistence.save(task)
        let loaded = try XCTUnwrap(persistence.load(TaskItem.self).first)
        XCTAssertEqual(loaded.editingMode,.markdown); XCTAssertEqual(loaded.notes,task.notes)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        json.removeValue(forKey: "documentMode")
        let legacy = try JSONDecoder().decode(TaskItem.self,from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.editingMode,.richText)
    }

    @MainActor func testMarkdownFileAndImageInsertionKeepSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let source = "# 文件标题\n\n```swift\n\tlet x = 1\n```\n"
        let file = folder.appendingPathComponent("input.md"); try source.write(to: file,atomically: true,encoding: .utf8)
        let editor = DocumentTextView(); editor.isRichText = false
        let controller = DocumentEditorController(); controller.editor = editor; controller.rich = false
        XCTAssertTrue(try controller.insertMarkdown([file]).isEmpty)
        XCTAssertEqual(editor.string,source)
        let store = Store(persistence: Persistence(inMemory: true)); defer { try? FileManager.default.removeItem(at: store.persistence.root) }
        editor.imageReference = { try store.writeDocumentImage($0,name: $1) }
        try editor.insertImage(documentImage())
        XCTAssertTrue(editor.string.hasPrefix(source)); XCTAssertTrue(editor.string.contains("Attachments/Images/"))
        XCTAssertFalse(editor.string.contains("base64")); XCTAssertLessThan(editor.string.count,source.count + 100)
        XCTAssertTrue(RichDocument.hasImages(MarkdownDocument.parse(editor.string,baseURL: store.persistence.root).content))
    }


    @MainActor func testDocumentImageLayoutCapsDisplayWithoutChangingOriginal() throws {
        let image = NSImage(size: NSSize(width: 1600,height: 1200)); image.lockFocus(); NSColor.systemBlue.setFill(); NSBezierPath(rect: NSRect(origin: .zero,size: image.size)).fill(); image.unlockFocus()
        let bytes = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png,properties: [:]))
        let content = try RichDocument.image(bytes)
        let attachment = try XCTUnwrap(content.attribute(.attachment,at: 0,effectiveRange: nil) as? NSTextAttachment)
        let original = attachment.fileWrapper?.regularFileContents
        let view = DocumentScrollView(frame: NSRect(x: 0,y: 0,width: 900,height: 500)); view.fitsContent = false
        let editor = DocumentTextView(frame: view.bounds); editor.isRichText = true; editor.textStorage?.setAttributedString(content); view.documentView = editor
        view.layout()
        XCTAssertLessThanOrEqual(attachment.attachmentCell!.cellSize().width,520)
        XCTAssertLessThanOrEqual(attachment.attachmentCell!.cellSize().height,360)
        XCTAssertEqual(attachment.fileWrapper?.regularFileContents,original)
        view.setFrameSize(NSSize(width: 260,height: 500)); view.layout()
        XCTAssertLessThanOrEqual(attachment.attachmentCell!.cellSize().width,252)
    }
    func testTaskSummaryDoesNotExposeImageEncodingOrEmptyAttachmentLines() {
        var task = TaskItem(); task.notes = "\u{fffc}\n\n图片后文\n"; XCTAssertEqual(TaskDocument.summary(task),"图片后文")
        task.notes = "![图片](data:image/png;base64,abc)\n尾部"; XCTAssertEqual(TaskDocument.summary(task),"[图片] 尾部")
        task.notes = "\u{fffc}\n  "; XCTAssertEqual(TaskDocument.summary(task),"")
    }
    @MainActor func testManagedMarkdownImagesDeduplicateAndSurviveBackupAndModeSwitch() throws {
        let store = Store(persistence: Persistence(inMemory: true)); defer { try? FileManager.default.removeItem(at: store.persistence.root) }
        var task = TaskItem(); task.documentMode = .markdown; XCTAssertTrue(store.save(task))
        let image = try documentImage()
        let path = try store.saveDocumentImage(image,name: "样图.png",to: task.id)
        XCTAssertEqual(path,try store.saveDocumentImage(image,name: "副本.png",to: task.id))
        task = try XCTUnwrap(store.tasks.first); XCTAssertEqual(task.attachments.count,1)
        task.notes = "图片前🙂\n![样图](" + path + ")\n图片后"
        XCTAssertTrue(store.save(task))
        let output = store.persistence.root.appendingPathComponent("backup.json"); try store.export(to: output)
        let backup = try ImportService.preview(output).backup
        XCTAssertNotNil(backup.attachmentFiles?[path])
        try FileManager.default.removeItem(at: store.persistence.root.appendingPathComponent(path))
        try store.persistence.restoreBlobs()
        XCTAssertTrue(RichDocument.hasImages(MarkdownDocument.parse(task.notes,baseURL: store.persistence.root).content))
        TaskDocument.switchMode(&task,to: .richText,baseURL: store.persistence.root)
        XCTAssertTrue(RichDocument.hasImages(try XCTUnwrap(task.richText.flatMap(RichDocument.decode))))
        TaskDocument.switchMode(&task,to: .markdown)
        XCTAssertTrue(store.save(task))
        let stored = try XCTUnwrap(store.tasks.first)
        XCTAssertFalse(stored.notes.contains("data:image/")); XCTAssertEqual(stored.attachments.count,1)
        XCTAssertTrue(RichDocument.hasImages(MarkdownDocument.parse(stored.notes,baseURL: store.persistence.root).content))
    }
    @MainActor func testLegacyInlineImageMigrationPreservesCodeAndSource() throws {
        let persistence = Persistence(inMemory: true); defer { try? FileManager.default.removeItem(at: persistence.root) }
        let uri = "data:image/png;base64," + (try documentImage()).base64EncodedString()
        let literal = "```markdown\n![示例](" + uri + ")\n```\n`![行内](" + uri + ")`\n"
        var task = TaskItem(); task.documentMode = .markdown
        task.notes = literal + "中文🙂 ![原图](" + uri + ")\n![副本](" + uri + ")\n尾部  \n"
        try persistence.save(task)
        let store = Store(persistence: persistence)
        let migrated = try XCTUnwrap(store.tasks.first)
        XCTAssertNil(store.error); XCTAssertTrue(migrated.notes.hasPrefix(literal)); XCTAssertTrue(migrated.notes.hasSuffix("尾部  \n"))
        XCTAssertTrue(migrated.notes.contains("![原图](Attachments/Images/")); XCTAssertEqual(migrated.attachments.count,1)
        XCTAssertEqual(try persistence.load(TaskItem.self).first?.notes,migrated.notes)
        store.reload(); XCTAssertEqual(store.tasks.first?.notes,migrated.notes)
        XCTAssertTrue(RichDocument.hasImages(MarkdownDocument.parse(migrated.notes,baseURL: persistence.root).content))
    }
    @MainActor func testMarkdownImageFileImportCopiesRelativeAssetsAndFailureKeepsText() throws {
        let store = Store(persistence: Persistence(inMemory: true)); defer { try? FileManager.default.removeItem(at: store.persistence.root) }
        let sourceFolder = store.persistence.root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: sourceFolder,withIntermediateDirectories: true)
        try documentImage().write(to: sourceFolder.appendingPathComponent("原图.png"))
        let source = "# 中文🙂\n![图片](原图.png)\n\n```\n![代码](原图.png)\n```\n"
        let file = sourceFolder.appendingPathComponent("input.md"); try source.write(to: file,atomically: true,encoding: .utf8)
        let editor = DocumentTextView(); editor.isRichText = false; editor.imageReference = { try store.writeDocumentImage($0,name: $1) }
        try editor.insertMarkdownFile(file)
        try FileManager.default.removeItem(at: sourceFolder)
        XCTAssertTrue(editor.string.hasPrefix("# 中文🙂\n![图片](Attachments/Images/")); XCTAssertTrue(editor.string.hasSuffix("```\n![代码](原图.png)\n```\n"))
        XCTAssertTrue(RichDocument.hasImages(MarkdownDocument.parse(editor.string,baseURL: store.persistence.root).content))
        let before = editor.string
        editor.imageReference = { _,_ in throw ServiceError.message("磁盘写入失败") }
        XCTAssertThrowsError(try editor.insertImage(documentImage())); XCTAssertEqual(editor.string,before)
    }
    @MainActor func testManagedMarkdownExportIncludesPortableAssetsWordAndPDF() throws {
        let store = Store(persistence: Persistence(inMemory: true)); defer { try? FileManager.default.removeItem(at: store.persistence.root) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: folder) }
        let path = try store.writeDocumentImage(documentImage())
        var task = TaskItem(); task.title = "图片路径验收"; task.documentMode = .markdown
        task.notes = "# 正文🙂\n\n![样图](" + path + ")\n\n```swift\n\tlet x = 1\n```\n尾部文字"
        for format in [DocumentExport.Format.markdown,.word,.pdf] { try DocumentExport.write(task: task,children: [],format: format,to: folder.appendingPathComponent("sample." + format.rawValue),baseURL: store.persistence.root) }
        try FileManager.default.removeItem(at: store.persistence.root.appendingPathComponent(path))
        let markdown = try String(contentsOf: folder.appendingPathComponent("sample.md"),encoding: .utf8)
        XCTAssertFalse(markdown.contains("base64")); XCTAssertFalse(markdown.contains("Attachments/Images/")); XCTAssertTrue(markdown.contains(".assets-"))
        XCTAssertTrue(markdown.hasSuffix("```swift\n\tlet x = 1\n```\n尾部文字"))
        let parsed = MarkdownDocument.parse(markdown,baseURL: folder); XCTAssertTrue(parsed.warnings.isEmpty); XCTAssertTrue(RichDocument.hasImages(parsed.content))
        let word = try Data(contentsOf: folder.appendingPathComponent("sample.docx")); XCTAssertNotNil(word.range(of: Data("word/media/image1.png".utf8)))
        let pdf = try XCTUnwrap(PDFDocument(url: folder.appendingPathComponent("sample.pdf"))); XCTAssertTrue(pdf.string?.precomposedStringWithCompatibilityMapping.contains("尾部文字") == true)
    }

    @MainActor func testPreviewUpdatesIndependentlyAndRetainsScroll() async throws {
        let view = WKWebView(frame: NSRect(x: 0,y: 0,width: 300,height: 160))
        let coordinator = MarkdownPreviewView.Coordinator()
        view.navigationDelegate = coordinator
        let source = "# 预览标题\n\n" + String(repeating: "正文 **粗体**\n\n",count: 60)
        coordinator.update(source,root: nil,dark: false,in: view)
        view.loadHTMLString(MarkdownPreviewView.page,baseURL: nil)
        for _ in 0..<100 { if coordinator.ready { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(coordinator.ready)
        let text = try await view.evaluateJavaScript("document.getElementById('document').innerText") as? String
        XCTAssertTrue(text?.hasPrefix("预览标题") == true); XCTAssertFalse(text?.contains("**") == true)
        _ = try await view.evaluateJavaScript("window.scrollTo(0,150)")
        let offset = try await view.evaluateJavaScript("window.scrollY") as? Double
        coordinator.update(source,root: nil,dark: false,in: view)
        let unchanged = try await view.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(unchanged,offset)
        coordinator.update(source + "\n最新中文🙂",root: nil,dark: true,in: view)
        let updated = try await view.evaluateJavaScript("document.getElementById('document').innerText") as? String
        XCTAssertTrue(updated?.contains("最新中文🙂") == true)
        let after = try await view.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(after,offset)
        let editable = try await view.evaluateJavaScript("document.getElementById('document').isContentEditable") as? Bool
        XCTAssertEqual(editable,false)
        let theme = try await view.evaluateJavaScript("document.documentElement.dataset.dark") as? String
        XCTAssertEqual(theme,"true")
    }

    @MainActor func testChineseCompositionDoesNotSaveUnconfirmedCandidates() {
        let editor = DocumentTextView()
        editor.isRichText = true
        editor.string = "已有正文："
        editor.typingAttributes = MarkdownTyping.bodyAttributes
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count,length: 0))
        var saved: [String] = []
        let parent = DetailDocumentEditor(text: editor.string,data: nil,rich: true,controller: DocumentEditorController(),height: .constant(26)) { text,_ in saved.append(text) }
        let coordinator = DetailDocumentEditor.Coordinator(parent: parent)
        editor.delegate = coordinator
        editor.setMarkedText("zhongwen",selectedRange: NSRange(location: 8,length: 0),replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification,object: editor))
        XCTAssertTrue(saved.isEmpty,"输入法选词期间不能把拼音或候选字写进任务")
        editor.delegate = nil
    }

    @MainActor func testChineseCompositionSurvivesRefreshAndCommitsInBothModes() throws {
        for rich in [true,false] {
            let prefix = "已有🙂正文："
            var saved: [(String,Data?)] = []
            let parent = DetailDocumentEditor(text: prefix,data: nil,rich: rich,controller: DocumentEditorController(),height: .constant(26)) { text,data in saved.append((text,data)) }
            let view = DocumentScrollView(frame: NSRect(x: 0,y: 0,width: 300,height: 26))
            let editor = DocumentTextView(frame: view.bounds); view.documentView = editor
            parent.populate(editor)
            let coordinator = DetailDocumentEditor.Coordinator(parent: parent); coordinator.attach(editor)
            editor.setSelectedRange(NSRange(location: prefix.utf16.count,length: 0))
            editor.setMarkedText("zhongwen",selectedRange: NSRange(location: 8,length: 0),replacementRange: editor.selectedRange())
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification,object: editor))
            let marked = editor.markedRange(), selection = editor.selectedRange()
            for _ in 0..<3 { coordinator.synchronize(view); view.layout() }
            XCTAssertTrue(editor.hasMarkedText()); XCTAssertEqual(editor.markedRange(),marked); XCTAssertEqual(editor.selectedRange(),selection)
            XCTAssertTrue(saved.isEmpty)
            editor.setMarkedText("中文候选",selectedRange: NSRange(location: 4,length: 0),replacementRange: NSRange(location: NSNotFound,length: 0))
            coordinator.synchronize(view)
            XCTAssertTrue(editor.hasMarkedText()); XCTAssertTrue(saved.isEmpty)
            editor.insertText("中文🙂",replacementRange: NSRange(location: NSNotFound,length: 0))
            XCTAssertFalse(editor.hasMarkedText()); XCTAssertEqual(editor.string,prefix + "中文🙂")
            XCTAssertEqual(saved.map(\.0),[prefix + "中文🙂"])
            if rich { XCTAssertEqual(try XCTUnwrap(saved.last?.1.flatMap(RichDocument.decode)).string,editor.string) }
            else { XCTAssertNil(saved.last?.1) }
            var echoed = parent; echoed.text = saved.last!.0; echoed.data = saved.last!.1
            coordinator.parent = echoed
            let committedSelection = editor.selectedRange()
            coordinator.synchronize(view)
            XCTAssertEqual(editor.selectedRange(),committedSelection); XCTAssertEqual(editor.string,prefix + "中文🙂")
            editor.delegate = nil
        }
    }

    @MainActor func testDocumentEchoPreservesTypingStyleSelectionAndAcceptsExternalEdit() throws {
        var saved: (String,Data?)?
        let parent = DetailDocumentEditor(text: "",data: nil,rich: true,controller: DocumentEditorController(),height: .constant(26)) { text,data in saved = (text,data) }
        let view = DocumentScrollView(frame: NSRect(x: 0,y: 0,width: 300,height: 26))
        let editor = DocumentTextView(frame: view.bounds); view.documentView = editor; parent.populate(editor)
        let coordinator = DetailDocumentEditor.Coordinator(parent: parent); coordinator.attach(editor)
        editor.insertText("## ",replacementRange: editor.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification,object: editor))
        XCTAssertEqual(editor.string,""); XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.pointSize,20)
        // SwiftUI can redraw the previous model during a height/toolbar update.
        coordinator.synchronize(view)
        XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.pointSize,20)
        editor.insertText("标题🙂中文",replacementRange: editor.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification,object: editor))
        coordinator.synchronize(view)
        XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.pointSize,20)
        let committed = try XCTUnwrap(saved)
        editor.setSelectedRange(NSRange(location: 2,length: 2))
        var echoed = parent; echoed.text = committed.0; echoed.data = committed.1; coordinator.parent = echoed
        coordinator.synchronize(view)
        XCTAssertEqual(editor.selectedRange(),NSRange(location: 2,length: 2)); XCTAssertEqual(editor.string,"标题🙂中文")
        // A real model edit (e.g. restoring history) still updates the editor.
        var external = parent; external.text = "短"; external.data = nil; coordinator.parent = external
        coordinator.synchronize(view)
        XCTAssertEqual(editor.string,"短"); XCTAssertEqual(editor.selectedRange(),NSRange(location: 1,length: 0))
        XCTAssertEqual(saved!.0,"标题🙂中文")
        editor.delegate = nil
    }

    @MainActor func testUnmarkCommitsWithoutSavingCandidatesAndCancellationKeepsContent() async {
        var saved: [String] = []
        let parent = DetailDocumentEditor(text: "原文",data: nil,rich: true,controller: DocumentEditorController(),height: .constant(26)) { text,_ in saved.append(text) }
        let editor = DocumentTextView(); parent.populate(editor)
        let coordinator = DetailDocumentEditor.Coordinator(parent: parent); coordinator.attach(editor)
        editor.setSelectedRange(NSRange(location: 2,length: 0))
        editor.setMarkedText("候选",selectedRange: NSRange(location: 2,length: 0),replacementRange: editor.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification,object: editor))
        XCTAssertTrue(saved.isEmpty)
        // Cancelling the marked insertion must not change the committed model.
        editor.setMarkedText("",selectedRange: NSRange(location: 0,length: 0),replacementRange: NSRange(location: NSNotFound,length: 0))
        editor.unmarkText()
        let cancelled = expectation(description: "cancel processed")
        DispatchQueue.main.async { cancelled.fulfill() }
        await fulfillment(of: [cancelled],timeout: 2)
        XCTAssertEqual(editor.string,"原文"); XCTAssertTrue(saved.isEmpty)
        editor.setMarkedText("确认",selectedRange: NSRange(location: 2,length: 0),replacementRange: editor.selectedRange())
        editor.unmarkText()
        let committed = expectation(description: "unmark processed")
        DispatchQueue.main.async { committed.fulfill() }
        await fulfillment(of: [committed],timeout: 2)
        XCTAssertEqual(saved,["原文确认"])
        editor.delegate = nil
    }

    @MainActor func testCursorMovementDoesNotRewriteExistingMarkdown() async {
        let original = "保留 **原始符号🙂**"
        var saved: [String] = []
        let parent = DetailDocumentEditor(text: original,data: nil,rich: true,controller: DocumentEditorController(),height: .constant(26)) { text,_ in saved.append(text) }
        let editor = DocumentTextView(); parent.populate(editor)
        let coordinator = DetailDocumentEditor.Coordinator(parent: parent); coordinator.attach(editor)
        editor.setSelectedRange(NSRange(location: original.utf16.count,length: 0))
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,object: editor))
        let moved = expectation(description: "selection callbacks processed")
        DispatchQueue.main.async { moved.fulfill() }
        await fulfillment(of: [moved],timeout: 2)
        XCTAssertEqual(editor.string,original); XCTAssertTrue(saved.isEmpty)
        editor.delegate = nil
    }

    @MainActor func testChineseCompositionInCodeBlockKeepsLiteralMarkdown() {
        var saved: [String] = []
        let parent = DetailDocumentEditor(text: "",data: nil,rich: true,controller: DocumentEditorController(),height: .constant(26)) { text,_ in saved.append(text) }
        let editor = DocumentTextView(); parent.populate(editor)
        let coordinator = DetailDocumentEditor.Coordinator(parent: parent); coordinator.attach(editor)
        editor.typingAttributes = MarkdownTyping.codeBlockAttributes
        editor.setMarkedText("zhongwen",selectedRange: NSRange(location: 8,length: 0),replacementRange: editor.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification,object: editor))
        XCTAssertTrue(saved.isEmpty)
        editor.insertText("**中文🙂**",replacementRange: NSRange(location: NSNotFound,length: 0))
        XCTAssertEqual(editor.string,"**中文🙂**"); XCTAssertEqual(saved,["**中文🙂**"])
        XCTAssertTrue(MarkdownTyping.isCodeBlock(editor.typingAttributes))
        editor.delegate = nil
    }

    @MainActor func testLegacyRichEditorKeepsCompositionAcrossRefresh() {
        var saved: [String] = []
        let parent = RichTextEditor(text: "正文：",data: nil) { text,_ in saved.append(text) }
        let view = NSScrollView(); let editor = DocumentTextView(); view.documentView = editor; parent.populate(editor)
        let coordinator = RichTextEditor.Coordinator(parent: parent); coordinator.attach(editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count,length: 0))
        editor.setMarkedText("ceshi",selectedRange: NSRange(location: 5,length: 0),replacementRange: editor.selectedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification,object: editor))
        coordinator.synchronize(view)
        XCTAssertTrue(editor.hasMarkedText()); XCTAssertTrue(saved.isEmpty)
        editor.insertText("测试",replacementRange: NSRange(location: NSNotFound,length: 0))
        XCTAssertEqual(editor.string,"正文：测试"); XCTAssertEqual(saved,["正文：测试"])
        editor.delegate = nil
    }

    @MainActor private func documentImage() throws -> Data {
        let image = NSImage(size: NSSize(width: 360,height: 120)); image.lockFocus()
        NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: NSRect(x: 0,y: 0,width: 360,height: 120),xRadius: 12,yRadius: 12).fill()
        NSAttributedString(string: "图片与文档验收",attributes: [.font:NSFont.boldSystemFont(ofSize: 24),.foregroundColor:NSColor.white]).draw(at: NSPoint(x: 40,y: 48))
        image.unlockFocus()
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png,properties: [:]))
    }
    @MainActor func testInlineImagePersistenceDeletionUndoAndLegacyRTF() throws {
        let editor = DocumentUndoTextView(); editor.isRichText = true; editor.allowsUndo = true
        editor.localUndo.groupsByEvent = false; editor.localUndo.beginUndoGrouping()
        editor.insertText("图片前文\n",replacementRange: editor.selectedRange())
        try editor.insertImage(documentImage(),name: "样图.png")
        editor.localUndo.endUndoGrouping()
        let stored = try XCTUnwrap(editor.textStorage.flatMap(RichDocument.encode))
        let restored = try XCTUnwrap(RichDocument.decode(stored)); XCTAssertTrue(RichDocument.hasImages(restored)); XCTAssertEqual(restored.string,editor.string)
        let imageRange = (editor.string as NSString).range(of: "\u{fffc}")
        editor.localUndo.beginUndoGrouping()
        editor.setSelectedRange(imageRange); editor.delete(nil); XCTAssertFalse(RichDocument.hasImages(try XCTUnwrap(editor.textStorage)))
        editor.localUndo.endUndoGrouping()
        editor.undoManager?.undo(); XCTAssertTrue(RichDocument.hasImages(try XCTUnwrap(editor.textStorage)))
        let old = NSAttributedString(string: "旧正文",attributes: [.font:NSFont.boldSystemFont(ofSize: 18)])
        let rtf = try old.data(from: NSRange(location:0,length:old.length),documentAttributes: [.documentType:NSAttributedString.DocumentType.rtf])
        XCTAssertEqual(RichDocument.decode(rtf)?.string,"旧正文")
    }
    @MainActor func testMarkdownFileImportExportWithRelativeImageAndCode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:folder) }
        try documentImage().write(to:folder.appendingPathComponent("样图.png"))
        let source = "# 标题\n\n**加粗**与*斜体*\n- 项目\n\n```swift\n\tlet text = \"**中文🙂**\"\n\n```\n\n![示例](样图.png)\n"
        let input = folder.appendingPathComponent("样例.md"); try source.write(to:input,atomically:true,encoding:.utf8)
        let imported = try MarkdownDocument.read(input); XCTAssertTrue(imported.warnings.isEmpty); XCTAssertTrue(RichDocument.hasImages(imported.content))
        let editor = DocumentTextView(); editor.isRichText = true
        editor.insertDocument(imported.content)
        let inserted = try XCTUnwrap(RichDocument.decode(XCTUnwrap(editor.textStorage.flatMap(RichDocument.encode))))
        XCTAssertEqual((inserted.attribute(.font,at:0,effectiveRange:nil) as? NSFont)?.pointSize,24)
        XCTAssertTrue(imported.content.string.contains("\tlet text = \"**中文🙂**\"")); XCTAssertFalse(imported.content.string.contains("# 标题"))
        let exported = MarkdownDocument.export(imported.content,assets:"images")
        XCTAssertEqual(exported.images.count,1); XCTAssertTrue(exported.text.contains("# 标题")); XCTAssertTrue(exported.text.contains("**加粗**"))
        let images = folder.appendingPathComponent("images"); try FileManager.default.createDirectory(at:images,withIntermediateDirectories:true)
        for (name,data) in exported.images { try data.write(to:images.appendingPathComponent(name)) }
        let second = MarkdownDocument.parse(exported.text,baseURL:folder); XCTAssertTrue(second.warnings.isEmpty); XCTAssertTrue(RichDocument.hasImages(second.content))
        XCTAssertEqual(second.content.string,imported.content.string)
        let missing = MarkdownDocument.parse("![缺失](missing.png)",baseURL:folder); XCTAssertEqual(missing.warnings.count,1); XCTAssertTrue(missing.content.string.contains("缺失"))
    }
    @MainActor func testLargeDocumentBlobVersionsAndBackupRoundtrip() throws {
        let persistence = Persistence(inMemory:true); defer { try? FileManager.default.removeItem(at:persistence.root) }
        var task = TaskItem(); task.title="大文档"; task.richText=Data(repeating:42,count:150_000)
        try persistence.save(task); XCTAssertEqual(try persistence.load(TaskItem.self).first?.richText,task.richText)
        let original = try XCTUnwrap(persistence.versions(owner:task.id).first { $0.field == "richText" })
        XCTAssertTrue(original.json.contains("documentBlob")); XCTAssertLessThan(original.json.count,200)
        task.richText=Data(repeating:24,count:150_000); try persistence.save(task)
        try persistence.restoreField(original); XCTAssertEqual(try persistence.load(TaskItem.self).first?.richText,Data(repeating:42,count:150_000))
    }
    @MainActor func testWordPDFAndMarkdownExportContainImagesAndText() throws {
        let folder = ProcessInfo.processInfo.environment["OWNLIST_EXPORT_QA_DIR"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let body = NSMutableAttributedString(attributedString:MarkdownDocument.parse("## 文档功能验收\n\n**加粗正文**，链接：[Apple](https://apple.com)。\n\n```swift\nlet message = \"中文与图片\"\nprint(message)\n```\n\n").content)
        body.append(try RichDocument.image(documentImage(),name:"样图.png")); body.append(NSAttributedString(string:"\n图片后的正文，确认内容完整。\n",attributes:MarkdownTyping.bodyAttributes))
        var task = TaskItem(); task.title="文档导出验收"; task.notes=body.string; task.richText=RichDocument.encode(body)
        for format in [DocumentExport.Format.word,.pdf,.markdown] { try DocumentExport.write(task:task,children:[],format:format,to:folder.appendingPathComponent("sample."+format.rawValue)) }
        let word = try Data(contentsOf:folder.appendingPathComponent("sample.docx"))
        XCTAssertTrue(word.starts(with:[0x50,0x4b])); XCTAssertNotNil(word.range(of:Data("word/media/image1.png".utf8)))
        let pdf = try XCTUnwrap(PDFDocument(url:folder.appendingPathComponent("sample.pdf")))
        XCTAssertTrue(pdf.string?.precomposedStringWithCompatibilityMapping.contains("图片后的正文") == true); XCTAssertGreaterThanOrEqual(pdf.pageCount,1)
        let md = try MarkdownDocument.read(folder.appendingPathComponent("sample.md")); XCTAssertTrue(md.warnings.isEmpty); XCTAssertTrue(RichDocument.hasImages(md.content)); XCTAssertTrue(md.content.string.contains("图片后的正文"))
        task.notes = (1...100).map { "第\($0)行长文档内容" }.joined(separator:"\n"); task.richText=nil
        try DocumentExport.write(task:task,children:[],format:.pdf,to:folder.appendingPathComponent("long.pdf"))
        let long = try XCTUnwrap(PDFDocument(url:folder.appendingPathComponent("long.pdf")))
        XCTAssertGreaterThan(long.pageCount,1); XCTAssertTrue(long.string?.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }.contains("第100行") == true, "PDFKit text: " + (long.string ?? "nil"))
    }
    @MainActor func testCodeBlockTypingLiteralIndentationAndExit() throws {
        let editor = NSTextView(); editor.isRichText = true; editor.typingAttributes = MarkdownTyping.bodyAttributes
        editor.insertText("```swift",replacementRange: editor.selectedRange())
        XCTAssertTrue(MarkdownTyping.insertNewline(in: editor)); XCTAssertTrue(MarkdownTyping.isCodeBlock(editor.typingAttributes))
        XCTAssertEqual(editor.selectedRange().location,0)
        editor.insertText("    let value = \"**中文🙂**\"",replacementRange: editor.selectedRange())
        XCTAssertFalse(MarkdownTyping.recognize(in: editor)); XCTAssertTrue(editor.string.contains("**中文🙂**"))
        XCTAssertTrue(MarkdownTyping.insertNewline(in: editor)); XCTAssertTrue(editor.string.contains("\n    \n"))
        editor.insertText("## 原样代码",replacementRange: editor.selectedRange()); XCTAssertFalse(MarkdownTyping.recognize(in: editor))
        XCTAssertTrue(MarkdownTyping.insertNewline(in: editor))
        editor.insertText("```",replacementRange: editor.selectedRange()); XCTAssertFalse(MarkdownTyping.recognize(in: editor))
        XCTAssertTrue(MarkdownTyping.insertNewline(in: editor)); XCTAssertFalse(MarkdownTyping.isCodeBlock(editor.typingAttributes))
        editor.insertText("**正文恢复**",replacementRange: editor.selectedRange()); XCTAssertTrue(MarkdownTyping.recognize(in: editor))
        XCTAssertTrue(editor.string.hasSuffix("正文恢复\n")); XCTAssertFalse(editor.string.contains("```"))
    }
    @MainActor func testPastedCodeBlockWhitespaceRTFAndReediting() throws {
        let editor = NSTextView(); editor.isRichText = true; editor.typingAttributes = MarkdownTyping.bodyAttributes
        let code = "  print(\"中文🙂\")\n\n\t**literal**\n- literal\n"
        editor.insertText("前文\n```python\n" + code + "```",replacementRange: editor.selectedRange())
        XCTAssertTrue(MarkdownTyping.recognize(in: editor)); XCTAssertEqual(editor.string,"前文\n" + code + "\n")
        XCTAssertFalse(MarkdownTyping.isCodeBlock(editor.typingAttributes))
        let rtf = try XCTUnwrap(editor.rtf(from: NSRange(location: 0,length: editor.string.utf16.count)))
        let restored = try NSAttributedString(data: rtf,options: [.documentType: NSAttributedString.DocumentType.rtf],documentAttributes: nil)
        XCTAssertEqual(restored.string,editor.string)
        let codeLocation = (editor.string as NSString).range(of: "  print").location
        XCTAssertTrue(MarkdownTyping.isCodeBlock(restored.attributes(at: codeLocation,effectiveRange: nil)))
        XCTAssertFalse(MarkdownTyping.isCodeBlock(restored.attributes(at: 0,effectiveRange: nil)))
        editor.textStorage?.setAttributedString(restored)
        editor.setSelectedRange(NSRange(location: codeLocation,length: 0)); editor.typingAttributes = restored.attributes(at: codeLocation,effectiveRange: nil)
        editor.insertText("**原样**",replacementRange: editor.selectedRange()); XCTAssertFalse(MarkdownTyping.recognize(in: editor))
        let source = NSTextView(); source.isRichText = false
        source.insertText("```swift\nlet x = 1\n```",replacementRange: source.selectedRange())
        XCTAssertFalse(MarkdownTyping.recognize(in: source)); XCTAssertTrue(source.string.contains("```swift"))
    }
    @MainActor func testCodeBlockToolbarAndConversionUndoPersist() {
        let editor = MarkdownUndoTextView(); editor.isRichText = true; editor.allowsUndo = true; editor.typingAttributes = MarkdownTyping.bodyAttributes
        let fenced = "```\n  **literal🙂**\n```"
        editor.string = fenced; editor.setSelectedRange(NSRange(location: fenced.utf16.count,length: 0))
        var persisted = ""
        let parent = DetailDocumentEditor(text: fenced,data: nil,rich: true,controller: DocumentEditorController(),height: .constant(26)) { text,_ in persisted = text }
        let coordinator = DetailDocumentEditor.Coordinator(parent: parent); editor.delegate = coordinator
        editor.localUndo.beginUndoGrouping(); coordinator.textDidChange(Notification(name: NSText.didChangeNotification,object: editor)); editor.localUndo.endUndoGrouping()
        XCTAssertEqual(editor.string,"  **literal🙂**\n\n"); XCTAssertEqual(persisted,editor.string)
        coordinator.performUndo(in: editor); XCTAssertEqual(editor.string,fenced); XCTAssertEqual(persisted,fenced)
        coordinator.performUndo(in: editor,redo: true); XCTAssertEqual(editor.string,"  **literal🙂**\n\n"); XCTAssertEqual(persisted,editor.string)
        editor.delegate = nil; editor.string = "前文\nfirst\nsecond"; editor.typingAttributes = MarkdownTyping.bodyAttributes
        editor.setSelectedRange((editor.string as NSString).range(of: "first\nsecond"))
        let controller = DocumentEditorController(); controller.editor = editor; controller.rich = true; controller.apply(.codeBlock)
        XCTAssertEqual(editor.string,"前文\nfirst\nsecond\n\n"); XCTAssertTrue(MarkdownTyping.isCodeBlock(editor.typingAttributes))
        XCTAssertTrue(controller.activeFormats.contains(.codeBlock))
        // Returning focus from a SwiftUI menu must restore the block's input
        // style, even if updating the RTF view reset the typing attributes.
        editor.delegate = coordinator; editor.typingAttributes = MarkdownTyping.bodyAttributes
        coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification,object: editor))
        XCTAssertTrue(MarkdownTyping.isCodeBlock(editor.typingAttributes))
        editor.insertText("**literal**",replacementRange: editor.selectedRange())
        XCTAssertFalse(MarkdownTyping.recognize(in: editor)); XCTAssertTrue(editor.string.contains("**literal**"))
    }
    @MainActor func testMarkdownTypingHeadingAndListContinuation() throws {
        for level in 1...6 {
            let heading = NSTextView(); heading.isRichText = true; heading.typingAttributes = MarkdownTyping.bodyAttributes
            heading.insertText(String(repeating: "#",count: level) + " ",replacementRange: heading.selectedRange())
            XCTAssertTrue(MarkdownTyping.recognize(in: heading))
            heading.insertText("标题",replacementRange: heading.selectedRange())
            XCTAssertTrue(MarkdownTyping.insertNewline(in: heading))
            XCTAssertEqual((heading.typingAttributes[.font] as? NSFont)?.pointSize,14)
        }
        let editor = NSTextView(); editor.isRichText = true; editor.typingAttributes = MarkdownTyping.bodyAttributes
        editor.insertText("## ",replacementRange: editor.selectedRange()); XCTAssertTrue(MarkdownTyping.recognize(in: editor)); XCTAssertEqual(editor.string,"")
        XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.pointSize,20)
        editor.insertText("中文标题🙂",replacementRange: editor.selectedRange())
        XCTAssertTrue(MarkdownTyping.insertNewline(in: editor)); XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.pointSize,14)
        editor.insertText("- ",replacementRange: editor.selectedRange()); XCTAssertTrue(MarkdownTyping.recognize(in: editor)); editor.insertText("项目🙂",replacementRange: editor.selectedRange())
        XCTAssertTrue(MarkdownTyping.insertNewline(in: editor)); XCTAssertEqual(editor.string,"中文标题🙂\n• 项目🙂\n• ")
        XCTAssertTrue(MarkdownTyping.insertNewline(in: editor)); XCTAssertEqual(editor.string,"中文标题🙂\n• 项目🙂\n")
        editor.insertText("9. ",replacementRange: editor.selectedRange()); XCTAssertTrue(MarkdownTyping.recognize(in: editor)); editor.insertText("编号项目",replacementRange: editor.selectedRange())
        XCTAssertTrue(MarkdownTyping.insertNewline(in: editor)); XCTAssertTrue(editor.string.hasSuffix("9. 编号项目\n10. "))
        XCTAssertTrue(MarkdownTyping.insertNewline(in: editor)); XCTAssertTrue(editor.string.hasSuffix("9. 编号项目\n"))
        editor.insertText("> ",replacementRange: editor.selectedRange()); XCTAssertTrue(MarkdownTyping.recognize(in: editor)); editor.insertText("引用",replacementRange: editor.selectedRange())
        XCTAssertTrue(MarkdownTyping.insertNewline(in: editor)); XCTAssertTrue(editor.string.hasSuffix("│ 引用\n│ "))
    }
    @MainActor func testMarkdownInlineUnicodeLinksAndRTFRoundtrip() throws {
        let editor = NSTextView(); editor.isRichText = true; editor.typingAttributes = MarkdownTyping.bodyAttributes
        editor.insertText("前文 **中文🙂**",replacementRange: editor.selectedRange()); XCTAssertTrue(MarkdownTyping.recognize(in: editor)); XCTAssertEqual(editor.string,"前文 中文🙂")
        let boldRange = (editor.string as NSString).range(of: "中文🙂")
        let font = try XCTUnwrap(editor.textStorage?.attribute(.font,at: boldRange.location,effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        editor.insertText(" 后文 *斜体*",replacementRange: editor.selectedRange()); XCTAssertTrue(MarkdownTyping.recognize(in: editor))
        editor.insertText(" ~~删除~~",replacementRange: editor.selectedRange()); XCTAssertTrue(MarkdownTyping.recognize(in: editor))
        editor.insertText(" `**原样代码**`",replacementRange: editor.selectedRange()); XCTAssertTrue(MarkdownTyping.recognize(in: editor)); XCTAssertTrue(editor.string.contains("**原样代码**"))
        editor.insertText(" [链接🙂](https://example.com)",replacementRange: editor.selectedRange()); XCTAssertTrue(MarkdownTyping.recognize(in: editor))
        let linkRange = (editor.string as NSString).range(of: "链接🙂")
        XCTAssertEqual((editor.textStorage?.attribute(.link,at: linkRange.location,effectiveRange: nil) as? URL)?.absoluteString,"https://example.com")
        let rtf = try XCTUnwrap(editor.rtf(from: NSRange(location: 0,length: (editor.string as NSString).length)))
        let restored = try NSAttributedString(data: rtf,options: [.documentType: NSAttributedString.DocumentType.rtf],documentAttributes: nil)
        XCTAssertEqual(restored.string,editor.string)
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(restored.attribute(.font,at: boldRange.location,effectiveRange: nil) as? NSFont)).contains(.boldFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: try XCTUnwrap(editor.typingAttributes[.font] as? NSFont)).contains(.boldFontMask))
    }
    @MainActor func testMarkdownDoesNotTransformSourceEscapesOrIncompleteInput() {
        let editor = NSTextView(); editor.isRichText = true; editor.typingAttributes = MarkdownTyping.bodyAttributes
        for input in ["普通正文 #", "\\**保留符号**", "未完成 **内容", "file_name_", "`**代码中的星号**"] {
            editor.string = input; editor.setSelectedRange(NSRange(location: (input as NSString).length,length: 0))
            XCTAssertFalse(MarkdownTyping.recognize(in: editor),input); XCTAssertEqual(editor.string,input)
        }
        editor.isRichText = false; editor.string = "## "; editor.setSelectedRange(NSRange(location: 3,length: 0))
        XCTAssertFalse(MarkdownTyping.recognize(in: editor)); XCTAssertEqual(editor.string,"## ")
    }
    @MainActor func testMarkdownConversionUndoRestoresSyntaxAndDoesNotReconvert() {
        let editor = MarkdownUndoTextView(); editor.isRichText = true; editor.allowsUndo = true
        editor.string = "**中文🙂**"; editor.setSelectedRange(NSRange(location: (editor.string as NSString).length,length: 0))
        editor.typingAttributes = MarkdownTyping.bodyAttributes
        var persisted = ""
        let parent = DetailDocumentEditor(text: editor.string,data: nil,rich: true,controller: DocumentEditorController(),height: .constant(26)) { text,_ in persisted = text }
        let coordinator = DetailDocumentEditor.Coordinator(parent: parent); editor.delegate = coordinator
        editor.localUndo.beginUndoGrouping()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification,object: editor))
        editor.localUndo.endUndoGrouping()
        XCTAssertEqual(editor.string,"中文🙂"); XCTAssertEqual(persisted,editor.string)
        XCTAssertTrue(editor.localUndo.canUndo); coordinator.performUndo(in: editor)
        XCTAssertEqual(editor.string,"**中文🙂**"); XCTAssertEqual(persisted,editor.string)
        coordinator.performUndo(in: editor,redo: true); XCTAssertEqual(editor.string,"中文🙂"); XCTAssertEqual(persisted,editor.string)
    }
    @MainActor func testChecklistBatchEntryReorderingAndUndoPreservesDocument() throws {
        let store = Store(persistence: Persistence(inMemory: true)); let id = try XCTUnwrap(store.add("检查清单验收"))
        store.mutate(id) { $0.notes = "正文🙂"; $0.richText = Data([1,2,3]) }
        XCTAssertTrue(store.addChecks(id,input: " \n \t ").isEmpty)
        let checks = store.addChecks(id,input: " 第一项🙂 \r\n第二项\n\n第三项 ")
        XCTAssertEqual(checks.count,3)
        XCTAssertEqual(store.tasks.first { $0.id == id }?.checks.map(\.title),["第一项🙂","第二项","第三项"])
        store.mutate(id) { $0.checks[0].done = true }
        XCTAssertTrue(store.moveCheck(id,checkID: checks[0],offset: 1))
        XCTAssertEqual(store.tasks.first { $0.id == id }?.checks.map(\.id),[checks[1],checks[0],checks[2]])
        store.undo(); XCTAssertEqual(store.tasks.first { $0.id == id }?.checks.first?.id,checks[0])
        store.redo(); XCTAssertTrue(store.reorderCheck(id,checkID: checks[2],before: checks[1]))
        XCTAssertFalse(store.reorderCheck(id,checkID: UUID(),before: checks[1]))
        XCTAssertFalse(store.moveCheck(id,checkID: checks[2],offset: -1))
        let restored = try XCTUnwrap(store.persistence.load(TaskItem.self).first { $0.id == id })
        XCTAssertEqual(restored.checks.map(\.id),[checks[2],checks[1],checks[0]])
        XCTAssertTrue(restored.checks.last!.done); XCTAssertEqual(restored.notes,"正文🙂"); XCTAssertEqual(restored.richText,Data([1,2,3]))
        store.undo(); store.undo(); store.undo(); store.undo()
        XCTAssertTrue(store.tasks.first { $0.id == id }!.checks.isEmpty)
        XCTAssertEqual(store.tasks.first { $0.id == id }?.notes,"正文🙂")
    }
    @MainActor func testDocumentHeightShrinksAndWrapsWithoutLosingContent() {
        let scroll = DocumentScrollView(frame: NSRect(x: 0,y: 0,width: 300,height: 26))
        let editor = NSTextView(frame: NSRect(x: 0,y: 0,width: 300,height: 26))
        editor.font = .systemFont(ofSize: 14); editor.textContainerInset = NSSize(width: 0,height: 3)
        editor.textContainer?.lineFragmentPadding = 0; editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        scroll.documentView = editor
        editor.string = "短正文🙂"; scroll.layout()
        XCTAssertLessThanOrEqual(editor.frame.height,32)
        let long = Array(repeating: "中文🙂长正文随栏宽换行且完整保留",count: 20).joined(separator: "\n")
        editor.string = long; scroll.layout(); let wide = editor.frame.height
        XCTAssertGreaterThan(wide,300)
        scroll.setFrameSize(NSSize(width: 120,height: 26)); scroll.layout()
        XCTAssertGreaterThan(editor.frame.height,wide); XCTAssertEqual(editor.string,long)
        editor.string = "短正文🙂"; scroll.layout(); XCTAssertLessThanOrEqual(editor.frame.height,32)
    }
    @MainActor func testFormattingStateTracksSelectionAndCaret() {
        let editor = NSTextView(); editor.isRichText = true
        editor.textStorage?.setAttributedString(NSAttributedString(string: "正文",attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        editor.setSelectedRange(NSRange(location: 0,length: 1))
        let controller = DocumentEditorController(); controller.editor = editor; controller.rich = true
        controller.apply(.bold); XCTAssertTrue(controller.activeFormats.contains(.bold))
        editor.setSelectedRange(NSRange(location: 1,length: 1)); controller.refreshSelection()
        XCTAssertFalse(controller.activeFormats.contains(.bold))
        editor.setSelectedRange(NSRange(location: 2,length: 0)); controller.apply(.underline)
        XCTAssertTrue(controller.activeFormats.contains(.underline)); XCTAssertEqual(editor.string,"正文")
    }
    @MainActor func testPrintDocumentFitsShortContentAndExpandsLongContent() throws {
        var task = TaskItem(); task.title = "打印验收"; task.notes = "中文🙂正文"; task.checks = [CheckItem(title: "检查项",done: true)]
        var child = TaskItem(); child.title = "子任务验收"
        let short = TaskPrintDocument.makeView(task: task,children: [child])
        XCTAssertTrue(short.string.contains("中文🙂正文")); XCTAssertTrue(short.string.contains("☑ 检查项")); XCTAssertTrue(short.string.contains("子任务验收"))
        XCTAssertGreaterThan(short.frame.height,24); XCTAssertLessThan(short.frame.height,300)
        let color = try XCTUnwrap(short.textStorage?.attribute(.foregroundColor,at: 0,effectiveRange: nil) as? NSColor)
        XCTAssertEqual(color,DocumentStyle.text)
        task.notes = Array(repeating: "长正文打印验收",count: 100).joined(separator: "\n")
        XCTAssertGreaterThan(TaskPrintDocument.makeView(task: task).frame.height,1000)
    }
    @MainActor func testDocumentFormattingPreservesUnicodeSelectionAndSurroundingText() {
        let editor = NSTextView(); editor.isRichText = false
        editor.string = "前缀 中文🙂 后缀"
        let selected = (editor.string as NSString).range(of: "中文🙂")
        editor.setSelectedRange(selected)
        let controller = DocumentEditorController(); controller.editor = editor
        controller.apply(.bold)
        XCTAssertEqual(editor.string,"前缀 **中文🙂** 后缀")
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()),"**中文🙂**")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length,length: 0))
        controller.apply(.link)
        XCTAssertTrue(editor.string.hasSuffix("[链接文字](https://)"))
    }
    @MainActor func testRichDocumentFormattingRoundtripWithoutChangingPlainText() throws {
        let editor = NSTextView(); editor.isRichText = true
        editor.textStorage?.setAttributedString(NSAttributedString(string: "中文🙂正文",attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        let range = (editor.string as NSString).range(of: "中文🙂")
        editor.setSelectedRange(range)
        let controller = DocumentEditorController(); controller.editor = editor; controller.rich = true
        controller.apply(.bold)
        controller.apply(.underline)
        let rtf = try XCTUnwrap(editor.rtf(from: NSRange(location: 0,length: (editor.string as NSString).length)))
        let restored = try NSAttributedString(data: rtf,options: [.documentType: NSAttributedString.DocumentType.rtf],documentAttributes: nil)
        XCTAssertEqual(restored.string,"中文🙂正文")
        let font = try XCTUnwrap(restored.attribute(.font,at: 0,effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(restored.attribute(.underlineStyle,at: 0,effectiveRange: nil) as? Int,NSUnderlineStyle.single.rawValue)
        controller.apply(.bold)
        let normal = try XCTUnwrap(editor.textStorage?.attribute(.font,at: 0,effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: normal).contains(.boldFontMask))
    }
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!; return c }
    func date(_ y: Int,_ m: Int,_ d: Int,_ h: Int = 9) -> Date { calendar.date(from: DateComponents(year: y,month: m,day: d,hour: h))! }
    func testChineseQuickEntry() { let result = QuickParser.parse("明天下午3点 写周报 #工作 !3",now: date(2026,10,6),calendar: calendar); XCTAssertEqual(result.title,"写周报"); XCTAssertEqual(result.tags,["工作"]); XCTAssertEqual(result.priority,3); XCTAssertEqual(result.due,date(2026,10,7,15)) }
    func testMonthlyClampsAndLeapYear() { var rule = RepeatRule(); rule.frequency = "monthly"; XCTAssertEqual(rule.next(after: date(2024,1,31),calendar: calendar),date(2024,2,29)); XCTAssertEqual(rule.next(after: date(2025,1,31),calendar: calendar),date(2025,2,28)); rule.frequency = "monthEnd"; XCTAssertEqual(rule.next(after: date(2026,1,10),calendar: calendar),date(2026,2,28)) }
    func testWorkdaysAndCompletionBased() { var rule = RepeatRule(); rule.frequency = "workdays"; XCTAssertEqual(rule.next(after: date(2026,10,9),calendar: calendar),date(2026,10,12)); rule.frequency = "daily"; rule.afterCompletion = true; XCTAssertEqual(rule.next(after: date(2026,10,1),completedAt: date(2026,10,6),calendar: calendar),date(2026,10,7)) }
    func testUntilAndWeekdays() { var rule = RepeatRule(); rule.frequency = "weekly"; rule.weekdays = [2,4]; XCTAssertEqual(rule.next(after: date(2026,10,6),calendar: calendar),date(2026,10,7)); rule.until = date(2026,10,6); XCTAssertNil(rule.next(after: date(2026,10,6),calendar: calendar)) }
    func testDaylightSavingUsesCalendarDays() { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!; let before = c.date(from: DateComponents(year: 2026,month: 3,day: 7,hour: 9))!; var r = RepeatRule(); r.frequency = "daily"; let next = r.next(after: before,calendar: c)!; XCTAssertEqual(c.component(.hour,from: next),9); XCTAssertEqual(next.timeIntervalSince(before),23 * 3600) }
    func testLunarNewYear() { var r = RepeatRule(); r.frequency = "lunar"; r.lunarMonth = 1; r.lunarDay = 1; XCTAssertEqual(r.next(after: date(2026,1,1),calendar: calendar),date(2026,2,17)) }
    func testCSVQuotedNewlines() { XCTAssertEqual(CSV.parse("Title,Content\r\n\"a,b\",\"line1\nline2 \"\"quote\"\"\"\r\n"),[["Title","Content"],["a,b","line1\nline2 \"quote\""]]) }
    func testICSUTCAndUnfolding() throws { let data = Data("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:one\r\nDTSTART:20261006T010000Z\r\nDTEND:20261006T020000Z\r\nSUMMARY:Long\r\n  title\r\nEND:VEVENT\r\nEND:VCALENDAR".utf8); let result = try ICSParser.parse(data,source: "test"); XCTAssertEqual(result.count,1); XCTAssertEqual(result[0].title,"Long title"); XCTAssertEqual(result[0].start,date(2026,10,6)); XCTAssertEqual(result[0].end.timeIntervalSince(result[0].start),3600) }
    func testPersistenceRoundtripOptionalClearingAndHistory() throws { let p = Persistence(inMemory: true); var t = TaskItem(); t.title = "持久化"; t.due = date(2026,10,6); t.tags = ["学习"]; t.checks = [CheckItem(title: "检查")]; try p.save(t); t.due = nil; t.title = "已修改"; try p.save(t); let loaded = try XCTUnwrap(p.load(TaskItem.self).first); XCTAssertNil(loaded.due); XCTAssertEqual(loaded.title,"已修改"); XCTAssertEqual(loaded.checks.count,1); let versions = try p.versions(owner: t.id); XCTAssertEqual(versions.filter { $0.field == "title" }.count,2); try p.restoreField(versions.first { $0.field == "title" }!); XCTAssertEqual(try p.load(TaskItem.self).first?.title,"持久化") }
    func testImportAndStableDeduplication() throws { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv"); defer { try? FileManager.default.removeItem(at: url) }; try "Title,List Name,Due Date,Tags,Status\n任务,工作,2026-10-06,标签,1\n".write(to: url,atomically: true,encoding: .utf8); let first = try ImportService.preview(url); let second = try ImportService.preview(url); XCTAssertEqual(first.count,1); XCTAssertTrue(first.backup.tasks[0].completed); XCTAssertEqual(first.backup.tasks[0].sourceID,second.backup.tasks[0].sourceID); XCTAssertEqual(first.backup.lists[0].name,"工作") }
    func testTenThousandTaskFiltering() { let tasks = (0..<10000).map { i in var t = TaskItem(); t.title = "任务 \(i)"; t.tags = i % 2 == 0 ? ["工作"] : ["学习"]; t.priority = i % 4; return t }; var f = SavedFilter(name: "工作高优先级"); f.tag = "工作"; f.priority = 2; measure { XCTAssertEqual(tasks.filter { f.matches($0) }.count,2500) } }
    @MainActor func testStoreUndoDeleteRepeatAndRestore() throws { let store = Store(persistence: Persistence(inMemory: true)); let id = try XCTUnwrap(store.add("测试")); store.mutate(id) { $0.due = self.date(2026,10,6); $0.repeatRule.frequency = "daily" }; store.complete(id); XCTAssertEqual(store.tasks.filter { !$0.deleted }.count,2); store.undo(); XCTAssertFalse(store.tasks.first { $0.id == id }!.completed); XCTAssertEqual(store.tasks.filter { !$0.deleted }.count,1); store.redo(); XCTAssertEqual(store.tasks.filter { !$0.deleted }.count,2); store.mutate(id) { $0.deleted = true }; store.undo(); XCTAssertFalse(store.tasks.first { $0.id == id }!.deleted) }
    func testBiweeklyAnchorAndMonthlyOrdinal() { var r = RepeatRule(); r.frequency = "weekly"; r.interval = 2; r.weekdays = [2,4]; r.anchor = date(2026,10,5); XCTAssertEqual(r.next(after: date(2026,10,5),calendar: calendar),date(2026,10,7)); XCTAssertEqual(r.next(after: date(2026,10,7),calendar: calendar),date(2026,10,19)); r.frequency = "monthlyWeekday"; r.interval = 1; r.weekday = 6; r.ordinal = -1; XCTAssertEqual(r.next(after: date(2026,10,6),calendar: calendar),date(2026,10,30)) }
    func testICSRecurrenceAndExclusions() throws { let r = try RecurrenceCodec.expand(start: date(2026,10,6),end: date(2026,10,6,10),rule: "FREQ=DAILY;COUNT=3",exclusions: [date(2026,10,7)],calendar: calendar); XCTAssertEqual(r.map { $0.0 },[date(2026,10,6),date(2026,10,8)]); XCTAssertEqual(RecurrenceCodec.duration("TRIGGER:-PT15M"),-900) }
    func testBackupMetadataAndParentMapping() throws { let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv"); defer { try? FileManager.default.removeItem(at: url) }; let csv = "Backup version: 1\nStatus:0 Normal 1 Completed 2 Archived\nFolder Name,List Name,Title,taskId,parentId,Repeat,Status\n项目,工作,父任务,abc,,FREQ=DAILY;INTERVAL=2,0\n项目,工作,子任务,def,abc,,1\n"; try csv.write(to: url,atomically: true,encoding: .utf8); let data = try ImportService.preview(url).backup; XCTAssertEqual(data.tasks[1].parentID,data.tasks[0].id); XCTAssertEqual(data.lists[0].folder,"项目"); XCTAssertEqual(data.tasks[0].repeatRule.interval,2); XCTAssertTrue(data.tasks[1].completed) }
    func testTenThousandPersistenceRoundtrip() throws { let persistence = Persistence(inMemory: true); let started = Date(); for i in 0..<10000 { var task = TaskItem(); task.title = "任务 \(i)"; task.priority = i % 4; try persistence.save(task) }; let loaded = try persistence.load(TaskItem.self); XCTAssertEqual(loaded.count,10000); XCTAssertEqual(loaded.filter { $0.priority == 3 }.count,2500); print("10,000 record save + load: \(Date().timeIntervalSince(started))s") }

    @MainActor func testParentDeleteRestoreAndCompletion() throws { let store = Store(persistence: Persistence(inMemory: true)); let parent = try XCTUnwrap(store.add("父")); let child = try XCTUnwrap(store.add("子",parentID: parent)); store.selectedTask = parent; store.complete(parent); XCTAssertTrue(store.tasks.first { $0.id == child }!.completed); store.undo(); XCTAssertFalse(store.tasks.first { $0.id == child }!.completed); store.mutate(parent) { $0.deleted = true }; XCTAssertTrue(store.tasks.first { $0.id == child }!.deleted); store.mutate(parent) { $0.deleted = false }; XCTAssertFalse(store.tasks.first { $0.id == child }!.deleted) }
    @MainActor func testBackupIncludesAttachmentsAndRejectsTraversal() throws { let store = Store(persistence: Persistence(inMemory: true)); defer { try? FileManager.default.removeItem(at: store.persistence.root) }; let content = Data("附件内容".utf8); try store.restoreFiles(["Attachments/test.txt":content]); var task = TaskItem(); task.title = "带附件任务"; task.attachments = [Attachment(name: "test.txt",relativePath: "Attachments/test.txt")]; store.save(task); let output = store.persistence.root.appendingPathComponent("backup.json"); try store.export(to: output); let data = try ImportService.preview(output).backup; XCTAssertEqual(data.attachmentFiles?["Attachments/test.txt"],content); XCTAssertThrowsError(try store.restoreFiles(["Attachments/../../outside":content])) }

    func testCalendarDateMovePreservesTimeAndDuration() { var t = TaskItem(); t.allDay = false; t.due = date(2026,10,6,15); t.start = date(2026,10,6,14); Scheduling.move(&t,to: date(2026,10,7),timed: false,calendar: calendar); XCTAssertEqual(t.due,date(2026,10,7,15)); XCTAssertEqual(t.start,date(2026,10,7,14)); t.duration = 1800; Scheduling.move(&t,to: date(2026,10,8,16),timed: true,calendar: calendar); XCTAssertEqual(t.start,date(2026,10,8,16)); XCTAssertEqual(t.due!.timeIntervalSince(t.start!),1800) }
    @MainActor func testTemplateCopiesNestedSubtasks() throws { let store = Store(persistence: Persistence(inMemory: true)); let root = try XCTUnwrap(store.add("父")); let child = try XCTUnwrap(store.add("子",parentID: root)); store.add("孙",parentID: child); let template = try XCTUnwrap(store.duplicate(root,asTemplate: true)); let templateChild = try XCTUnwrap(store.tasks.first { $0.parentID == template }); XCTAssertTrue(templateChild.isTemplate); XCTAssertEqual(store.tasks.filter { $0.parentID == templateChild.id }.count,1); let instance = try XCTUnwrap(store.duplicate(template)); let instanceChild = try XCTUnwrap(store.tasks.first { $0.parentID == instance }); XCTAssertFalse(instanceChild.isTemplate); XCTAssertEqual(store.tasks.filter { $0.parentID == instanceChild.id }.count,1) }

    @MainActor func testListCreationValidationEditingAndUndo() throws {
        let store = Store(persistence: Persistence(inMemory: true))
        let list = try store.commitList(existing: nil,name: "  阅读 \n",folder: "  个人  ",color: "green",sections: "计划，进行中,计划\n 完成 ; ;")
        XCTAssertEqual(list.name,"阅读"); XCTAssertEqual(list.folder,"个人"); XCTAssertEqual(list.sections,["计划","进行中","完成"])
        XCTAssertThrowsError(try store.commitList(existing: nil,name: "阅读",folder: "个人",color: "blue",sections: ""))
        XCTAssertThrowsError(try store.commitList(existing: nil,name: " \n",folder: "",color: "blue",sections: ""))
        let task = try XCTUnwrap(store.add("读第一章",listID: list.id))
        let edited = try store.commitList(existing: list,name: "读书",folder: "",color: "purple",sections: "笔记")
        XCTAssertEqual(edited.id,list.id); XCTAssertEqual(store.tasks.first { $0.id == task }?.listID,list.id)
        store.undo(); XCTAssertEqual(store.lists.first?.name,"阅读")
        store.redo(); XCTAssertEqual(store.lists.first?.name,"读书")
        XCTAssertEqual(try store.persistence.load(TaskList.self).first?.folder,"")
    }
    @MainActor func testQuickEntryContextAndDateOverride() throws {
        let store = Store(persistence: Persistence(inMemory: true))
        let list = try store.commitList(existing: nil,name: "验收",folder: "",color: "blue",sections: "准备",defaultView: "看板")
        let due = Calendar.current.startOfDay(for: Date())
        let id = try XCTUnwrap(store.add("无日期录入",listID: list.id,defaultDue: due,section: "准备",starred: true))
        let task = try XCTUnwrap(store.tasks.first { $0.id == id })
        XCTAssertEqual(task.due,due); XCTAssertEqual(task.section,"准备"); XCTAssertEqual(task.listID,list.id); XCTAssertTrue(task.starred)
        store.undo(); XCTAssertFalse(store.tasks.contains { $0.id == id && !$0.deleted })
        store.redo(); XCTAssertEqual(store.tasks.first { $0.id == id }?.section,"准备")
        let explicit = try XCTUnwrap(store.add("明天 验收记录",defaultDue: due))
        XCTAssertTrue(Calendar.current.isDate(store.tasks.first { $0.id == explicit }!.due!,inSameDayAs: Calendar.current.date(byAdding: .day,value: 1,to: due)!))
        XCTAssertNil(store.add("  ")); XCTAssertEqual(try store.persistence.load(TaskList.self).first?.defaultView,"看板")
    }
    func testLegacyListViewCompatibility() throws {
        let list = TaskList(name: "旧清单")
        let data = try JSONEncoder().encode(list)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
        json.removeValue(forKey: "defaultView")
        let loaded = try JSONDecoder().decode(TaskList.self,from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.name,"旧清单"); XCTAssertNil(loaded.defaultView)
    }

    func testAllDayDeadlineAndTimedDeadline() {
        var task = TaskItem(); task.due = date(2026,10,6,0)
        XCTAssertFalse(Scheduling.isOverdue(task,now: date(2026,10,6,23),calendar: calendar))
        XCTAssertTrue(Scheduling.isOverdue(task,now: date(2026,10,7,0),calendar: calendar))
        task.allDay = false; task.due = date(2026,10,6,15)
        XCTAssertFalse(Scheduling.isOverdue(task,now: date(2026,10,6,14),calendar: calendar))
        XCTAssertTrue(Scheduling.isOverdue(task,now: date(2026,10,6,16),calendar: calendar))
        task.completed = true; XCTAssertFalse(Scheduling.isOverdue(task,now: date(2026,10,7),calendar: calendar))
    }

}

private final class DocumentUndoTextView: DocumentTextView {
    let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }
}
private final class MarkdownUndoTextView: NSTextView {
    let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }
}

extension OwnListTests {
    @MainActor func testMarkdownPreviewPreservesNoteLineBreaks() {
        let source = "- 指标名称 metric\t\n" +
            "prometheus 内置建立的规范就是叫 metric（即 __name__）。\n" +
            "指标名称以 _total 结尾。\n\n" +
            "- 服务名称 service\n服务名称需要全局唯一。\n"
        let rendered = MarkdownRenderer.shared.render(source)
        XCTAssertTrue(rendered.html.contains("指标名称 metric\t<br>\nprometheus"))
        XCTAssertTrue(rendered.html.contains("__name__）。<br>\n指标名称以 _total 结尾。"))
        XCTAssertTrue(rendered.html.contains("服务名称 service<br>\n服务名称需要全局唯一。"))
        XCTAssertEqual(rendered.html.components(separatedBy: "<li>").count - 1,2)
        XCTAssertEqual(rendered.codes,[])

        let paragraphs = MarkdownRenderer.shared.render("第一行\n第二行\n\n另一段\r\n下一行\n").html
        XCTAssertEqual(paragraphs,"<p>第一行<br>\n第二行</p>\n<p>另一段<br>\n下一行</p>\n")
        let nested = MarkdownRenderer.shared.render("- 父项\n  说明\n  - 子项\n    子项说明\n").html
        XCTAssertEqual(nested.components(separatedBy: "<ul>").count - 1,2)
        XCTAssertTrue(nested.contains("父项<br>\n说明"))
        XCTAssertTrue(nested.contains("子项<br>\n子项说明"))
        let code = "\tprint(\"第一行\")\n\tprint(\"第二行\")\n"
        let fence = MarkdownRenderer.shared.render("```python\n" + code + "```\n")
        XCTAssertEqual(fence.codes,[code])
        XCTAssertFalse(fence.html.contains("<br>"),"正文换行规则不改变代码块")
    }
    @MainActor func testMarkdownPreviewCommonMarkIdentifiersAndLayout() {
        let source = "## 标签\n\nnginx_upstream_check_module __name__ _total **粗体** _斜体_\n\n- 项目一\n  - 嵌套项\n\n| 字段 | 值 |\n| --- | --- |\n| 名称 | 中文😀 |\n"
        let html = MarkdownRenderer.shared.render(source).html
        XCTAssertTrue(html.contains("nginx_upstream_check_module __name__ _total"))
        XCTAssertTrue(html.contains("<strong>粗体</strong>"))
        XCTAssertTrue(html.contains("<em>斜体</em>"))
        XCTAssertTrue(html.contains("<table>")); XCTAssertTrue(html.contains("<h2>标签</h2>"))
        XCTAssertEqual(html.components(separatedBy: "<ul>").count - 1,2)
        let native = MarkdownDocument.parse("nginx_upstream_check_module __name__ _total **粗体** _斜体_").content
        XCTAssertEqual(native.string,"nginx_upstream_check_module __name__ _total 粗体 斜体")
    }
    @MainActor func testMarkdownCodeLanguagesHighlightAndPreserveContent() {
        XCTAssertEqual(MarkdownRenderer.shared.languages.count,192)
        let fixtures: [(String,String)] = [
            ("swift","let value = \"中文😀\"\nprint(value)\n"),
            ("python","def hello():\n    return \"中文😀\"\n"),
            ("js","const value = \"中文\";\nconsole.log(value);\n"),
            ("typescript","const value: string = \"中文\";\n"),
            ("bash","# comment\necho \"$HOME\"\n"),
            ("json","{\"name\": \"中文\", \"count\": 2}\n"),
            ("yaml","name: 中文\nenabled: true\n"),
            ("sql","SELECT name FROM users WHERE id = 2;\n"),
            ("html","<div class=\"test\">中文</div>\n"),
            ("css",".test { color: red; }\n"),
            ("go","package main\nfunc main() { println(\"中文\") }\n"),
            ("rust","fn main() { let value = 2; }\n"),
            ("java","public class Test { int value = 2; }\n"),
            ("cpp","int main() { return 2; }\n"),
            ("csharp","public class Test { string value = \"中文\"; }\n"),
            ("nginx","server { listen 80; server_name example.test; }\n"),
            ("dockerfile","FROM alpine:3.20\nRUN echo hello\n")
        ]
        for (language,code) in fixtures {
            let rendered = MarkdownRenderer.shared.render("```"+language+"\n"+code+"```\n")
            XCTAssertEqual(rendered.codes,[code],language)
            XCTAssertTrue(rendered.html.contains("class=\"hljs-"),language)
            XCTAssertTrue(rendered.html.contains("zilo-copy:0"),language)
        }
        let unknown = MarkdownRenderer.shared.render("```unknown-language\n<unsafe> & __name__\n```\n")
        XCTAssertEqual(unknown.codes,["<unsafe> & __name__\n"])
        XCTAssertTrue(unknown.html.contains("&lt;unsafe&gt; &amp; __name__"))
        XCTAssertFalse(unknown.html.contains("<unsafe>"))
    }
    @MainActor func testMarkdownPreviewEscapesHTMLAndKeepsFenceBoundaries() {
        let source = "<script>alert('unsafe')</script>\n\n![图](Attachments/Images/test.png)\n\n![远程](https://example.test/a.png)\n\n```bash\necho 中文\n### 原样保留的代码\n"
        let result = MarkdownRenderer.shared.render(source)
        XCTAssertFalse(result.html.contains("<script>"))
        XCTAssertTrue(result.html.contains("&lt;script&gt;"))
        XCTAssertTrue(result.html.contains("zilo-image://local/Attachments/Images/test.png"))
        XCTAssertFalse(result.html.contains("src=\"https://"))
        XCTAssertEqual(result.codes,["echo 中文\n### 原样保留的代码\n"])
        XCTAssertFalse(result.html.contains("<h3>"),"未闭合的代码围栏后续内容仍属于代码，不能擅自修改源文档")
        let malicious = MarkdownRenderer.shared.render("[unsafe](javascript:alert(1))\n\n![unsafe](file:///etc/passwd)").html
        XCTAssertFalse(malicious.contains("href=\"javascript:")); XCTAssertFalse(malicious.contains("src=\"file:"))
    }
    @MainActor func testPreviewImageAccessRestrictedToAttachments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Attachments/Images"),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(MarkdownRenderer.imageURL(URL(string:"zilo-image://local/Attachments/Images/test.png")!,root:root),root.appendingPathComponent("Attachments/Images/test.png"))
        XCTAssertNil(MarkdownRenderer.imageURL(URL(string:"zilo-image://local/Attachments/../../private.txt")!,root:root))
        XCTAssertNil(MarkdownRenderer.imageURL(URL(string:"zilo-image://other/Attachments/test.png")!,root:root))
        let escaped = root.appendingPathComponent("Attachments/Images/escaped")
        try FileManager.default.createSymbolicLink(at:escaped,withDestinationURL:root.deletingLastPathComponent())
        XCTAssertNil(MarkdownRenderer.imageURL(URL(string:"zilo-image://local/Attachments/Images/escaped/private.txt")!,root:root))
    }
}

extension OwnListTests {
    @MainActor private func sourceEditor(_ source: String) -> MarkdownUndoTextView {
        let editor = MarkdownUndoTextView(); editor.isRichText = false; editor.allowsUndo = true
        editor.string = source; editor.setSelectedRange(NSRange(location: source.utf16.count,length: 0))
        return editor
    }
    @MainActor func testMarkdownSourceListQuoteAndTaskContinuation() {
        for (source,expected) in [
            ("- 中文😀","- 中文😀\n- "),("* 项目","* 项目\n* "),
            ("9. 编号","9. 编号\n10. "),("4) 项目","4) 项目\n5) "),
            ("  - 子项","  - 子项\n  - "),("> 引用","> 引用\n> "),
            ("> - 项目","> - 项目\n> - "),("- [x] 完成","- [x] 完成\n- [ ] "),
            ("- ",""),("> ",""),("> > ","> "),("    - ","- "),("> - ","> ")
        ] {
            let editor = sourceEditor(source)
            XCTAssertTrue(MarkdownSourceEditing.newline(in: editor),source)
            XCTAssertEqual(editor.string,expected,source)
        }
        let split = sourceEditor("- 中文😀尾部")
        split.setSelectedRange(NSRange(location: "- 中文😀".utf16.count,length: 0))
        XCTAssertTrue(MarkdownSourceEditing.newline(in: split)); XCTAssertEqual(split.string,"- 中文😀\n- 尾部")
        let ordinary = sourceEditor("说明文字")
        XCTAssertFalse(MarkdownSourceEditing.newline(in: ordinary)); XCTAssertEqual(ordinary.string,"说明文字")
        let soft = sourceEditor("- 指标名称")
        XCTAssertTrue(MarkdownSourceEditing.handle(#selector(NSResponder.insertLineBreak(_:)),in: soft))
        XCTAssertEqual(soft.string,"- 指标名称\n")
    }
    @MainActor func testMarkdownShiftReturnWhenAppKitDispatchesInsertNewline() {
        let editor = sourceEditor("- 指标名称 metric")
        XCTAssertTrue(MarkdownSourceEditing.handle(#selector(NSResponder.insertNewline(_:)),in: editor,modifiers: [.shift]))
        XCTAssertEqual(editor.string,"- 指标名称 metric\n")
        let quote = sourceEditor("> 说明😀")
        XCTAssertTrue(MarkdownSourceEditing.handle(#selector(NSResponder.insertNewline(_:)),in: quote,modifiers: [.shift]))
        XCTAssertEqual(quote.string,"> 说明😀\n")
        let regular = sourceEditor("- 项目")
        XCTAssertTrue(MarkdownSourceEditing.handle(#selector(NSResponder.insertNewline(_:)),in: regular))
        XCTAssertEqual(regular.string,"- 项目\n- ")
    }
    @MainActor func testMarkdownSourceFenceIndentationAndMarkedText() {
        for fence in ["```python","~~~~bash"] {
            let editor = sourceEditor(fence + "\n    - literal")
            XCTAssertTrue(MarkdownSourceEditing.newline(in: editor))
            XCTAssertEqual(editor.string,fence + "\n    - literal\n    ")
            let codeTab = sourceEditor(fence + "\n    - literal")
            MarkdownSourceEditing.indent(in: codeTab,outdent: false)
            XCTAssertEqual(codeTab.string,fence + "\n    - literal\t","代码中的列表符号应保持原样")
        }
        let closed = sourceEditor("```\n- literal\n```\n- 项目")
        XCTAssertTrue(MarkdownSourceEditing.newline(in: closed)); XCTAssertTrue(closed.string.hasSuffix("\n- 项目\n- "))
        let windows = sourceEditor("```\r\n- literal\r\n```\r\n- 项目")
        XCTAssertTrue(MarkdownSourceEditing.newline(in: windows)); XCTAssertEqual(windows.string,"```\r\n- literal\r\n```\r\n- 项目\n- ")
        let composing = sourceEditor("- 已提交")
        composing.setMarkedText("候选",selectedRange: NSRange(location: 2,length: 0),replacementRange: composing.selectedRange())
        let original = composing.string
        XCTAssertFalse(MarkdownSourceEditing.handle(#selector(NSResponder.insertNewline(_:)),in: composing))
        MarkdownSourceEditing.indent(in: composing,outdent: false)
        MarkdownSourceEditing.apply(.bold,in: composing)
        XCTAssertEqual(composing.string,original)
    }
    @MainActor func testMarkdownSourceIndentSelectionUndoAndRedo() {
        let editor = sourceEditor("- 中文😀\n- 第二项\n尾部")
        let selection = NSRange(location: 2,length: "中文😀\n- 第二项\n".utf16.count)
        editor.setSelectedRange(selection)
        let before = editor.string
        editor.localUndo.beginUndoGrouping()
        MarkdownSourceEditing.indent(in: editor,outdent: false)
        editor.localUndo.endUndoGrouping()
        XCTAssertEqual(editor.string,"    - 中文😀\n    - 第二项\n尾部")
        XCTAssertEqual(editor.selectedRange().location,6)
        editor.localUndo.undo(); XCTAssertEqual(editor.string,before)
        editor.localUndo.redo(); XCTAssertEqual(editor.string,"    - 中文😀\n    - 第二项\n尾部")
        editor.setSelectedRange(NSRange(location: 0,length: "    - 中文😀\n    - 第二项\n".utf16.count))
        MarkdownSourceEditing.indent(in: editor,outdent: true); XCTAssertEqual(editor.string,before)
        let single = sourceEditor("普通正文")
        MarkdownSourceEditing.indent(in: single,outdent: false); XCTAssertEqual(single.string,"普通正文\t")
        let mixed = sourceEditor("\t第一行\n  第二行\n第三行")
        mixed.setSelectedRange(NSRange(location: 0,length: mixed.string.utf16.count))
        MarkdownSourceEditing.indent(in: mixed,outdent: true)
        XCTAssertEqual(mixed.string,"第一行\n第二行\n第三行")
        XCTAssertEqual(mixed.selectedRange(),NSRange(location: 0,length: mixed.string.utf16.count))
    }
    @MainActor func testMarkdownSourceToolbarUsesWholeLinesAndSafeCodeFences() {
        let editor = sourceEditor("前文 中文😀 后文\n第二行")
        editor.setSelectedRange(NSRange(location: 3,length: "中文😀".utf16.count))
        MarkdownSourceEditing.apply(.bullet,in: editor)
        XCTAssertEqual(editor.string,"- 前文 中文😀 后文\n第二行")
        MarkdownSourceEditing.apply(.bullet,in: editor); XCTAssertEqual(editor.string,"前文 中文😀 后文\n第二行")
        let converted = sourceEditor("- 项目一\n- 项目二")
        converted.setSelectedRange(NSRange(location: 0,length: converted.string.utf16.count))
        MarkdownSourceEditing.apply(.numbered,in: converted)
        XCTAssertEqual(converted.string,"1. 项目一\n2. 项目二")
        let inline = sourceEditor("")
        MarkdownSourceEditing.apply(.bold,in: inline)
        XCTAssertEqual(inline.string,"****"); XCTAssertEqual(inline.selectedRange().location,2)
        inline.insertText("中文😀",replacementRange: inline.selectedRange()); XCTAssertEqual(inline.string,"**中文😀**")
        inline.setSelectedRange(NSRange(location: 0,length: inline.string.utf16.count))
        MarkdownSourceEditing.apply(.bold,in: inline); XCTAssertEqual(inline.string,"中文😀")
        let code = sourceEditor("```swift\nlet value = 1\n```")
        code.setSelectedRange(NSRange(location: 0,length: code.string.utf16.count))
        let original = code.string
        MarkdownSourceEditing.apply(.codeBlock,in: code)
        XCTAssertTrue(code.string.hasPrefix("````\n"))
        XCTAssertEqual(MarkdownRenderer.shared.render(code.string).codes,[original + "\n"])
        let ticks = sourceEditor("`中文`")
        ticks.setSelectedRange(NSRange(location: 0,length: ticks.string.utf16.count))
        MarkdownSourceEditing.apply(.code,in: ticks)
        XCTAssertEqual(MarkdownRenderer.shared.render(ticks.string).html,"<p><code>`中文`</code></p>\n")
    }
    @MainActor func testMarkdownPreviewTaskListsAreReadOnlyAndEscaped() {
        let html = MarkdownRenderer.shared.render("- [ ] 未完成\n- [x] 已完成\n- \\[ ] 普通符号\n\n[x] 普通正文\n").html
        XCTAssertEqual(html.components(separatedBy: "class=\"task-checkbox\"").count - 1,2)
        XCTAssertTrue(html.contains("disabled aria-label=\"已完成\" checked"))
        XCTAssertTrue(html.contains("disabled aria-label=\"未完成\""))
        XCTAssertTrue(html.contains("[ ] 普通符号")); XCTAssertTrue(html.contains("<p>[x] 普通正文</p>"))
    }
}
