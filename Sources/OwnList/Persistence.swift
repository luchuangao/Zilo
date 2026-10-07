import Foundation
import CoreData
import Combine
import CloudKit
import CryptoKit

struct FieldVersion: Identifiable { var id: UUID; var owner: UUID; var kind: String; var field: String; var json: String; var timestamp: Date }
final class Persistence {
    let container: NSPersistentContainer
    let root: URL
    let inMemory: Bool
    private var cacheLoaded = false
    private var fieldCache: [UUID: [String: String]] = [:]
    var loadError: String?
    var onChange: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var cloudObserver: NSObjectProtocol?
    var onCloudEvent: ((String) -> Void)?
    init(inMemory: Bool = false, cloud: Bool = UserDefaults.standard.bool(forKey: "cloudEnabled") && Capability.cloudAvailable) {
        self.inMemory = inMemory
        root = inMemory ? FileManager.default.temporaryDirectory.appendingPathComponent("OwnListTests-" + UUID().uuidString,isDirectory: true) : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OwnList", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = NSManagedObjectModel(); let entity = NSEntityDescription(); entity.name = "FieldVersion"; entity.managedObjectClassName = "NSManagedObject"
        func attr(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription { let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = true; return a }
        entity.properties = [attr("id", .UUIDAttributeType), attr("owner", .UUIDAttributeType), attr("kind", .stringAttributeType), attr("field", .stringAttributeType), attr("json", .stringAttributeType), attr("timestamp", .dateAttributeType)]
        let blob = NSEntityDescription(); blob.name = "AttachmentBlob"; blob.managedObjectClassName = "NSManagedObject"
        let content = attr("data", .binaryDataAttributeType); content.allowsExternalBinaryDataStorage = true
        blob.properties = [attr("path", .stringAttributeType), content]
        model.entities = [entity, blob]
        if cloud && !inMemory {
            let c = NSPersistentCloudKitContainer(name: "OwnList", managedObjectModel: model)
            container = c
        } else { container = NSPersistentContainer(name: "OwnList", managedObjectModel: model) }
        let description = NSPersistentStoreDescription(url: inMemory ? URL(fileURLWithPath: "/dev/null") : root.appendingPathComponent("OwnList.sqlite"))
        if inMemory { description.type = NSInMemoryStoreType }
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if cloud && !inMemory { description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.gaoluchuan.ownlist") }
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in if let error { self.loadError = error.localizedDescription; self.onCloudEvent?("存储错误：\(error.localizedDescription)") } }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        observer = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in self?.fieldCache.removeAll(); self?.cacheLoaded = false; self?.container.viewContext.refreshAllObjects(); self?.onChange?() }
        cloudObserver = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] n in
            guard let event = n.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            self?.onCloudEvent?(event.error.map { "同步失败：\(CloudMessage.describe($0))" } ?? (event.endDate == nil ? "正在同步…" : "已同步 · \(Date().formatted(date: .omitted, time: .shortened))")); if event.endDate != nil { self?.fieldCache.removeAll(); self?.cacheLoaded = false; self?.onChange?() }
        }
    }
    func versions(owner: UUID? = nil, kind: String? = nil) throws -> [FieldVersion] {
        let r = NSFetchRequest<NSManagedObject>(entityName: "FieldVersion"); if let owner { r.predicate = NSPredicate(format: "owner == %@", owner as CVarArg) }
        if let kind { r.predicate = NSPredicate(format: "kind == %@", kind) }
        return try container.viewContext.fetch(r).compactMap { o in guard let id = o.value(forKey: "id") as? UUID, let owner = o.value(forKey: "owner") as? UUID, let kind = o.value(forKey: "kind") as? String, let field = o.value(forKey: "field") as? String, let json = o.value(forKey: "json") as? String, let timestamp = o.value(forKey: "timestamp") as? Date else { return nil }; return FieldVersion(id: id, owner: owner, kind: kind, field: field, json: json, timestamp: timestamp) }.sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp }
    }
    func load<T: ListRecord>(_ type: T.Type) throws -> [T] {
        let values = try versions(kind: T.kind); var objects: [UUID: [String: Any]] = [:]
        for value in values {
            var decoded = try JSONSerialization.jsonObject(with: Data(value.json.utf8), options: [.fragmentsAllowed])
            if value.field == "richText", let marker = decoded as? [String: String], let path = marker["documentBlob"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: "AttachmentBlob"); request.predicate = NSPredicate(format: "path == %@",path); request.fetchLimit = 1
                guard let data = try container.viewContext.fetch(request).first?.value(forKey: "data") as? Data else { onCloudEvent?("正文图片正在下载…"); continue }
                decoded = data.base64EncodedString()
            }
            objects[value.owner, default: [:]][value.field] = decoded
        }
        return try objects.values.map { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) }
    }
    func save<T: ListRecord>(_ record: T) throws {
        let encoded = try JSONEncoder().encode(record); let dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        if !cacheLoaded { fieldCache.removeAll(); for v in try versions() { fieldCache[v.owner,default: [:]][v.field] = v.json }; cacheLoaded = true }; var previous = fieldCache[record.id] ?? [:]
        for key in Set(dict.keys).union(previous.keys) {
            var value = dict[key] ?? NSNull()
            if key == "richText", let encoded = value as? String, let data = Data(base64Encoded: encoded), data.count > 100_000 {
                let digest = SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
                let path = "Documents/" + digest + ".rtfd"
                try saveBlob(path: path,data: data)
                value = ["documentBlob":path]
            }
            let json = String(data: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed,.sortedKeys]), encoding: .utf8)!
            guard previous[key] != json else { continue }; previous[key] = json
            let o = NSEntityDescription.insertNewObject(forEntityName: "FieldVersion", into: container.viewContext)
            o.setValue(UUID(), forKey: "id"); o.setValue(record.id, forKey: "owner"); o.setValue(T.kind, forKey: "kind"); o.setValue(key, forKey: "field"); o.setValue(json, forKey: "json"); o.setValue(Date(), forKey: "timestamp")
        }
        try container.viewContext.save(); fieldCache[record.id] = previous
    }
    func saveBlob(path: String, data: Data) throws {
        let r = NSFetchRequest<NSManagedObject>(entityName: "AttachmentBlob"); r.predicate = NSPredicate(format: "path == %@",path); r.fetchLimit = 1
        guard try container.viewContext.fetch(r).isEmpty else { return }
        let object = NSEntityDescription.insertNewObject(forEntityName: "AttachmentBlob",into: container.viewContext); object.setValue(path,forKey: "path"); object.setValue(data,forKey: "data"); try container.viewContext.save()
    }
    func restoreBlobs() throws {
        let r = NSFetchRequest<NSManagedObject>(entityName: "AttachmentBlob")
        for object in try container.viewContext.fetch(r) { if let path = object.value(forKey: "path") as? String, path.hasPrefix("Attachments/"), !path.contains(".."), let data = object.value(forKey: "data") as? Data { let url = root.appendingPathComponent(path); if !FileManager.default.fileExists(atPath: url.path) { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true); try data.write(to: url,options: .atomic) } } }
    }
    func restoreField(_ version: FieldVersion) throws {
        let o = NSEntityDescription.insertNewObject(forEntityName: "FieldVersion", into: container.viewContext)
        o.setValue(UUID(), forKey: "id"); o.setValue(version.owner, forKey: "owner"); o.setValue(version.kind, forKey: "kind"); o.setValue(version.field, forKey: "field"); o.setValue(version.json, forKey: "json"); o.setValue(Date(), forKey: "timestamp"); try container.viewContext.save(); fieldCache.removeValue(forKey: version.owner); cacheLoaded = false
    }
}
struct Backup: Codable { var formatVersion = 1; var created = Date(); var tasks: [TaskItem]; var lists: [TaskList]; var filters: [SavedFilter]; var habits: [Habit]; var focus: [FocusRecord]; var subscriptions: [CalendarSubscription]; var attachmentFiles: [String: Data]? = nil }
@MainActor final class Store: ObservableObject {
    let persistence: Persistence
    @Published var tasks: [TaskItem] = []; @Published var lists: [TaskList] = []; @Published var filters: [SavedFilter] = []; @Published var habits: [Habit] = []; @Published var focus: [FocusRecord] = []; @Published var subscriptions: [CalendarSubscription] = []
    @Published var error: String?; @Published var syncStatus = "本地保存"; @Published var selectedTask: UUID?
    private var backupTimer: Timer?
    private var undoStack: [Backup] = []; private var redoStack: [Backup] = []
    init(persistence: Persistence = Persistence()) {
        self.persistence = persistence
        persistence.onChange = { [weak self] in Task { @MainActor in self?.reload() } }
        persistence.onCloudEvent = { [weak self] message in Task { @MainActor in self?.syncStatus = message } }
        reload(); if UserDefaults.standard.bool(forKey: "cloudEnabled") && Capability.cloudAvailable { syncStatus = "等待 iCloud 同步" }
        if !persistence.inMemory && !UserDefaults.standard.bool(forKey: "didInitialize") { do { try persistence.save(TaskList(name: "学习", color: "blue", order: 0)); try persistence.save(TaskList(name: "工作", color: "green", order: 1)); try persistence.save(TaskList(name: "家庭生活", color: "orange", order: 2)); UserDefaults.standard.set(true, forKey: "didInitialize"); reload() } catch { self.error = error.localizedDescription } }
        if !persistence.inMemory { automaticBackup(); backupTimer = Timer.scheduledTimer(withTimeInterval: 3600,repeats: true) { [weak self] _ in Task { @MainActor in self?.automaticBackup() } } }
    }
    func reload() {
        do { if let failure = persistence.loadError { throw ServiceError.message(failure) }; if !persistence.inMemory { try persistence.restoreBlobs() }; tasks = try persistence.load(TaskItem.self); lists = try persistence.load(TaskList.self); filters = try persistence.load(SavedFilter.self); habits = try persistence.load(Habit.self); focus = try persistence.load(FocusRecord.self); subscriptions = try persistence.load(CalendarSubscription.self) } catch { self.error = "读取数据失败：\(error.localizedDescription)" }
        if !persistence.inMemory { DesktopBridge.updateBadge(tasks.filter { !$0.deleted && $0.archived != true && !$0.completed && !$0.isTemplate && $0.due.map { Calendar.current.isDateInToday($0) } == true }.count)
        WidgetSnapshot.write(tasks: tasks, lists: lists) }
    }
    var backup: Backup { Backup(tasks: tasks, lists: lists, filters: filters, habits: habits, focus: focus, subscriptions: subscriptions) }
    @discardableResult func save<T: ListRecord>(_ record: T, undoable: Bool = true) -> Bool {
        let before = undoable ? backup : nil
        do { try persistence.save(record); if let before { undoStack.append(before); if undoStack.count > 40 { undoStack.removeFirst() }; redoStack.removeAll() }; updatePublished(record); if !persistence.inMemory { if let task = record as? TaskItem { NotificationService.shared.schedule(task) }; if let habit = record as? Habit { NotificationService.shared.schedule(habit) } }; return true } catch { self.error = error.localizedDescription; return false }
    }
    func commitList(existing: TaskList?, name: String, folder: String, color: String, sections: String, defaultView: String? = nil) throws -> TaskList {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ServiceError.message("请输入清单名称。") }
        guard !lists.contains(where: { !$0.deleted && $0.id != existing?.id && $0.folder.compare(folder,options: [.caseInsensitive,.diacriticInsensitive]) == .orderedSame && $0.name.compare(name,options: [.caseInsensitive,.diacriticInsensitive]) == .orderedSame }) else { throw ServiceError.message("这个文件夹内已有同名清单，请换一个名称。") }
        var value = existing ?? TaskList(name: name,order: (lists.map(\.order).max() ?? -1) + 1)
        value.name = name; value.folder = folder; value.color = color
        if let defaultView { guard ["列表","看板","时间线"].contains(defaultView) else { throw ServiceError.message("请选择支持的清单视图。") }; value.defaultView = defaultView }
        var seen = Set<String>()
        value.sections = sections.components(separatedBy: CharacterSet(charactersIn: ",，;；\n\r")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        let before = backup
        try persistence.save(value)
        undoStack.append(before); if undoStack.count > 40 { undoStack.removeFirst() }; redoStack.removeAll()
        updatePublished(value)
        return value
    }
    private func updatePublished<T: ListRecord>(_ record: T) {
        func updated<R: ListRecord>(_ records: [R], _ record: R) -> [R] { var list = records; if let i = list.firstIndex(where: { $0.id == record.id }) { list[i] = record } else { list.append(record) }; return list }
        if let r = record as? TaskItem { tasks = updated(tasks,r); if !persistence.inMemory { DesktopBridge.updateBadge(tasks.filter { !$0.deleted && $0.archived != true && !$0.completed && !$0.isTemplate && $0.due.map { Calendar.current.isDateInToday($0) } == true }.count); WidgetSnapshot.write(tasks: tasks,lists: lists) } }
        if let r = record as? TaskList { lists = updated(lists,r) }; if let r = record as? SavedFilter { filters = updated(filters,r) }; if let r = record as? Habit { habits = updated(habits,r) }; if let r = record as? FocusRecord { focus = updated(focus,r) }; if let r = record as? CalendarSubscription { subscriptions = updated(subscriptions,r) }
    }
    func mutate(_ id: UUID, _ body: (inout TaskItem) -> Void) { guard var task = tasks.first(where: { $0.id == id }) else { return }; let before = backup; let wasDeleted = task.deleted; body(&task); save(task); if task.deleted != wasDeleted { cascadeDelete(id,deleted: task.deleted,visited: [id]); groupUndo(before) } }
    /// One saved operation for multiline input, with stable IDs and a single undo step.
    @discardableResult func addChecks(_ taskID: UUID,input: String) -> [UUID] {
        let titles = input.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !titles.isEmpty, var task = tasks.first(where: { $0.id == taskID && !$0.deleted }) else { return [] }
        let checks = titles.map { CheckItem(title: $0) }; task.checks.append(contentsOf: checks)
        return save(task) ? checks.map(\.id) : []
    }
    @discardableResult func moveCheck(_ taskID: UUID,checkID: UUID,offset: Int) -> Bool {
        guard var task = tasks.first(where: { $0.id == taskID && !$0.deleted }), let index = task.checks.firstIndex(where: { $0.id == checkID }) else { return false }
        let target = index + offset
        guard task.checks.indices.contains(target), target != index else { return false }
        let check = task.checks.remove(at: index); task.checks.insert(check,at: target)
        return save(task)
    }
    @discardableResult func reorderCheck(_ taskID: UUID,checkID: UUID,before destination: UUID) -> Bool {
        guard checkID != destination, var task = tasks.first(where: { $0.id == taskID && !$0.deleted }), let source = task.checks.firstIndex(where: { $0.id == checkID }), task.checks.contains(where: { $0.id == destination }) else { return false }
        let check = task.checks.remove(at: source)
        guard let target = task.checks.firstIndex(where: { $0.id == destination }) else { return false }
        task.checks.insert(check,at: target)
        return save(task)
    }
    private func cascadeDelete(_ id: UUID,deleted: Bool,visited: Set<UUID>) { for var child in tasks.filter({ $0.parentID == id && (deleted ? !$0.deleted : $0.trashedWithParent == id) }) { guard !visited.contains(child.id) else { continue }; child.deleted = deleted; child.trashedWithParent = deleted ? id : nil; save(child,undoable: false); cascadeDelete(child.id,deleted: deleted,visited: visited.union([child.id])) } }
    @discardableResult func add(_ input: String, listID: UUID? = nil, parentID: UUID? = nil, defaultDue: Date? = nil, section: String = "", starred: Bool = false) -> UUID? {
        let parsed = QuickParser.parse(input); guard !parsed.title.isEmpty else { return nil }
        var task = TaskItem(); task.title = parsed.title; task.due = parsed.due ?? defaultDue; task.section = section; task.starred = starred; task.tags = parsed.tags; task.priority = parsed.priority; task.listID = listID; task.parentID = parentID
        task.allDay = task.due.map { Calendar.current.component(.hour, from: $0) == 0 && Calendar.current.component(.minute, from: $0) == 0 } ?? true
        if task.due != nil { task.reminders = [0] }; guard save(task) else { return nil }; selectedTask = task.id; return task.id
    }
    func complete(_ id: UUID) {
        guard var task = tasks.first(where: { $0.id == id }) else { return }
        let before = backup; task.completed.toggle(); task.completedAt = task.completed ? Date() : nil; task.checks = task.checks.map { var c = $0; c.done = task.completed; return c }; save(task)
        completeChildren(task.id,completed: task.completed,visited: [task.id])
        if task.repeatRule.anchor == nil { task.repeatRule.anchor = task.due }; if task.completed, let due = task.due, let next = task.repeatRule.next(after: due) { var nextTask = task; if let count = nextTask.repeatRule.remainingCount { nextTask.repeatRule.remainingCount = count - 1 }; nextTask.id = UUID(); nextTask.sourceID = nil; nextTask.completed = false; nextTask.completedAt = nil; nextTask.due = next; nextTask.created = Date(); if let start = task.start { nextTask.start = next.addingTimeInterval(start.timeIntervalSince(due)) }; nextTask.checks = task.checks.map { var c = $0; c.done = false; return c }; save(nextTask, undoable: false)
            cloneChildren(from: id,to: nextTask.id,asTemplate: false,dateShift: next.timeIntervalSince(due),visited: [id])
            if !undoStack.isEmpty { undoStack[undoStack.count - 1] = before }
        }
    }
    @discardableResult func duplicate(_ id: UUID,asTemplate: Bool = false) -> UUID? { guard var task = tasks.first(where: { $0.id == id }) else { return nil }; let before = backup; let oldID = task.id; task.id = UUID(); task.parentID = nil; task.sourceID = nil; task.completed = false; task.completedAt = nil; task.created = Date(); task.isTemplate = asTemplate; task.checks = task.checks.map { var c = $0; c.done = false; return c }; save(task); cloneChildren(from: oldID,to: task.id,asTemplate: asTemplate,dateShift: 0,visited: [oldID]); groupUndo(before); selectedTask = task.id; return task.id }
    private func cloneChildren(from source: UUID,to destination: UUID,asTemplate: Bool,dateShift: Double,visited: Set<UUID>) { let originals = tasks.filter { $0.parentID == source && !$0.deleted }; for var child in originals { let oldID = child.id; guard !visited.contains(oldID) else { continue }; child.id = UUID(); child.parentID = destination; child.sourceID = nil; child.completed = false; child.completedAt = nil; child.isTemplate = asTemplate; child.due = child.due?.addingTimeInterval(dateShift); child.start = child.start?.addingTimeInterval(dateShift); child.checks = child.checks.map { var c = $0; c.done = false; return c }; save(child,undoable: false); cloneChildren(from: oldID,to: child.id,asTemplate: asTemplate,dateShift: dateShift,visited: visited.union([oldID])) } }
    private func completeChildren(_ id: UUID,completed: Bool,visited: Set<UUID>) { for var child in tasks.filter({ $0.parentID == id && !$0.deleted }) { guard !visited.contains(child.id) else { continue }; child.completed = completed; child.completedAt = completed ? Date() : nil; child.checks = child.checks.map { var check = $0; check.done = completed; return check }; save(child,undoable: false); completeChildren(child.id,completed: completed,visited: visited.union([child.id])) } }
    func move(_ ids: Set<UUID>, to list: UUID?) { let before = backup; for id in ids { mutate(id) { $0.listID = list } }; groupUndo(before) }
    func groupUndo(_ before: Backup) { undoStack = Array(undoStack.prefix(while: { $0.created < before.created })); undoStack.append(before) }
    func undo() { guard let prior = undoStack.popLast() else { return }; redoStack.append(backup); apply(prior) }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(backup); apply(next) }
    func apply(_ data: Backup) {
        do {
            try restoreFiles(data.attachmentFiles ?? [:])
            func applyRecords<T: ListRecord>(_ old: [T], _ new: [T]) throws { for var r in old where !new.contains(where: { $0.id == r.id }) { r.deleted = true; try persistence.save(r) }; for r in new { try persistence.save(r) } }
            try applyRecords(tasks,data.tasks); try applyRecords(lists,data.lists); try applyRecords(filters,data.filters); try applyRecords(habits,data.habits); try applyRecords(focus,data.focus); try applyRecords(subscriptions,data.subscriptions); reload(); reschedule()
        } catch { self.error = error.localizedDescription }
    }
    func reschedule() { guard !persistence.inMemory else { return }; for task in tasks { NotificationService.shared.schedule(task) }; for habit in habits { NotificationService.shared.schedule(habit) } }
    func restoreFiles(_ files: [String: Data]) throws {
        for (path, data) in files { guard path.hasPrefix("Attachments/"), !path.contains(".."), !path.hasPrefix("/") else { throw ServiceError.message("备份包含非法附件路径") }; let url = persistence.root.appendingPathComponent(path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true); try data.write(to: url,options: .atomic); try persistence.saveBlob(path: path,data: data) }
    }
    func export(to url: URL) throws { var snapshot = backup; var files: [String: Data] = [:]; for a in tasks.flatMap(\.attachments) { if let data = try? Data(contentsOf: persistence.root.appendingPathComponent(a.relativePath)) { files[a.relativePath] = data } }; snapshot.attachmentFiles = files; let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; try encoder.encode(snapshot).write(to: url, options: .atomic) }
    func automaticBackup() {
        let folder = persistence.root.appendingPathComponent("Backups"); try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(Day.key(Date())).ownlist.json"); do { try export(to: url) } catch { self.error = "备份失败：\(error.localizedDescription)" }
        let cutoff = Date().addingTimeInterval(-30 * 86400); for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] { if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff { try? FileManager.default.removeItem(at: file) } }
    }
    func manualBackup() throws { let folder = persistence.root.appendingPathComponent("ManualBackups"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try export(to: folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970)).ownlist.json")) }
    func attach(_ urls: [URL], to id: UUID) {
        do { let directory = persistence.root.appendingPathComponent("Attachments"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var attachments: [Attachment] = []
            for url in urls { let name = UUID().uuidString + "-" + url.lastPathComponent; try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name)); try persistence.saveBlob(path: "Attachments/" + name,data: Data(contentsOf: url)); attachments.append(Attachment(name: url.lastPathComponent, relativePath: "Attachments/" + name)) }
            mutate(id) { $0.attachments += attachments }
        } catch { self.error = error.localizedDescription }
    }
}

// Keep system diagnostics out of the ordinary navigation while preserving actionable guidance.
enum CloudMessage {
    static func describe(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == CKErrorDomain {
            switch e.code {
            case CKError.notAuthenticated.rawValue: return "请在系统设置中登录 iCloud；本机数据仍会保存。"
            case CKError.networkUnavailable.rawValue, CKError.networkFailure.rawValue: return "网络暂不可用，联网后系统会继续同步；本机数据仍会保存。"
            case CKError.quotaExceeded.rawValue: return "iCloud 空间不足，请清理空间后重试；本机数据仍会保存。"
            case CKError.partialFailure.rawValue, CKError.serverRejectedRequest.rawValue, CKError.permissionFailure.rawValue: return "云数据库尚未就绪，请完成 CloudKit 配置；本机数据仍会保存。"
            default: return "iCloud 暂不可用，请稍后重新启动应用重试；本机数据仍会保存。"
            }
        }
        return "同步暂不可用，请重新启动应用重试；本机数据仍会保存。"
    }
}
