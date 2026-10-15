import Foundation

/// Localize interface labels without changing persisted identifiers or user content.
enum ZiloLanguage {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
    static var locale: Locale { Locale(identifier: bundle.preferredLocalizations.first ?? "zh-Hans") }
    static func text(_ key: String) -> String { bundle.localizedString(forKey: key,value: key,table: "Localizable") }
    static func format(_ key: String,_ arguments: CVarArg...) -> String { String(format: text(key),locale: locale,arguments: arguments) }
    static func select(_ language: String) {
        if language == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([language],forKey: "AppleLanguages") }
    }
    static func status(_ message: String) -> String {
        for (prefix,key) in [("已同步 · ","Synced · "),("同步失败：","Sync failed: "),("存储错误：","Storage error: ")] {
            if locale.identifier.hasPrefix("en"), message.hasPrefix(prefix) { return key + String(message.dropFirst(prefix.count)) }
        }
        return text(message)
    }
}

protocol ListRecord: Codable, Identifiable where ID == UUID { var id: UUID { get }; var deleted: Bool { get set }; static var kind: String { get } }


enum DocumentEditingMode: String, Codable, CaseIterable {
    case richText, markdown
    var title: String { self == .richText ? "富文本" : "Markdown" }
    static func defaultMode(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: "defaultDocumentMode").flatMap(Self.init(rawValue:)) ?? .richText
    }
}
struct TaskItem: ListRecord, Hashable {
    static let kind = "task"
    var id = UUID(); var deleted = false
    var title = ""; var notes = ""; var richText: Data?; var listID: UUID?; var section = ""; var tags: [String] = []
    var documentMode: DocumentEditingMode?
    var editingMode: DocumentEditingMode { documentMode ?? .richText }
    var priority = 0; var starred = false; var completed = false; var completedAt: Date?
    var start: Date?; var due: Date?; var allDay = true; var duration: Double = 1800
    var reminders: [Double] = []; var repeatRule = RepeatRule(); var parentID: UUID?
    var trashedWithList: UUID?; var trashedWithParent: UUID?; var checks: [CheckItem] = []; var attachments: [Attachment] = []
    var created = Date(); var order: Double = Date().timeIntervalSince1970; var isTemplate = false
    var archived: Bool?; var special = ""; var sourceID: String?
    var pinned: Bool?; var abandoned: Bool?; var isNote: Bool?
    var isPendingTask: Bool { !deleted && !completed && !isTemplate && archived != true && abandoned != true && isNote != true }
}
struct CheckItem: Codable, Hashable, Identifiable { var id = UUID(); var title: String; var done = false; var due: Date?; var reminders: [Double]? }
struct PlannedReminder: Identifiable, Equatable {
    var id: String; var title: String; var body: String; var date: Date; var checkID: UUID?
}
extension TaskItem {
    /// The deadline is the end of the time block; keep calendar duration consistent.
    mutating func setStart(_ value: Date?) {
        start = value
        guard let value else { return }
        if let due, due > value { duration = due.timeIntervalSince(value) }
        else { due = value.addingTimeInterval(max(60,duration)) }
    }
    mutating func setDue(_ value: Date?) {
        due = value
        guard let value else { start = nil; reminders = []; return }
        if let start {
            if value > start { duration = value.timeIntervalSince(start) }
            else { self.start = value.addingTimeInterval(-max(60,duration)) }
        }
    }
    func plannedReminders(after now: Date = Date()) -> [PlannedReminder] {
        guard isPendingTask else { return [] }
        var result: [PlannedReminder] = []
        if let due {
            for offset in Set(reminders.filter { $0.isFinite && $0 >= 0 }).sorted() {
                let date = due.addingTimeInterval(-offset)
                if date > now { result.append(PlannedReminder(id: "\(id)-task-\(offset)",title: title,body: String(notes.prefix(250)),date: date)) }
            }
        }
        for check in checks where !check.done {
            guard let due = check.due else { continue }
            for offset in Set((check.reminders ?? [0]).filter { $0.isFinite && $0 >= 0 }).sorted() {
                let date = due.addingTimeInterval(-offset)
                if date > now { result.append(PlannedReminder(id: "\(id)-check-\(check.id)-\(offset)",title: check.title,body: title,date: date,checkID: check.id)) }
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}

struct Attachment: Codable, Hashable, Identifiable { var id = UUID(); var name: String; var relativePath: String }
struct TaskList: ListRecord, Hashable {
    static let kind = "list"
    var id = UUID(); var deleted = false; var name: String; var color = "blue"; var folder = ""; var sections: [String] = []; var order = 0; var defaultView: String?
}
struct SavedFilter: ListRecord, Hashable {
    static let kind = "filter"
    var id = UUID(); var deleted = false; var name: String; var text = ""; var tag = ""; var priority = -1; var listID: UUID?; var days = -1; var starredOnly = false
    func matches(_ task: TaskItem, now: Date = Date()) -> Bool {
        !task.deleted && task.archived != true && !task.completed && !task.isTemplate && (text.isEmpty || (task.title + task.notes).localizedCaseInsensitiveContains(text)) && (tag.isEmpty || task.tags.contains(tag)) && (priority < 0 || priority == task.priority) && (listID == nil || listID == task.listID) && (!starredOnly || task.starred) && (days < 0 || task.due.map { $0 < Calendar.current.date(byAdding: .day, value: days + 1, to: Calendar.current.startOfDay(for: now))! } == true)
    }
}
struct Habit: ListRecord, Hashable {
    static let kind = "habit"
    var id = UUID(); var deleted = false; var name: String; var emoji = "🌱"; var goal = 1; var weekdays = [1,2,3,4,5,6,7]; var reminderHour = -1; var logs: [String: Int] = [:]
    func count(on date: Date) -> Int { logs[Day.key(date)] ?? 0 }
    func streak(now: Date = Date()) -> Int {
        var result = 0; var day = Calendar.current.startOfDay(for: now)
        if count(on: day) < goal { day = Calendar.current.date(byAdding: .day, value: -1, to: day)! }
        for _ in 0..<3660 {
            if weekdays.contains(Calendar.current.component(.weekday, from: day)) {
                if count(on: day) < goal { break }; result += 1
            }
            day = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        }
        return result
    }
}
struct FocusRecord: ListRecord, Hashable {
    static let kind = "focus"
    var id = UUID(); var deleted = false; var taskID: UUID?; var started: Date; var seconds: Double; var mode: String; var completedPomodoro: Bool?; var ended: Date?
    var isPomodoro: Bool { mode == "番茄" && (completedPomodoro ?? (seconds >= 1500)) }
}
struct CalendarSubscription: ListRecord, Hashable {
    static let kind = "subscription"
    var id = UUID(); var deleted = false; var name: String; var url: String
}
struct ExternalEvent: Identifiable, Hashable { var id: String; var title: String; var start: Date; var end: Date; var source: String }
struct RepeatRule: Codable, Hashable {
    var frequency = "none"; var interval = 1; var weekdays: [Int] = []; var afterCompletion = false; var until: Date?
    var remainingCount: Int?; var monthDay: Int?; var ordinal: Int?; var weekday: Int?; var lunarMonth = 1; var lunarDay = 1; var anchor: Date?
    func next(after date: Date, completedAt: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard frequency != "none", remainingCount == nil || remainingCount! > 1 else { return nil }
        let base = afterCompletion ? completedAt : date; let n = max(1, interval)
        var value: Date?
        switch frequency {
        case "daily": value = calendar.date(byAdding: .day, value: n, to: base)
        case "weekly":
            if weekdays.isEmpty { value = calendar.date(byAdding: .weekOfYear, value: n, to: base) }
            else { let origin = calendar.dateInterval(of: .weekOfYear, for: anchor ?? base)!.start; for offset in 1...(7 * n + 7) { let d = calendar.date(byAdding: .day, value: offset, to: base)!; let week = calendar.dateInterval(of: .weekOfYear,for: d)!.start; let weeks = (calendar.dateComponents([.day],from: origin,to: week).day ?? 0) / 7; if weekdays.contains(calendar.component(.weekday, from: d)) && weeks % n == 0 { value = d; break } } }
        case "workdays": for offset in 1...7 { let d = calendar.date(byAdding: .day, value: offset, to: base)!; if (2...6).contains(calendar.component(.weekday, from: d)) { value = d; break } }
        case "monthly":
            let day = calendar.component(.day, from: base)
            var c = calendar.dateComponents([.year, .month, .hour, .minute, .second], from: base); c.day = 1
            if let first = calendar.date(from: c), let target = calendar.date(byAdding: .month, value: n, to: first), let range = calendar.range(of: .day, in: .month, for: target) { c = calendar.dateComponents([.year, .month, .hour, .minute, .second], from: target); c.day = min(day, range.count); value = calendar.date(from: c) }
        case "monthEnd":
            var c = calendar.dateComponents([.year, .month, .hour, .minute], from: base); c.day = 1
            if let first = calendar.date(from: c), let target = calendar.date(byAdding: .month, value: n + 1, to: first) { value = calendar.date(byAdding: .day, value: -1, to: target) }
        case "monthlyDay", "monthlyWeekday":
            var c = calendar.dateComponents([.year,.month,.hour,.minute,.second],from: base); c.day = 1
            if let first = calendar.date(from: c) { for addition in 0...(n * 2) { guard let target = calendar.date(byAdding: .month,value: addition,to: first), let range = calendar.range(of: .day,in: .month,for: target) else { continue }; var candidates: [Date] = []; for d in range { var dc = calendar.dateComponents([.year,.month,.hour,.minute,.second],from: target); dc.day = d; let candidate = calendar.date(from: dc)!; if frequency == "monthlyDay" { let requested = monthDay ?? 1; if d == (requested < 0 ? range.count + requested + 1 : requested) { candidates.append(candidate) } } else if calendar.component(.weekday,from: candidate) == (weekday ?? 2) { candidates.append(candidate) } }; if frequency == "monthlyWeekday" { let index = ordinal ?? 1; candidates = index > 0 ? Array(candidates.dropFirst(index - 1).prefix(1)) : Array(candidates.suffix(abs(index)).prefix(1)) }; if addition % n == 0, let candidate = candidates.first(where: { $0 > base }) { value = candidate; break } } }
        case "yearly": value = calendar.date(byAdding: .year, value: n, to: base)
        case "lunar":
            var lunar = Calendar(identifier: .chinese); lunar.timeZone = calendar.timeZone
            let time = calendar.dateComponents([.hour,.minute,.second], from: date)
            for offset in 1...800 { let d = calendar.date(byAdding: .day, value: offset, to: base)!; let c = lunar.dateComponents([.month,.day,.isLeapMonth], from: d); if c.month == lunarMonth && c.day == lunarDay && c.isLeapMonth != true { value = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: time.second ?? 0, of: d); break } }
        default: break
        }
        if let until, let value, value > until { return nil }; return value
    }
}
enum Day {
    static func key(_ date: Date) -> String { let c = Calendar.current.dateComponents([.year,.month,.day], from: date); return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!) }
    static func date(_ key: String) -> Date? { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.date(from: key) }
}
struct ParsedTask { var title: String; var due: Date?; var tags: [String]; var priority: Int }
enum QuickParser {
    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current,recognizeDates: Bool = true,removeDates: Bool = true,removeTags: Bool = true) -> ParsedTask {
        var title = input.trimmingCharacters(in: .whitespacesAndNewlines); var tags: [String] = []; var priority = 0; var due: Date?
        func remove(_ value: String,enabled: Bool = true) { guard enabled else { return }; title = title.replacingOccurrences(of: value, with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if let regex = try? NSRegularExpression(pattern: "#([^\\s#]+)") { for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() { if let r = Range(match.range(at: 1), in: input), let full = Range(match.range, in: input) { tags.insert(String(input[r]), at: 0); remove(String(input[full]),enabled: removeTags) } } }
        for p in (1...3).reversed() { if title.contains("!\(p)") { priority = p; remove("!\(p)"); break } }
        if recognizeDates {
        // Match complete English words so titles such as “Todayland” remain unchanged.
        let englishDates = [("day after tomorrow",2),("tomorrow",1),("today",0),("next week",7)]
        for (word,offset) in englishDates {
            if let range = title.range(of: "\\b" + word + "\\b",options: [.regularExpression,.caseInsensitive]) {
                due = calendar.date(byAdding: .day,value: offset,to: calendar.startOfDay(for: now))
                remove(String(title[range]),enabled: removeDates); break
            }
        }
        if let expression = try? NSRegularExpression(pattern: "(?i)\\b(?:at\\s+)?(1[0-2]|0?[1-9])(?::([0-5][0-9]))?\\s*(am|pm)\\b"),
           let match = expression.firstMatch(in: title,range: NSRange(title.startIndex...,in: title)) {
            func part(_ index: Int) -> String { Range(match.range(at: index),in: title).map { String(title[$0]) } ?? "" }
            let hour = (Int(part(1)) ?? 12) % 12 + (part(3).lowercased() == "pm" ? 12 : 0)
            due = calendar.date(bySettingHour: hour,minute: Int(part(2)) ?? 0,second: 0,of: due ?? now)
            if let range = Range(match.range,in: title) { remove(String(title[range]),enabled: removeDates) }
        }
        for (word, offset) in [("大后天",3),("后天",2),("明天",1),("今天",0)] { if title.contains(word) { due = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)); remove(word,enabled: removeDates); break } }
        if title.contains("下周") { due = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)); remove("下周") }
        let weekdays = ["周日":1,"周一":2,"周二":3,"周三":4,"周四":5,"周五":6,"周六":7]
        for (word, weekday) in weekdays where title.contains(word) { let base = due ?? now; let offset = (weekday - calendar.component(.weekday, from: base) + 7) % 7; due = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: base)); remove(word,enabled: removeDates); break }
        if let regex = try? NSRegularExpression(pattern: "(\\d{4})[-/](\\d{1,2})[-/](\\d{1,2})"), let m = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let r = Range(m.range, in: title) { let parts = String(title[r]).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }; if parts.count == 3 { due = calendar.date(from: DateComponents(year: parts[0],month: parts[1],day: parts[2])); remove(String(title[r]),enabled: removeDates) } }
        if let regex = try? NSRegularExpression(pattern: "(上午|下午|晚上)?\\s*(\\d{1,2})(?:[:：](\\d{2})|点(?:(\\d{1,2})分?)?)"), let m = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) {
            func group(_ i: Int) -> String { Range(m.range(at: i), in: title).map { String(title[$0]) } ?? "" }
            var hour = Int(group(2)) ?? 9; let minute = Int(group(3)) ?? Int(group(4)) ?? 0
            if ["下午","晚上"].contains(group(1)) && hour < 12 { hour += 12 }
            if hour < 24 && minute < 60 { due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: due ?? now); if let r = Range(m.range, in: title) { remove(String(title[r]),enabled: removeDates) } }
        }
        }
        return ParsedTask(title: title, due: due, tags: tags, priority: priority)
    }
}

