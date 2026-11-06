import XCTest
import Combine
import WebKit
@testable import OwnList

final class NavigationPerformanceTests: XCTestCase {
    func fixture(_ count: Int = 400) -> [TaskItem] {
        let list = UUID(),today = Calendar.current.startOfDay(for: Date())
        return (0..<count).map { i in
            var t = TaskItem(title: "任务 \(i)")
            t.listID = i % 3 == 0 ? nil : list; t.completed = i % 7 == 0
            t.deleted = i % 19 == 0; t.archived = i % 17 == 0
            t.abandoned = i % 13 == 0; t.isTemplate = i % 11 == 0; t.starred = i % 5 == 0
            t.tags = i % 2 == 0 ? ["验收"] : []; t.order = Double(count - i); t.priority = i % 4
            t.due = i % 4 == 0 ? nil : Calendar.current.date(byAdding: .day,value: i % 12 - 3,to: today)
            return t
        }
    }
    func testCachedNavigationMatchesExistingFiltersAndInvalidatesAtDayBoundary() {
        var tasks = fixture(); tasks[1].parentID = tasks[13].id; tasks[1].abandoned = true
        var filter = SavedFilter(name: "高优先级"); filter.priority = 2
        let cache = TaskQueryCache(tasks: tasks,filters: [filter])
        let keys = ["today","tomorrow","week","all","inbox","completed","trash","archived","abandoned","templates","starred","tag:验收","filter:" + filter.id.uuidString,"list:" + tasks[2].listID!.uuidString]
        for key in keys {
            XCTAssertEqual(cache.filtered(key).map(\.id),legacy(key,tasks: tasks,filters: [filter]).map(\.id),key)
            XCTAssertEqual(cache.sorted(key,sort: "手动").map(\.id),cache.filtered(key).sorted { a,b in
                if (a.pinned == true) != (b.pinned == true) { return a.pinned == true }; return a.order < b.order
            }.map(\.id))
        }
        let today = Calendar.current.startOfDay(for: Date())
        var t = TaskItem(title: "明天"); t.allDay = false; t.due = Calendar.current.date(byAdding: .day,value: 1,to: today)
        let dateCache = TaskQueryCache(tasks: [t],filters: [],now: today)
        XCTAssertTrue(dateCache.filtered("today").isEmpty)
        dateCache.updateClock(now: t.due!)
        XCTAssertEqual(dateCache.filtered("today").map(\.id),[t.id])
        var criteria = TaskSearchCriteria(); criteria.date = "overdue"
        dateCache.updateClock(now: t.due!.addingTimeInterval(-60))
        XCTAssertTrue(dateCache.sorted("all",sort: "手动",criteria: criteria).isEmpty)
        dateCache.updateClock(now: t.due!.addingTimeInterval(60))
        XCTAssertEqual(dateCache.sorted("all",sort: "手动",criteria: criteria).count,1)
    }
    @MainActor func testDerivedCacheSurvivesSelectionButNotTaskOrFilterChanges() {
        let store = Store(persistence: Persistence(inMemory: true,cloud: false)); store.tasks = fixture()
        let cache = store.taskQueries
        store.selectedTask = store.tasks[3].id; store.syncStatus = "正在同步…"
        XCTAssertTrue(cache === store.taskQueries)
        store.tasks[3].title = "修改"; XCTAssertFalse(cache === store.taskQueries)
        let edited = store.taskQueries
        store.filters.append(SavedFilter(name: "新增")); XCTAssertFalse(edited === store.taskQueries)
    }
    func testIndexedHierarchyKeepsOrderCollapseAndCycleProtection() {
        var root = TaskItem(title: "父任务"),child = TaskItem(title: "子任务"),abandoned = TaskItem(title: "放弃")
        child.parentID = root.id; abandoned.parentID = root.id; abandoned.abandoned = true; abandoned.pinned = true
        root.parentID = child.id
        let index = TaskHierarchy.Index(tasks: [root,child,abandoned])
        XCTAssertEqual(index.rows(root: root,collapsed: []).map(\.id),[root.id,abandoned.id,child.id])
        XCTAssertEqual(index.rows(root: root,collapsed: [],includeAbandoned: false).map(\.id),[root.id,child.id])
        XCTAssertEqual(index.rows(root: root,collapsed: [root.id]).count,1)
    }
    @MainActor func testRemoteSnapshotSkipsUnchangedPublicationsAndRejectsStaleRead() {
        let store = Store(persistence: Persistence(inMemory: true,cloud: false)); store.tasks = fixture(30)
        let snapshot = store.backup,revision = store.dataRevision
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        var reordered = snapshot; reordered.tasks.reverse()
        XCTAssertTrue(store.applyRemoteSnapshot(reordered,expectedRevision: revision))
        XCTAssertEqual(publications,0); XCTAssertEqual(store.dataRevision,revision)
        store.tasks[0].notes = "本地新内容"
        XCTAssertFalse(store.applyRemoteSnapshot(snapshot,expectedRevision: revision))
        XCTAssertEqual(store.tasks[0].notes,"本地新内容")
        var remote = store.backup; remote.tasks[1].completed.toggle()
        let before = publications
        XCTAssertTrue(store.applyRemoteSnapshot(remote,expectedRevision: store.dataRevision))
        XCTAssertEqual(publications,before + 1)
        withExtendedLifetime(observation) {}
    }
    @MainActor func testBackgroundSnapshotResolvesLatestFieldsAndDeletedNoteTombstones() async throws {
        let persistence = Persistence(inMemory: true,cloud: false)
        var task = TaskItem(title: "旧标题"); try persistence.save(task)
        task.title = "新标题"; task.notes = "中文🙂正文"; try persistence.save(task)
        var note = SideNote(); note.title = "删除"; note.deleted = true; try persistence.save(note); try persistence.purgeSideNote(note)
        let result: Backup = try await withCheckedThrowingContinuation { continuation in
            persistence.readSnapshot { continuation.resume(with: $0) }
        }
        XCTAssertEqual(result.tasks,[task]); XCTAssertEqual(result.sideNotes,[])
    }
    @MainActor func testPreviewRapidSwitchOnlyDisplaysLatestDocument() async throws {
        let view = WKWebView(frame: .zero),coordinator = MarkdownPreviewView.Coordinator()
        coordinator.update(String(repeating: "# 旧正文\n",count: 500),root: nil,dark: false,in: view)
        coordinator.update("# 最后选择的任务",root: nil,dark: false,in: view)
        for _ in 0..<200 { if coordinator.rendered.html.contains("最后选择的任务") { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(coordinator.rendered.html.contains("最后选择的任务"))
        coordinator.cancelRendering()
        coordinator.update("# 不应显示",root: nil,dark: false,in: view); coordinator.cancelRendering()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(coordinator.rendered.html.contains("不应显示"))
    }
    func testNavigationCalculationWorkload() {
        let tasks = fixture(1500),keys = ["today","tomorrow","week","all","inbox","completed","trash","archived","abandoned","templates","starred"]
        let start = Date(); var baseline = 0
        for _ in 0..<10 { for key in keys { baseline += legacy(key,tasks: tasks,filters: []).count } }
        let baselineMS = Date().timeIntervalSince(start) * 1000
        let optimizedStart = Date(); let cache = TaskQueryCache(tasks: tasks,filters: []); var optimized = 0
        for _ in 0..<10 { for key in keys { optimized += cache.filtered(key).count } }
        let optimizedMS = Date().timeIntervalSince(optimizedStart) * 1000
        XCTAssertEqual(baseline,optimized)
        print("NAVIGATION_WORKLOAD tasks=1500 passes=10 baseline_ms=\(baselineMS) optimized_ms=\(optimizedMS)")
    }
    func legacy(_ key: String,tasks: [TaskItem],filters: [SavedFilter]) -> [TaskItem] {
        tasks.filter { t in
            if key == "trash" { return t.deleted }; guard !t.deleted else { return false }; if key == "abandoned" { return t.abandoned == true && !t.isTemplate && (t.parentID == nil || !tasks.contains { $0.id == t.parentID && $0.abandoned == true && !$0.deleted }) }; guard t.abandoned != true else { return false }
            if key == "archived" { return t.archived == true }; if key == "templates" { return t.isTemplate && t.parentID == nil }; guard t.archived != true else { return false }; guard !t.isTemplate && t.parentID == nil else { return false }
            switch key { case "today": return t.due.map { $0 < Calendar.current.date(byAdding: .day,value: 1,to: Calendar.current.startOfDay(for: Date()))! } == true && !t.completed
            case "tomorrow": return t.due.map { Calendar.current.isDateInTomorrow($0) } == true && !t.completed
            case "week": return t.due.map { $0 < Calendar.current.date(byAdding: .day,value: 7,to: Calendar.current.startOfDay(for: Date()))! } == true && !t.completed
            case "inbox": return t.listID == nil
            case "all": return true
            case "completed": return t.completed
            case "starred": return t.starred
            default: if key.hasPrefix("list:") { return t.listID?.uuidString == String(key.dropFirst(5)) }; if key.hasPrefix("tag:") { return t.tags.contains(String(key.dropFirst(4))) }; if let filter = filters.first(where: { "filter:" + $0.id.uuidString == key }) { return filter.matches(t) }; return false }
        }
    }
}
