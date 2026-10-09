import XCTest
import AppKit
import PDFKit
@testable import OwnList

final class DocumentConsistencyTests: XCTestCase {
    static let fixture = """
    ## 换行与缩进
    - 指标名称 metric
      说明单独显示在下一行。
      - 嵌套事项
        子项说明也保留换行。

    ## 任务列表
    - [ ] 未完成事项
    - [x] 已完成事项

    ## 代码高亮
    ```python
    # 保留缩进与中文
    for name in ["Zilo", "中文 🙂"]:
        print(name)
    ```

    > 引用支持续写，也支持只换行。
    > 第二行说明。

    | 操作 | 结果 |
    | --- | --- |
    | 回车 | 列表续写 |
    | Shift + 回车 | 同一项内换行 |
    | Tab / Shift + Tab | 缩进 / 减少缩进 |

    ```mermaid
    mindmap
      文档规划
        内容
          Markdown
          富文本
        导出
          Word
          PDF
    ```
    """
    @MainActor func testSharedParserKeepsSoftBreaksNestedListsAndTaskMarkers() throws {
        let document = MarkdownDocument.parse(Self.fixture).content
        XCTAssertTrue(document.string.contains("指标名称 metric\u{2028}说明单独显示在下一行。"))
        let child = (document.string as NSString).range(of:"嵌套事项").location
        XCTAssertEqual(DocumentStyle.metadata(document.attributes(at:child,effectiveRange:nil))["listDepth"],"1")
        XCTAssertTrue(document.string.contains("☐ 未完成事项")); XCTAssertTrue(document.string.contains("☑ 已完成事项"))
        let stored = try XCTUnwrap(RichDocument.decode(XCTUnwrap(RichDocument.encode(document))))
        XCTAssertEqual(stored.string,document.string)
        let heading = (stored.string as NSString).range(of:"换行与缩进").location
        XCTAssertTrue((stored.attribute(.paragraphStyle,at:heading,effectiveRange:nil) as? NSParagraphStyle)?.textBlocks.isEmpty ?? false,"标题不能存成表格单元格")
        XCTAssertEqual(DocumentStyle.metadata(stored.attributes(at:child,effectiveRange:nil))["listDepth"],"1")
    }
    @MainActor func testConversionKeepsTableLanguagesCheckboxesAndMindmapAfterEditingAndReload() throws {
        var task = TaskItem(); task.documentMode = .markdown; task.notes = Self.fixture
        TaskDocument.switchMode(&task,to:.richText)
        let rich = try XCTUnwrap(RichDocument.decode(XCTUnwrap(task.richText)))
        let editable = NSMutableAttributedString(attributedString:rich)
        let label = (editable.string as NSString).range(of:"列表续写"); editable.replaceCharacters(in:label,with:"自动续写")
        task.richText = RichDocument.encode(editable); task.notes = editable.string
        TaskDocument.switchMode(&task,to:.markdown)
        XCTAssertTrue(task.notes.contains("```python")); XCTAssertTrue(task.notes.contains("- [ ] 未完成事项")); XCTAssertTrue(task.notes.contains("- [x] 已完成事项"))
        XCTAssertTrue(task.notes.contains("| 操作 | 结果 |")); XCTAssertTrue(task.notes.contains("自动续写")); XCTAssertTrue(task.notes.contains("```mermaid"))
        let html = MarkdownRenderer.shared.render(task.notes).html
        XCTAssertTrue(html.contains("<table>")); XCTAssertTrue(html.contains("task-checkbox")); XCTAssertTrue(html.contains("<svg")); XCTAssertTrue(html.contains("hljs-keyword"))
    }
    @MainActor func testCodeHighlightColorsAndTableCellsSurviveRichTextPersistence() throws {
        let source = MarkdownDocument.parse(Self.fixture).content
        let rich = try XCTUnwrap(RichDocument.decode(XCTUnwrap(RichDocument.encode(source))))
        let code = (rich.string as NSString).range(of:"for name").location
        XCTAssertEqual(DocumentStyle.metadata(rich.attributes(at:code,effectiveRange:nil))["language"],"python")
        XCTAssertEqual(try XCTUnwrap((rich.attribute(.foregroundColor,at:code,effectiveRange:nil) as? NSColor)?.usingColorSpace(.sRGB)?.redComponent),CGFloat(166)/255,accuracy:0.01)
        let cell = (rich.string as NSString).range(of:"操作").location
        XCTAssertEqual(DocumentStyle.metadata(rich.attributes(at:cell,effectiveRange:nil))["kind"],"table")
        XCTAssertFalse((rich.attribute(.paragraphStyle,at:cell,effectiveRange:nil) as? NSParagraphStyle)?.textBlocks.isEmpty ?? true)
    }
    @MainActor func testWordAndPDFExportPreserveRichAndMarkdownDocumentStructure() throws {
        let folder = ProcessInfo.processInfo.environment["OWNLIST_CONSISTENCY_QA_DIR"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var task = TaskItem(); task.title = "文档一致性验收"; task.documentMode = .markdown; task.notes = Self.fixture
        try Self.fixture.write(to:folder.appendingPathComponent("验收样例.md"),atomically:true,encoding:.utf8)
        for mode in [DocumentEditingMode.markdown,.richText] {
            if mode == .richText { TaskDocument.switchMode(&task,to:.richText) }
            let name = mode == .markdown ? "Markdown":"富文本"
            for format in [DocumentExport.Format.word,.pdf,.markdown] { try DocumentExport.write(task:task,children:[],format:format,to:folder.appendingPathComponent(name+"."+format.rawValue)) }
            let word = try Data(contentsOf:folder.appendingPathComponent(name+".docx")); let bytes = String(decoding:word,as:UTF8.self)
            XCTAssertTrue(bytes.contains("<w:tbl>")); XCTAssertTrue(bytes.contains("<w:br/>")); XCTAssertTrue(bytes.contains("w:hanging=")); XCTAssertTrue(bytes.contains("A626A4")); XCTAssertTrue(bytes.contains("267B42")); XCTAssertTrue(bytes.contains("Apple Color Emoji")); XCTAssertTrue(bytes.contains("☑")); XCTAssertTrue(bytes.contains("word/media/image1.png"))
            let pdf = try XCTUnwrap(PDFDocument(url:folder.appendingPathComponent(name+".pdf")))
            let plain = (pdf.string ?? "").precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
            XCTAssertTrue(plain.contains("减少缩进")); XCTAssertTrue(plain.contains("未完成事项")); XCTAssertTrue(plain.contains("print(name)"))
        }
    }
    @MainActor func testEditedCheckboxAndCodeLabelNeverLoseTextOnMarkdownExport() {
        let rich = NSMutableAttributedString(attributedString:MarkdownDocument.parse("- [ ] 事项\n\n```python\nprint(1)\n```").content)
        rich.replaceCharacters(in:(rich.string as NSString).range(of:"☐"),with:"☑")
        rich.replaceCharacters(in:(rich.string as NSString).range(of:"Python"),with:"补充说明")
        let md = MarkdownDocument.export(rich,assets:"images").text
        XCTAssertTrue(md.contains("- [x] 事项")); XCTAssertFalse(md.contains("- [x] ☑")); XCTAssertTrue(md.contains("补充说明")); XCTAssertTrue(md.contains("```python"))
    }
    @MainActor func testInvalidMindmapKeepsEditableSourceAcrossModeSwitch() {
        let original = "mindmap\n  主题\n  另一主题"
        let rich = MarkdownDocument.parse("```mermaid\n"+original+"\n```")
        XCTAssertFalse(rich.warnings.isEmpty)
        let md = MarkdownDocument.export(rich.content,assets:"images").text
        XCTAssertTrue(md.contains("```mermaid")); XCTAssertTrue(md.contains(original))
    }
    @MainActor func testMindmapHierarchyEscapingAndReeditableRichAttachment() throws {
        let diagram = try MindMapDocument.parse("mindmap\n  root((中心主题))\n    分支 A\n      <script>alert(1)</script>\n    分支 B🙂")
        XCTAssertEqual(diagram.nodes.map(\.parent),[nil,0,1,0]); XCTAssertEqual(diagram.nodes[0].title,"中心主题")
        let svg = MindMapDocument.svg(diagram); XCTAssertFalse(svg.contains("<script>")); XCTAssertTrue(svg.contains("&lt;script&gt;"))
        let rich = try XCTUnwrap(RichDocument.decode(XCTUnwrap(RichDocument.encode(try MindMapDocument.attachment(diagram.source)))))
        XCTAssertTrue(RichDocument.hasImages(rich)); XCTAssertEqual(DocumentStyle.metadata(rich.attributes(at:0,effectiveRange:nil))["source"],diagram.source)
        XCTAssertTrue(MarkdownDocument.export(rich,assets:"images").text.contains("root((中心主题))"))
        XCTAssertThrowsError(try MindMapDocument.parse("中心\n另一中心")); XCTAssertThrowsError(try MindMapDocument.parse("mindmap\n  中心\n    ::icon(fa fa-book)"))
        for node in diagram.nodes { XCTAssertGreaterThanOrEqual(node.rect.minX,0); XCTAssertLessThanOrEqual(node.rect.maxX,diagram.size.width); XCTAssertLessThanOrEqual(node.rect.maxY,diagram.size.height) }
        if let folder = ProcessInfo.processInfo.environment["OWNLIST_CONSISTENCY_QA_DIR"] { try FileManager.default.createDirectory(at:URL(fileURLWithPath:folder),withIntermediateDirectories:true); try XCTUnwrap(MindMapDocument.png(diagram)).write(to:URL(fileURLWithPath:folder).appendingPathComponent("思维导图.png")) }
    }
}
