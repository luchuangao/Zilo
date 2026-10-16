import SwiftUI
import UIKit

@MainActor extension MobileStore {
    @discardableResult func applyTaskChanges(_ changed: [TaskItem],action: String) -> Bool {
        guard !changed.isEmpty else { return false }
        do {
            try persistence.transaction { for task in changed { try persistence.save(task) } }
            reload(); log(action,changed[0].title,owner: changed[0].id); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func moveTaskTree(_ id: UUID,to listID: UUID?) -> Bool {
        guard var root = tasks.first(where: { $0.id == id && !$0.deleted }),listID == nil || lists.contains(where: { $0.id == listID && !$0.deleted }) else { return false }
        let children = TaskHierarchy.rows(root: root,tasks: tasks,collapsed: []).dropFirst().map(\.task)
        root.parentID = nil; root.listID = listID; root.section = ""
        return applyTaskChanges([root] + children.map { var task = $0; task.listID = listID; task.section = ""; return task },action: "移动任务")
    }
    @discardableResult func setTaskAbandoned(_ id: UUID,to value: Bool) -> Bool {
        guard let root = tasks.first(where: { $0.id == id && !$0.deleted }) else { return false }
        let changed = TaskHierarchy.rows(root: root,tasks: tasks,collapsed: []).map { row -> TaskItem in
            var task = row.task
            if task.id != id && task.completed { return task }
            task.abandoned = value
            if value { task.completed = false; task.completedAt = nil; task.archived = false }
            return task
        }
        return applyTaskChanges(changed,action: value ? "放弃任务" : "恢复任务")
    }
    func setTaskNote(_ id: UUID,to value: Bool) {
        mutate(id) { $0.isNote = value; if value { $0.completed = false; $0.completedAt = nil; $0.abandoned = false } }
    }
    func setTaskDate(_ id: UUID,date: Date?,allDay: Bool) {
        mutate(id) { task in
            task.setDue(date); task.allDay = allDay; task.repeatRule.anchor = date
            if date != nil && task.reminders.isEmpty { task.reminders = TaskCreationPreferences.reminders(allDay: allDay) }
        }
    }
    @discardableResult func duplicateTask(_ id: UUID) -> UUID? {
        guard let root = tasks.first(where: { $0.id == id && !$0.deleted }) else { return nil }
        let rows = TaskHierarchy.rows(root: root,tasks: tasks,collapsed: [])
        let ids = Dictionary(uniqueKeysWithValues: rows.map { ($0.id,UUID()) })
        let changed = rows.map { row -> TaskItem in
            var task = row.task; task.id = ids[row.id]!; task.parentID = row.depth == 0 ? nil : task.parentID.flatMap { ids[$0] }
            task.sourceID = nil; task.completed = false; task.completedAt = nil; task.abandoned = false; task.pinned = false; task.isTemplate = false; task.archived = false; task.created = Date()
            if row.depth == 0 { task.order = root.order + 0.5 }
            task.checks = task.checks.map { var check = $0; check.id = UUID(); check.done = false; return check }
            return task
        }
        return applyTaskChanges(changed,action: "创建副本") ? ids[id] : nil
    }
}

enum MobileTaskMenuEditor: String,Identifiable { case date, child, parent, tag, rename, note
    var id: String { rawValue }
    var title: String { switch self { case .date: return "设置日期"; case .child: return "添加子任务"; case .parent: return "关联主任务"; case .tag: return "新建标签"; case .rename: return "修改名称"; case .note: return "便签" } }
}
struct MobileTaskMenu: ViewModifier {
    var taskID: UUID
    var quadrantActions = false
    @EnvironmentObject private var store: MobileStore
    @EnvironmentObject private var timer: MobileFocusTimer
    @State private var editor: MobileTaskMenuEditor?
    var task: TaskItem? { store.tasks.first { $0.id == taskID } }
    func body(content: Content) -> some View {
        content.contextMenu {
            if let task {
                if task.deleted { Button("恢复任务",systemImage: "arrow.uturn.backward") { store.restore(taskID) } }
                else {
                    Menu("日期",systemImage: "calendar") {
                        Button("今天",systemImage: "sun.max") { setDate(0) }
                        Button("明天",systemImage: "sunrise") { setDate(1) }
                        Button("一周后",systemImage: "calendar.badge.plus") { setDate(7) }
                        Button("选择日期…",systemImage: "calendar") { editor = .date }
                        if task.due != nil { Button("清除日期") { store.setTaskDate(taskID,date: nil,allDay: true) } }
                    }
                    Menu("优先级",systemImage: "flag") {
                        ForEach([3,2,1,0],id: \.self) { priority in
                            Toggle(isOn: Binding(get: { task.priority == priority },set: { if $0 { store.mutate(taskID) { $0.priority = priority } } })) {
                                Label(LocalizedStringKey(["无优先级","低优先级","中优先级","高优先级"][priority]),systemImage: priority == 0 ? "flag" : "flag.fill")
                            }
                        }
                    }
                    if quadrantActions && task.isPendingTask {
                        Menu("移动象限",systemImage: "square.grid.2x2") {
                            ForEach(0..<4,id: \.self) { index in
                                Button(LocalizedStringKey(["重要且紧急","重要不紧急","不重要但紧急","不重要不紧急"][index])) {
                                    store.mutate(taskID) { item in
                                        item.priority = index < 2 ? 2 : 0
                                        let today = Calendar.current.startOfDay(for: Date())
                                        if index == 0 || index == 2 { item.setDue(Calendar.current.date(bySettingHour: 23,minute: 59,second: 0,of: today)) }
                                        else if let due = item.due,due < Calendar.current.date(byAdding: .day,value: 1,to: today)! { item.setDue(Calendar.current.date(byAdding: .day,value: 7,to: due)) }
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("添加子任务",systemImage: "arrow.turn.down.right") { editor = .child }
                    Button("关联主任务",systemImage: "arrow.triangle.branch") { editor = .parent }
                    if task.parentID != nil { Button("移为顶层任务",systemImage: "arrow.up.left") { _ = store.promoteTask(taskID) } }
                    Button(task.pinned == true ? "取消置顶" : "置顶",systemImage: "pin") { store.mutate(taskID) { $0.pinned = !($0.pinned ?? false) } }
                    if task.isNote != true { Button(task.abandoned == true ? "恢复为待办" : "放弃",systemImage: "xmark.square") { _ = store.setTaskAbandoned(taskID,to: task.abandoned != true) } }
                    Menu("移动到",systemImage: "folder") {
                        Button("收集箱",systemImage: "tray") { _ = store.moveTaskTree(taskID,to: nil) }
                        ForEach(store.lists.filter { !$0.deleted }) { list in Button(list.name) { _ = store.moveTaskTree(taskID,to: list.id) } }
                    }
                    Menu("标签",systemImage: "tag") {
                        ForEach(Array(Set(store.tasks.filter { !$0.deleted }.flatMap(\.tags))).sorted(),id: \.self) { tag in
                            Toggle(tag,isOn: Binding(get: { task.tags.contains(tag) },set: { add in store.mutate(taskID) { if add { if !$0.tags.contains(tag) { $0.tags.append(tag) } } else { $0.tags.removeAll { $0 == tag } } } }))
                        }
                        Button("新建标签…",systemImage: "plus") { editor = .tag }
                    }
                    Divider()
                    if task.isPendingTask {
                        Menu("开始专注",systemImage: "timer") {
                            ForEach(["番茄","正计时"],id: \.self) { mode in Button(LocalizedStringKey(mode == "番茄" ? "番茄计时" : mode)) {
                                if timer.startTask(taskID,mode: mode) { store.selectedModule = "focus" } else { store.error = ZiloLanguage.text("请先结束当前专注，再开始其他任务。") }
                            }.disabled((timer.running || timer.elapsed > 0) && !(timer.taskID == taskID && timer.mode == mode && timer.phase == "专注")) }
                            if timer.running || timer.elapsed > 0 { Button("查看当前专注") { store.selectedModule = "focus" } }
                        }
                    }
                    Button("创建副本",systemImage: "doc.on.doc") { _ = store.duplicateTask(taskID) }
                    Button("复制链接",systemImage: "link") { UIPasteboard.general.url = URL(string: "ownlist://task?id=\(taskID.uuidString)") }
                    Button("打开便签",systemImage: "note.text") { _ = store.linkSideNote(taskID: taskID); editor = .note }
                    Button(task.isNote == true ? "转换为任务" : "转换为笔记",systemImage: "doc.text") { store.setTaskNote(taskID,to: task.isNote != true) }
                    Button("修改名称",systemImage: "pencil") { editor = .rename }
                    Button("打开详情",systemImage: "doc.text.magnifyingglass") { store.openTask(taskID) }
                    Divider()
                    Button("删除",systemImage: "trash",role: .destructive) { store.trash(taskID) }
                }
            }
        }.sheet(item: $editor) { action in NavigationStack { if action == .note,let note = store.sideNotes.first(where: { $0.taskID == taskID && !$0.deleted }) { MobileSideNoteEditor(noteID: note.id) } else { MobileTaskMenuForm(taskID: taskID,action: action) } }.presentationDetents(action == .note || action == .parent ? [.large] : [.medium,.large]) }
    }
    func setDate(_ offset: Int) {
        guard var task else { return }
        Scheduling.move(&task,to: Calendar.current.date(byAdding: .day,value: offset,to: Date())!,timed: false)
        store.setTaskDate(taskID,date: task.due,allDay: task.allDay)
    }
}
extension View { func mobileTaskMenu(_ id: UUID,quadrantActions: Bool = false) -> some View { modifier(MobileTaskMenu(taskID: id,quadrantActions: quadrantActions)) } }

struct MobileTaskMenuForm: View {
    var taskID: UUID
    var action: MobileTaskMenuEditor
    @EnvironmentObject private var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Date()
    @State private var allDay = true
    @FocusState private var focused: Bool
    var task: TaskItem? { store.tasks.first { $0.id == taskID && !$0.deleted } }
    var parents: [TaskItem] { store.active.filter { $0.title.localizedCaseInsensitiveContains(text) && TaskPlacement.changes(store.tasks,source: taskID,target: $0.id,position: .child) != nil } }
    var body: some View {
        Group {
            if action == .note {
                if let task {
                    VStack(alignment: .leading,spacing: 12) {
                        Text(task.title).font(.title2.bold())
                        if task.editingMode == .richText { MobileRichTextEditor(data: Binding(get: { self.task?.richText },set: { data in store.mutate(taskID) { $0.richText = data } }),plain: Binding(get: { self.task?.notes ?? "" },set: { text in store.mutate(taskID) { $0.notes = text } })) }
                        else { TextEditor(text: Binding(get: { self.task?.notes ?? "" },set: { text in store.mutate(taskID) { $0.notes = text } })).accessibilityLabel("便签内容") }
                    }.padding(20)
                }
            } else {
                Form {
                    if action == .date {
                        Toggle("全天",isOn: $allDay)
                        DatePicker("日期",selection: $date,displayedComponents: allDay ? [.date] : [.date,.hourAndMinute])
                        if task?.due != nil { Button("清除日期") { store.setTaskDate(taskID,date: nil,allDay: true); dismiss() } }
                    } else {
                        TextField(action == .parent ? "搜索主任务" : action == .tag ? "标签名称" : action == .rename ? "任务名称" : "子任务名称",text: $text).focused($focused).onSubmit(save)
                        if action == .parent {
                            ForEach(parents) { parent in Button { store.place(taskID,parent.id,.child); if store.tasks.first(where: { $0.id == taskID })?.parentID == parent.id { dismiss() } } label: { Label(parent.title,systemImage: "arrow.turn.down.right") } }
                            if parents.isEmpty { Text("没有可关联的主任务").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.navigationTitle(LocalizedStringKey(action.title)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(action == .note ? "完成" : "取消") { dismiss() } }
                if action != .note && action != .parent { ToolbarItem(placement: .confirmationAction) { Button("保存",action: save).disabled(action != .date && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
            }
            .onAppear { date = task?.due ?? Date(); allDay = task?.allDay ?? true; if action == .rename { text = task?.title ?? "" }; focused = ![.date,.note,.parent].contains(action) }
    }
    func save() {
        guard let task else { dismiss(); return }
        let value = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: action == .tag ? "#" : "")))
        switch action {
        case .date: store.setTaskDate(taskID,date: allDay ? Calendar.current.startOfDay(for: date) : date,allDay: allDay)
        case .child: guard !value.isEmpty,store.add(value,listID: task.listID,parentID: taskID) != nil else { return }
        case .tag: guard !value.isEmpty else { return }; store.mutate(taskID) { if !$0.tags.contains(value) { $0.tags.append(value) } }
        case .rename: guard !value.isEmpty else { return }; store.mutate(taskID) { $0.title = value }
        default: return
        }
        dismiss()
    }
}