/// Flatten visible descendants while keeping each child directly under its parent.
/// A visited set also makes imported cyclic hierarchies safe to display.
enum TaskHierarchy {
    struct Row: Identifiable { let task: TaskItem; let depth: Int; var id: UUID { task.id } }
    static func rows(root: TaskItem,tasks: [TaskItem],collapsed: Set<UUID>) -> [Row] {
        let children = Dictionary(grouping: tasks.filter { !$0.deleted && $0.parentID != nil },by: { $0.parentID! })
        var result: [Row] = []; var visited = Set<UUID>()
        func append(_ task: TaskItem,depth: Int) {
            guard visited.insert(task.id).inserted else { return }
            result.append(Row(task: task,depth: depth))
            guard !collapsed.contains(task.id) else { return }
            for child in (children[task.id] ?? []).sorted(by: { if ($0.pinned == true) != ($1.pinned == true) { return $0.pinned == true }; return $0.order == $1.order ? $0.created < $1.created : $0.order < $1.order }) { append(child,depth: depth + 1) }
        }
        append(root,depth: 0); return result
    }
}

/// Ordered tree moves. All descendants retain their content, dates and completion state.
enum TaskPlacement {
    enum Position { case before, child, after }
    /// Place a subtask after its outermost parent so it becomes a visible root.
    static func promotedChanges(_ tasks: [TaskItem],source: UUID) -> [TaskItem]? {
        guard let moved = tasks.first(where: { $0.id == source && !$0.deleted }), moved.parentID != nil else { return nil }
        var ancestor = moved
        var visited: Set<UUID> = [source]
        var inheritedSchedule: TaskItem?
        while let parentID = ancestor.parentID {
            guard visited.insert(parentID).inserted,
                  let parent = tasks.first(where: { $0.id == parentID && !$0.deleted }) else { return nil }
            if inheritedSchedule == nil && parent.due != nil { inheritedSchedule = parent }
            ancestor = parent
        }
        guard var changed = changes(tasks,source: source,target: ancestor.id,position: .after) else { return nil }
        // An undated child was visible inside a dated parent (for example in Today).
        // Keep it visible after the move without altering a date the child already has.
        if moved.due == nil,let inheritedSchedule,
           let index = changed.firstIndex(where: { $0.id == source }) {
            changed[index].due = inheritedSchedule.due
            changed[index].allDay = inheritedSchedule.allDay
        }
        return changed
    }
    static func changes(_ tasks: [TaskItem],source: UUID,target: UUID,position: Position) -> [TaskItem]? {
        guard source != target, var moved = tasks.first(where: { $0.id == source }), let destination = tasks.first(where: { $0.id == target }),
              !moved.deleted, !destination.deleted, moved.archived != true, destination.archived != true,
              moved.isTemplate == destination.isTemplate else { return nil }
        let tree = TaskHierarchy.rows(root: moved,tasks: tasks,collapsed: [])
        let members = Set(tree.map(\.id))
        guard !members.contains(target) else { return nil }
        let parent = position == .child ? target : destination.parentID
        // Reject invalid or cyclic imported ancestor chains as well as new cycles.
        var ancestor = parent; var visited = Set<UUID>()
        while let id = ancestor {
            guard !members.contains(id), visited.insert(id).inserted else { return nil }
            ancestor = tasks.first { $0.id == id }?.parentID
        }
        moved.parentID = parent; moved.listID = destination.listID; moved.section = destination.section
        var siblings = tasks.filter { !$0.deleted && $0.id != source && $0.parentID == parent && $0.listID == moved.listID && $0.section == moved.section && $0.isTemplate == moved.isTemplate }.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        let insertion = position == .child ? siblings.count : (siblings.firstIndex { $0.id == target } ?? siblings.count) + (position == .after ? 1 : 0)
        siblings.insert(moved,at: min(insertion,siblings.count))
        var changed = [UUID:TaskItem]()
        for (i,var sibling) in siblings.enumerated() { sibling.order = Double(i); changed[sibling.id] = sibling }
        for var child in tree.dropFirst().map(\.task) { child.listID = destination.listID; child.section = destination.section; changed[child.id] = child }
        if position == .child && !moved.completed && destination.completed { var parent = destination; parent.completed = false; parent.completedAt = nil; changed[parent.id] = parent }
        return changed.values.filter { value in tasks.first { $0.id == value.id } != value }
    }
    static func listChanges(_ lists: [TaskList],source: UUID,target: UUID?,after: Bool = false,folder: String? = nil) -> [TaskList]? {
        guard var moved = lists.first(where: { $0.id == source && !$0.deleted }), source != target else { return nil }
        let destination = target.flatMap { id in lists.first { $0.id == id && !$0.deleted } }
        if target != nil && destination == nil { return nil }
        moved.folder = folder ?? destination?.folder ?? ""
        var siblings = lists.filter { !$0.deleted && $0.id != source && $0.folder == moved.folder }.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        let insertion = destination.flatMap { dest in siblings.firstIndex { $0.id == dest.id } }.map { $0 + (after ? 1 : 0) } ?? siblings.count
        siblings.insert(moved,at: insertion)
        return siblings.enumerated().compactMap { i,value in var list = value; list.order = i; return lists.first { $0.id == list.id } == list ? nil : list }
    }
}


