import SwiftUI
import AppKit

enum TaskMenuCommand: String,Identifiable { case date, child, parent, tag, rename, batch, details, window
    var id: String { rawValue }
}

/// A passive observer leaves normal clicking, disclosure and dragging to the row.
struct TaskRowContextSurface: NSViewRepresentable {
    var recordID: UUID
    var open: (NSEvent,NSView) -> Void
    func makeNSView(context: Context) -> ContextSurface { ContextSurface() }
    func updateNSView(_ view: ContextSurface,context: Context) { view.open = open; view.identifier = NSUserInterfaceItemIdentifier(recordID.uuidString) }
    static func dismantleNSView(_ view: ContextSurface,coordinator: ()) { view.stop() }
    final class ContextSurface: NSView {
        var open: ((NSEvent,NSView) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown,.leftMouseDown]) { [weak self] event in
                guard let self,event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                      event.window === self.window,!self.isHiddenOrHasHiddenAncestor,
                      self.containsContextPoint(event.locationInWindow) else { return event }
                self.window?.makeFirstResponder(nil)
                DispatchQueue.main.async { [weak self] in guard let self,self.window != nil else { return }; self.open?(event,self) }
                return nil
            }
        }
        func containsContextPoint(_ point: NSPoint) -> Bool {
            let local = convert(point,from: nil)
            return bounds.contains(local) && visibleRect.contains(local)
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { stop() }
    }
}

