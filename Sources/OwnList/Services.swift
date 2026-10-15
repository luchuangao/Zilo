import SwiftUI
import AppKit
import UserNotifications
import EventKit
import Carbon
import ServiceManagement
import Security
import WidgetKit
import CryptoKit

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService(); var onComplete: ((UUID) -> Void)?; var onCompleteCheck: ((UUID,UUID) -> Void)?;
    private var taskGenerations: [UUID: Int] = [:]; var onOpen: (([AnyHashable:Any]) -> Void)?
    func configure() {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        let snooze = UNNotificationAction(identifier: "snooze", title: "10 分钟后提醒", options: [])
        let done = UNNotificationAction(identifier: "done", title: "完成任务", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "task", actions: [done,snooze], intentIdentifiers: [])])
    }
    func request() async throws -> Bool { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.badge,.sound]) }
    @MainActor func schedule(_ task: TaskItem) {
        let center = UNUserNotificationCenter.current()
        let generation = (taskGenerations[task.id] ?? 0) + 1; taskGenerations[task.id] = generation
        Task { @MainActor in
            let pending = await center.pendingNotificationRequests()
            guard taskGenerations[task.id] == generation else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix(task.id.uuidString + "-") }.map(\.identifier))
            guard UserDefaults.standard.object(forKey: "taskNotifications") as? Bool != false else { return }
            for reminder in task.plannedReminders() {
                guard taskGenerations[task.id] == generation else { return }
                let c = UNMutableNotificationContent(); c.title = reminder.title; c.body = reminder.body; c.sound = UserDefaults.standard.object(forKey: "notificationSound") as? Bool == false ? nil : .default; c.categoryIdentifier = "task"; c.userInfo = ["taskID":task.id.uuidString]
                if let checkID = reminder.checkID { c.userInfo["checkID"] = checkID.uuidString }
                let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second],from: reminder.date),repeats: false)
                try? await center.add(UNNotificationRequest(identifier: reminder.id,content: c,trigger: trigger))
            }
        }
    }
    func schedule(_ habit: Habit) {
        let center = UNUserNotificationCenter.current(); center.removePendingNotificationRequests(withIdentifiers: (1...7).map { "habit-\(habit.id)-\($0)" })
        guard UserDefaults.standard.object(forKey: "habitNotifications") as? Bool != false, !habit.deleted, habit.reminderHour >= 0 else { return }
        for weekday in habit.weekdays { let c = UNMutableNotificationContent(); c.title = "\(habit.emoji) \(habit.name)"; c.body = "今天的习惯目标：\(habit.goal)"; c.userInfo = ["habitID":habit.id.uuidString]; c.sound = UserDefaults.standard.object(forKey: "notificationSound") as? Bool == false ? nil : .default; center.add(UNNotificationRequest(identifier: "habit-\(habit.id)-\(weekday)", content: c, trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: habit.reminderHour, minute: 0, weekday: weekday), repeats: true))) }
    }
    func schedule(_ day: Countdown) {
        let center = UNUserNotificationCenter.current()
        let ids = (0..<4).map { "countdown-\(day.id)-\($0)" }; center.removePendingNotificationRequests(withIdentifiers: ids)
        guard UserDefaults.standard.object(forKey: "countdownNotifications") as? Bool != false else { return }
        for (index,date) in day.reminders().enumerated() {
            let c = UNMutableNotificationContent(); c.title = "\(day.emoji) \(day.name)"
            c.body = day.reminderDays == 0 ? "今天是\(day.name)" : "还有 \(day.reminderDays) 天"; c.userInfo = ["countdownID":day.id.uuidString]
            c.sound = UserDefaults.standard.object(forKey: "notificationSound") as? Bool == false ? nil : .default
            center.add(UNNotificationRequest(identifier: ids[index],content: c,trigger: UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year,.month,.day,.hour,.minute],from: date),repeats: false)))
        }
    }
    func focusDeadline(_ date: Date,phase: String) { let center = UNUserNotificationCenter.current(); center.removePendingNotificationRequests(withIdentifiers: ["focus-deadline"]); guard UserDefaults.standard.object(forKey: "focusNotifications") as? Bool != false else { return }; let c = UNMutableNotificationContent(); c.userInfo = ["focus":true]; c.title = phase == "专注" ? "专注完成，休息一下" : "休息结束，开始下一轮专注"; c.sound = UserDefaults.standard.object(forKey: "notificationSound") as? Bool == false ? nil : .default; center.add(UNNotificationRequest(identifier: "focus-deadline",content: c,trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1,date.timeIntervalSinceNow),repeats: false))) }
    func cancelFocusDeadline() { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["focus-deadline"]) }
    func notify(_ title: String) { let c = UNMutableNotificationContent(); c.title = title; c.body = "任务、习惯、专注和纪念日提醒已接入系统通知。"; c.sound = UserDefaults.standard.object(forKey: "notificationSound") as? Bool == false ? nil : .default; UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner,.sound]) }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo["taskID"] as? String, let id = UUID(uuidString: raw) {
            if response.actionIdentifier == "done" { DispatchQueue.main.async { if let raw = response.notification.request.content.userInfo["checkID"] as? String,let check = UUID(uuidString: raw) { self.onCompleteCheck?(id,check) } else { self.onComplete?(id) } } }
            if response.actionIdentifier == "snooze" { let c = response.notification.request.content.mutableCopy() as! UNMutableNotificationContent; center.add(UNNotificationRequest(identifier: "\(id)-0", content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))) }
        }; if response.actionIdentifier == UNNotificationDefaultActionIdentifier { DispatchQueue.main.async { self.onOpen?(response.notification.request.content.userInfo) } }; completionHandler()
    }
}
@MainActor final class FocusTimer: ObservableObject {
    @Published var running = false; @Published var remaining: Double = 1500; @Published var elapsed: Double = 0
    @Published var minutes = 25; @Published var breakMinutes = 5; @Published var longBreakMinutes = 15; @Published var mode = "番茄"; @Published var phase = "专注"; @Published var taskID: UUID?; @Published var rounds = 0
    private var sessionStarted: Date?; private var started: Date?; private var deadline: Date?; private var prior: Double = 0; private var ticker: Timer?
    private let defaults: UserDefaults; private let now: () -> Date; private let notifications: Bool
    private var pending: [FocusRecord] = []
    var onRecord: ((FocusRecord) -> Void)? { didSet { if let onRecord { let records = pending; pending.removeAll(); records.forEach(onRecord) } } }
    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init, notifications: Bool = true) {
        self.defaults = defaults; self.now = now; self.notifications = notifications
        minutes = max(1,defaults.object(forKey: "focusMinutes") as? Int ?? 25)
        breakMinutes = max(1,defaults.object(forKey: "breakMinutes") as? Int ?? 5)
        longBreakMinutes = max(1,defaults.object(forKey: "longBreakMinutes") as? Int ?? 15)
        if let data = defaults.data(forKey: "activeFocus"), let state = try? JSONDecoder().decode(Session.self,from: data) {
            mode = state.mode; phase = state.phase; started = state.started; deadline = state.deadline; prior = state.prior; elapsed = prior; running = state.running; taskID = state.taskID; rounds = state.rounds; sessionStarted = state.sessionStarted ?? state.started?.addingTimeInterval(-state.prior)
        }
        if notifications { ticker = Timer.scheduledTimer(withTimeInterval: 1,repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } } }; tick()
    }
    deinit { ticker?.invalidate() }
    struct Session: Codable { var mode: String; var phase: String; var started: Date?; var deadline: Date?; var prior: Double; var running: Bool; var taskID: UUID?; var rounds: Int; var sessionStarted: Date? }
    func persist() { defaults.set(try? JSONEncoder().encode(Session(mode: mode,phase: phase,started: started,deadline: deadline,prior: running ? prior : elapsed,running: running,taskID: taskID,rounds: rounds,sessionStarted: sessionStarted)),forKey: "activeFocus") }
    func saveDurations() { defaults.set(minutes,forKey: "focusMinutes"); defaults.set(breakMinutes,forKey: "breakMinutes"); defaults.set(longBreakMinutes,forKey: "longBreakMinutes"); if !running && elapsed == 0 { remaining = phaseLength }; persist() }
    func changeMode(_ value: String) { guard !running && elapsed == 0 else { return }; mode = value; phase = "专注"; prior = 0; deadline = nil; remaining = phaseLength; persist() }
    var phaseLength: Double { Double((phase == "专注" ? minutes : rounds % 4 == 0 ? longBreakMinutes : breakMinutes) * 60) }
    func start() { guard !running else { return }; started = now(); if sessionStarted == nil { sessionStarted = started }; running = true; if mode == "番茄" { deadline = now().addingTimeInterval(max(1,phaseLength - prior)); rescheduleNotification() }; persist(); tick() }
    @discardableResult func startTask(_ id: UUID,mode requestedMode: String) -> Bool {
        guard ["番茄","正计时"].contains(requestedMode) else { return false }
        if running || elapsed > 0 {
            guard taskID == id,mode == requestedMode,phase == "专注" else { return false }
        } else { changeMode(requestedMode); taskID = id }
        start(); return true
    }
    func rescheduleNotification() { guard notifications else { return }; if running,mode == "番茄",let deadline { NotificationService.shared.focusDeadline(deadline,phase: phase) } else { NotificationService.shared.cancelFocusDeadline() } }
    func pause() { tick(); guard running else { return }; prior = elapsed; running = false; started = nil; deadline = nil; rescheduleNotification(); persist() }
    func tick() {
        guard running, let started else { if mode == "番茄" { remaining = max(0,phaseLength - prior) }; return }
        elapsed = prior + max(0,now().timeIntervalSince(started)); remaining = deadline.map { max(0,$0.timeIntervalSince(now())) } ?? elapsed
        if mode == "番茄", remaining <= 0 {
            if phase == "专注" { elapsed = min(elapsed,phaseLength); record(completed: true); rounds += 1; phase = "休息"; if notifications && defaults.object(forKey: "focusSound") as? Bool != false { NSSound(named: "Glass")?.play() } } else { phase = "专注" }
            running = false; prior = 0; elapsed = 0; self.started = nil; sessionStarted = nil; deadline = nil; remaining = phaseLength; persist()
        }
    }
    func stop() { tick(); if phase == "专注" && elapsed > 0 { record(completed: false) }; running = false; started = nil; sessionStarted = nil; deadline = nil; prior = 0; elapsed = 0; phase = "专注"; remaining = Double(minutes * 60); rescheduleNotification(); persist() }
    private func record(completed: Bool) { let value = FocusRecord(taskID: taskID,started: sessionStarted ?? now().addingTimeInterval(-elapsed),seconds: elapsed,mode: mode,completedPomodoro: completed && mode == "番茄",ended: now()); if let onRecord { onRecord(value) } else { pending.append(value) } }
    var display: String { let seconds = max(0,Int(mode == "番茄" ? remaining : elapsed)); return String(format: "%02d:%02d",seconds / 60,seconds % 60) }
}
@MainActor final class CalendarService: ObservableObject {
    let eventStore = EKEventStore(); @Published var events: [ExternalEvent] = []; @Published var message = ""; @Published var calendars: [EKCalendar] = []
    func authorize() async { do { if try await eventStore.requestFullAccessToEvents() { calendars = eventStore.calendars(for: .event); refresh() } else { message = "日历权限未开启，请在系统设置中允许访问" } } catch { message = error.localizedDescription } }
    func refresh() { guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }; let start = Calendar.current.date(byAdding: .year,value: -1,to: Date())!; let end = Calendar.current.date(byAdding: .year,value: 2,to: Date())!; events = eventStore.events(matching: eventStore.predicateForEvents(withStart: start,end: end,calendars: nil)).map { ExternalEvent(id: $0.eventIdentifier ?? UUID().uuidString,title: $0.title ?? "日程",start: $0.startDate,end: $0.endDate,source: $0.calendar.title) }; calendars = eventStore.calendars(for: .event) }
    func exportTask(_ task: TaskItem) throws { guard let due = task.due else { throw ServiceError.message("请先设置任务日期") }; guard let calendar = eventStore.defaultCalendarForNewEvents else { throw ServiceError.message("请先开启日历权限并设置默认日历") }; let event = EKEvent(eventStore: eventStore); event.title = task.title; event.notes = task.notes; event.startDate = task.start ?? due; event.endDate = event.startDate.addingTimeInterval(task.duration); event.isAllDay = task.allDay; event.calendar = calendar; try eventStore.save(event,span: .thisEvent); refresh() }
    func importReminders(into store: Store) async { do { guard try await eventStore.requestFullAccessToReminders() else { message = "提醒事项权限未开启"; return }; let reminders: [EKReminder] = await withCheckedContinuation { continuation in eventStore.fetchReminders(matching: eventStore.predicateForReminders(in: nil)) { continuation.resume(returning: $0 ?? []) } }; var added = 0; for r in reminders where !store.tasks.contains(where: { $0.sourceID == "apple:" + r.calendarItemIdentifier }) { var t = TaskItem(); t.title = r.title; t.notes = r.notes ?? ""; t.sourceID = "apple:" + r.calendarItemIdentifier; t.completed = r.isCompleted; t.completedAt = r.completionDate; t.due = r.dueDateComponents?.date; t.priority = r.priority == 0 ? 0 : (r.priority <= 4 ? 3 : 1); store.save(t); added += 1 }; message = "已导入 \(added) 条提醒事项" } catch { message = error.localizedDescription } }
    func subscribe(_ url: String, name: String) async throws { guard let target = URL(string: url), ["https","http"].contains(target.scheme) else { throw ServiceError.message("请输入有效的 HTTPS 日历地址") }; let (data,response) = try await URLSession.shared.data(from: target); guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ServiceError.message("日历下载失败") }; let parsed = try ICSParser.parse(data, source: name); events.removeAll { $0.source == name }; events += parsed }
}
enum ServiceError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let text) = self { return text }; return nil } }
enum ICSParser {
    static func parse(_ data: Data, source: String) throws -> [ExternalEvent] {
        guard let text = String(data: data,encoding: .utf8), text.contains("BEGIN:VCALENDAR") else { throw ServiceError.message("文件不是有效的 ICS 日历") }
        let unfolded = text.replacingOccurrences(of: "\r\n ",with: "").replacingOccurrences(of: "\r\n\t",with: "")
        var result: [ExternalEvent] = []; var values: [String: (String,String)] = [:]; var inside = false
        func date(_ field: (String,String)?) -> Date? { guard let (header,value) = field else { return nil }; let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = value.count == 8 ? "yyyyMMdd" : (value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"); if value.hasSuffix("Z") { f.timeZone = TimeZone(secondsFromGMT: 0) } else if let range = header.range(of: "TZID=") { f.timeZone = TimeZone(identifier: String(header[range.upperBound...]).split(separator: ";").first.map(String.init) ?? "") }; return f.date(from: value) }
        for raw in unfolded.components(separatedBy: .newlines) { let line = raw.trimmingCharacters(in: .whitespacesAndNewlines); if line == "BEGIN:VEVENT" { inside = true; values = [:] } else if line == "END:VEVENT" { if let start = date(values["DTSTART"]) { let end = date(values["DTEND"]) ?? start.addingTimeInterval(values["DTSTART"]?.1.count == 8 ? 86400 : 3600)
                    let uid = "ics:" + source + ":" + (values["UID"]?.1 ?? UUID().uuidString); let title = (values["SUMMARY"]?.1 ?? "日程").replacingOccurrences(of: "\\n",with: "\n").replacingOccurrences(of: "\\,",with: ",")
                    var occurrences = [(start,end)]
                    if let repeatValue = values["RRULE"]?.1 { var calendar = Calendar.current; if let header = values["DTSTART"]?.0, let range = header.range(of: "TZID="), let zone = TimeZone(identifier: String(header[range.upperBound...])) { calendar.timeZone = zone }; let exclusions = Set((values["EXDATE"]?.1 ?? "").split(separator: ",").compactMap { date((values["EXDATE"]?.0 ?? "EXDATE",String($0))) }); occurrences = try RecurrenceCodec.expand(start: start,end: end,rule: repeatValue,exclusions: exclusions,calendar: calendar) }
                    for (begin,finish) in occurrences { result.append(ExternalEvent(id: uid + ":" + String(begin.timeIntervalSince1970),title: title,start: begin,end: finish,source: source)) } }; inside = false } else if inside, let colon = line.firstIndex(of: ":") { let header = String(line[..<colon]); let key = header.split(separator: ";").first.map(String.init) ?? header; values[key] = (header,String(line[line.index(after: colon)...])) } }
        return result
    }
}
struct ImportPreview { var backup: Backup; var warnings: [String]; var source: String; var count: Int { backup.tasks.count } }
enum ImportService {
    static func preview(_ url: URL) throws -> ImportPreview {
        let data = try Data(contentsOf: url)
        if let backup = try? JSONDecoder().decode(Backup.self,from: data) { guard backup.formatVersion == 1 else { throw ServiceError.message("不支持的备份版本") }; return ImportPreview(backup: backup,warnings: [],source: "Zilo备份") }
        guard let text = String(data: data,encoding: .utf8) else { throw ServiceError.message("请提供 UTF-8 CSV 或本工具 JSON 备份") }
        let allRows = CSV.parse(text); guard let headerIndex = allRows.firstIndex(where: { row in row.contains { ["title","task name","任务名称","标题"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "\u{feff}",with: "")) } }) else { throw ServiceError.message("找不到任务标题表头") }; let rows = Array(allRows.dropFirst(headerIndex)); let headers = rows[0]
        let names = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "\u{feff}",with: "") }
        func column(_ options: [String]) -> Int? { names.firstIndex { options.contains($0) } }
        guard let titleIndex = column(["title","task name","任务名称","标题"]) else { throw ServiceError.message("无法识别任务标题列。支持 Title / Task Name / 标题 / 任务名称；请导出 CSV 备份") }
        var lists: [TaskList] = []; var tasks: [TaskItem] = []; var warnings: [String] = []
        for (index,row) in rows.dropFirst().enumerated() {
            func value(_ options: [String]) -> String { guard let i = column(options), i < row.count else { return "" }; return row[i] }
            guard titleIndex < row.count, !row[titleIndex].isEmpty else { warnings.append("第 \(index + 2) 行缺少标题，已跳过"); continue }
            var t = TaskItem(); t.title = row[titleIndex]; t.notes = value(["content","description","内容","描述"])
            let folder = value(["folder name","文件夹"]); let listName = value(["list name","list","project name","清单名称","清单"])
            if !listName.isEmpty { if let l = lists.first(where: { $0.name == listName && $0.folder == folder }) { t.listID = l.id } else { let l = TaskList(name: listName,folder: folder,order: lists.count); lists.append(l); t.listID = l.id } }
            t.tags = value(["tags","标签"]).split(whereSeparator: { $0 == "," || $0 == ";" }).map { String($0).trimmingCharacters(in: .whitespaces) }
            let p = value(["priority","优先级"]); t.priority = ["high":3,"medium":2,"low":1][p.lowercased()] ?? min(3,max(0,Int(p) ?? 0))
            let status = value(["status","completed","状态","完成"]); t.completed = ["true","completed","已完成","done","1"].contains(status.lowercased()); t.archived = status == "2" || status.lowercased() == "archived"
            func parseDate(_ raw: String) -> Date? { if raw.isEmpty { return nil }; if let d = ISO8601DateFormatter().date(from: raw) { return d }; for format in ["yyyy-MM-dd'T'HH:mm:ssZ","yyyy-MM-dd HH:mm:ss","yyyy-MM-dd HH:mm","yyyy-MM-dd","yyyy/MM/dd"] { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format; if let d = f.date(from: raw) { return d } }; return nil }
            let due = value(["due date","due","截止日期","日期"]); t.due = parseDate(due); if !due.isEmpty && t.due == nil { warnings.append("第 \(index + 2) 行日期无法识别：\(due)") }
            t.start = parseDate(value(["start date","开始日期"])); t.completedAt = parseDate(value(["completed time","完成时间"])); t.created = parseDate(value(["created time","创建时间"])) ?? Date()
            let source = value(["task id","taskid","id","任务id"]); t.sourceID = source.isEmpty ? "csv:" + stableKey(listName + "|" + t.title + "|" + due + "|" + t.notes) : "dida:" + source
            t.section = value(["column name","分组"]); let allDayValue = value(["is all day","全天"]); t.allDay = allDayValue.isEmpty ? due.count <= 10 : ["true","y","1"].contains(allDayValue.lowercased()); t.order = Double(value(["order","排序"])) ?? Double(index)
            if let repeatText = value(["repeat","重复"]).nilIfEmpty { do { t.repeatRule = try RecurrenceCodec.rule(repeatText,anchor: t.due) } catch { warnings.append("第 \(index + 2) 行重复规则未恢复：\(error.localizedDescription)") } }
            let reminderText = value(["reminder","提醒"]); if !reminderText.isEmpty { t.reminders = reminderText.split(separator: ";").compactMap { RecurrenceCodec.duration(String($0)) }.map(abs); if t.reminders.isEmpty { warnings.append("第 \(index + 2) 行提醒未识别：\(reminderText)") } }
            if let sid = t.sourceID { t.id = sourceUUID(sid) }
            let parent = value(["parentid","parent id","父任务id"]); if !parent.isEmpty { t.parentID = sourceUUID("dida:" + parent) }
            if value(["is check list","检查清单"]).lowercased() == "y" { t.checks = t.notes.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { line in CheckItem(title: line.replacingOccurrences(of: "[x] ",with: "").replacingOccurrences(of: "[ ] ",with: ""),done: line.hasPrefix("[x]")) }; t.notes = "" }
            tasks.append(t)
        }
        let ids = Set(tasks.map(\.id)); for i in tasks.indices { if let parent = tasks[i].parentID, !ids.contains(parent) { warnings.append("任务「\(tasks[i].title)」的父任务不在备份中，作为顶层任务导入"); tasks[i].parentID = nil } }
        warnings.append("CSV 中的附件内容、习惯及专注记录不会由任务列恢复；数字状态按 CSV 定义 0 待办、1 完成、2 归档处理，请核对预览。")
        return ImportPreview(backup: Backup(tasks: tasks,lists: lists,filters: [],habits: [],focus: [],subscriptions: []),warnings: warnings,source: "任务 CSV")
    }
    static func sourceUUID(_ value: String) -> UUID { let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16)); return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])) }
    static func stableKey(_ value: String) -> String { var hash: UInt64 = 14695981039346656037; for b in value.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }; return String(hash,radix: 16) }
}
enum CSV {
    static func parse(_ text: String) -> [[String]] { var rows: [[String]] = []; var row: [String] = []; var field = ""; var quoted = false; let chars = Array(text); var i = 0
        while i < chars.count { let c = chars[i]; if c == "\"" { if quoted && i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 } else { quoted.toggle() } } else if c == "," && !quoted { row.append(field); field = "" } else if (c == "\n" || c == "\r" || c == "\r\n") && !quoted { row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = []; field = ""; if c == "\r" && i+1 < chars.count && chars[i+1] == "\n" { i += 1 } } else { field.append(c) }; i += 1 }; row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; return rows
    }
}
enum Capability {
    static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "OwnListAppGroup") as? String ?? "VFDQL6Z55P.com.gaoluchuan.ownlist" }
    static var entitlements: [String: Any] { var code: SecCode?; guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return [:] }; var staticCode: SecStaticCode?; guard SecCodeCopyStaticCode(code,[],&staticCode) == errSecSuccess, let staticCode else { return [:] }; var info: CFDictionary?; guard SecCodeCopySigningInformation(staticCode,SecCSFlags(rawValue: kSecCSSigningInformation),&info) == errSecSuccess else { return [:] }; return (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:] }
    static var cloudAvailable: Bool { (entitlements["com.apple.developer.icloud-services"] as? [String])?.contains("CloudKit") == true }
    static var groupAvailable: Bool { (entitlements["com.apple.security.application-groups"] as? [String])?.contains(groupID) == true }
}
enum WidgetSnapshot {
    static let queue = DispatchQueue(label: "OwnList.WidgetSnapshot",qos: .utility)
    static func write(tasks: [TaskItem],lists: [TaskList]) { queue.async { guard Capability.groupAvailable, let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Capability.groupID) else { return }; let data = tasks.filter { !$0.deleted && $0.archived != true && !$0.completed && !$0.isTemplate && $0.due.map { Calendar.current.isDateInToday($0) } == true }; try? JSONEncoder().encode(data).write(to: root.appendingPathComponent("today.json"),options: .atomic); WidgetCenter.shared.reloadAllTimelines() } }
}

