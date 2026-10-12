import XCTest
import SwiftUI
import UIKit
@testable import Zilo

final class MobileStoreTests: XCTestCase {
    func testEditingTitlePreservesMacDocumentMetadata() async throws {
        try await MainActor.run {
            let p = Persistence(inMemory: true); let store = MobileStore(persistence: p)
            var task = TaskItem(); task.title = "Mac 任务"; task.notes = "中文与链接"; task.richText = Data([1,2,3]); task.documentMode = .richText
            task.checks = [CheckItem(title: "检查")]; task.attachments = [Attachment(name: "image.png",relativePath: "Attachments/a.png")]; task.repeatRule.frequency = "weekly"; task.repeatRule.interval = 2; task.sourceID = "original"
            XCTAssertTrue(store.save(task)); store.mutate(task.id) { $0.title = "iPhone 修改" }
            let actual = try XCTUnwrap(p.load(TaskItem.self).first)
            var expected = task; expected.title = "iPhone 修改"; XCTAssertEqual(actual,expected)
        }
    }
    func testRepeatingParentClonesEntireSubtree() async throws {
        try await MainActor.run {
            let store = MobileStore(persistence: Persistence(inMemory: true))
            var root = TaskItem(); root.title = "每天"; root.due = Day.date("2026-10-11"); root.repeatRule.frequency = "daily"; root.repeatRule.remainingCount = 3
            var child = TaskItem(); child.title = "子任务"; child.parentID = root.id; child.due = root.due; child.checks = [CheckItem(title: "检查")]
            var grandchild = TaskItem(); grandchild.title = "孙任务"; grandchild.parentID = child.id
            XCTAssertTrue(store.save(root)); XCTAssertTrue(store.save(child)); XCTAssertTrue(store.save(grandchild)); store.complete(root.id)
            XCTAssertEqual(store.tasks.count,6)
            let copy = try XCTUnwrap(store.tasks.first { $0.id != root.id && $0.parentID == nil })
            XCTAssertFalse(copy.completed); XCTAssertEqual(copy.repeatRule.remainingCount,2); XCTAssertEqual(Day.key(copy.due!),"2026-10-12")
            let childCopy = try XCTUnwrap(store.tasks.first { $0.parentID == copy.id })
            XCTAssertEqual(Day.key(childCopy.due!),"2026-10-12"); XCTAssertFalse(childCopy.checks[0].done)
            XCTAssertEqual(store.tasks.filter { $0.parentID == childCopy.id }.count,1)
            XCTAssertTrue(store.tasks.first { $0.id == grandchild.id }!.completed)
        }
    }
    func testRestoreParentRetainsChildLinksAndPreviouslyDeletedChildren() async {
        await MainActor.run {
            let store = MobileStore(persistence: Persistence(inMemory: true))
            var root = TaskItem(); root.title = "父任务"
            var child = TaskItem(); child.parentID = root.id; child.title = "子任务"
            var grand = TaskItem(); grand.parentID = child.id
            var older = TaskItem(); older.parentID = root.id; older.deleted = true
            for item in [root,child,grand,older] { XCTAssertTrue(store.save(item)) }
            store.trash(root.id); XCTAssertTrue(store.tasks.first { $0.id == grand.id }!.deleted)
            store.restore(root.id)
            XCTAssertEqual(store.tasks.first { $0.id == child.id }!.parentID,root.id)
            XCTAssertEqual(store.tasks.first { $0.id == grand.id }!.parentID,child.id)
            XCTAssertFalse(store.tasks.first { $0.id == grand.id }!.deleted)
            XCTAssertTrue(store.tasks.first { $0.id == older.id }!.deleted)
        }
    }
    func testMoveRejectsCyclesAndMovesListForAllDescendants() async throws {
        await MainActor.run {
            let store = MobileStore(persistence: Persistence(inMemory: true))
            let list = TaskList(name: "工作"); var parent = TaskItem(); parent.listID = list.id
            var child = TaskItem(); child.parentID = parent.id; child.listID = list.id
            var target = TaskItem(); target.listID = UUID()
            for task in [parent,child,target] { XCTAssertTrue(store.save(task)) }
            store.place(parent.id,child.id,.child); XCTAssertNil(store.tasks.first { $0.id == parent.id }!.parentID)
            store.place(parent.id,target.id,.child)
            XCTAssertEqual(store.tasks.first { $0.id == parent.id }!.parentID,target.id)
            XCTAssertEqual(store.tasks.first { $0.id == child.id }!.listID,target.listID)
        }
    }
    func testBackupRoundTripIncludesSubscriptionsAndAttachmentsAndMergeRetainsOtherTasks() async throws {
        try await MainActor.run {
            let a = MobileStore(persistence: Persistence(inMemory: true))
            var task = TaskItem(); task.title = "备份"; task.richText = Data(repeating: 9,count: 110_000)
            task.attachments = [Attachment(name: "中文.png",relativePath: "Attachments/example.png")]
            let image = Data([1,3,5]); try FileManager.default.createDirectory(at: a.persistence.root.appendingPathComponent("Attachments"),withIntermediateDirectories: true)
            try image.write(to: a.persistence.root.appendingPathComponent("Attachments/example.png")); try a.persistence.saveBlob(path: "Attachments/example.png",data: image)
            XCTAssertTrue(a.save(task)); XCTAssertTrue(a.save(CalendarSubscription(name: "订阅",url: "https://example.com/calendar.ics")))
            var day = Countdown(); day.name = "生日"; XCTAssertTrue(a.save(day)); XCTAssertTrue(a.save(Habit(name: "阅读")))
            let url = try a.exportBackup(); let decoded = try JSONDecoder().decode(Backup.self,from: Data(contentsOf: url)); XCTAssertEqual(decoded.subscriptions.count,1); XCTAssertEqual(decoded.tasks.first?.richText,task.richText)
            let b = MobileStore(persistence: Persistence(inMemory: true)); var other = TaskItem(); other.title = "保留"; XCTAssertTrue(b.save(other)); try b.importBackup(url)
            XCTAssertEqual(b.tasks.count,2); XCTAssertEqual(b.subscriptions.count,1); XCTAssertEqual(b.countdowns.count,1); XCTAssertEqual(b.habits.count,1)
            XCTAssertEqual(try Data(contentsOf: b.persistence.root.appendingPathComponent("Attachments/example.png")),image)
        }
    }
    func testBackupRejectsAttachmentTraversal() async throws {
        try await MainActor.run {
            let store = MobileStore(persistence: Persistence(inMemory: true))
            let backup = Backup(tasks: [],lists: [],filters: [],habits: [],focus: [],subscriptions: [],attachmentFiles: ["Attachments/../../escape":Data([1])])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"); try JSONEncoder().encode(backup).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertThrowsError(try store.importBackup(url)); XCTAssertTrue(store.tasks.isEmpty)
        }
    }
    func testOfflineMarkdownAndMindMapRenderEscapesHTMLAndPreservesChinese() throws {
        let result = MarkdownRenderer.shared.render("# 中文\n<script>alert(1)</script>\n```swift\nlet x = \"中文\"\n```\n```mermaid\nmindmap\n  中心\n    子主题\n```")
        XCTAssertTrue(result.html.contains("&lt;script&gt;")); XCTAssertFalse(result.html.contains("<script>")); XCTAssertTrue(result.html.contains("hljs-keyword")); XCTAssertTrue(result.html.contains("思维导图")); XCTAssertTrue(result.html.contains("子主题"))
    }
}

