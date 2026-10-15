import SwiftUI
import UIKit

struct MobileTheme {
    static let colors = ["blue","teal","cyan","green","orange","pink","purple","brown","navy","gray","night","spring","summer","autumn","winter"]
    static let names = ["晴蓝","松石","秘青","蒹葭","杏黄","桃夭","暮山紫","沉香","藏蓝","灰色","夜间","春日","夏海","秋叶","冬雪"]
    static func color(_ value: String) -> Color {
        let hex: UInt32 = ["blue":0x4C6FFF,"teal":0x20A98E,"cyan":0x45A8B4,"green":0x62B45C,"orange":0xF5AD49,"yellow":0xF1C532,"lime":0xA1B828,"red":0xEF626C,"pink":0xD35C9B,"purple":0x8474D5,"brown":0xA8876F,"navy":0x465780,"gray":0x687081,"night":0x798CE9,"spring":0x4C7544,"summer":0x277984,"autumn":0xA05E27,"winter":0x465780,"none":0x9296A0][value] ?? 0x4C6FFF
        return Color(red: Double((hex >> 16) & 255) / 255,green: Double((hex >> 8) & 255) / 255,blue: Double(hex & 255) / 255)
    }
    static var accent: Color { color(UserDefaults.standard.string(forKey: "accent") ?? "blue") }
}
private struct MobileAccentKey: EnvironmentKey { static let defaultValue = Color.blue }
extension EnvironmentValues {
    var mobileAccent: Color { get { self[MobileAccentKey.self] } set { self[MobileAccentKey.self] = newValue } }
}
@main struct ZiloMobileApp: App {
    @StateObject private var store = MobileStore()
    @StateObject private var timer = MobileFocusTimer()
    @AppStorage("accent") private var accent = "blue"
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var scene
    var body: some Scene {
        WindowGroup {
            MobileRoot().environmentObject(store).environmentObject(timer).environment(\.locale,ZiloLanguage.locale).tint(MobileTheme.color(accent)).environment(\.mobileAccent,MobileTheme.color(accent))
                .preferredColorScheme(accent == "night" ? .dark : appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task {
                    timer.store = store; timer.tick(); MobileNotifications.shared.configure()
                    MobileNotifications.shared.onComplete = { id in Task { @MainActor in if store.tasks.first(where: { $0.id == id })?.completed == false { store.complete(id) } } }
                    MobileNotifications.shared.onCompleteCheck = { id,check in Task { @MainActor in store.mutate(id) { task in if let index = task.checks.firstIndex(where: { $0.id == check }) { task.checks[index].done = true } } } }
                    MobileNotifications.shared.onOpen = { info in Task { @MainActor in
                        if let id = info["taskID"] as? String,let uuid = UUID(uuidString: id) { store.openTask(uuid) }
                        else if info["habitID"] != nil { store.selectedModule = "habits" }
                        else if info["countdownID"] != nil { store.selectedModule = "more" }
                        else if info["focus"] != nil { store.selectedModule = "focus" }
                    } }
                    await store.sync()
                }
                .onChange(of: scene) { _,value in store.persistWorkspace(); if value == .active { timer.tick(); Task { await store.sync() } } else { timer.persist() } }
                .onOpenURL { url in if url.scheme == "ownlist",url.host == "task",let value = URLComponents(url: url,resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,let id = UUID(uuidString: value) { store.openTask(id) } }
                .alert("操作未完成",isPresented: Binding(get: { store.error != nil },set: { if !$0 { store.error = nil } })) { Button("好") { store.error = nil } } message: { Text(store.error ?? "") }
        }
    }
}
struct MobileRoot: View {
    @AppStorage("moduleVisibility") private var modules = ""
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    var body: some View {
        TabView(selection: $store.selectedModule) {
            MobileTasksView().tabItem { Label("任务",systemImage: "checkmark.square") }.tag("tasks")
            if ModulePreferences(rawValue: modules).isVisible(.calendar) { MobileCalendarView().tabItem { Label("日历",systemImage: "calendar") }.tag("calendar") }
            if ModulePreferences(rawValue: modules).isVisible(.focus) { MobileFocusView().tabItem { Label("专注",systemImage: "timer") }.tag("focus") }
            if ModulePreferences(rawValue: modules).isVisible(.habits) { MobileHabitsView().tabItem { Label("习惯",systemImage: "leaf") }.tag("habits") }
            MobileMoreView().tabItem { Label("更多",systemImage: "ellipsis.circle") }.tag("more")
        }.onChange(of: modules) { _,_ in store.selectedModule = "tasks" }.sheet(item: $store.selectedTask) { task in NavigationStack { MobileTaskDetail(id: task.id) } }
    }
}
struct MobileEmpty: View {
    @Environment(\.mobileAccent) private var appAccent
    var title: String; var detail: String; var icon: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 46,weight: .light)).foregroundStyle(.tint).padding(24).background(appAccent.opacity(0.07),in: Circle())
            Text(LocalizedStringKey(title)).font(.headline); Text(LocalizedStringKey(detail)).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity,maxHeight: .infinity)
    }
}
struct MobileAddTask: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore; @Environment(\.dismiss) var dismiss
    var listID: UUID?; var parentID: UUID?; var defaultDate: Date?
    @State private var title = ""; @State private var due = Date(); @State private var hasDate = false
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack { VStack(alignment: .leading,spacing: 20) {
            TextField("准备做什么？",text: $title,axis: .vertical).font(.title3).focused($focused).lineLimit(2...5).submitLabel(.done).onSubmit(create)
            Divider()
            HStack {
                Image(systemName: "calendar").foregroundStyle(.tint)
                Toggle("设置日期",isOn: $hasDate)
            }
            if hasDate { DatePicker("日期",selection: $due,displayedComponents: [.date,.hourAndMinute]).datePickerStyle(.compact) }
            Text("输入“明天下午 3 点”或 #标签，可以自动识别。").font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(22).navigationTitle(parentID == nil ? "添加任务" : "添加子任务").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("添加",action: create).fontWeight(.semibold).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        }.presentationDetents([.medium,.large]).onAppear { hasDate = defaultDate != nil; due = defaultDate ?? Date(); focused = true }
    }
    func create() { if store.add(title,listID: listID,parentID: parentID,date: hasDate ? due : nil) != nil { dismiss() } }
}
struct MobileTasksView: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    private var selection: String { get { store.taskSelection } nonmutating set { store.taskSelection = newValue } }
    private var listID: UUID? { get { store.taskListID } nonmutating set { store.taskListID = newValue } }
    @State private var sidebar = false; @State private var add = false; @State private var notifications = false; @State private var settings = false
    @State private var search = ""; @State private var collapsed = Set<UUID>()
    private var showCompleted: Bool { get { store.showCompleted } nonmutating set { store.showCompleted = newValue } }
    @State private var advancedSearch = false
    @State private var searchCriteria = TaskSearchCriteria()
    @State private var countdownsExpanded = true
    @State private var countdownEditor: Countdown?
    @AppStorage("showCountdownsToday") private var showCountdownsToday = true
    var todayCountdowns: [Countdown] { selection == "today" && listID == nil && showCountdownsToday ? store.countdowns.filter { !$0.deleted && $0.pinned }.sorted { $0.days() < $1.days() } : [] }
    @State private var editing = EditMode.inactive
    var title: String {
        if selection.hasPrefix("filter:"),let uuid = UUID(uuidString: String(selection.dropFirst(7))) { return store.filters.first { $0.id == uuid }?.name ?? "过滤器" }
        if selection.hasPrefix("tag:") { return "#" + String(selection.dropFirst(4)) }
        return listID.flatMap { id in store.lists.first { $0.id == id }?.name } ?? ZiloLanguage.text((["all":"所有","today":"今天","tomorrow":"明天","week":"最近 7 天","inbox":"收集箱","starred":"收藏","completed":"已完成","trash":"回收站","archived":"归档任务","abandoned":"已放弃"][selection] ?? "任务")) }
    var matching: [TaskItem] {
        store.tasks.filter { task in
            guard !task.isTemplate else { return false }
            if selection != "trash" && (!search.isEmpty || searchCriteria.isActive) { return searchCriteria.matches(task,query: search) }
            if selection == "trash" { return task.deleted && (search.isEmpty || task.title.localizedCaseInsensitiveContains(search)) }
            guard !task.deleted else { return false }
            if selection == "abandoned" { return task.abandoned == true }
            guard task.abandoned != true else { return false }
            if selection == "archived" { guard task.archived == true else { return false } } else { guard task.archived != true else { return false } }
            if !search.isEmpty && !(task.title + task.notes + task.tags.joined()).localizedCaseInsensitiveContains(search) { return false }
            if let listID { return task.listID == listID }
            switch selection {
            case "today": return task.due.map { Calendar.current.isDateInToday($0) || (!task.completed && $0 < Calendar.current.startOfDay(for: Date())) } == true
            case "tomorrow": return task.due.map { Calendar.current.isDateInTomorrow($0) } == true
            case "week": return task.due.map { $0 < Calendar.current.date(byAdding: .day,value: 7,to: Calendar.current.startOfDay(for: Date()))! && (!task.completed || $0 >= Calendar.current.startOfDay(for: Date())) } == true
            case "inbox": return task.listID == nil
            case "starred": return task.starred
            case "completed": return task.completed
            default:
                if selection.hasPrefix("filter:"),let uuid = UUID(uuidString: String(selection.dropFirst(7))),let filter = store.filters.first(where: { $0.id == uuid }) { return filter.matches(task) }
                if selection.hasPrefix("tag:") { return task.tags.contains(String(selection.dropFirst(4))) }
                return true
            }
        }.sorted { if ($0.pinned == true) != ($1.pinned == true) { return $0.pinned == true }; return $0.order < $1.order }
    }
    var roots: [TaskItem] { let ids = Set(matching.map(\.id)); return matching.filter { $0.parentID == nil || !ids.contains($0.parentID!) } }
    var rows: [TaskHierarchy.Row] { roots.filter { !$0.completed || selection == "completed" || selection == "trash" || showCompleted || !search.isEmpty || searchCriteria.isActive }.flatMap { root in TaskHierarchy.rows(root: root,tasks: store.tasks.filter { !$0.deleted && !$0.isTemplate && $0.archived != true && (selection == "abandoned" || $0.abandoned != true) },collapsed: collapsed) } }
    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty && !searchCriteria.isActive && !todayCountdowns.isEmpty {
                    Section {
                        if countdownsExpanded { ForEach(todayCountdowns) { day in
                            Button { countdownEditor = day } label: { HStack(spacing: 12) { Text(day.emoji); Text(day.displayName).foregroundStyle(.primary); Spacer(); Text(day.days() == 0 ? ZiloLanguage.text("就是今天") : ZiloLanguage.format(day.days() > 0 ? "还有 %lld 天" : "已经 %lld 天",abs(day.days()))).font(.caption).foregroundStyle(day.days() < 0 ? .green : appAccent) }.padding(.vertical,5) }.buttonStyle(.plain)
                        } }
                    } header: { Button { countdownsExpanded.toggle() } label: { HStack { Image(systemName: countdownsExpanded ? "chevron.down" : "chevron.right"); Text("倒数纪念日"); Text("\(todayCountdowns.count)"); Spacer() } }.foregroundStyle(.secondary) }
                }
                if rows.isEmpty && (todayCountdowns.isEmpty || !search.isEmpty) { MobileEmpty(title: search.isEmpty ? "今天也从容一点" : "没有找到任务",detail: search.isEmpty ? "点击右下角 +，记录下一件要做的事。" : "试试其他关键词。",icon: "checkmark.circle").listRowSeparator(.hidden).listRowBackground(Color.clear) }
                ForEach(rows) { row in
                    HStack(spacing: 9) {
                        if store.tasks.contains(where: { !$0.deleted && $0.parentID == row.id }) {
                            Button { if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) } } label: { Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down").font(.system(size: 11)).frame(width: 14,height: 36) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        MobileTaskRow(task: row.task).padding(.leading,CGFloat(min(row.depth,5)) * 20)
                    }.listRowInsets(EdgeInsets(top: 8,leading: 16,bottom: 8,trailing: 16))
                        .swipeActions(edge: .trailing) { if row.task.deleted { Button("恢复") { store.restore(row.id) }.tint(.green) } else { Button("删除",role: .destructive) { store.trash(row.id) } } }
                        .swipeActions(edge: .leading) { if !row.task.deleted && row.task.isNote != true && row.task.abandoned != true { Button(row.task.completed ? "恢复" : "完成") { store.complete(row.id) }.tint(appAccent) } }
                }.onMove { offsets,destination in
                    let ids = rows.map(\.id); guard destination <= ids.count else { return }
                    for source in offsets { guard source < ids.count else { continue }; let targetIndex = destination == ids.count ? ids.count - 1 : destination; if ids[source] != ids[targetIndex] { store.place(ids[source],ids[targetIndex],destination == ids.count ? .after : .before) } }
                }
                if selection != "completed" && selection != "trash" && matching.contains(where: \.completed) {
                    Button { showCompleted.toggle() } label: { Label("已完成  \(matching.filter(\.completed).count)",systemImage: showCompleted ? "chevron.down" : "chevron.right").font(.subheadline.weight(.medium)).foregroundStyle(.secondary) }.padding(.vertical,10)
                }
            }.listStyle(.plain).environment(\.editMode,$editing).refreshable { await store.sync() }
                .sheet(item: $countdownEditor) { day in NavigationStack { MobileCountdownEditor(existing: day) } }
                .searchable(text: $search,prompt: "搜索任务")
                .navigationTitle(title).navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { sidebar = true } label: { Image(systemName: "line.3.horizontal").frame(width: 30,height: 30) }.accessibilityLabel("选择清单") }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { notifications = true } label: { Image(systemName: "bell") }.accessibilityLabel("通知")
                        Menu { Button("高级搜索",systemImage: "line.3.horizontal.decrease.circle") { advancedSearch = true }; Button(showCompleted ? "隐藏已完成" : "显示已完成") { showCompleted.toggle() }; Button(editing.isEditing ? "结束排序" : "调整顺序") { editing = editing.isEditing ? .inactive : .active }; Button("设置") { settings = true } } label: { Image(systemName: "ellipsis") }.accessibilityLabel("任务选项")
                    }
                }.overlay(alignment: .bottomTrailing) {
                    if selection != "trash" { Button { add = true } label: { Image(systemName: "plus").font(.system(size: 26,weight: .medium)).foregroundStyle(.white).frame(width: 56,height: 56).background(appAccent,in: Circle()).shadow(color: appAccent.opacity(0.24),radius: 8,y: 4) }.padding(22).accessibilityLabel("添加任务") }
                }
        }.sheet(isPresented: $add) { MobileAddTask(listID: listID,defaultDate: selection == "today" ? Calendar.current.startOfDay(for: Date()) : nil) }
            .sheet(isPresented: $sidebar) { MobileSidebar(selection: $store.taskSelection,listID: $store.taskListID).presentationDetents([.large]) }
            .sheet(isPresented: $advancedSearch) { NavigationStack { MobileAdvancedSearch(criteria: $searchCriteria) } }
            .sheet(isPresented: $settings) { NavigationStack { MobileSettings() } }
            .sheet(isPresented: $notifications) { NavigationStack { MobileNotificationInbox() } }
    }
}
struct MobileTaskRow: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    var task: TaskItem
    var quadrantActions = false
    var body: some View {
        HStack(alignment: .top,spacing: 12) {
            Button { if !task.deleted { store.complete(task.id) } } label: {
                Image(systemName: task.isNote == true ? "doc.text" : task.abandoned == true ? "xmark.square" : task.completed ? "checkmark.square.fill" : "square").font(.system(size: 23,weight: .light))
                    .foregroundStyle(task.completed ? appAccent : task.priority == 3 ? .red : task.priority == 2 ? .orange : task.priority == 1 ? appAccent : Color.secondary)
                    .frame(width: 26,height: 30)
            }.buttonStyle(.borderless).disabled(task.isNote == true || task.abandoned == true).accessibilityLabel(task.isNote == true ? "笔记" : task.abandoned == true ? "已放弃" : task.completed ? "恢复 \(task.title)" : "完成 \(task.title)")
            Button { store.selectedTask = task } label: {
                VStack(alignment: .leading,spacing: 5) {
                    Text(task.title).font(.system(size: 16)).strikethrough(task.completed || task.abandoned == true).foregroundStyle(task.completed || task.abandoned == true ? Color.secondary : Color.primary).multilineTextAlignment(.leading)
                    if !task.notes.isEmpty { Text(task.notes.replacingOccurrences(of: "\n",with: " ")).font(.system(size: 12)).foregroundStyle(Color.secondary).lineLimit(1) }
                    HStack(spacing: 7) {
                        if let due = task.due { Text(due,format: .dateTime.month().day()).foregroundStyle(due < (task.allDay ? Calendar.current.startOfDay(for: Date()) : Date()) && !task.completed ? Color.red : appAccent) }
                        if !task.tags.isEmpty { Text(task.tags.map { "#" + $0 }.joined(separator: " ")).foregroundStyle(Color.secondary).lineLimit(1) }
                        let children = store.tasks.filter { !$0.deleted && $0.parentID == task.id }
                        if !children.isEmpty { Label("\(children.filter(\.completed).count)/\(children.count)",systemImage: "list.bullet") }
                        if !task.attachments.isEmpty { Image(systemName: "paperclip") }
                    }.font(.system(size: 11)).foregroundStyle(Color.secondary)
                }.frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.borderless)
            if task.pinned == true { Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top,6).accessibilityLabel("已置顶") }
            if task.starred { Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(.yellow).padding(.top,6) }
        }.padding(.vertical,4).mobileTaskMenu(task.id,quadrantActions: quadrantActions)
    }
}
struct MobileSidebar: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore; @Environment(\.dismiss) var dismiss
    @Binding var selection: String; @Binding var listID: UUID?
    @State private var newList = false; @State private var settings = false; @State private var editingList: TaskList?; @State private var newFilter = false; @State private var editingFilter: SavedFilter?
    @AppStorage("smartListVisibility") private var smartRaw = ""
    var body: some View {
        NavigationStack { List {
            Section {
                HStack {
                    Button { settings = true } label: { Image("ZiloLogo").resizable().frame(width: 42,height: 42).clipShape(RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.borderless).accessibilityLabel("打开设置")
                    VStack(alignment: .leading,spacing: 4) { Text("Zilo").font(.title3.bold()); Text(ZiloLanguage.status(store.syncStatus)).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button { Task { await store.sync() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }.buttonStyle(.borderless).accessibilityLabel("同步")
                }.padding(.vertical,6)
                ForEach(SmartListOption.primary.filter { SmartListPreferences(rawValue: smartRaw).isVisible($0.id,count: count($0.id)) }) { option in
                    Button { selection = option.id; listID = nil; dismiss() } label: {
                        HStack { Label(LocalizedStringKey(option.title),systemImage: option.icon); Spacer(); let n = count(option.id); if n > 0 { Text("\(n)").font(.caption).foregroundStyle(.secondary) } }.foregroundStyle(.primary)
                    }
                }
            }
            Section { ForEach(store.lists.filter { !$0.deleted }) { list in
                Button { listID = list.id; selection = "list"; dismiss() } label: { HStack { Image(systemName: "line.3.horizontal"); Text(list.name); Spacer(); Circle().fill(MobileTheme.color(list.color)).frame(width: 8,height: 8); Text("\(store.active.filter { $0.listID == list.id }.count)").font(.caption).foregroundStyle(.secondary) }.foregroundStyle(.primary) }
                    .contextMenu { Button("编辑清单") { editingList = list } }
            } } header: { HStack { Text("清单"); Spacer(); Button { newList = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建清单") } }
            if SmartListPreferences(rawValue: smartRaw).isVisible("filters",count: store.filters.filter { !$0.deleted }.count) {
                Section { ForEach(store.filters.filter { !$0.deleted }) { filter in
                    Button { selection = "filter:" + filter.id.uuidString; listID = nil; dismiss() } label: { Label(filter.name,systemImage: "line.3.horizontal.decrease").foregroundStyle(.primary) }.contextMenu { Button("编辑") { editingFilter = filter }; Button("删除",role: .destructive) { var item = filter; item.deleted = true; store.save(item) } }
                } } header: { HStack { Text("过滤器"); Spacer(); Button { newFilter = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建过滤器") } }
            }
            if SmartListPreferences(rawValue: smartRaw).isVisible("tags",count: Set(store.active.flatMap(\.tags)).count) {
                Section("标签") { ForEach(Array(Set(store.active.flatMap(\.tags))).sorted(),id: \.self) { tag in
                    Button { selection = "tag:" + tag; listID = nil; dismiss() } label: { Label(tag,systemImage: "tag").foregroundStyle(.primary) }
                } }
            }
            Section { ForEach(SmartListOption.secondary.filter { SmartListPreferences(rawValue: smartRaw).isVisible($0.id,count: count($0.id)) }) { option in Button { selection = option.id; listID = nil; dismiss() } label: { Label(LocalizedStringKey(option.title),systemImage: option.icon).foregroundStyle(.primary) } } }
        }.navigationTitle("清单").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.sheet(item: $editingList) { list in NavigationStack { MobileListEditor(existing: list) } }.sheet(item: $editingFilter) { filter in NavigationStack { MobileFilterEditor(existing: filter) } }.sheet(isPresented: $newFilter) { NavigationStack { MobileFilterEditor() } }.sheet(isPresented: $newList) { NavigationStack { MobileListEditor() } }.sheet(isPresented: $settings) { NavigationStack { MobileSettings() } }
    }
    func count(_ key: String) -> Int { switch key { case "today": return store.active.filter { $0.due.map { Calendar.current.isDateInToday($0) || $0 < Date() } == true }.count; case "tomorrow": return store.active.filter { $0.due.map { Calendar.current.isDateInTomorrow($0) } == true }.count; case "week": return store.active.filter { $0.due.map { $0 < Date().addingTimeInterval(7 * 86400) } == true }.count; case "inbox": return store.active.filter { $0.listID == nil }.count; case "starred": return store.active.filter(\.starred).count; case "completed": return store.tasks.filter { !$0.deleted && $0.completed }.count; case "abandoned": return store.tasks.filter { !$0.deleted && $0.abandoned == true }.count; case "trash": return store.tasks.filter(\.deleted).count; default: return store.active.count } }
}
struct MobileListEditor: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore; @Environment(\.dismiss) var dismiss
    var existing: TaskList?
    @State private var name = ""; @State private var color = "blue"; @State private var folder = ""
    var body: some View { Form {
        Section { TextField("清单名称",text: $name); TextField("文件夹（可选）",text: $folder) }
        Section("清单颜色") { LazyVGrid(columns: Array(repeating: GridItem(.flexible()),count: 6),spacing: 16) { ForEach(["blue","teal","green","yellow","orange","red","pink","purple","lime","cyan","gray","none"],id: \.self) { c in Button { color = c } label: { Circle().fill(MobileTheme.color(c)).frame(width: 34,height: 34).overlay { if c == color { Image(systemName: "checkmark").foregroundStyle(.white).fontWeight(.semibold) } } }.buttonStyle(.plain).accessibilityLabel(c) } } }
    }.navigationTitle(existing == nil ? "新建清单" : "编辑清单").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("保存") { var list = existing ?? TaskList(name: name,order: store.lists.count); list.name = name.trimmingCharacters(in: .whitespacesAndNewlines); list.color = color; list.folder = folder; if store.save(list) { dismiss() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }.onAppear { if let existing { name = existing.name; color = existing.color; folder = existing.folder } }
    }
}

struct MobileAdvancedSearch: View {
    @EnvironmentObject var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @Binding var criteria: TaskSearchCriteria
    var body: some View { Form {
        Section {
            Picker("状态",selection: $criteria.status) { Text("不限").tag("all"); Text("待完成").tag("active"); Text("已完成").tag("completed"); Text("归档任务").tag("archived") }
            Picker("清单",selection: $criteria.listID) { Text("所有清单").tag(nil as UUID?); ForEach(store.lists.filter { !$0.deleted }) { list in Text(list.name).tag(Optional(list.id)) } }
            Picker("优先级",selection: $criteria.priority) { Text("不限").tag(-1); Text("无").tag(0); Text("低").tag(1); Text("中").tag(2); Text("高").tag(3) }
            Picker("截止日期",selection: $criteria.date) { Text("不限").tag("any"); Text("今天").tag("today"); Text("已过期").tag("overdue"); Text("未来 7 天").tag("week"); Text("无日期").tag("undated") }
            TextField("标签",text: $criteria.tag); Toggle("仅含附件",isOn: $criteria.attachmentsOnly); Toggle("仅收藏",isOn: $criteria.starredOnly)
        } footer: { Text("条件同时满足时显示任务") }
        Section { Button("重置") { criteria = TaskSearchCriteria() } }
    }.navigationTitle("高级搜索").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } }
}