enum SmartListVisibility: String,CaseIterable,Codable {
    case show, hide, whenNotEmpty
    var title: String { switch self { case .show: return "显示"; case .hide: return "隐藏"; case .whenNotEmpty: return "有内容时显示" } }
    func isVisible(count: Int) -> Bool { self == .show || (self == .whenNotEmpty && count > 0) }
}
struct SmartListOption: Identifiable {
    var id: String; var title: String; var icon: String; var initial: SmartListVisibility
    static let primary: [Self] = [
        .init(id:"all",title:"所有",icon:"square.stack",initial:.hide),
        .init(id:"today",title:"今天",icon:"calendar",initial:.show),
        .init(id:"tomorrow",title:"明天",icon:"sunrise",initial:.hide),
        .init(id:"week",title:"最近 7 天",icon:"calendar.badge.clock",initial:.show),
        .init(id:"inbox",title:"收集箱",icon:"tray",initial:.show),
        .init(id:"starred",title:"收藏",icon:"star",initial:.hide)]
    static let organization: [Self] = [
        .init(id:"tags",title:"标签",icon:"tag",initial:.show),
        .init(id:"filters",title:"过滤器",icon:"line.3.horizontal.decrease",initial:.show)]
    static let secondary: [Self] = [
        .init(id:"completed",title:"已完成",icon:"checkmark.square",initial:.show),
        .init(id:"abandoned",title:"已放弃",icon:"xmark.square",initial:.show),
        .init(id:"archived",title:"归档任务",icon:"archivebox",initial:.hide),
        .init(id:"trash",title:"回收站",icon:"trash",initial:.show)]
    static var all: [Self] { primary + organization + secondary }
}
struct SmartListPreferences {
    var values: [String:String]
    init(rawValue: String) {
        values = rawValue.data(using: .utf8).flatMap { try? JSONDecoder().decode([String:String].self,from: $0) } ?? [:]
    }
    func visibility(for key: String) -> SmartListVisibility {
        values[key].flatMap(SmartListVisibility.init(rawValue:)) ?? SmartListOption.all.first { $0.id == key }?.initial ?? .show
    }
    func isVisible(_ key: String,count: Int) -> Bool { visibility(for: key).isVisible(count: count) }
    func updating(_ key: String,to value: SmartListVisibility) -> String {
        var updated = values; updated[key] = value.rawValue
        return (try? JSONEncoder().encode(updated)).flatMap { String(data: $0,encoding: .utf8) } ?? ""
    }
}