extension MobileStoreTests {
    @MainActor func testInlineMarkdownPreviewReportsHeightAndShrinksAfterEditing() async throws {
        let large = expectation(description: "Long document height")
        let small = expectation(description: "Short document height")
        var phase = 0
        var largeReported = false; var smallReported = false
        let root = FileManager.default.temporaryDirectory
        let report: (CGFloat) -> Void = { height in
            if phase == 0 && height > 1000 && !largeReported { largeReported = true; large.fulfill() }
            if phase == 1 && height > 0 && height < 150 && !smallReported { smallReported = true; small.fulfill() }
        }
        let source = (0..<50).map { "Paragraph \($0) with **Markdown**." }.joined(separator: "\n\n")
        let controller = UIHostingController(rootView: MobileMarkdownPreview(source: .constant(source),root: root,onContentHeight: report))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let original = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0,y: 0,width: 350,height: 600); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKey() }
        await fulfillment(of: [large],timeout: 20)
        phase = 1
        controller.rootView = MobileMarkdownPreview(source: .constant("Short document."),root: root,onContentHeight: report)
        await fulfillment(of: [small],timeout: 20)
    }
    @MainActor func testRepeatingTaskAdvancesChecklistReminderDate() throws {
        let store = MobileStore(persistence: Persistence(inMemory: true))
        var task = TaskItem(); task.title = "Weekly"; task.due = Date().addingTimeInterval(86400); task.repeatRule.frequency = "weekly"
        var check = CheckItem(title: "Review"); check.due = task.due!.addingTimeInterval(-3600); check.reminders = [0,600]; task.checks = [check]
        XCTAssertTrue(store.save(task)); store.complete(task.id)
        let next = try XCTUnwrap(store.tasks.first { $0.id != task.id && $0.parentID == nil })
        XCTAssertEqual(next.checks.first?.due,next.due?.addingTimeInterval(-3600)); XCTAssertEqual(next.checks.first?.reminders,[0,600]); XCTAssertEqual(next.checks.first?.done,false)
    }
}