@MainActor enum DesktopBridge {
    static var windows: [NSWindow] = []; static var quickAction: (() -> Void)?; static var hotKey: EventHotKeyRef?; static var installedHandler = false; static var hotKeyError: OSStatus = noErr
    static func updateBadge(_ count: Int) { NSApp?.dockTile.badgeLabel = count == 0 ? nil : String(count) }
    static func panel<V: View>(title: String, view: V, floating: Bool = true, size: NSSize = NSSize(width: 420,height: 450)) { let window = NSPanel(contentRect: NSRect(origin: .zero,size: size),styleMask: [.titled,.closable,.resizable,.nonactivatingPanel],backing: .buffered,defer: false); window.title = title; window.contentView = NSHostingView(rootView: view); window.level = floating ? .floating : .normal; window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil); windows.append(window) }
    static func registerHotkey() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }; guard UserDefaults.standard.object(forKey: "quickEnabled") as? Bool != false else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),eventKind: UInt32(kEventHotKeyPressed))
        if !installedHandler { InstallEventHandler(GetApplicationEventTarget(), { _,_,_ in DispatchQueue.main.async { DesktopBridge.quickAction?() }; return noErr },1,&spec,nil,nil); installedHandler = true }
        let key = UInt32(UserDefaults.standard.object(forKey: "quickCode") as? Int ?? (UserDefaults.standard.integer(forKey: "quickKey") == 1 ? kVK_ANSI_Q : kVK_ANSI_A)); let modifiers = UInt32(UserDefaults.standard.object(forKey: "quickModifiers") as? Int ?? (cmdKey | optionKey))
        hotKeyError = RegisterEventHotKey(key, modifiers,EventHotKeyID(signature: 0x4f574e4c,id: 1),GetApplicationEventTarget(),0,&hotKey)
    }
}
