import Foundation
import UserNotifications
import UIKit

final class MobileNotifications: NSObject,UNUserNotificationCenterDelegate {
    static let shared = MobileNotifications()
    var onOpen: (([AnyHashable: Any]) -> Void)?
    var onComplete: ((UUID) -> Void)?
    var onCompleteCheck: ((UUID,UUID) -> Void)?
    private var generation = 0
    @MainActor func configure() {
        let center = UNUserNotificationCenter.current(); center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "task",actions: [UNNotificationAction(identifier: "done",title: "完成任务",options: []),UNNotificationAction(identifier: "snooze",title: "10 分钟后提醒",options: [])],intentIdentifiers: [])])
        if Capability.cloudAvailable && UserDefaults.standard.bool(forKey: "cloudEnabled") {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    func request() async throws -> Bool { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert,.badge,.sound]) }
    func reschedule(tasks: [TaskItem],habits: [Habit],countdowns: [Countdown]) {
        generation += 1; let revision = generation
        Task { @MainActor in
            let center = UNUserNotificationCenter.current(); let settings = await center.notificationSettings()
            guard revision == generation,settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            var candidates: [(Date,UNNotificationRequest)] = []
            func add(_ id: String,_ title: String,_ body: String,_ info: [String: Any],_ date: Date,_ category: String = "") {
                guard date > Date() else { return }
                let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.userInfo = info; content.categoryIdentifier = category
                if UserDefaults.standard.object(forKey: "notificationSound") as? Bool != false { content.sound = .default }
                let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second],from: date),repeats: false)
                candidates.append((date,UNNotificationRequest(identifier: "zilo-" + id,content: content,trigger: trigger)))
            }
            if UserDefaults.standard.object(forKey: "taskNotifications") as? Bool != false {
                for item in tasks where !item.deleted && !item.completed && !item.isTemplate && item.archived != true {
                    for reminder in item.plannedReminders() {
                        var info = ["taskID":item.id.uuidString]; if let check = reminder.checkID { info["checkID"] = check.uuidString }
                        add(reminder.id,reminder.title,reminder.body,info,reminder.date,"task")
                    }
                }
            }
            if UserDefaults.standard.object(forKey: "habitNotifications") as? Bool != false {
                for habit in habits where !habit.deleted && habit.reminderHour >= 0 {
                    for weekday in habit.weekdays {
                        let parts = DateComponents(hour: habit.reminderHour,minute: 0,weekday: weekday)
                        guard let next = Calendar.current.nextDate(after: Date(),matching: parts,matchingPolicy: .nextTime) else { continue }
                        let content = UNMutableNotificationContent(); content.title = habit.emoji + " " + habit.name; content.body = "今天的目标：\(habit.goal)"; content.userInfo = ["habitID":habit.id.uuidString]
                        if UserDefaults.standard.object(forKey: "notificationSound") as? Bool != false { content.sound = .default }
                        candidates.append((next,UNNotificationRequest(identifier: "zilo-habit-\(habit.id)-\(weekday)",content: content,trigger: UNCalendarNotificationTrigger(dateMatching: parts,repeats: true))))
                    }
                }
            }
            if UserDefaults.standard.object(forKey: "countdownNotifications") as? Bool != false {
                for item in countdowns { for (index,date) in item.reminders().enumerated() { add("day-\(item.id)-\(index)",item.emoji + " " + item.name,item.reminderDays == 0 ? "今天是\(item.name)" : "还有 \(item.reminderDays) 天",["countdownID":item.id.uuidString],date) } }
            }
            let pending = await center.pendingNotificationRequests(); guard revision == generation else { return }
            let stale = pending.filter { $0.identifier.hasPrefix("zilo-") && !$0.identifier.hasPrefix("zilo-focus") && !$0.identifier.hasPrefix("zilo-snooze") }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: stale)
            // iOS allows 64 pending reminders; reserve a slot for the current focus timer.
            for (_,request) in candidates.sorted(by: { $0.0 < $1.0 }).prefix(max(0,63 - pending.filter { $0.identifier.hasPrefix("zilo-snooze") }.count)) {
                guard revision == generation else { return }; try? await center.add(request)
            }
        }
    }
    func focusDeadline(_ date: Date?,phase: String = "专注") {
        let center = UNUserNotificationCenter.current(); center.removePendingNotificationRequests(withIdentifiers: ["zilo-focus"])
        guard let date,date > Date(),UserDefaults.standard.object(forKey: "focusNotifications") as? Bool != false else { return }
        let content = UNMutableNotificationContent(); content.title = phase == "专注" ? "专注完成" : "休息结束"; content.body = phase == "专注" ? "做得很好，休息一下吧。" : "准备开始下一次专注。"; content.userInfo = ["focus":true]
        if UserDefaults.standard.object(forKey: "notificationSound") as? Bool != false { content.sound = .default }
        let request = UNNotificationRequest(identifier: "zilo-focus",content: content,trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1,date.timeIntervalSinceNow),repeats: false)); center.add(request)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,willPresent notification: UNNotification,withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) { completion([.banner,.list,.sound]) }
    func userNotificationCenter(_ center: UNUserNotificationCenter,didReceive response: UNNotificationResponse,withCompletionHandler completion: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            if response.actionIdentifier == "done",let raw = info["taskID"] as? String,let id = UUID(uuidString: raw) { if let raw = info["checkID"] as? String,let check = UUID(uuidString: raw) { self.onCompleteCheck?(id,check) } else { self.onComplete?(id) } }
            else if response.actionIdentifier == "snooze" {
                let copy = response.notification.request.content.mutableCopy() as! UNMutableNotificationContent
                center.add(UNNotificationRequest(identifier: "zilo-snooze-" + UUID().uuidString,content: copy,trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600,repeats: false)))
            } else { self.onOpen?(info) }
            completion()
        }
    }
}
@MainActor final class MobileFocusTimer: ObservableObject {
    struct Snapshot: Codable { var mode: String; var minutes: Int; var taskID: UUID?; var elapsed: Double; var started: Date?; var resumed: Date?; var phase: String?; var rounds: Int?; var shortBreak: Int?; var longBreak: Int? }
    @Published var mode = "番茄"
    @Published var minutes = 25
    @Published var shortBreak = 5
    @Published var longBreak = 15
    @Published var phase = "专注"
    @Published var rounds = 0
    @Published var taskID: UUID?
    @Published var elapsed: Double = 0
    @Published var running = false
    private var started: Date?
    private var resumed: Date?
    private var accumulated: Double = 0
    private var clock: Timer?
    private let defaults: UserDefaults
    private let now: () -> Date
    weak var store: MobileStore?
    init(defaults: UserDefaults = .standard,now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.now = now
        if let data = defaults.data(forKey: "mobileFocus"),let s = try? JSONDecoder().decode(Snapshot.self,from: data) {
            mode = s.mode; minutes = s.minutes; taskID = s.taskID; accumulated = s.elapsed; started = s.started; resumed = s.resumed; running = resumed != nil; elapsed = accumulated
            phase = s.phase ?? "专注"; rounds = s.rounds ?? 0; shortBreak = s.shortBreak ?? 5; longBreak = s.longBreak ?? 15
        }
        clock = Timer.scheduledTimer(withTimeInterval: 0.5,repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    deinit { clock?.invalidate() }
    var length: Double { Double((phase == "休息" ? (rounds % 4 == 0 ? longBreak : shortBreak) : minutes) * 60) }
    var display: String { let seconds = Int(mode == "番茄" ? max(0,length - elapsed) : elapsed); return String(format: "%02d:%02d",seconds / 60,seconds % 60) }
    func selectMode(_ value: String) { guard !running && elapsed == 0 else { return }; mode = value; phase = "专注"; persist() }
    func start() {
        guard !running else { return }; if started == nil { started = now() }; resumed = now(); running = true; persist()
        if mode == "番茄" { MobileNotifications.shared.focusDeadline(now().addingTimeInterval(length - elapsed),phase: phase) }
    }
    func pause() { tick(); guard running else { return }; accumulated = elapsed; resumed = nil; running = false; MobileNotifications.shared.focusDeadline(nil); persist() }
    func tick() {
        if running,let resumed { elapsed = max(0,accumulated + now().timeIntervalSince(resumed)) }
        if running && mode == "番茄" && elapsed >= length && store != nil { finish(completed: true) }
    }
    func finish(completed: Bool = false) {
        let duration = completed ? length : elapsed
        let ended = completed ? resumed?.addingTimeInterval(max(0,length - accumulated)) ?? now() : now()
        if phase == "专注",duration > 0,let started {
            let record = FocusRecord(taskID: taskID,started: started,seconds: duration,mode: mode,completedPomodoro: completed && mode == "番茄",ended: ended)
            if store?.save(record) == false { accumulated = elapsed; resumed = nil; running = false; MobileNotifications.shared.focusDeadline(nil); persist(); return }
            store?.log("结束专注","\(Int(duration / 60)) 分钟",owner: record.id)
        }
        if completed && mode == "番茄" {
            if phase == "专注" { rounds += 1; phase = "休息" } else { phase = "专注" }
        } else { phase = "专注" }
        running = false; resumed = nil; started = nil; accumulated = 0; elapsed = 0; MobileNotifications.shared.focusDeadline(nil); persist()
    }
    func persist() {
        let s = Snapshot(mode: mode,minutes: minutes,taskID: taskID,elapsed: accumulated,started: started,resumed: resumed,phase: phase,rounds: rounds,shortBreak: shortBreak,longBreak: longBreak)
        defaults.set(try? JSONEncoder().encode(s),forKey: "mobileFocus")
    }
}
