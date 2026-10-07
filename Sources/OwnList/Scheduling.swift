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