/// Visibility applies to navigation only; stored data is retained when a module is hidden.
struct ModulePreferences {
    var rawValue: String
    private var values: [String:Bool] { guard let data = rawValue.data(using: .utf8) else { return [:] }; return (try? JSONDecoder().decode([String:Bool].self,from: data)) ?? [:] }
    func isVisible(_ module: Module) -> Bool { module == .tasks || module == .stats || values[module.rawValue] != false }
    func updating(_ module: Module,to visible: Bool) -> String { var changed = values; changed[module.rawValue] = visible; return String(data: (try? JSONEncoder().encode(changed)) ?? Data(),encoding: .utf8) ?? "" }
}

/// Mobile navigation stays local to the device, independently of task synchronization.
struct MobileWorkspaceState: Codable, Equatable {
    var module = "tasks"
    var selection = "today"
    var listID: UUID?
    var taskID: UUID?
    var morePath: [String] = []
    var showCompleted = false
    static func launch(defaults: UserDefaults = .standard) -> Self {
        if defaults.object(forKey: "restoreLastWorkspace") as? Bool != false,
           let data = defaults.data(forKey: "lastMobileWorkspace"),let state = try? JSONDecoder().decode(Self.self,from: data) { return state }
        return Self(module: defaults.string(forKey: "mobileStartupModule") ?? "tasks",selection: defaults.string(forKey: "mobileStartupSmartList") ?? "today")
    }
    func save(defaults: UserDefaults = .standard) { if let data = try? JSONEncoder().encode(self) { defaults.set(data,forKey: "lastMobileWorkspace") } }
    func validated(tasks: [TaskItem],lists: [TaskList],filters: [SavedFilter],visibility: ModulePreferences) -> Self {
        var result = self
        let modules: [String:Module] = ["tasks":.tasks,"calendar":.calendar,"focus":.focus,"habits":.habits]
        if module != "more" && (modules[module] == nil || !visibility.isVisible(modules[module]!)) { result.module = "tasks" }
        let keys = Set(SmartListOption.primary.map(\.id) + SmartListOption.secondary.map(\.id))
        let valid: Bool
        if selection == "list" { valid = lists.contains { $0.id == listID && !$0.deleted } }
        else if selection.hasPrefix("filter:") { valid = filters.contains { "filter:" + $0.id.uuidString == selection && !$0.deleted } }
        else if selection.hasPrefix("tag:") { valid = tasks.contains { !$0.deleted && $0.tags.contains(String(selection.dropFirst(4))) } }
        else { valid = keys.contains(selection) }
        if !valid { result.selection = "today"; result.listID = nil; result.taskID = nil }
        if result.selection != "list" { result.listID = nil }
        if !tasks.contains(where: { $0.id == result.taskID && !$0.deleted }) { result.taskID = nil }
        let destinations = ["matrix","countdown","statistics","notifications","settings"]
        result.morePath = Array(morePath.prefix(while: { destinations.contains($0) && ($0 != "matrix" || visibility.isVisible(.matrix)) && ($0 != "countdown" || visibility.isVisible(.countdown)) }))
        return result
    }
}
enum TaskCreationPreferences {
    static func parse(_ input: String,defaults: UserDefaults = .standard,now: Date = Date(),calendar: Calendar = .current) -> ParsedTask {
        QuickParser.parse(input,now: now,calendar: calendar,recognizeDates: defaults.object(forKey: "recognizeDates") as? Bool != false,removeDates: defaults.object(forKey: "removeDateText") as? Bool != false,removeTags: defaults.object(forKey: "removeTagText") as? Bool != false)
    }
    static func due(defaults: UserDefaults = .standard,now: Date = Date(),calendar: Calendar = .current) -> Date? {
        switch defaults.string(forKey: "defaultTaskDate") { case "today": return calendar.startOfDay(for: now); case "tomorrow": return calendar.date(byAdding: .day,value: 1,to: calendar.startOfDay(for: now)); default: return nil }
    }
    static func reminders(allDay: Bool,defaults: UserDefaults = .standard) -> [Double] {
        let key = allDay ? "defaultAllDayReminder" : "defaultTimedReminder"
        let value = defaults.object(forKey: key) as? Double ?? 0
        return value >= 0 ? [value] : []
    }
}
enum CalendarPreferences {
    static func calendar(firstWeekday: Int,timeZone: TimeZone = .current) -> Calendar { var result = Calendar.current; result.firstWeekday = (1...7).contains(firstWeekday) ? firstWeekday : Calendar.current.firstWeekday; result.timeZone = timeZone; return result }
    static func lunarLabel(_ date: Date,timeZone: TimeZone = .current) -> String {
        var lunar = Calendar(identifier: .chinese); lunar.timeZone = timeZone
        let day = lunar.component(.day,from: date)
        let days = ["初一","初二","初三","初四","初五","初六","初七","初八","初九","初十","十一","十二","十三","十四","十五","十六","十七","十八","十九","二十","廿一","廿二","廿三","廿四","廿五","廿六","廿七","廿八","廿九","三十"]
        guard (1...30).contains(day) else { return "" }
        if day == 1 { let months = ["正","二","三","四","五","六","七","八","九","十","冬","腊"]; let month = lunar.component(.month,from: date); return (lunar.dateComponents([.isLeapMonth],from: date).isLeapMonth == true ? "闰" : "") + months[max(0,min(11,month - 1))] + "月" }
        return days[day - 1]
    }
}

