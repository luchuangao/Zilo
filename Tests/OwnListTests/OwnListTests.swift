import XCTest
import AppKit
import PDFKit
@testable import OwnList

final class OwnListTests: XCTestCase {
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
        XCTAssertEqual(color,NSColor.black)
        task.notes = Array(repeating: "长正文打印验收",count: 100).joined(separator: "\n")
        XCTAssertGreaterThan(TaskPrintDocument.makeView(task: task).frame.height,1000)
    }
    @MainActor func testDocumentFormattingPreservesUnicodeSelectionAndSurroundingText() {
        let editor = NSTextView()
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
