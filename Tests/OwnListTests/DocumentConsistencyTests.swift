import XCTest
import AppKit
import PDFKit
@testable import OwnList

final class DocumentConsistencyTests: XCTestCase {
    func testThemesMaintainReadableNavigationAndContentInBothAppearances() {
        func contrast(_ a: UInt32,_ b: UInt32) -> Double {
            let first = AppTheme.luminance(a), second = AppTheme.luminance(b)
            return (max(first,second) + 0.05) / (min(first,second) + 0.05)
        }
        for theme in AppTheme.all {
            for dark in [false,true] {
                XCTAssertGreaterThanOrEqual(contrast(theme.value("railForeground",dark: dark),theme.value("rail",dark: dark)),3,"Navigation: \(theme.id), dark=\(dark)")
                for surface in ["canvas","sidebar","input","selection","hover"] {
                    XCTAssertGreaterThanOrEqual(contrast(theme.value("text",dark: dark),theme.value(surface,dark: dark)),4.5,"Text on \(surface): \(theme.id), dark=\(dark)")
                }
                XCTAssertGreaterThanOrEqual(contrast(theme.value("accent",dark: dark),theme.value("canvas",dark: dark)),4.5,"Accent: \(theme.id), dark=\(dark)")
            }
        }
    }
    func testThemeChangesMultipleSurfacesAndPreservesExistingChoices() {
        let blue = AppTheme.resolve("blue"), green = AppTheme.resolve("green")
        for surface in ["rail","sidebar","selection","hover","input","accent"] {
            XCTAssertNotEqual(blue.value(surface,dark: false),green.value(surface,dark: false),surface)
        }
        for legacy in ["blue","green","orange","yellow","purple","red","pink"] {
            XCTAssertEqual(AppTheme.resolve(legacy).id,legacy)
        }
        XCTAssertEqual(AppTheme.resolve("unknown").id,"blue")
        XCTAssertTrue(AppTheme.resolve("night").forcesDark)
        let before = NSColor("green".listColor).usingColorSpace(.sRGB)
        let previous = UserDefaults.standard.object(forKey: "accent")
        defer { if let previous { UserDefaults.standard.set(previous,forKey: "accent") } else { UserDefaults.standard.removeObject(forKey: "accent") } }
        UserDefaults.standard.set("gray",forKey: "accent")
        let after = NSColor("green".listColor).usingColorSpace(.sRGB)
        XCTAssertEqual(before,after,"List colors must not be changed by application themes")
    }

