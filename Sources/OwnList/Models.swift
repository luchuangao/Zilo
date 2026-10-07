import Foundation

protocol ListRecord: Codable, Identifiable where ID == UUID { var id: UUID { get }; var deleted: Bool { get set }; static var kind: String { get } }
enum DocumentEditingMode: String, Codable, CaseIterable {
    case richText, markdown
    var title: String { self == .richText ? "富文本" : "Markdown" }
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
    var trashedWithParent: UUID?; var checks: [CheckItem] = []; var attachments: [Attachment] = []
    var created = Date(); var order: Double = Date().timeIntervalSince1970; var isTemplate = false
    var archived: Bool?; var special = ""; var sourceID: String?
}
struct CheckItem: Codable, Hashable, Identifiable { var id = UUID(); var title: String; var done = false }
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
    var id = UUID(); var deleted = false; var taskID: UUID?; var started: Date; var seconds: Double; var mode: String
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
    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedTask {
        var title = input.trimmingCharacters(in: .whitespacesAndNewlines); var tags: [String] = []; var priority = 0; var due: Date?
        func remove(_ value: String) { title = title.replacingOccurrences(of: value, with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if let regex = try? NSRegularExpression(pattern: "#([^\\s#]+)") { for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() { if let r = Range(match.range(at: 1), in: input), let full = Range(match.range, in: input) { tags.insert(String(input[r]), at: 0); remove(String(input[full])) } } }
        for p in (1...3).reversed() { if title.contains("!\(p)") { priority = p; remove("!\(p)"); break } }
        for (word, offset) in [("大后天",3),("后天",2),("明天",1),("今天",0)] { if title.contains(word) { due = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)); remove(word); break } }
        if title.contains("下周") { due = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)); remove("下周") }
        let weekdays = ["周日":1,"周一":2,"周二":3,"周三":4,"周四":5,"周五":6,"周六":7]
        for (word, weekday) in weekdays where title.contains(word) { let base = due ?? now; let offset = (weekday - calendar.component(.weekday, from: base) + 7) % 7; due = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: base)); remove(word); break }
        if let regex = try? NSRegularExpression(pattern: "(\\d{4})[-/](\\d{1,2})[-/](\\d{1,2})"), let m = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)), let r = Range(m.range, in: title) { let parts = String(title[r]).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }; if parts.count == 3 { due = calendar.date(from: DateComponents(year: parts[0],month: parts[1],day: parts[2])); remove(String(title[r])) } }
        if let regex = try? NSRegularExpression(pattern: "(上午|下午|晚上)?\\s*(\\d{1,2})(?:[:：](\\d{2})|点(?:(\\d{1,2})分?)?)"), let m = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) {
            func group(_ i: Int) -> String { Range(m.range(at: i), in: title).map { String(title[$0]) } ?? "" }
            var hour = Int(group(2)) ?? 9; let minute = Int(group(3)) ?? Int(group(4)) ?? 0
            if ["下午","晚上"].contains(group(1)) && hour < 12 { hour += 12 }
            if hour < 24 && minute < 60 { due = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: due ?? now); if let r = Range(m.range, in: title) { remove(String(title[r])) } }
        }
        return ParsedTask(title: title, due: due, tags: tags, priority: priority)
    }
}
