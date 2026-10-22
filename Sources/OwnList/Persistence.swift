import Foundation
import CoreData
import Combine
import CloudKit
import CryptoKit
#if os(macOS)
import AppKit
#endif

struct FieldVersion: Identifiable { var id: UUID; var owner: UUID; var kind: String; var field: String; var json: String; var timestamp: Date }
final class Persistence {
    let container: NSPersistentContainer
    let root: URL
    let inMemory: Bool
    private var inTransaction = false
    private var cacheLoaded = false
    private var fieldCache: [UUID: [String: String]] = [:]
    var loadError: String?
    var onChange: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var cloudObserver: NSObjectProtocol?
    var onCloudEvent: ((String) -> Void)?
    init(inMemory: Bool = false, cloud: Bool = UserDefaults.standard.bool(forKey: "cloudEnabled") && Capability.cloudAvailable) {
        self.inMemory = inMemory
        #if DEBUG
        let capturePath = ProcessInfo.processInfo.environment["ZILO_DATA_DIRECTORY"] ?? Bundle.main.object(forInfoDictionaryKey: "ZiloQADataDirectory") as? String
        let captureDirectory = capturePath.map { URL(fileURLWithPath: $0,isDirectory: true) }
        #else
        let captureDirectory: URL? = nil
        #endif
        let cloud = cloud && captureDirectory == nil
        root = inMemory ? FileManager.default.temporaryDirectory.appendingPathComponent("OwnListTests-" + UUID().uuidString,isDirectory: true) : captureDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OwnList", isDirectory: true)
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
            let message: String
            if let error = event.error { message = "同步失败：" + CloudMessage.describe(error) }
            else if event.endDate == nil { message = event.type == .setup ? "正在连接 iCloud…" : "正在同步…" }
            else if !event.succeeded { message = "同步失败：系统暂未完成同步，将自动重试" }
            else if event.type == .setup { message = "iCloud 已连接 · 等待数据同步" }
            else { message = "已同步 · " + Date().formatted(date: .omitted,time: .shortened) }
            self?.onCloudEvent?(message)
            if event.endDate != nil { self?.fieldCache.removeAll(); self?.cacheLoaded = false; self?.onChange?() }
        }
    }
    func versions(owner: UUID? = nil, kind: String? = nil) throws -> [FieldVersion] {
        let r = NSFetchRequest<NSManagedObject>(entityName: "FieldVersion"); if let owner { r.predicate = NSPredicate(format: "owner == %@", owner as CVarArg) }
        if let kind { r.predicate = NSPredicate(format: "kind == %@", kind) }
        return try container.viewContext.fetch(r).compactMap { o in guard let id = o.value(forKey: "id") as? UUID, let owner = o.value(forKey: "owner") as? UUID, let kind = o.value(forKey: "kind") as? String, let field = o.value(forKey: "field") as? String, let json = o.value(forKey: "json") as? String, let timestamp = o.value(forKey: "timestamp") as? Date else { return nil }; return FieldVersion(id: id, owner: owner, kind: kind, field: field, json: json, timestamp: timestamp) }.sorted { $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp }
    }
    func load<T: ListRecord>(_ type: T.Type) throws -> [T] {
        let values = try versions(kind: T.kind); var objects: [UUID: [String: Any]] = [:]
        // Resolve newest fields first. Historical versions remain available for
        // activity/restore, but their large document bodies need not be decoded.
        var resolved: [UUID: Set<String>] = [:]
        for value in values.reversed() {
            guard resolved[value.owner]?.contains(value.field) != true else { continue }
            var decoded = try JSONSerialization.jsonObject(with: Data(value.json.utf8), options: [.fragmentsAllowed])
            if value.field == "richText", let marker = decoded as? [String: String], let path = marker["documentBlob"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: "AttachmentBlob"); request.predicate = NSPredicate(format: "path == %@",path); request.fetchLimit = 1
                guard let data = try container.viewContext.fetch(request).first?.value(forKey: "data") as? Data else { onCloudEvent?("正文图片正在下载…"); continue }
                decoded = data.base64EncodedString()
            }
            resolved[value.owner,default: []].insert(value.field)
            objects[value.owner, default: [:]][value.field] = decoded
        }
        return try objects.values.filter { T.kind != SideNote.kind || $0["permanentlyDeleted"] as? Bool != true }.map { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) }
    }
    func save<T: ListRecord>(_ record: T) throws {
        let encoded = try JSONEncoder().encode(record); let dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        if !cacheLoaded { fieldCache.removeAll(); for v in try versions() { fieldCache[v.owner,default: [:]][v.field] = v.json }; cacheLoaded = true }; var previous = fieldCache[record.id] ?? [:]
        if T.kind == SideNote.kind && previous["permanentlyDeleted"] == "true" { throw NSError(domain: "Zilo.SideNotes",code: 1,userInfo: [NSLocalizedDescriptionKey:ZiloLanguage.text("便签已永久删除，无法恢复。")]) }
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
        if !inTransaction { try container.viewContext.save() }; fieldCache[record.id] = previous
    }
    /// Remove document/history fields and leave only a content-free tombstone.
    /// This prevents stale offline versions from making the note recoverable again.
    func purgeSideNote(_ note: SideNote) throws {
        guard note.deleted else { return }
        try transaction {
            let request = NSFetchRequest<NSManagedObject>(entityName: "FieldVersion")
            request.predicate = NSPredicate(format: "owner == %@ AND kind == %@",note.id as CVarArg,SideNote.kind)
            for object in try container.viewContext.fetch(request) { container.viewContext.delete(object) }
            fieldCache.removeAll(); cacheLoaded = false
            var marker = SideNote(); marker.id = note.id; marker.deleted = true; marker.permanentlyDeleted = true
            try save(marker)
        }
    }
    func ensureDefaultCountdowns(started: Date = Date()) throws {
        guard !inMemory, loadError == nil else { return }
        let existing = Set(try load(Countdown.self).map(\.id))
        let missing = Countdown.defaults(started: started).filter { !existing.contains($0.id) }
        if !missing.isEmpty { try transaction { for item in missing { try save(item) } } }
    }
    func saveBlob(path: String, data: Data) throws {
        let r = NSFetchRequest<NSManagedObject>(entityName: "AttachmentBlob"); r.predicate = NSPredicate(format: "path == %@",path); r.fetchLimit = 1
        guard try container.viewContext.fetch(r).isEmpty else { return }
        let object = NSEntityDescription.insertNewObject(forEntityName: "AttachmentBlob",into: container.viewContext); object.setValue(path,forKey: "path"); object.setValue(data,forKey: "data"); if !inTransaction { try container.viewContext.save() }
    }
    // Publish list and task tombstones together, including when disk writes fail.
    func transaction(_ body: () throws -> Void) throws {
        precondition(!inTransaction)
        inTransaction = true
        defer { inTransaction = false }
        do { try body(); try container.viewContext.save() }
        catch { container.viewContext.rollback(); fieldCache.removeAll(); cacheLoaded = false; throw error }
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
struct Backup: Codable { var formatVersion = 1; var created = Date(); var tasks: [TaskItem]; var lists: [TaskList]; var filters: [SavedFilter]; var habits: [Habit]; var focus: [FocusRecord]; var subscriptions: [CalendarSubscription]; var attachmentFiles: [String: Data]? = nil; var countdowns: [Countdown]? = nil; var sideNotes: [SideNote]? = nil; var noteFolders: [SideNoteFolder]? = nil }
#if os(macOS)
@MainActor final class Store: ObservableObject {
    let persistence: Persistence
    @Published var tasks: [TaskItem] = []; @Published var lists: [TaskList] = []; @Published var filters: [SavedFilter] = []; @Published var habits: [Habit] = []; @Published var focus: [FocusRecord] = []; @Published var subscriptions: [CalendarSubscription] = []
    @Published var sideNotes: [SideNote] = []; @Published var noteFolders: [SideNoteFolder] = []
    @Published var countdowns: [Countdown] = []; @Published var activity: [ActivityEntry] = []
    @Published var checkingSync = false
    @Published var notificationTask: UUID?; @Published var notificationHabit: UUID?; @Published var notificationCountdown: UUID?; @Published var notificationModule: Module?
    @Published var error: String?; @Published var syncStatus = "本地保存"; @Published var selectedTask: UUID?
    private var backupTimer: Timer?
    private var undoStack: [Backup] = []; private var redoStack: [Backup] = []
    init(persistence: Persistence = Persistence()) {
        self.persistence = persistence
        #if DEBUG
        selectedTask = ZiloScreenshotData.seed(persistence)
        #endif
        persistence.onChange = { [weak self] in Task { @MainActor in self?.reload(); self?.reschedule() } }
        persistence.onCloudEvent = { [weak self] message in Task { @MainActor in self?.syncStatus = message; if message.hasPrefix("同步失败") { self?.logActivity("同步失败",detail: message) } else if message.hasPrefix("已同步") { self?.logActivity("数据已同步",detail: message) } } }
        if !persistence.inMemory, let data = try? Data(contentsOf: persistence.root.appendingPathComponent("Activity.json")) { activity = (try? JSONDecoder().decode([ActivityEntry].self,from: data)) ?? [] }
        do { try persistence.ensureDefaultCountdowns(started: (try? persistence.load(TaskItem.self).map(\.created).min()) ?? Date()) } catch { self.error = error.localizedDescription }
        reload(); reschedule(); if UserDefaults.standard.bool(forKey: "cloudEnabled") && Capability.cloudAvailable { syncStatus = "等待 iCloud 同步" }
        if !persistence.inMemory && !UserDefaults.standard.bool(forKey: "didInitialize") { do { if lists.isEmpty { try persistence.save(TaskList(name: "学习", color: "blue", order: 0)); try persistence.save(TaskList(name: "工作", color: "green", order: 1)); try persistence.save(TaskList(name: "家庭生活", color: "orange", order: 2)) }; UserDefaults.standard.set(true, forKey: "didInitialize"); reload() } catch { self.error = error.localizedDescription } }
        if !persistence.inMemory { automaticBackup(); backupTimer = Timer.scheduledTimer(withTimeInterval: 3600,repeats: true) { [weak self] _ in Task { @MainActor in self?.automaticBackup() } } }
    }
    func reload() {
        do { if let failure = persistence.loadError { throw ServiceError.message(failure) }; if !persistence.inMemory { try persistence.restoreBlobs() }; tasks = try persistence.load(TaskItem.self); lists = try persistence.load(TaskList.self); filters = try persistence.load(SavedFilter.self); habits = try persistence.load(Habit.self); focus = try persistence.load(FocusRecord.self); subscriptions = try persistence.load(CalendarSubscription.self); countdowns = try persistence.load(Countdown.self); sideNotes = try persistence.load(SideNote.self); noteFolders = try persistence.load(SideNoteFolder.self); try migrateInlineDocumentImages() } catch { self.error = "读取数据失败：\(error.localizedDescription)" }
        if !persistence.inMemory { DesktopBridge.updateBadge(tasks.filter { $0.isPendingTask && $0.due.map { Calendar.current.isDateInToday($0) } == true }.count)
        WidgetSnapshot.write(tasks: tasks, lists: lists) }
    }
    var trashEntryCount: Int {
        let deletedLists = Set(lists.filter(\.deleted).map(\.id))
        return deletedLists.count + tasks.filter { $0.deleted && $0.trashedWithList.map(deletedLists.contains) != true }.count
    }
    var backup: Backup { Backup(tasks: tasks, lists: lists, filters: filters, habits: habits, focus: focus, subscriptions: subscriptions, countdowns: countdowns,sideNotes: sideNotes,noteFolders: noteFolders) }
    @discardableResult func save<T: ListRecord>(_ record: T, undoable: Bool = true) -> Bool {
        let before = undoable ? backup : nil
        do { var prepared = record
            if var task = record as? TaskItem, task.editingMode == .markdown, task.notes.contains("data:image/") { try externalizeDocumentImages(&task); prepared = task as! T }
            try persistence.save(prepared); if let before { undoStack.append(before); if undoStack.count > 40 { undoStack.removeFirst() }; redoStack.removeAll() }; updatePublished(prepared); if !persistence.inMemory { if let task = prepared as? TaskItem { NotificationService.shared.schedule(task) }; if let habit = record as? Habit { NotificationService.shared.schedule(habit) }; if let day = record as? Countdown { NotificationService.shared.schedule(day) }; if let task = record as? TaskItem, undoable { logActivity(task.deleted ? "任务已删除" : task.completed ? "任务已完成" : "任务已更新",detail: task.title,owner: task.id) }; if let habit = record as? Habit { logActivity(habit.deleted ? "习惯已删除" : "习惯已更新",detail: habit.name,owner: habit.id) }; if let day = record as? Countdown { logActivity(day.deleted ? "纪念日已删除" : "纪念日已更新",detail: day.name,owner: day.id) }; if let focus = record as? FocusRecord { logActivity(focus.deleted ? "专注记录已删除" : "专注已记录",detail: "\(Int(focus.seconds / 60)) 分钟 · \(focus.mode)",owner: focus.id) } }; return true } catch { self.error = error.localizedDescription; return false }
    }
    /// Images use the existing attachment backup and CloudKit blob transport.
    func writeDocumentImage(_ bytes: Data,name: String = "图片.png") throws -> String {
        let image = try RichDocument.image(bytes,name: name)
        guard let attachment = image.attribute(.attachment,at: 0,effectiveRange: nil) as? NSTextAttachment, let png = RichDocument.imageData(attachment) else { throw RichDocument.TransferError.invalidImage(name) }
        let digest = SHA256.hash(data: png).map { String(format: "%02x",$0) }.joined()
        let path = "Attachments/Images/" + digest.prefix(24) + ".png"
        let file = persistence.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { try png.write(to: file,options: .atomic) }
        try persistence.saveBlob(path: path,data: png)
        return path
    }
    func saveDocumentImage(_ bytes: Data,name: String,to id: UUID) throws -> String {
        guard var task = tasks.first(where: { $0.id == id }) else { throw ServiceError.message("未找到要添加图片的任务。") }
        let path = try writeDocumentImage(bytes,name: name)
        if !task.attachments.contains(where: { $0.relativePath == path }) {
            task.attachments.append(Attachment(name: name,relativePath: path))
            guard save(task,undoable: false) else { throw ServiceError.message(error ?? "图片保存失败") }
        }
        return path
    }
    func externalizeDocumentImages(_ task: inout TaskItem) throws {
        guard task.editingMode == .markdown else { return }
        var images = task.attachments
        let source = try MarkdownDocument.rewriteImages(task.notes) { address in
            guard address.hasPrefix("data:image/"), let bytes = MarkdownDocument.imageBytes(address,baseURL: nil) else { return address }
            let path = try writeDocumentImage(bytes)
            if !images.contains(where: { $0.relativePath == path }) { images.append(Attachment(name: "图片.png",relativePath: path)) }
            return path
        }
        task.notes = source; task.attachments = images
    }
    private func migrateInlineDocumentImages() throws {
        let legacy = tasks.filter { $0.editingMode == .markdown && $0.notes.contains("data:image/") }
        guard !legacy.isEmpty else { return }
        var changed: [TaskItem] = []
        for var task in legacy {
            let original = task.notes
            try externalizeDocumentImages(&task)
            if task.notes != original { changed.append(task) }
        }
        guard !changed.isEmpty else { return }
        if !persistence.inMemory { try manualBackup() }
        try persistence.transaction { for task in changed { try persistence.save(task) } }
        for task in changed { if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } }
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
        if let r = record as? TaskItem { tasks = updated(tasks,r); if !persistence.inMemory { DesktopBridge.updateBadge(tasks.filter { $0.isPendingTask && $0.due.map { Calendar.current.isDateInToday($0) } == true }.count); WidgetSnapshot.write(tasks: tasks,lists: lists) } }
        if let r = record as? SideNote { sideNotes = updated(sideNotes,r) }; if let r = record as? SideNoteFolder { noteFolders = updated(noteFolders,r) }
        if let r = record as? TaskList { lists = updated(lists,r) }; if let r = record as? SavedFilter { filters = updated(filters,r) }; if let r = record as? Habit { habits = updated(habits,r) }; if let r = record as? FocusRecord { focus = updated(focus,r) }; if let r = record as? CalendarSubscription { subscriptions = updated(subscriptions,r) }; if let r = record as? Countdown { countdowns = updated(countdowns,r) }
    }
    @discardableResult func deleteList(_ id: UUID) -> Bool {
        guard var list = lists.first(where: { $0.id == id && !$0.deleted }) else { return false }
        list.deleted = true
        var members = Set(tasks.filter { $0.listID == id && !$0.deleted }.map(\.id))
        // Include descendants even if an older import assigned a different list.
        var previousCount = -1
        while previousCount != members.count {
            previousCount = members.count
            for task in tasks where !task.deleted && task.parentID.map(members.contains) == true { members.insert(task.id) }
        }
        let changed = tasks.filter { members.contains($0.id) }.map { original -> TaskItem in
            var task = original; task.deleted = true; task.trashedWithList = id; return task
        }
        return saveListChange(list,tasks: changed)
    }
    @discardableResult func restoreList(_ id: UUID) -> Bool {
        guard var list = lists.first(where: { $0.id == id && $0.deleted }) else { return false }
        let originalName = list.name
        var suffix = 0
        while lists.contains(where: { !$0.deleted && $0.folder.localizedCaseInsensitiveCompare(list.folder) == .orderedSame && $0.name.localizedCaseInsensitiveCompare(list.name) == .orderedSame }) {
            suffix += 1; list.name = originalName + (suffix == 1 ? "（恢复）" : "（恢复 \(suffix)）")
        }
        list.deleted = false
        let changed = tasks.filter { $0.trashedWithList == id }.map { original -> TaskItem in
            var task = original; task.deleted = false; task.trashedWithList = nil; return task
        }
        return saveListChange(list,tasks: changed)
    }
    private func saveListChange(_ list: TaskList,tasks changed: [TaskItem]) -> Bool {
        let before = backup
        do {
            try persistence.transaction { try persistence.save(list); for task in changed { try persistence.save(task) } }
            let changes = Dictionary(uniqueKeysWithValues: changed.map { ($0.id,$0) })
            lists = lists.map { $0.id == list.id ? list : $0 }
            tasks = tasks.map { changes[$0.id] ?? $0 }
            groupUndo(before); redoStack.removeAll()
            if !persistence.inMemory {
                DesktopBridge.updateBadge(tasks.filter { $0.isPendingTask && $0.due.map { Calendar.current.isDateInToday($0) } == true }.count)
                WidgetSnapshot.write(tasks: tasks,lists: lists)
                for task in changed { NotificationService.shared.schedule(task) }
            }
            if selectedTask.map({ id in changed.contains { $0.id == id && $0.deleted } }) == true { selectedTask = nil }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func setTaskAbandoned(_ id: UUID,to value: Bool) -> Bool {
        guard let root = tasks.first(where: { $0.id == id && !$0.deleted }) else { return false }
        let changed = TaskHierarchy.rows(root: root,tasks: tasks,collapsed: []).map { row -> TaskItem in
            var task = row.task
            if task.id != id && task.completed { return task }
            task.abandoned = value
            if value { task.archived = false }
            if value { task.completed = false; task.completedAt = nil }
            return task
        }
        return savePlacement(tasks: changed,lists: [])
    }
    @discardableResult func setTaskNote(_ id: UUID,to value: Bool) -> Bool {
        guard var task = tasks.first(where: { $0.id == id && !$0.deleted }) else { return false }
        task.isNote = value
        if value { task.completed = false; task.completedAt = nil; task.abandoned = false }
        return save(task)
    }
    @discardableResult func setTaskDate(_ id: UUID,date: Date?,allDay: Bool) -> Bool {
        guard var task = tasks.first(where: { $0.id == id && !$0.deleted }) else { return false }
        task.setDue(date); task.allDay = allDay; task.repeatRule.anchor = date
        if date != nil && task.reminders.isEmpty { task.reminders = TaskCreationPreferences.reminders(allDay: allDay) }
        return save(task)
    }
    @discardableResult func placeTask(_ source: UUID,relativeTo target: UUID,position: TaskPlacement.Position) -> Bool {
        guard let changed = TaskPlacement.changes(tasks,source: source,target: target,position: position) else { return false }
        return savePlacement(tasks: changed,lists: [])
    }
    @discardableResult func promoteTask(_ id: UUID) -> Bool {
        guard let changed = TaskPlacement.promotedChanges(tasks,source: id) else { return false }
        return savePlacement(tasks: changed,lists: [])
    }
    @discardableResult func placeList(_ source: UUID,relativeTo target: UUID? = nil,after: Bool = false,folder: String? = nil) -> Bool {
        guard let changed = TaskPlacement.listChanges(lists,source: source,target: target,after: after,folder: folder) else { return false }
        return savePlacement(tasks: [],lists: changed)
    }
    @discardableResult func moveTaskTree(_ id: UUID,to listID: UUID?) -> Bool {
        guard var root = tasks.first(where: { $0.id == id && !$0.deleted }), listID == nil || lists.contains(where: { $0.id == listID && !$0.deleted }) else { return false }
        let descendants = TaskHierarchy.rows(root: root,tasks: tasks,collapsed: []).dropFirst().map(\.task)
        root.parentID = nil; root.listID = listID; root.section = ""
        let changed = [root] + descendants.map { original in var child = original; child.listID = listID; child.section = ""; return child }
        return savePlacement(tasks: changed,lists: [])
    }
    private func savePlacement(tasks changedTasks: [TaskItem],lists changedLists: [TaskList]) -> Bool {
        guard !changedTasks.isEmpty || !changedLists.isEmpty else { return true }
        let before = backup
        do {
            try persistence.transaction {
                for task in changedTasks { try persistence.save(task) }
                for list in changedLists { try persistence.save(list) }
            }
            for task in changedTasks { updatePublished(task) }
            for list in changedLists { updatePublished(list) }
            groupUndo(before); redoStack.removeAll()
            if !persistence.inMemory {
                WidgetSnapshot.write(tasks: tasks,lists: lists)
                for task in changedTasks { NotificationService.shared.schedule(task) }
                DesktopBridge.updateBadge(tasks.filter { $0.isPendingTask && $0.due.map { Calendar.current.isDateInToday($0) } == true }.count)
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func restoreTask(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id && $0.deleted }) else { return }
        let before = backup
        if let listID = task.trashedWithList ?? task.listID, lists.contains(where: { $0.id == listID && $0.deleted }) {
            guard restoreList(listID) else { return }
        }
        mutate(id) { $0.deleted = false; $0.trashedWithList = nil }
        groupUndo(before)
    }
    func mutate(_ id: UUID, _ body: (inout TaskItem) -> Void) { guard var task = tasks.first(where: { $0.id == id }) else { return }; let before = backup; let wasDeleted = task.deleted; body(&task); guard save(task) else { return }; if task.deleted != wasDeleted { cascadeDelete(id,deleted: task.deleted,visited: [id]); groupUndo(before) } }
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
        let parsed = TaskCreationPreferences.parse(input); guard !parsed.title.isEmpty else { return nil }
        var task = TaskItem(); task.documentMode = DocumentEditingMode.defaultMode(); task.title = parsed.title; task.due = parsed.due ?? defaultDue ?? TaskCreationPreferences.due(); task.section = section; task.starred = starred; task.tags = parsed.tags; task.priority = parsed.priority == 0 ? max(0,min(3,UserDefaults.standard.integer(forKey: "defaultPriority"))) : parsed.priority; task.listID = listID; task.parentID = parentID
        task.allDay = task.due.map { Calendar.current.component(.hour, from: $0) == 0 && Calendar.current.component(.minute, from: $0) == 0 } ?? true
        if task.due != nil { task.reminders = TaskCreationPreferences.reminders(allDay: task.allDay) }; guard save(task) else { return nil }; selectedTask = task.id; return task.id
    }
    func complete(_ id: UUID) {
        guard var task = tasks.first(where: { $0.id == id && $0.isNote != true && $0.abandoned != true }) else { return }
        let before = backup; task.completed.toggle(); task.completedAt = task.completed ? Date() : nil; task.checks = task.checks.map { var c = $0; c.done = task.completed; return c }; save(task)
        if task.completed && !persistence.inMemory && UserDefaults.standard.bool(forKey: "completionSound") { NSSound(named: "Pop")?.play() }
        completeChildren(task.id,completed: task.completed,visited: [task.id])
        if task.repeatRule.anchor == nil { task.repeatRule.anchor = task.due }; if task.completed, let due = task.due, let next = task.repeatRule.next(after: due) { var nextTask = task; if let count = nextTask.repeatRule.remainingCount { nextTask.repeatRule.remainingCount = count - 1 }; nextTask.id = UUID(); nextTask.sourceID = nil; nextTask.completed = false; nextTask.completedAt = nil; nextTask.due = next; nextTask.created = Date(); if let start = task.start { nextTask.start = next.addingTimeInterval(start.timeIntervalSince(due)) }; nextTask.checks = task.checks.map { var c = $0; c.done = false; c.due = c.due?.addingTimeInterval(next.timeIntervalSince(due)); return c }; save(nextTask, undoable: false)
            cloneChildren(from: id,to: nextTask.id,asTemplate: false,dateShift: next.timeIntervalSince(due),visited: [id])
            if !undoStack.isEmpty { undoStack[undoStack.count - 1] = before }
        }
    }
    @discardableResult func duplicate(_ id: UUID,asTemplate: Bool = false) -> UUID? { guard var task = tasks.first(where: { $0.id == id }) else { return nil }; let before = backup; let oldID = task.id; task.id = UUID(); task.parentID = nil; task.sourceID = nil; task.completed = false; task.completedAt = nil; task.abandoned = false; task.pinned = false; task.created = Date(); task.isTemplate = asTemplate; task.checks = task.checks.map { var c = $0; c.done = false; return c }; save(task); cloneChildren(from: oldID,to: task.id,asTemplate: asTemplate,dateShift: 0,visited: [oldID]); groupUndo(before); selectedTask = task.id; return task.id }
    private func cloneChildren(from source: UUID,to destination: UUID,asTemplate: Bool,dateShift: Double,visited: Set<UUID>) { let originals = tasks.filter { $0.parentID == source && !$0.deleted }; for var child in originals { let oldID = child.id; guard !visited.contains(oldID) else { continue }; child.id = UUID(); child.parentID = destination; child.sourceID = nil; child.completed = false; child.completedAt = nil; child.abandoned = false; child.pinned = false; child.isTemplate = asTemplate; child.due = child.due?.addingTimeInterval(dateShift); child.start = child.start?.addingTimeInterval(dateShift); child.checks = child.checks.map { var c = $0; c.done = false; c.due = c.due?.addingTimeInterval(dateShift); return c }; save(child,undoable: false); cloneChildren(from: oldID,to: child.id,asTemplate: asTemplate,dateShift: dateShift,visited: visited.union([oldID])) } }
    private func completeChildren(_ id: UUID,completed: Bool,visited: Set<UUID>) { for var child in tasks.filter({ $0.parentID == id && !$0.deleted && $0.isNote != true && $0.abandoned != true }) { guard !visited.contains(child.id) else { continue }; child.completed = completed; child.completedAt = completed ? Date() : nil; child.checks = child.checks.map { var check = $0; check.done = completed; return check }; save(child,undoable: false); completeChildren(child.id,completed: completed,visited: visited.union([child.id])) } }
    func move(_ ids: Set<UUID>, to list: UUID?) { let before = backup; for id in ids { mutate(id) { $0.listID = list } }; groupUndo(before) }
    func groupUndo(_ before: Backup) { undoStack = Array(undoStack.prefix(while: { $0.created < before.created })); undoStack.append(before) }
    func undo() { guard let prior = undoStack.popLast() else { return }; redoStack.append(backup); apply(prior) }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(backup); apply(next) }
    func apply(_ data: Backup) {
        do {
            try restoreFiles(data.attachmentFiles ?? [:])
            func applyRecords<T: ListRecord>(_ old: [T], _ new: [T]) throws { for var r in old where !new.contains(where: { $0.id == r.id }) { r.deleted = true; try persistence.save(r) }; for r in new { try persistence.save(r) } }
            try applyRecords(tasks,data.tasks); try applyRecords(lists,data.lists); try applyRecords(filters,data.filters); try applyRecords(habits,data.habits); try applyRecords(focus,data.focus); try applyRecords(subscriptions,data.subscriptions); try applyRecords(countdowns,data.countdowns ?? []); if let notes = data.sideNotes { try applyRecords(sideNotes,notes) }; if let folders = data.noteFolders { try applyRecords(noteFolders,folders) }; reload(); reschedule()
        } catch { self.error = error.localizedDescription }
    }
    func reschedule() { guard !persistence.inMemory else { return }; for task in tasks { NotificationService.shared.schedule(task) }; for habit in habits { NotificationService.shared.schedule(habit) }; for day in countdowns { NotificationService.shared.schedule(day) } }
    func logActivity(_ title: String, detail: String, owner: UUID? = nil) {
        guard !persistence.inMemory else { return }
        if let last = activity.first, last.title == title, last.detail == detail, last.owner == owner, Date().timeIntervalSince(last.date) < 60 { return }
        activity.insert(ActivityEntry(title: title,detail: detail,owner: owner),at: 0); activity = Array(activity.prefix(200))
        do { try JSONEncoder().encode(activity).write(to: persistence.root.appendingPathComponent("Activity.json"),options: .atomic) } catch { self.error = "活动记录保存失败：\(error.localizedDescription)" }
    }
    func checkSync() async {
        guard !checkingSync else { return }; checkingSync = true; defer { checkingSync = false }
        guard Capability.cloudAvailable else { syncStatus = "此构建未启用 iCloud 同步"; return }
        guard UserDefaults.standard.bool(forKey: "cloudEnabled") else { syncStatus = "iCloud 同步已关闭 · 本地保存"; return }
        guard persistence.container is NSPersistentCloudKitContainer else { syncStatus = "重启 Zilo 后启用 iCloud 同步"; return }
        do {
            let account = try await CKContainer(identifier: "iCloud.com.gaoluchuan.ownlist").accountStatus()
            guard account == .available else { syncStatus = account == .noAccount ? "请在系统设置中登录 iCloud" : "iCloud 账户暂不可用"; return }
            try persistence.container.viewContext.save()
            // Re-read imported data; the CloudKit container manages transfer and retries.
            persistence.container.viewContext.refreshAllObjects(); reload(); reschedule()
            if !syncStatus.hasPrefix("同步失败"), !syncStatus.hasPrefix("已同步") { syncStatus = "iCloud 已连接 · 等待系统同步" }
        } catch { syncStatus = "同步失败：" + CloudMessage.describe(error); logActivity("同步失败",detail: syncStatus) }
    }
    func restoreFiles(_ files: [String: Data]) throws {
        for (path, data) in files { guard path.hasPrefix("Attachments/"), !path.contains(".."), !path.hasPrefix("/") else { throw ServiceError.message("备份包含非法附件路径") }; let url = persistence.root.appendingPathComponent(path); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true); try data.write(to: url,options: .atomic); try persistence.saveBlob(path: path,data: data) }
    }
    func export(to url: URL) throws { var snapshot = backup; var files: [String: Data] = [:]; for a in tasks.flatMap(\.attachments) + sideNotes.flatMap(\.attachments) { if let data = try? Data(contentsOf: persistence.root.appendingPathComponent(a.relativePath)) { files[a.relativePath] = data } }; snapshot.attachmentFiles = files; let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; try encoder.encode(snapshot).write(to: url, options: .atomic) }
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

#endif

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

#if DEBUG
/// Real persisted sample records for isolated screenshot builds. Never runs in Release.
enum ZiloScreenshotData {
    static func seed(_ persistence: Persistence) -> UUID? {
        guard ProcessInfo.processInfo.environment["ZILO_SCREENSHOTS"] == "1",
              ProcessInfo.processInfo.environment["ZILO_DATA_DIRECTORY"] != nil,
              (try? persistence.load(TaskItem.self).isEmpty) == true else { return nil }
        let english = ZiloLanguage.locale.identifier.hasPrefix("en")
        func label(_ zh: String,_ en: String) -> String { english ? en : zh }
        let day = Calendar.current.startOfDay(for: Date())
        let work = TaskList(name: label("工作","Work"),color: "blue",order: 0)
        let life = TaskList(name: label("生活","Personal"),color: "green",order: 1)
        let learning = TaskList(name: label("学习","Learning"),color: "orange",order: 2)
        var plan = TaskItem(); plan.title = label("准备产品发布","Plan the product launch"); plan.listID = work.id; plan.due = day; plan.priority = 2; plan.order = 0; plan.documentMode = .markdown
        plan.notes = english ? "## A thoughtful release\n\nKeep the important things in one place.\n\n### Release checklist\n- Review the app experience\n- Capture both interface languages\n- Publish the latest Mac download\n\n### A small piece of code\n```swift\nlet message = \"Hello, Zilo\"\nprint(message)\n```" : "## 认真准备每一次发布\n\n把重要的事情，放在一个地方。\n\n### 发布清单\n- 检查应用体验\n- 采集中英文真实界面\n- 发布最新 Mac 安装包\n\n### 一小段代码\n```swift\nlet message = \"你好，Zilo\"\nprint(message)\n```"
        var child = TaskItem(); child.title = label("完成截图与说明","Finalize screenshots and copy"); child.parentID = plan.id; child.listID = work.id; child.order = 1
        var finished = TaskItem(); finished.title = label("确认发布清单","Review the release checklist"); finished.parentID = plan.id; finished.listID = work.id; finished.order = 0; finished.completed = true; finished.completedAt = Date()
        var review = TaskItem(); review.title = label("回顾本周计划","Review the weekly plan"); review.notes = label("留一点时间，看看进展和下一步。","Make time to reflect and choose the next step."); review.listID = work.id; review.due = day; review.order = 2
        var read = TaskItem(); read.title = label("阅读 20 分钟","Read for 20 minutes"); read.listID = learning.id; read.due = day; read.order = 3; read.tags = [label("阅读","reading")]
        var walk = TaskItem(); walk.title = label("傍晚散步","Take an evening walk"); walk.listID = life.id; walk.due = day; walk.order = 4
        var habit = Habit(name: label("每天阅读","Read every day")); habit.emoji = "📚"; habit.logs = [Day.key(day):1]
        var countdown = Countdown(name: label("下次旅行","Next trip"),date: Calendar.current.date(byAdding: .day,value: 18,to: day)!); countdown.emoji = "✈️"
        do {
            try persistence.transaction {
                for list in [work,life,learning] { try persistence.save(list) }
                for task in [plan,child,finished,review,read,walk] { try persistence.save(task) }
                try persistence.save(habit); try persistence.save(countdown)
            }
            UserDefaults.standard.set(true,forKey: "didInitialize")
            return plan.id
        } catch { return nil }
    }
}
#endif