    @MainActor func testTaskDropFeedbackClearsOnSessionEndAndIgnoresLateUpdates() {
        // Session end must work even when SwiftUI never sends dropExited/performDrop.
        let feedback = TaskDragFeedback(), target = UUID()
        feedback.begin(session: 10)
        feedback.hover(target: target,position: .child)
        XCTAssertEqual(feedback.state?.target,target)
        feedback.end(session: 10)
        XCTAssertNil(feedback.state)
        feedback.hover(target: target,position: .child)
        XCTAssertNil(feedback.state,"Late hover callbacks must not resurrect a finished drag")
        feedback.begin(session: 11)
        XCTAssertNil(feedback.state?.target,"A new drag must not reuse the old target")
        feedback.hover(target: target,position: .after)
        feedback.end(session: 10)
        XCTAssertEqual(feedback.state?.target,target,"An old session must not clear the current drag")
        feedback.end(session: 11)
        XCTAssertNil(feedback.state)
    }
    @MainActor func testTaskDropFeedbackExitFromPreviousRowDoesNotClearNewTarget() {
        let feedback = TaskDragFeedback(), first = UUID(), second = UUID()
        feedback.begin(session: 20)
        feedback.hover(target: first,position: .child)
        feedback.hover(target: second,position: .before)
        feedback.exit(target: first)
        XCTAssertEqual(feedback.state?.target,second)
        feedback.exit(target: second)
        XCTAssertNil(feedback.state?.target)
        XCTAssertEqual(feedback.state?.session,20)
        feedback.end(session: 20)
        XCTAssertNil(feedback.state)
    }
    func testCodeLanguageChangingFencePreservesCodeAndOtherBlocks() throws {
        let source = "前文\r\n```swift\r\nlet value = \"中文🙂\"\r\n\tprint(value)\r\n```\r\n\r\n```mermaid\r\nmindmap\r\n  root\r\n```\r\n\r\n> ~~~python\r\n> print('hello')\r\n> ~~~\r\n"
        let first = try XCTUnwrap(CodeLanguage.replacing(source,index: 0,language: "python"))
        XCTAssertEqual(first,source.replacingOccurrences(of:"```swift",with:"```python"))
        let second = try XCTUnwrap(CodeLanguage.replacing(source,index: 1,language: "javascript"))
        XCTAssertEqual(second,source.replacingOccurrences(of:"~~~python",with:"~~~javascript"))
        XCTAssertNil(CodeLanguage.replacing(source,index: 2,language: "swift"))
        XCTAssertNil(CodeLanguage.replacing(source,index: 0,language: "not-a-language"))
        XCTAssertTrue(MarkdownRenderer.shared.render(first).html.contains("zilo-language:0"))
    }
    @MainActor func testRichCodeLanguageMenuPreservesCodeAndUndo() throws {
        let code = "\tlet value = \"中文🙂\"\n\nprint(value)\n"
        let content = CodeLanguage.richBlock(code: code,language: "swift")
        let block = try XCTUnwrap(DocumentStyle.metadata(content.attributes(at: 0,effectiveRange: nil))["block"])
        let editor = LanguageUndoTextView(); editor.isRichText = true; editor.allowsUndo = true
        editor.textStorage?.setAttributedString(content)
        editor.localUndo.beginUndoGrouping()
        XCTAssertTrue(CodeLanguage.changeRichBlock(block,language: "python",in: editor))
        editor.localUndo.endUndoGrouping()
        XCTAssertTrue(editor.string.hasPrefix("Python\n"))
        let markdown = MarkdownDocument.export(try XCTUnwrap(editor.textStorage),assets: "images").text
        XCTAssertTrue(markdown.contains("```python\n" + code + "```"))
        XCTAssertFalse(markdown.contains("Python\n\tlet"))
        editor.localUndo.undo()
        XCTAssertEqual(editor.string,content.string)
        XCTAssertEqual(DocumentStyle.metadata(try XCTUnwrap(editor.textStorage).attributes(at: 0,effectiveRange: nil))["language"],"swift")
        let legacy = NSAttributedString(string: code,attributes: MarkdownTyping.codeBlockAttributes)
        let upgraded = CodeLanguage.decorateLegacyBlocks(legacy)
        XCTAssertTrue(upgraded.string.contains(code))
        XCTAssertEqual(CodeLanguage.decorateLegacyBlocks(upgraded).string,upgraded.string)
    }
    func testSmartListVisibilityDefaultsAndRoundTrip() {
        for raw in ["","invalid","[]"] {
            let preferences = SmartListPreferences(rawValue: raw)
            XCTAssertTrue(preferences.isVisible("today",count: 0))
            XCTAssertTrue(preferences.isVisible("inbox",count: 0))
            XCTAssertFalse(preferences.isVisible("all",count: 100))
            XCTAssertFalse(preferences.isVisible("archived",count: 100))
        }
        var preferences = SmartListPreferences(rawValue: "")
        preferences = SmartListPreferences(rawValue: preferences.updating("completed",to: .whenNotEmpty))
        XCTAssertFalse(preferences.isVisible("completed",count: 0))
        XCTAssertTrue(preferences.isVisible("completed",count: 2))
        preferences = SmartListPreferences(rawValue: preferences.updating("inbox",to: .hide))
        preferences = SmartListPreferences(rawValue: preferences.updating("all",to: .show))
        XCTAssertFalse(preferences.isVisible("inbox",count: 2))
        XCTAssertTrue(preferences.isVisible("all",count: 0))
        XCTAssertEqual(preferences.visibility(for: "completed"),.whenNotEmpty)
        XCTAssertEqual(SmartListPreferences(rawValue: "{\"today\":\"future-value\"}").visibility(for: "today"),.show)
    }
    @MainActor func testTaskNameEditingCommitsOnlyOnBlurAndCancelsSafely() {
        _ = NSApplication.shared
        var commits: [String?] = []
        var began = 0
        let view = TaskNameField(title: "原任务",completed: false,fontSize: 14,requestFocus: false,
            onBegin: { began += 1 },onEnd: { commits.append($0) })
        let coordinator = view.makeCoordinator()
        let field = TaskNameTextField(); field.stringValue = "原任务"
        let begin = Notification(name: NSControl.textDidBeginEditingNotification,object: field)
        let end = Notification(name: NSControl.textDidEndEditingNotification,object: field)
        coordinator.controlTextDidBeginEditing(begin)
        field.stringValue = "中文修改🙂"
        XCTAssertTrue(commits.isEmpty)
        coordinator.controlTextDidEndEditing(end)
        XCTAssertEqual(commits.compactMap { $0 },["中文修改🙂"])
        XCTAssertEqual(began,1)
        coordinator.controlTextDidEndEditing(end)
        XCTAssertEqual(commits.count,1)

        coordinator.controlTextDidBeginEditing(begin)
        field.stringValue = "未保存"
        let editor = NSTextView()
        XCTAssertTrue(coordinator.control(field,textView: editor,doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        coordinator.controlTextDidEndEditing(end)
        XCTAssertNil(commits.last!)
        XCTAssertEqual(field.stringValue,"中文修改🙂")

        coordinator.controlTextDidBeginEditing(begin)
        field.stringValue = "  "
        coordinator.controlTextDidEndEditing(end)
        XCTAssertNil(commits.last!)
        XCTAssertEqual(field.stringValue,"中文修改🙂")
        editor.setMarkedText("拼音",selectedRange: NSRange(location: 2,length: 0),replacementRange: NSRange(location: NSNotFound,length: 0))
        XCTAssertFalse(coordinator.control(field,textView: editor,doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }
    func testLinkAddressValidationAndOptionalLabel() throws {
        let url = try XCTUnwrap(DocumentLink.url("  https://luchuangao.github.io/\n"))
        XCTAssertEqual(DocumentLink.title("",url: url),"https://luchuangao.github.io/")
        XCTAssertEqual(DocumentLink.title(" 个人网站 ",url: url),"个人网站")
        for value in ["个人网站","https://","","javascript:alert(1)","https://example.com/a b"] { XCTAssertNil(DocumentLink.url(value)) }
        XCTAssertNotNil(DocumentLink.url("mailto:test@example.com"))
    }
    @MainActor func testLinkInsertionReplacesSelectionInBothDocumentModes() throws {
        _ = NSApplication.shared
        for rich in [false,true] {
            let editor = NSTextView(); editor.isRichText = rich; editor.string = "前面网站后面"
            editor.setSelectedRange(NSRange(location:2,length:2))
            let controller = DocumentEditorController(); controller.editor = editor; controller.rich = rich
            let url = try XCTUnwrap(DocumentLink.url("https://example.com/path(a)"))
            controller.insertLink(title:"个人[网站]",url:url)
            if rich {
                XCTAssertEqual(editor.string,"前面个人[网站]后面")
                XCTAssertEqual(editor.textStorage?.attribute(.link,at:2,effectiveRange:nil) as? URL,url)
            } else {
                XCTAssertEqual(editor.string,"前面[个人\\[网站\\]](https://example.com/path%28a%29)后面")
                let rendered = MarkdownRenderer.shared.render(editor.string).html
                XCTAssertTrue(rendered.contains("<a href=")); XCTAssertTrue(rendered.contains("个人[网站]"))
            }
        }
    }
    func testSubtaskHierarchyExpansionCompletionAndDeletion() {
        var parent = TaskItem(); parent.title = "父任务"
        var child = TaskItem(); child.parentID = parent.id; child.completed = true
        var nested = TaskItem(); nested.parentID = child.id
        var removed = TaskItem(); removed.parentID = parent.id; removed.deleted = true
        let tasks = [parent,child,nested,removed]
        let rows = TaskHierarchy.rows(root:parent,tasks:tasks,collapsed:[])
        XCTAssertEqual(rows.map(\.id),[parent.id,child.id,nested.id])
        XCTAssertEqual(rows.map(\.depth),[0,1,2])
        XCTAssertEqual(TaskHierarchy.rows(root:parent,tasks:tasks,collapsed:[parent.id]).map(\.id),[parent.id])
        XCTAssertEqual(TaskHierarchy.rows(root:parent,tasks:tasks,collapsed:[child.id]).map(\.id),[parent.id,child.id])
        parent.parentID = nested.id
        XCTAssertEqual(TaskHierarchy.rows(root:parent,tasks:[parent,child,nested],collapsed:[]).count,3)
    }
    func testMatrixGroupingAndVisibility() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year:2026,month:3,day:8,hour:12))!
        var task = TaskItem()
        XCTAssertEqual(TaskMatrix.index(task,now:now,calendar:calendar),3)
        XCTAssertEqual(TaskMatrix.group(task,now:now,calendar:calendar),.undated)
        task.priority = 2
        XCTAssertEqual(TaskMatrix.index(task,now:now,calendar:calendar),1)
        task.due = calendar.date(bySettingHour:23,minute:59,second:0,of:now)
        XCTAssertEqual(TaskMatrix.index(task,now:now,calendar:calendar),0)
        XCTAssertEqual(TaskMatrix.group(task,now:now,calendar:calendar),.today)
        task.due = calendar.date(byAdding:.day,value:1,to:calendar.startOfDay(for:now))
        XCTAssertEqual(TaskMatrix.index(task,now:now,calendar:calendar),1)
        task.due = now.addingTimeInterval(-3600); task.allDay = false
        XCTAssertEqual(TaskMatrix.group(task,now:now,calendar:calendar),.overdue)
        task.completed = true
        XCTAssertEqual(TaskMatrix.group(task,now:now,calendar:calendar),.completed)
        XCTAssertTrue(TaskMatrix.isVisible(task))
        task.archived = true; XCTAssertFalse(TaskMatrix.isVisible(task))
        task.archived = false; task.parentID = UUID(); XCTAssertFalse(TaskMatrix.isVisible(task))
        task.parentID = nil; task.deleted = true; XCTAssertFalse(TaskMatrix.isVisible(task))
        task.deleted = false; task.isTemplate = true; XCTAssertFalse(TaskMatrix.isVisible(task))
    }
    func testMatrixDragPreservesDatesAndScheduling() {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:"Asia/Shanghai")!
        let now = calendar.date(from:DateComponents(year:2026,month:10,day:10,hour:10))!
        var task = TaskItem(); task.priority = 3; task.allDay = false
        task.due = calendar.date(byAdding:.day,value:3,to:now)
        task.start = task.due!.addingTimeInterval(-7200); task.reminders = [-600,0]
        let due = task.due; let start = task.start
        TaskMatrix.move(&task,to:3,now:now,calendar:calendar)
        XCTAssertEqual(task.due,due); XCTAssertEqual(task.start,start); XCTAssertEqual(task.priority,0)
        TaskMatrix.move(&task,to:2,now:now,calendar:calendar)
        XCTAssertEqual(TaskMatrix.index(task,now:now,calendar:calendar),2)
        XCTAssertEqual(task.due!.timeIntervalSince(task.start!),7200)
        XCTAssertEqual(calendar.component(.hour,from:task.due!),10)
        XCTAssertEqual(task.reminders,[-600,0]); XCTAssertEqual(task.repeatRule.anchor,task.due)
        let urgentDue = task.due
        TaskMatrix.move(&task,to:0,now:now,calendar:calendar)
        XCTAssertEqual(task.due,urgentDue); XCTAssertEqual(task.priority,2)
        TaskMatrix.move(&task,to:1,now:now,calendar:calendar)
        XCTAssertEqual(TaskMatrix.index(task,now:now,calendar:calendar),1)
        XCTAssertEqual(task.due!.timeIntervalSince(task.start!),7200)
        var undated = TaskItem()
        TaskMatrix.move(&undated,to:1,now:now,calendar:calendar)
        XCTAssertNil(undated.due)
    }
    @MainActor func testTaskDragTreeMoveAndUndo() throws {
        let store = Store(persistence: Persistence(inMemory:true))
        let first = TaskList(name:"原清单"), second = TaskList(name:"目标清单")
        store.save(first); store.save(second)
        let parent = try XCTUnwrap(store.add("父任务",listID:first.id))
        let child = try XCTUnwrap(store.add("子任务",listID:first.id,parentID:parent))
        let nested = try XCTUnwrap(store.add("孙任务",listID:first.id,parentID:child))
        let target = try XCTUnwrap(store.add("目标",listID:second.id))
        store.mutate(target) { $0.section = "分组" }
        store.mutate(child) { $0.due = Date(timeIntervalSince1970:123456); $0.notes = "保留内容" }
        let before = store.tasks
        XCTAssertFalse(store.placeTask(parent,relativeTo:nested,position:.child))
        XCTAssertFalse(store.placeTask(parent,relativeTo:parent,position:.after))
        XCTAssertEqual(store.tasks,before)
        XCTAssertTrue(store.placeTask(parent,relativeTo:target,position:.child))
        XCTAssertEqual(store.tasks.first { $0.id == parent }?.parentID,target)
        for id in [parent,child,nested] {
            XCTAssertEqual(store.tasks.first { $0.id == id }?.listID,second.id)
            XCTAssertEqual(store.tasks.first { $0.id == id }?.section,"分组")
        }
        XCTAssertEqual(store.tasks.first { $0.id == child }?.notes,"保留内容")
        XCTAssertEqual(store.tasks.first { $0.id == child }?.due,Date(timeIntervalSince1970:123456))
        store.undo(); XCTAssertEqual(Set(store.tasks),Set(before))
        store.redo(); XCTAssertEqual(store.tasks.first { $0.id == parent }?.parentID,target)
        XCTAssertTrue(store.placeTask(child,relativeTo:target,position:.after))
        XCTAssertNil(store.tasks.first { $0.id == child }?.parentID)
        XCTAssertEqual(store.tasks.first { $0.id == nested }?.parentID,child)
        XCTAssertTrue(store.moveTaskTree(parent,to:first.id))
        XCTAssertNil(store.tasks.first { $0.id == parent }?.parentID)
    }
    func testTaskDragBeforeAfterAndImportedCycle() throws {
        var a = TaskItem(), b = TaskItem(), c = TaskItem(); a.order = 0; b.order = 1; c.order = 2
        func apply(_ changed: [TaskItem],to tasks: [TaskItem]) -> [TaskItem] { let map = Dictionary(uniqueKeysWithValues:changed.map { ($0.id,$0) }); return tasks.map { map[$0.id] ?? $0 } }
        let original = [a,b,c]
        let moved = apply(try XCTUnwrap(TaskPlacement.changes(original,source:c.id,target:a.id,position:.before)),to:original)
        XCTAssertEqual(moved.sorted { $0.order < $1.order }.map(\.id),[c.id,a.id,b.id])
        let again = apply(try XCTUnwrap(TaskPlacement.changes(moved,source:c.id,target:b.id,position:.after)),to:moved)
        XCTAssertEqual(again.sorted { $0.order < $1.order }.map(\.id),[a.id,b.id,c.id])
        a.parentID = b.id; b.parentID = a.id
        XCTAssertNil(TaskPlacement.changes([a,b,c],source:c.id,target:a.id,position:.child))
    }
    @MainActor func testListDragBetweenFoldersAndUndo() throws {
        let store = Store(persistence:Persistence(inMemory:true))
        var a = TaskList(name:"A",order:0), b = TaskList(name:"B",order:1), c = TaskList(name:"C",order:2)
        b.folder = "文件夹"; c.folder = "文件夹"
        store.save(a); store.save(b); store.save(c)
        XCTAssertTrue(store.placeList(a.id,relativeTo:c.id,after:true))
        XCTAssertEqual(store.lists.first { $0.id == a.id }?.folder,"文件夹")
        XCTAssertEqual(store.lists.filter { $0.folder == "文件夹" }.sorted { $0.order < $1.order }.map(\.id),[b.id,c.id,a.id])
        store.undo(); XCTAssertEqual(store.lists.first { $0.id == a.id }?.folder,"")
        store.redo(); XCTAssertTrue(store.placeList(a.id,folder:""))
        XCTAssertEqual(store.lists.first { $0.id == a.id }?.folder,"")
    }
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

private final class LanguageUndoTextView: NSTextView {
    let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }
}
