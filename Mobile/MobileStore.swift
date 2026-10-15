import Foundation
import Combine
import CloudKit
import CoreData
import UIKit
import UserNotifications

// The simulator runs locally; device builds use the same private CloudKit database as Zilo for Mac.
enum Capability {
    static var cloudAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }
}
@MainActor final class MobileStore: ObservableObject {
    let persistence: Persistence
    private var remindersWork: Task<Void,Never>?
    @Published var tasks: [TaskItem] = []
    @Published var lists: [TaskList] = []
    @Published var habits: [Habit] = []
    @Published var focus: [FocusRecord] = []
    @Published var countdowns: [Countdown] = []
    @Published var subscriptions: [CalendarSubscription] = []
    @Published var filters: [SavedFilter] = []
    @Published var activity: [ActivityEntry] = []
    @Published var syncStatus = "已保存在本机"
    @Published var error: String?
    @Published var selectedTask: TaskItem? { didSet { if !restoringWorkspace { visibleTaskID = selectedTask?.id; persistWorkspace() } } }
    @Published var selectedModule = "tasks" { didSet { persistWorkspace() } }
    @Published var taskSelection = "today" { didSet { persistWorkspace() } }
    @Published var taskListID: UUID? { didSet { persistWorkspace() } }
    @Published var morePath: [String] = [] { didSet { persistWorkspace() } }
    @Published var showCompleted = false { didSet { persistWorkspace() } }
    @Published var visibleTaskID: UUID? { didSet { persistWorkspace() } }
    private var restoringWorkspace = true
    init(persistence supplied: Persistence? = nil) {
        UserDefaults.standard.register(defaults: ["cloudEnabled":true,"accent":"blue","recognizeDate":true])
        persistence = supplied ?? Persistence(cloud: Capability.cloudAvailable && UserDefaults.standard.bool(forKey: "cloudEnabled"))
        #if DEBUG
        _ = ZiloScreenshotData.seed(persistence)
        #endif
        persistence.onChange = { [weak self] in Task { @MainActor in self?.reload() } }
        persistence.onCloudEvent = { [weak self] message in Task { @MainActor in self?.syncStatus = message; if message.hasPrefix("已同步") || message.hasPrefix("同步失败") { self?.log(message.hasPrefix("已同步") ? "iCloud 同步" : "同步失败",message) } } }
        do { try persistence.ensureDefaultCountdowns(started: (try? persistence.load(TaskItem.self).map(\.created).min()) ?? Date()) } catch { self.error = error.localizedDescription }
        reload()
        if let data = try? Data(contentsOf: persistence.root.appendingPathComponent("Activity.json")),let entries = try? JSONDecoder().decode([ActivityEntry].self,from: data) { activity = entries }
        error = persistence.loadError
        let workspace = MobileWorkspaceState.launch().validated(tasks: tasks,lists: lists,filters: filters,visibility: ModulePreferences(rawValue: UserDefaults.standard.string(forKey: "moduleVisibility") ?? ""))
        selectedModule = workspace.module; taskSelection = workspace.selection; taskListID = workspace.listID
        morePath = workspace.morePath; showCompleted = workspace.showCompleted; visibleTaskID = workspace.taskID
        selectedTask = tasks.first { $0.id == workspace.taskID }
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZILO_SCREENSHOTS"] == "1", let scene = ProcessInfo.processInfo.environment["ZILO_SCREENSHOT_SCENE"], ["tasks","focus"].contains(scene) { selectedModule = scene; selectedTask = nil; visibleTaskID = nil }
        #endif
        restoringWorkspace = false
        persistWorkspace()
    }
    func persistWorkspace() {
        guard !restoringWorkspace else { return }
        MobileWorkspaceState(module: selectedModule,selection: taskSelection,listID: taskListID,taskID: visibleTaskID,morePath: morePath,showCompleted: showCompleted).save()
    }
    func openTask(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id && !$0.deleted }) else { return }
        selectedModule = "tasks"; taskListID = task.abandoned == true ? nil : task.listID; taskSelection = task.abandoned == true ? "abandoned" : task.listID == nil ? "inbox" : "list"
        selectedTask = task
    }
    var active: [TaskItem] { tasks.filter(\.isPendingTask).sorted { if ($0.pinned == true) != ($1.pinned == true) { return $0.pinned == true }; return $0.order < $1.order } }
    func reload() {
        do {
            tasks = try persistence.load(TaskItem.self); lists = try persistence.load(TaskList.self).sorted { $0.order < $1.order }
            habits = try persistence.load(Habit.self); focus = try persistence.load(FocusRecord.self)
            countdowns = try persistence.load(Countdown.self); subscriptions = try persistence.load(CalendarSubscription.self); filters = try persistence.load(SavedFilter.self)
            try persistence.restoreBlobs()
            scheduleReminders()
        } catch is DecodingError { syncStatus = "正在载入 iCloud 数据…" }
        catch { self.error = error.localizedDescription }
    }
    private func scheduleReminders() {
        guard !persistence.inMemory else { return }; remindersWork?.cancel()
        remindersWork = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self,!Task.isCancelled else { return }
            MobileNotifications.shared.reschedule(tasks: tasks,habits: habits,countdowns: countdowns)
        }
    }
    @discardableResult func save<T: ListRecord>(_ value: T) -> Bool {
        do {
            try persistence.save(value)
            func upsert<R: ListRecord>(_ item: R,_ array: inout [R]) { if let index = array.firstIndex(where: { $0.id == item.id }) { array[index] = item } else { array.append(item) } }
            if let item = value as? TaskItem { upsert(item,&tasks); scheduleReminders() }
            else if let item = value as? TaskList { upsert(item,&lists); lists.sort { $0.order < $1.order } }
            else if let item = value as? Habit { upsert(item,&habits); scheduleReminders() }
            else if let item = value as? FocusRecord { upsert(item,&focus) }
            else if let item = value as? Countdown { upsert(item,&countdowns); scheduleReminders() }
            else if let item = value as? SavedFilter { upsert(item,&filters) }
            else if let item = value as? CalendarSubscription { upsert(item,&subscriptions) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func mutate(_ id: UUID,_ change: (inout TaskItem) -> Void) { guard var task = tasks.first(where: { $0.id == id }) else { return }; let before = task; change(&task); guard before != task else { return }; if save(task) { log("更新任务",task.title,owner: id) } }
    @discardableResult func add(_ text: String,listID: UUID? = nil,parentID: UUID? = nil,date: Date? = nil) -> TaskItem? {
        let parsed = TaskCreationPreferences.parse(text)
        guard !parsed.title.isEmpty else { return nil }
        var item = TaskItem(); item.title = parsed.title; item.due = parsed.due ?? date; item.tags = parsed.tags; item.priority = parsed.priority
        item.documentMode = .markdown; item.listID = listID; item.parentID = parentID
        item.allDay = item.due.map { Calendar.current.component(.hour,from: $0) == 0 && Calendar.current.component(.minute,from: $0) == 0 } ?? true
        if item.due != nil { item.reminders = [0] }
        guard save(item) else { return nil }; log("创建任务",item.title,owner: item.id); return item
    }
    func complete(_ id: UUID) {
        guard var item = tasks.first(where: { $0.id == id && !$0.deleted && $0.isNote != true && $0.abandoned != true }) else { return }
        let originals = tasks
        let persistence = self.persistence
        item.completed.toggle(); item.completedAt = item.completed ? Date() : nil
        item.checks = item.checks.map { var c = $0; c.done = item.completed; return c }
        do {
            try persistence.transaction {
                try persistence.save(item)
                func children(_ parent: UUID,_ visited: Set<UUID>) throws {
                    for var child in originals.filter({ !$0.deleted && $0.isNote != true && $0.abandoned != true && $0.parentID == parent && !visited.contains($0.id) }) {
                        child.completed = item.completed; child.completedAt = item.completedAt
                        child.checks = child.checks.map { var c = $0; c.done = item.completed; return c }
                        try persistence.save(child); try children(child.id,visited.union([child.id]))
                    }
                }
                try children(item.id,[item.id])
                if item.completed,let due = item.due,let next = item.repeatRule.next(after: due) {
                    var copy = item; copy.id = UUID(); copy.sourceID = nil; copy.completed = false; copy.completedAt = nil; copy.due = next; copy.created = Date()
                    copy.repeatRule.anchor = copy.repeatRule.anchor ?? due
                    if let count = copy.repeatRule.remainingCount { copy.repeatRule.remainingCount = count - 1 }
                    if let start = item.start { copy.start = next.addingTimeInterval(start.timeIntervalSince(due)) }
                    copy.checks = copy.checks.map { var c = $0; c.done = false; c.due = c.due?.addingTimeInterval(next.timeIntervalSince(due)); return c }; try persistence.save(copy)
                    func clone(_ source: UUID,_ dest: UUID,_ visited: Set<UUID>) throws {
                        for var child in originals.filter({ !$0.deleted && $0.parentID == source && !visited.contains($0.id) }) {
                            let old = child.id; child.id = UUID(); child.parentID = dest; child.completed = false; child.completedAt = nil; child.sourceID = nil
                            child.due = child.due?.addingTimeInterval(next.timeIntervalSince(due)); child.start = child.start?.addingTimeInterval(next.timeIntervalSince(due))
                            child.checks = child.checks.map { var c = $0; c.done = false; c.due = c.due?.addingTimeInterval(next.timeIntervalSince(due)); return c }; try persistence.save(child); try clone(old,child.id,visited.union([old]))
                        }
                    }
                    try clone(item.id,copy.id,[item.id])
                }
            }
            reload(); log(item.completed ? "完成任务" : "恢复任务",item.title,owner: id)
        } catch { self.error = error.localizedDescription }
    }
    func trash(_ id: UUID) {
        let originals = tasks
        let persistence = self.persistence
        do {
            try persistence.transaction {
                func remove(_ parent: UUID,_ visited: Set<UUID>,_ root: Bool) throws {
                    guard var task = originals.first(where: { $0.id == parent }) else { return }; task.deleted = true
                    if !root { task.trashedWithParent = task.parentID }; try persistence.save(task)
                    for child in originals.filter({ !$0.deleted && $0.parentID == parent && !visited.contains($0.id) }) { try remove(child.id,visited.union([child.id]),false) }
                }
                try remove(id,[id],true)
            }; reload(); log("移到回收站",originals.first { $0.id == id }?.title ?? "任务",owner: id)
        } catch { self.error = error.localizedDescription }
    }
    func restore(_ id: UUID) {
        do {
            let originals = tasks
        let persistence = self.persistence
            try persistence.transaction {
                func restoreTree(_ parent: UUID,_ visited: Set<UUID>) throws {
                    guard var item = originals.first(where: { $0.id == parent }) else { return }
                    item.deleted = false; item.trashedWithParent = nil; item.trashedWithList = nil
                    if let parentID = item.parentID,!visited.contains(parentID),originals.first(where: { $0.id == parentID })?.deleted != false { item.parentID = nil }
                    try persistence.save(item)
                    for child in originals.filter({ $0.trashedWithParent == parent && !visited.contains($0.id) }) { try restoreTree(child.id,visited.union([child.id])) }
                }; try restoreTree(id,[id])
            }; reload()
        } catch { self.error = error.localizedDescription }
    }
    func place(_ source: UUID,_ target: UUID,_ position: TaskPlacement.Position) {
        do { guard let changes = TaskPlacement.changes(tasks,source: source,target: target,position: position) else { return }
            try persistence.transaction { for item in changes { try persistence.save(item) } }; reload()
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func promoteTask(_ id: UUID) -> Bool {
        guard let changes = TaskPlacement.promotedChanges(tasks,source: id) else { return false }
        do { try persistence.transaction { for item in changes { try persistence.save(item) } }; reload(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func log(_ title: String,_ detail: String,owner: UUID? = nil) {
        if let last = activity.first,last.title == title,last.detail == detail,last.owner == owner,Date().timeIntervalSince(last.date) < 60 { return }
        activity.insert(ActivityEntry(title: title,detail: detail,owner: owner),at: 0); activity = Array(activity.prefix(200))
        do { try JSONEncoder().encode(activity).write(to: persistence.root.appendingPathComponent("Activity.json"),options: .atomic) } catch { self.error = error.localizedDescription }
    }
    func sync() async {
        guard Capability.cloudAvailable else { syncStatus = "模拟器使用本地存储"; return }
        guard UserDefaults.standard.bool(forKey: "cloudEnabled") else { syncStatus = "iCloud 已关闭 · 本机保存"; return }
        guard persistence.container is NSPersistentCloudKitContainer else { syncStatus = "重启 Zilo 后启用 iCloud"; return }
        do {
            let status = try await CKContainer(identifier: "iCloud.com.gaoluchuan.ownlist").accountStatus()
            guard status == .available else { syncStatus = "请在 iPhone 设置中登录 iCloud"; return }
            try persistence.container.viewContext.save(); persistence.container.viewContext.refreshAllObjects(); reload()
            if !syncStatus.hasPrefix("已同步") { syncStatus = "iCloud 已连接 · 等待系统同步" }
        } catch { syncStatus = CloudMessage.describe(error) }
    }
    func attach(_ urls: [URL],taskID: UUID) {
        do {
            let directory = persistence.root.appendingPathComponent("Attachments"); try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
            var attachments: [Attachment] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let path = "Attachments/" + UUID().uuidString + "-" + url.lastPathComponent; let data = try Data(contentsOf: url)
                try data.write(to: persistence.root.appendingPathComponent(path),options: .atomic); try persistence.saveBlob(path: path,data: data)
                attachments.append(Attachment(name: url.lastPathComponent,relativePath: path))
            }; mutate(taskID) { $0.attachments += attachments }
        } catch { self.error = error.localizedDescription }
    }
    func exportBackup() throws -> URL {
        var blobs: [String: Data] = [:]
        for attachment in tasks.flatMap(\.attachments) { if let data = try? Data(contentsOf: persistence.root.appendingPathComponent(attachment.relativePath)) { blobs[attachment.relativePath] = data } }
        let data = Backup(tasks: tasks,lists: lists,filters: filters,habits: habits,focus: focus,subscriptions: subscriptions,attachmentFiles: blobs,countdowns: countdowns)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Zilo-" + Day.key(Date()) + ".ownlist.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; try encoder.encode(data).write(to: url,options: .atomic); return url
    }
    // Import merges records by ID; existing records absent from the backup are retained.
    func importBackup(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let backup = try JSONDecoder().decode(Backup.self,from: Data(contentsOf: url))
        guard backup.formatVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        for (path,data) in backup.attachmentFiles ?? [:] {
            guard path.hasPrefix("Attachments/"),!path.contains(".."),!path.hasPrefix("/") else { throw CocoaError(.fileReadCorruptFile) }
            let target = persistence.root.appendingPathComponent(path); try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),withIntermediateDirectories: true); try data.write(to: target,options: .atomic); try persistence.saveBlob(path: path,data: data)
        }
        try persistence.transaction {
            for record in backup.tasks { try persistence.save(record) }; for record in backup.lists { try persistence.save(record) }
            for record in backup.filters { try persistence.save(record) }; for record in backup.habits { try persistence.save(record) }
            for record in backup.focus { try persistence.save(record) }; for record in backup.countdowns ?? [] { try persistence.save(record) }
            for record in backup.subscriptions { try persistence.save(record) }
        }; reload(); log("导入备份","记录已合并")
    }
}