private final class TaskActionItem: NSMenuItem {
    var handler: () -> Void
    init(_ title: String,symbol: String? = nil,checked: Bool = false,localize: Bool = true,action: @escaping () -> Void) {
        handler = action
        super.init(title: localize ? ZiloLanguage.text(title) : title,action: #selector(run),keyEquivalent: "")
        target = self; state = checked ? .on : .off
        if let symbol { image = NSImage(systemSymbolName: symbol,accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func run() { handler() }
}

@MainActor enum TaskContextMenu {
    static func show(_ id: UUID,store: Store,focus: FocusTimer,event: NSEvent,view: NSView,supportsBatch: Bool,command: @escaping (TaskMenuCommand) -> Void) {
        guard let task = store.tasks.first(where: { $0.id == id }) else { return }
        store.selectedTask = id
        let menu = NSMenu(); menu.autoenablesItems = false
        func action(_ title: String,_ symbol: String? = nil,checked: Bool = false,_ body: @escaping () -> Void) {
            menu.addItem(TaskActionItem(title,symbol: symbol,checked: checked,action: body))
        }
        func submenu(_ title: String,_ symbol: String,_ children: [NSMenuItem]) {
            let item = NSMenuItem(title: ZiloLanguage.text(title),action: nil,keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol,accessibilityDescription: nil)
            let child = NSMenu(); child.autoenablesItems = false; children.forEach(child.addItem); item.submenu = child; menu.addItem(item)
        }
        if task.deleted {
            action("恢复任务","arrow.uturn.backward") { store.restoreTask(id) }
        } else {
            let quick = NSMenuItem()
            let header = TaskMenuQuickControls(task: task) { days in
                menu.cancelTracking()
                DispatchQueue.main.async {
                    if let days {
                        var changed = task
                        Scheduling.move(&changed,to: Calendar.current.date(byAdding: .day,value: days,to: Date())!,timed: false)
                        _ = store.setTaskDate(id,date: changed.due,allDay: changed.allDay)
                    } else { command(.date) }
                }
            } priority: { priority in menu.cancelTracking(); DispatchQueue.main.async { store.mutate(id) { $0.priority = priority } } }
            let hosting = NSHostingView(rootView: header.environment(\.locale,ZiloLanguage.locale).themeAppearance())
            hosting.frame = NSRect(x: 0,y: 0,width: 236,height: 130); quick.view = hosting; menu.addItem(quick)
            menu.addItem(.separator())
            action("添加子任务","arrow.turn.down.right") { command(.child) }
            action("关联主任务","arrow.triangle.branch") { command(.parent) }
            if task.parentID != nil { action("移为顶层任务","arrow.up.left") { _ = store.promoteTask(id) } }
            action(task.pinned == true ? "取消置顶" : "置顶","pin",checked: task.pinned == true) { store.mutate(id) { $0.pinned = !($0.pinned ?? false) } }
            if task.isNote != true {
                action(task.abandoned == true ? "恢复为待办" : "放弃","xmark.square") { _ = store.setTaskAbandoned(id,to: task.abandoned != true) }
            }
            submenu("移动到","folder",[TaskActionItem("收集箱",symbol: "tray",checked: task.listID == nil) { _ = store.moveTaskTree(id,to: nil) }] + store.lists.filter { !$0.deleted }.sorted { $0.order < $1.order }.map { list in
                TaskActionItem(list.name,checked: task.listID == list.id,localize: false) { _ = store.moveTaskTree(id,to: list.id) }
            })
            let tags = Set(store.tasks.filter { !$0.deleted }.flatMap(\.tags)).union(task.tags).sorted()
            submenu("标签","tag",tags.map { tag in TaskActionItem(tag,checked: task.tags.contains(tag),localize: false) {
                store.mutate(id) { if $0.tags.contains(tag) { $0.tags.removeAll { $0 == tag } } else { $0.tags.append(tag) } }
            }} + [.separator(),TaskActionItem("新建标签…",symbol: "plus") { command(.tag) }])
            menu.addItem(.separator())
            if task.isPendingTask {
                let focusItems: [NSMenuItem] = [("番茄计时","番茄"),("正计时","正计时")].map { title,mode in
                    let item = TaskActionItem(title,symbol: "timer") {
                        if focus.startTask(id,mode: mode) { store.notificationModule = .focus }
                        else { store.error = ZiloLanguage.text("请先结束当前专注，再开始其他任务。") }
                    }
                    item.isEnabled = (!focus.running && focus.elapsed == 0) || (focus.taskID == id && focus.mode == mode && focus.phase == "专注")
                    return item
                }
                submenu("开始专注","timer",focusItems + (focus.running || focus.elapsed > 0 ? [TaskActionItem("查看当前专注") { store.notificationModule = .focus }] : []))
            }
            action("创建副本","doc.on.doc") { _ = store.duplicate(id) }
            action("复制链接","link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("ownlist://task?id=\(id.uuidString)",forType: .string) }
            action("打开便签","note.text") { SideNotesPanel.shared.show(store,taskID: id) }
            action(task.isNote == true ? "转换为任务" : "转换为笔记","doc.text") { _ = store.setTaskNote(id,to: task.isNote != true) }
            submenu("更多","ellipsis",[
                TaskActionItem("打开详情",symbol: "sidebar.right") { command(.details) },
                TaskActionItem("在新窗口打开",symbol: "macwindow") { command(.window) },
                TaskActionItem("修改名称",symbol: "pencil") { command(.rename) },
                
                TaskActionItem(task.starred ? "取消收藏" : "收藏任务",symbol: "star") { store.mutate(id) { $0.starred.toggle() } },
                TaskActionItem(task.archived == true ? "取消归档" : "归档任务",symbol: "archivebox") { store.mutate(id) { $0.archived = task.archived != true } },
                TaskActionItem(task.isTemplate ? "从模板创建任务" : "保存为模板",symbol: "doc.badge.plus") { _ = store.duplicate(id,asTemplate: !task.isTemplate) }
            ] + (supportsBatch ? [TaskActionItem("批量编辑",symbol: "checklist") { command(.batch) }] : []))
            menu.addItem(.separator())
            action("删除","trash") { store.mutate(id) { $0.deleted = true } }
        }
        NSMenu.popUpContextMenu(menu,with: event,for: view)
    }
}

private struct TaskMenuQuickControls: View {
    var task: TaskItem
    var date: (Int?) -> Void
    var priority: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading,spacing: 7) {
            Text("日期").font(.system(size: 11)).foregroundStyle(ListTheme.secondary)
            HStack(spacing: 10) {
                quick("今天","sun.max",color: ListTheme.text) { date(0) }
                quick("明天","sunrise",color: ListTheme.text) { date(1) }
                quick("一周后","calendar.badge.plus",color: ListTheme.text) { date(7) }
                quick("选择日期…","calendar",color: ListTheme.text) { date(nil) }
            }
            Text("优先级").font(.system(size: 11)).foregroundStyle(ListTheme.secondary)
            HStack(spacing: 10) {
                ForEach([3,2,1,0],id: \.self) { value in
                    quick(["无优先级","低优先级","中优先级","高优先级"][value],value == 0 ? "flag" : "flag.fill",color: value == 3 ? "red".listColor : value == 2 ? "orange".listColor : value == 1 ? "blue".listColor : ListTheme.text,selected: task.priority == value) { priority(value) }
                }
            }
        }.padding(.horizontal,14).padding(.vertical,10).foregroundStyle(ListTheme.text)
    }
    func quick(_ title: String,_ symbol: String,color: Color,selected: Bool = false,action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(color).frame(width: 42,height: 29).contentShape(Rectangle()) }
            .buttonStyle(.plain).quietHover(selected: selected).help(LocalizedStringKey(title)).accessibilityLabel(ZiloLanguage.text(title))
    }
}

struct TaskContextMenuModifier: ViewModifier {
    var taskID: UUID
    var rename: (() -> Void)?
    var batch: (() -> Void)?
    var childAdded: () -> Void
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var focus: FocusTimer
    @Environment(\.openWindow) private var openWindow
    @State private var editor: TaskMenuCommand?
    func body(content: Content) -> some View {
        content.background { TaskRowContextSurface(recordID: taskID) { event,view in
            TaskContextMenu.show(taskID,store: store,focus: focus,event: event,view: view,supportsBatch: batch != nil) { command in
                DispatchQueue.main.async {
                    switch command {
                    case .rename: if let rename { rename() } else { editor = command }
                    case .batch: batch?()
                    case .details: store.notificationTask = taskID
                    case .window: openWindow(id: "task-detail",value: taskID)
                    default: editor = command
                    }
                }
            }
        }}.sheet(item: $editor) { command in TaskContextEditor(taskID: taskID,command: command,childAdded: childAdded).environmentObject(store).environment(\.locale,ZiloLanguage.locale).themeAppearance() }
    }
}
extension View {
    func taskContextMenu(_ id: UUID,rename: (() -> Void)? = nil,batch: (() -> Void)? = nil,childAdded: @escaping () -> Void = {}) -> some View {
        modifier(TaskContextMenuModifier(taskID: id,rename: rename,batch: batch,childAdded: childAdded))
    }
}

private struct TaskContextEditor: View {
    var taskID: UUID
    var command: TaskMenuCommand
    var childAdded: () -> Void
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Date()
    @State private var allDay = true
    @FocusState private var focused: Bool
    var task: TaskItem? { store.tasks.first { $0.id == taskID && !$0.deleted } }
    var title: String { switch command { case .date: return "设置日期"; case .parent: return "关联主任务"; case .tag: return "新建标签"; case .rename: return "修改名称"; default: return "添加子任务" } }
    var candidates: [TaskItem] { store.tasks.filter { !$0.deleted && !$0.completed && $0.abandoned != true && $0.isNote != true && $0.title.localizedCaseInsensitiveContains(text) && TaskPlacement.changes(store.tasks,source: taskID,target: $0.id,position: .child) != nil }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text(LocalizedStringKey(title)).font(.headline)
            if command == .date {
                DatePicker("日期",selection: $date,displayedComponents: .date).datePickerStyle(.graphical)
                Toggle("全天",isOn: $allDay)
                if !allDay { DatePicker("时间",selection: $date,displayedComponents: .hourAndMinute) }
            } else {
                TextField(command == .parent ? "搜索主任务" : command == .tag ? "标签名称" : command == .rename ? "任务名称" : "子任务名称",text: $text).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
                if command == .parent {
                    ScrollView { LazyVStack(spacing: 4) {
                        ForEach(candidates) { target in Button { if store.placeTask(taskID,relativeTo: target.id,position: .child) { store.selectedTask = target.id; dismiss() } } label: {
                            HStack { Image(systemName: "arrow.turn.down.right"); Text(target.title).lineLimit(1); Spacer(); Text(store.lists.first { $0.id == target.listID }?.name ?? ZiloLanguage.text("收集箱")).font(.caption).foregroundStyle(ListTheme.secondary) }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain).quietHover() }
                        if candidates.isEmpty { Text("没有可关联的主任务").foregroundStyle(ListTheme.secondary).padding() }
                    }}.frame(height: 260)
                }
            }
            HStack {
                if command == .date { Button("清除日期") { _ = store.setTaskDate(taskID,date: nil,allDay: true); dismiss() } }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                if command != .parent { Button("保存",action: save).keyboardShortcut(.defaultAction).disabled(command != .date && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }.padding(22).frame(width: 360).foregroundStyle(ListTheme.text)
            .onAppear { date = task?.due ?? Date(); allDay = task?.allDay ?? true; if command == .rename { text = task?.title ?? "" }; focused = command != .date }
    }
    func save() {
        guard let task else { dismiss(); return }
        let value = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: command == .tag ? "#" : "")))
        switch command {
        case .date: _ = store.setTaskDate(taskID,date: allDay ? Calendar.current.startOfDay(for: date) : date,allDay: allDay)
        case .child:
            guard !value.isEmpty,store.add(value,listID: task.listID,parentID: taskID,section: task.section) != nil else { return }; childAdded()
        case .rename:
            guard !value.isEmpty else { return }; store.mutate(taskID) { $0.title = value }
        case .tag:
            guard !value.isEmpty else { return }; store.mutate(taskID) { if !$0.tags.contains(value) { $0.tags.append(value) } }
        default: return
        }
        dismiss()
    }
}
