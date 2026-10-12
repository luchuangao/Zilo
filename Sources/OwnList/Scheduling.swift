import Foundation

enum Scheduling {
    static func isOverdue(_ task: TaskItem,now: Date = Date(),calendar: Calendar = .current) -> Bool {
        guard !task.completed, !task.deleted, let due = task.due else { return false }
        return task.allDay ? calendar.startOfDay(for: due) < calendar.startOfDay(for: now) : due < now
    }

    static func move(_ task: inout TaskItem,to destination: Date,timed: Bool,calendar: Calendar = .current) {
        if timed { task.start = destination; task.due = destination.addingTimeInterval(task.duration); task.allDay = false }
        else { let old = task.due; let time = old.map { calendar.dateComponents([.hour,.minute,.second],from: $0) }; let new = task.allDay ? calendar.startOfDay(for: destination) : calendar.date(bySettingHour: time?.hour ?? 9,minute: time?.minute ?? 0,second: time?.second ?? 0,of: destination)!; task.due = new; if let old, let start = task.start { task.start = new.addingTimeInterval(start.timeIntervalSince(old)) } }
        task.repeatRule.anchor = task.due
    }
}

/// Shared rules for matrix grouping and drag scheduling, using local calendar days.
enum TaskMatrix {
    enum Group: String,CaseIterable { case overdue = "已过期", today = "今天", upcoming = "未来", undated = "无日期", completed = "已完成" }
    static func isVisible(_ task: TaskItem) -> Bool { !task.deleted && !task.isTemplate && task.archived != true && task.parentID == nil }
    static func index(_ task: TaskItem,now: Date = Date(),calendar: Calendar = .current) -> Int {
        let important = task.priority >= 2
        let tomorrow = calendar.date(byAdding: .day,value: 1,to: calendar.startOfDay(for: now))!
        let urgent = task.due.map { $0 < tomorrow } ?? false
        return important ? (urgent ? 0 : 1) : (urgent ? 2 : 3)
    }
    static func group(_ task: TaskItem,now: Date = Date(),calendar: Calendar = .current) -> Group {
        if task.completed { return .completed }
        guard let due = task.due else { return .undated }
        if Scheduling.isOverdue(task,now: now,calendar: calendar) { return .overdue }
        return calendar.isDate(due,inSameDayAs: now) ? .today : .upcoming
    }
    static func sorted(_ tasks: [TaskItem],by sort: String) -> [TaskItem] {
        tasks.sorted { a,b in
            switch sort {
            case "标题": if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            case "优先级": if a.priority != b.priority { return a.priority > b.priority }
            case "日期": if a.due != b.due { return (a.due ?? .distantFuture) < (b.due ?? .distantFuture) }
            default: break
            }
            return a.order == b.order ? a.id.uuidString < b.id.uuidString : a.order < b.order
        }
    }
    static func move(_ task: inout TaskItem,to destination: Int,now: Date = Date(),calendar: Calendar = .current) {
        guard (0..<4).contains(destination), index(task,now: now,calendar: calendar) != destination else { return }
        let important = destination < 2
        if important && task.priority < 2 { task.priority = 2 }
        if !important && task.priority >= 2 { task.priority = 0 }
        let urgent = destination == 0 || destination == 2
        let currentUrgent = index(task,now: now,calendar: calendar) % 2 == 0
        // Changing importance alone must preserve existing dates, durations and reminders.
        if urgent != currentUrgent {
            let day = urgent ? now : calendar.date(byAdding: .day,value: 7,to: now)!
            Scheduling.move(&task,to: day,timed: false,calendar: calendar)
        }
    }
}