enum Module: String, CaseIterable { case tasks = "任务", calendar = "日历", matrix = "四象限", focus = "专注", habits = "习惯", countdown = "倒数纪念日", stats = "统计"
    var icon: String { switch self { case .tasks: return "checkmark.square.fill"; case .calendar: return "calendar"; case .matrix: return "square.grid.2x2"; case .focus: return "timer"; case .habits: return "leaf"; case .countdown: return "calendar.badge.clock"; case .stats: return "chart.bar" } }
}


struct Countdown: ListRecord, Hashable {
    static let kind = "countdown"
    var id = UUID(); var deleted = false; var name = ""; var emoji = "🎉"
    var category = "倒数日"; var date = Date(); var yearly = false; var pinned = false
    var reminderDays = -1; var reminderHour = 9
    var preset: String?
    /// Clamp February 29 to the last day of February in non-leap years.
    func occurrence(on now: Date = Date(), calendar: Calendar = .current) -> Date {
        let anchor = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        if preset == "weekend" {
            return calendar.date(byAdding: .day,value: (7 - calendar.component(.weekday,from: today)) % 7,to: today) ?? today
        }
        if preset == "springFestival" {
            var lunar = Calendar(identifier: .chinese); lunar.timeZone = calendar.timeZone
            return lunar.nextDate(after: today.addingTimeInterval(-1),matching: DateComponents(month: 1,day: 1),matchingPolicy: .nextTime) .map { calendar.startOfDay(for: $0) } ?? anchor
        }
        guard yearly, anchor < today else { return anchor }
        let month = calendar.component(.month, from: anchor), day = calendar.component(.day, from: anchor)
        let year = calendar.component(.year, from: today)
        for y in year...(year + 1) {
            guard let first = calendar.date(from: DateComponents(year: y, month: month, day: 1)), let range = calendar.range(of: .day, in: .month, for: first), let value = calendar.date(from: DateComponents(year: y, month: month, day: min(day,range.count))) else { continue }
            if value >= today { return value }
        }
        return anchor
    }
    var displayName: String { ["周末","春节","开始使用 Zilo"].contains(name) ? ZiloLanguage.text(name) : name }
    static func defaults(started: Date) -> [Countdown] {
        [("E5F3071A-2A74-4497-9334-ACC420600001","周末","⏳","倒数日","weekend"),
         ("E5F3071A-2A74-4497-9334-ACC420600002","春节","🧧","节日","springFestival"),
         ("E5F3071A-2A74-4497-9334-ACC420600003","开始使用 Zilo","✨","纪念日","started")].map { id,name,emoji,category,preset in
            var item = Countdown(); item.id = UUID(uuidString: id)!; item.name = name; item.emoji = emoji; item.category = category; item.date = started; item.pinned = true; item.preset = preset; item.yearly = preset == "springFestival"; return item
        }
    }
    func days(on now: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: occurrence(on: now, calendar: calendar)).day ?? 0
    }
    func reminders(after now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        guard !deleted, reminderDays >= 0 else { return [] }
        var result: [Date] = []; var cursor = now
        for _ in 0..<((yearly || preset == "weekend") ? 4 : 1) {
            let occurrence = occurrence(on: cursor,calendar: calendar)
            if let day = calendar.date(byAdding: .day,value: -reminderDays,to: occurrence), let time = calendar.date(bySettingHour: reminderHour,minute: 0,second: 0,of: day), time > now { result.append(time) }
            guard let next = calendar.date(byAdding: .day,value: 1,to: occurrence) else { break }; cursor = next
        }
        return result
    }
}
struct ActivityEntry: Codable, Identifiable {
    var id = UUID(); var date = Date(); var title: String; var detail: String; var owner: UUID?
}

/// Search combines every selected condition and leaves the user's task data untouched.
struct TaskSearchCriteria: Equatable {
    var status = "all"; var priority = -1; var listID: UUID?; var tag = ""; var date = "any"
    var attachmentsOnly = false; var starredOnly = false
    var isActive: Bool { self != TaskSearchCriteria() }
    func matches(_ task: TaskItem,query: String = "",now: Date = Date(),calendar: Calendar = .current) -> Bool {
        guard !task.deleted, !task.isTemplate else { return false }
        if !query.isEmpty && !(task.title + " " + task.notes + " " + task.tags.joined(separator: " ") + " " + task.attachments.map(\.name).joined(separator: " ")).localizedCaseInsensitiveContains(query) { return false }
        if priority >= 0 && task.priority != priority { return false }
        if let listID, task.listID != listID { return false }
        if !tag.isEmpty && !task.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) == .orderedSame }) { return false }
        if attachmentsOnly && task.attachments.isEmpty { return false }
        if starredOnly && !task.starred { return false }
        switch status { case "active": if task.completed || task.archived == true { return false }; case "completed": if !task.completed { return false }; case "archived": if task.archived != true { return false }; default: break }
        let today = calendar.startOfDay(for: now)
        switch date {
        case "today": return task.due.map { calendar.isDate($0,inSameDayAs: now) } ?? false
        case "overdue": return !task.completed && task.due.map { task.allDay ? calendar.startOfDay(for: $0) < today : $0 < now } == true
        case "week": return task.due.map { $0 >= today && $0 < calendar.date(byAdding: .day,value: 7,to: today)! } ?? false
        case "undated": return task.due == nil
        default: return true
        }
    }
}
