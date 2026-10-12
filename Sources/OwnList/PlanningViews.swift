import SwiftUI

struct CalendarView: View {
    @AppStorage("accent") private var applicationTheme = "blue"
    @EnvironmentObject var store: Store; @EnvironmentObject var service: CalendarService
    @AppStorage("firstWeekday") private var firstWeekday = Calendar.current.firstWeekday
    @AppStorage("showLunar") private var showLunar = false
    @AppStorage("showWeekNumbers") private var showWeekNumbers = false
    var displayCalendar: Calendar { CalendarPreferences.calendar(firstWeekday: firstWeekday) }
    var compact = false
    @State private var date = Date(); @State private var mode = "月"; @State private var showHabits = true; @State private var showFocus = true; @State private var zoom = 50.0; @State private var secondaryZone = "Asia/Hong_Kong"; @State private var editing: UUID?
    var body: some View {
        let _ = applicationTheme
 VStack(alignment: .leading,spacing: 16) {
        HStack { Text("日历").font(.largeTitle.bold()); Spacer(); Button("今天") { date = Date() }; Button { advance(-1) } label: { Image(systemName: "chevron.left") }; Text(date,format: .dateTime.year().month()).font(.headline); Button { advance(1) } label: { Image(systemName: "chevron.right") } }
        HStack { Picker("视图",selection: $mode) { ForEach(["年","月","周","日","日程","课表"],id: \.self) { Text(LocalizedStringKey($0)) } }.pickerStyle(.segmented); Menu { Toggle("习惯",isOn: $showHabits); Toggle("专注记录",isOn: $showFocus); Picker("辅助时区",selection: $secondaryZone) { ForEach(["Asia/Hong_Kong","Asia/Tokyo","Europe/London","America/New_York","America/Los_Angeles"],id: \.self) { Text(LocalizedStringKey($0)) } }; Slider(value: $zoom,in: 30...100) { Text("时间轴缩放") } } label: { Image(systemName: "slider.horizontal.3") } }
        if mode == "年" { ScrollView { LazyVGrid(columns: Array(repeating: GridItem(.flexible()),count: compact ? 2 : 3),spacing: 18) { ForEach(1...12,id: \.self) { month in let d = Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year,from: date),month: month,day: 1))!; VStack { Button("\(month) 月") { date = d; mode = "月" }.font(.headline); monthGrid(d,mini: true) }.padding(8).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 12)) } } } }
        else if mode == "月" { ScrollView { monthGrid(date,mini: false) } }
        else if ["周","日","课表"].contains(mode) { timeGrid }
        else { ScrollView { LazyVStack(alignment: .leading,spacing: 14) { ForEach(0..<30,id: \.self) { offset in let day = Calendar.current.date(byAdding: .day,value: offset,to: Calendar.current.startOfDay(for: date))!; if !dayTasks(day).isEmpty || !dayEvents(day).isEmpty { Text(day,format: .dateTime.weekday().month().day()).font(.headline); dayContent(day,limit: 100) } } } } }
        if !service.message.isEmpty { Text(service.message).font(.caption).foregroundStyle(.secondary) }
    }.padding(compact ? 12 : 24).task { service.refresh(); for sub in store.subscriptions.filter({ !$0.deleted }) { do { try await service.subscribe(sub.url,name: sub.name) } catch { service.message = error.localizedDescription } } }
        .sheet(item: Binding(get: { editing.flatMap { id in store.tasks.first { $0.id == id } } },set: { editing = $0?.id })) { task in TaskDetailView(selection: $editing).environmentObject(store).environmentObject(service).frame(width: 450,height: 700) }
    }
    func advance(_ amount: Int) { date = Calendar.current.date(byAdding: mode == "年" ? .year : mode == "月" ? .month : mode == "周" || mode == "课表" ? .weekOfYear : .day,value: amount,to: date)! }
    func dayTasks(_ day: Date) -> [TaskItem] { store.tasks.filter { !$0.deleted && !$0.isTemplate && $0.due.map { Calendar.current.isDate($0,inSameDayAs: day) } == true && (mode != "课表" || $0.special == "course") }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }
    func dayEvents(_ day: Date) -> [ExternalEvent] { service.events.filter { Calendar.current.isDate($0.start,inSameDayAs: day) } }
    func monthGrid(_ value: Date,mini: Bool) -> some View {
        let c = displayCalendar; let first = c.date(from: c.dateComponents([.year,.month],from: value))!; let leading = (c.component(.weekday,from: first) - c.firstWeekday + 7) % 7
        let count = c.range(of: .day,in: .month,for: first)!.count; let total = ((leading + count + 6) / 7) * 7
        return VStack(spacing: 2) { HStack { ForEach(0..<7,id: \.self) { i in Text(["日","一","二","三","四","五","六"][(c.firstWeekday - 1 + i) % 7]).font(.caption).frame(maxWidth: .infinity) } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 2),count: 7),spacing: 2) { ForEach(0..<total,id: \.self) { index in let day = c.date(byAdding: .day,value: index - leading,to: first)!; VStack(alignment: .leading,spacing: 5) { HStack { Text("\(c.component(.day,from: day))").font(mini ? .caption : .body).foregroundStyle(c.isDateInToday(day) ? Color.accentColor : c.component(.month,from: day) == c.component(.month,from: value) ? .primary : .secondary); Spacer(); if !mini && showWeekNumbers && index % 7 == 0 { Text("W\(c.component(.weekOfYear,from: day))").font(.system(size: 9)).foregroundStyle(.secondary) }; if !mini { Button { create(on: day) } label: { Image(systemName: "plus").font(.caption2) }.buttonStyle(.plain) } }; if showLunar { Text(CalendarPreferences.lunarLabel(day)).font(.system(size: mini ? 8 : 10)).foregroundStyle(.secondary).lineLimit(1) }; if mini { if !dayTasks(day).isEmpty { Circle().fill(Color.accentColor).frame(width: 4,height: 4) } } else { dayContent(day,limit: compact ? 2 : 4) }; Spacer(minLength: 0) }.padding(mini ? 3 : 8).frame(minHeight: mini ? 28 : compact ? 85 : 110).background(c.isDateInToday(day) ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.04)).onTapGesture { if mini { date = day; mode = "日" } }.dropDestination(for: String.self) { values,_ in move(values,to: day); return true } } }
        }
    }
    func dayContent(_ day: Date,limit: Int) -> some View { VStack(alignment: .leading,spacing: 4) { ForEach(dayTasks(day).prefix(limit)) { t in Button { store.selectedTask = t.id; editing = t.id } label: { HStack(spacing: 4) { if t.completed { Image(systemName: "checkmark") }; Text(t.title).lineLimit(1) }.font(.caption).frame(maxWidth: .infinity,alignment: .leading).padding(4).background(color(t).opacity(0.13),in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(color(t)) }.buttonStyle(.plain).draggable(t.id.uuidString) }
        ForEach(dayEvents(day).prefix(limit)) { e in Text(e.title).font(.caption).lineLimit(1).padding(3).background(Color.purple.opacity(0.1)).help("\(e.source) · \(e.start.formatted())") }
        if showHabits { ForEach(store.habits.filter { !$0.deleted && $0.weekdays.contains(Calendar.current.component(.weekday,from: day)) }.prefix(limit)) { h in Text("\(h.emoji) \(h.name) \(h.count(on: day))/\(h.goal)").font(.caption2).foregroundStyle(.green).lineLimit(1) } }
        if showFocus { let seconds = store.focus.filter { !$0.deleted && Calendar.current.isDate($0.started,inSameDayAs: day) }.reduce(0) { $0 + $1.seconds }; if seconds > 0 { Text("专注 \(Int(seconds / 60)) 分钟").font(.caption2).foregroundStyle(.orange) } }
    } }
    var timeGrid: some View { let c = displayCalendar; let count = mode == "日" ? 1 : 7; let base = count == 1 ? c.startOfDay(for: date) : c.dateInterval(of: .weekOfYear,for: date)!.start
        return ScrollView([.vertical,.horizontal]) { VStack(spacing: 0) { HStack { Text("时间").frame(width: 95); ForEach(0..<count,id: \.self) { offset in let day = c.date(byAdding: .day,value: offset,to: base)!; VStack { Text(day,format: .dateTime.weekday().day()).font(.headline); ForEach(dayTasks(day).filter(\.allDay)) { t in Text(t.title).font(.caption).lineLimit(1).onTapGesture { store.selectedTask = t.id; editing = t.id }.draggable(t.id.uuidString) } }.frame(width: mode == "日" ? 550 : 140) } }
            ForEach(0..<24,id: \.self) { hour in HStack(alignment: .top,spacing: 0) { VStack { Text(String(format: "%02d:00",hour)); let reference = c.date(bySettingHour: hour,minute: 0,second: 0,of: base)!; Text(zoneLabel(reference)).font(.caption2).foregroundStyle(.secondary) }.frame(width: 95); ForEach(0..<count,id: \.self) { offset in let day = c.date(byAdding: .day,value: offset,to: base)!; VStack(alignment: .leading,spacing: 2) { ForEach(dayTasks(day).filter { !$0.allDay && c.component(.hour,from: $0.start ?? $0.due!) == hour }) { t in Text(t.title).font(.caption).padding(5).frame(maxWidth: .infinity,alignment: .leading).background(color(t).opacity(0.18),in: RoundedRectangle(cornerRadius: 5)).onTapGesture { store.selectedTask = t.id; editing = t.id }.draggable(t.id.uuidString) }; ForEach(dayEvents(day).filter { c.component(.hour,from: $0.start) == hour }) { e in Text(e.title).font(.caption).foregroundStyle(.purple) }; Spacer(minLength: 0) }.frame(width: mode == "日" ? 550 : 140,height: zoom).background(Color.gray.opacity(0.025)).border(.quaternary,width: 0.5).dropDestination(for: String.self) { values,_ in move(values,to: c.date(bySettingHour: hour,minute: 0,second: 0,of: day)!); return true } } } }
        } }
    }
    func zoneLabel(_ value: Date) -> String { let f = DateFormatter(); f.timeZone = TimeZone(identifier: secondaryZone); f.dateFormat = "HH:mm"; return f.string(from: value) }
    func color(_ task: TaskItem) -> Color { store.lists.first { $0.id == task.listID }?.color.listColor ?? .blue }
    func move(_ values: [String],to day: Date) { for raw in values { if let id = UUID(uuidString: raw) { store.mutate(id) { Scheduling.move(&$0,to: day,timed: ["日","周","课表"].contains(mode)) } } } }
    func create(on day: Date) { if let id = store.add("新任务") { store.mutate(id) { $0.due = day }; editing = id } }
}
struct MatrixView: View {
    @AppStorage("accent") private var applicationTheme = "blue"
    @EnvironmentObject var store: Store
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var focus: FocusTimer
    @AppStorage("matrixShowCompleted") private var showCompleted = true
    @AppStorage("matrixShowMetadata") private var showMetadata = true
    @AppStorage("matrixSort") private var sort = "日期"

    var body: some View {
        let _ = applicationTheme

        TimelineView(.periodic(from: .now,by: 60)) { timeline in
            let tasks = store.tasks.filter(TaskMatrix.isVisible)
            VStack(spacing: 0) {
                HStack {
                    Text("四象限").font(.system(size: 20,weight: .semibold))
                    Spacer()
                    Menu {
                        Toggle("显示已完成",isOn: $showCompleted)
                        Toggle("显示清单和日期",isOn: $showMetadata)
                        Picker("排序",selection: $sort) {
                            ForEach(["日期","优先级","标题","手动"],id: \.self) { Text(LocalizedStringKey($0)) }
                        }
                    } label: { Image(systemName: "ellipsis").frame(width: 30,height: 30) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(ListTheme.secondary).help("四象限显示设置").accessibilityLabel("四象限显示设置")
                }.frame(height: 52)
                GeometryReader { geometry in
                    let height = max(150,(geometry.size.height - 12) / 2)
                    VStack(spacing: 12) {
                        HStack(spacing: 12) { card(0,tasks: tasks,now: timeline.date); card(1,tasks: tasks,now: timeline.date) }.frame(height: height)
                        HStack(spacing: 12) { card(2,tasks: tasks,now: timeline.date); card(3,tasks: tasks,now: timeline.date) }.frame(height: height)
                    }
                }
            }.padding(.horizontal,20).padding(.bottom,18)
            .foregroundStyle(ListTheme.text).background(ListTheme.sidebar)
        }
    }
    func card(_ index: Int,tasks: [TaskItem],now: Date) -> some View {
        MatrixCard(index: index,tasks: TaskMatrix.sorted(tasks.filter { TaskMatrix.index($0,now: now) == index },by: sort),now: now,showCompleted: $showCompleted,showMetadata: showMetadata)
            .environmentObject(store).environmentObject(calendar).environmentObject(focus)
            .frame(maxWidth: .infinity,maxHeight: .infinity)
    }
}

private struct MatrixCard: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("accent") private var applicationTheme = "blue"
    let index: Int
    let tasks: [TaskItem]
    let now: Date
    @Binding var showCompleted: Bool
    let showMetadata: Bool
    @EnvironmentObject var store: Store
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var focus: FocusTimer
    @State private var collapsedGroups = Set<String>()
    @State private var collapsedTasks = Set<UUID>()
    @State private var adding = false
    @State private var draft = ""
    @State private var listID: UUID?
    @State private var dropTargeted = false
    @FocusState private var inputFocused: Bool

    var title: String { ["重要且紧急","重要不紧急","不重要但紧急","不重要不紧急"][index] }
    var color: Color { [ListTheme.adaptive(0xEE596B,0xFF8391),ListTheme.adaptive(0xD99700,0xFFC454),ListTheme.adaptive(0x526AE8,0x9BAAFF),ListTheme.adaptive(0x10B994,0x5BDABC)][index] }
    var visibleTasks: [TaskItem] { tasks.filter { showCompleted || !$0.completed } }
    var body: some View {
        let _ = applicationTheme

        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(["I","II","III","IV"][index]).font(.system(size: 11,weight: .semibold,design: .serif))
                    .foregroundStyle(.white).frame(width: 17,height: 17).background(color,in: Circle())
                Text(LocalizedStringKey(title)).font(.system(size: 14,weight: .semibold)).foregroundStyle(color)
                Spacer(minLength: 4)
                Button { adding = true } label: { Image(systemName: "plus").frame(width: 26,height: 26) }
                    .buttonStyle(.plain).quietHover().foregroundStyle(ListTheme.secondary)
                    .accessibilityLabel("添加任务到" + title).help("添加任务")
                    .popover(isPresented: $adding) { addForm }
                Menu {
                    Button("添加任务",systemImage: "plus") { adding = true }
                    Toggle("显示已完成",isOn: $showCompleted)
                    Button("展开全部分组") { collapsedGroups.removeAll(); collapsedTasks.removeAll() }
                    Button("收起全部分组") { collapsedGroups = Set(TaskMatrix.Group.allCases.map(\.rawValue)) }
                } label: { Image(systemName: "ellipsis").frame(width: 26,height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(ListTheme.secondary).accessibilityLabel(title + "选项")
            }.padding(.horizontal,14).frame(height: 42)
            if visibleTasks.isEmpty {
                Text("没有任务").font(.system(size: 13)).foregroundStyle(ListTheme.secondary.opacity(0.65))
                    .frame(maxWidth: .infinity,maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading,spacing: 0) {
                        ForEach(TaskMatrix.Group.allCases,id: \.self) { group in
                            let items = visibleTasks.filter { TaskMatrix.group($0,now: now) == group }
                            if !items.isEmpty { groupHeader(group,count: items.count)
                                if !collapsedGroups.contains(group.rawValue) {
                                    ForEach(items) { task in
                                        ForEach(TaskHierarchy.rows(root: task,tasks: store.tasks.filter { $0.archived != true && (showCompleted || !$0.completed) },collapsed: collapsedTasks)) { row in
                                            taskRow(row.task,depth: row.depth)
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal,12).padding(.bottom,10)
                }
            }
        }.background(ListTheme.canvas,in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(dropTargeted ? color.opacity(0.7) : .clear,lineWidth: 2) }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .dropDestination(for: String.self) { values,_ in
                var accepted = false
                for raw in values {
                    if let id = UUID(uuidString: raw), let task = store.tasks.first(where: { $0.id == id }), TaskMatrix.isVisible(task) {
                        store.mutate(id) { TaskMatrix.move(&$0,to: index,now: now) }; accepted = true
                    }
                }
                return accepted
            } isTargeted: { dropTargeted = $0 }
    }
    func groupHeader(_ group: TaskMatrix.Group,count: Int) -> some View {
        Button {
            if !collapsedGroups.insert(group.rawValue).inserted { collapsedGroups.remove(group.rawValue) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsedGroups.contains(group.rawValue) ? "chevron.right" : "chevron.down").font(.system(size: 9)).foregroundStyle(ListTheme.secondary)
                Text(LocalizedStringKey(group.rawValue)).font(.system(size: 13,weight: .semibold))
                Text("\(count)").font(.system(size: 11)).foregroundStyle(ListTheme.secondary.opacity(0.75))
                Spacer()
            }.frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel((collapsedGroups.contains(group.rawValue) ? "展开" : "收起") + group.rawValue + "，\(count) 项任务")
    }
    func taskRow(_ task: TaskItem,depth: Int) -> some View {
        let children = store.tasks.contains { !$0.deleted && $0.parentID == task.id }
        let list = store.lists.first { !$0.deleted && $0.id == task.listID }
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                if children {
                    Button {
                        if !collapsedTasks.insert(task.id).inserted { collapsedTasks.remove(task.id) }
                    } label: { Image(systemName: collapsedTasks.contains(task.id) ? "chevron.right" : "chevron.down").font(.system(size: 9)).frame(width: 10,height: 26) }
                    .buttonStyle(.plain).foregroundStyle(ListTheme.secondary).accessibilityLabel("展开或收起子任务")
                } else { Color.clear.frame(width: 10,height: 1) }
                Button { store.complete(task.id) } label: {
                    Image(systemName: task.completed ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16)).foregroundStyle(task.completed ? ListTheme.secondary.opacity(0.45) : ListTheme.secondary)
                }.buttonStyle(.plain).accessibilityLabel((task.completed ? "取消完成：" : "完成：") + task.title)
                Button { store.selectedTask = task.id } label: {
                    HStack(spacing: 8) {
                        Text(task.title).font(.system(size: 14)).lineLimit(1).frame(maxWidth: .infinity,alignment: .leading)
                        if showMetadata { metadata(task,list: list) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(task.completed ? ListTheme.secondary.opacity(0.55) : ListTheme.text)
            }.padding(.leading,CGFloat(depth) * 20).padding(.horizontal,3).frame(height: 40)
            Rectangle().fill(ListTheme.separator.opacity(0.65)).frame(height: 0.5).padding(.leading,30 + CGFloat(depth) * 20)
        }.quietHover(selected: store.selectedTask == task.id).onTapGesture(count: 2) { open(task) }.draggable(task.id.uuidString)
        .contextMenu {
            Button("打开任务",systemImage: "square.and.pencil") { open(task) }
            Button(task.completed ? "取消完成" : "完成任务",systemImage: "checkmark") { store.complete(task.id) }
            Menu("移到象限") {
                ForEach(0..<4) { destination in
                    Button(["重要且紧急","重要不紧急","不重要但紧急","不重要不紧急"][destination]) { store.mutate(task.id) { TaskMatrix.move(&$0,to: destination,now: now) } }
                }
            }
        }
    }
    func metadata(_ task: TaskItem,list: TaskList?) -> some View {
        HStack(spacing: 5) {
            if let list {
                if list.color != "none" { Circle().fill(list.color.listColor).frame(width: 4,height: 4) }
                Text(list.name).lineLimit(1).frame(maxWidth: 65)
            } else { Text("收集箱") }
            if !task.attachments.isEmpty { Image(systemName: "paperclip") }
            if !task.notes.isEmpty || task.richText != nil { Image(systemName: "text.alignleft") }
            if let due = task.due {
                Text(due,format: .dateTime.month(.twoDigits).day(.twoDigits))
                    .foregroundStyle(Scheduling.isOverdue(task,now: now) ? Color.red : ListTheme.secondary)
            }
        }.font(.system(size: 10)).foregroundStyle(ListTheme.secondary.opacity(task.completed ? 0.45 : 0.75))
    }
    var addForm: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text("添加到" + title).font(.headline).foregroundStyle(color)
            TextField("任务名称，支持日期和 #标签",text: $draft).textFieldStyle(.roundedBorder).focused($inputFocused).onSubmit(create)
            Picker("清单",selection: $listID) {
                Text("收集箱").tag(nil as UUID?)
                ForEach(store.lists.filter { !$0.deleted }) { Text($0.name).tag(Optional($0.id)) }
            }
            HStack {
                Button("取消") { adding = false }
                Spacer()
                Button("添加",action: create).buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 310).onAppear { inputFocused = true }
    }
    func create() {
        guard let id = store.add(draft,listID: listID) else { return }
        store.mutate(id) { TaskMatrix.move(&$0,to: index,now: now) }
        draft = ""; adding = false
        collapsedGroups.removeAll()
    }
    func open(_ task: TaskItem) {
        openWindow(id: "task-detail",value: task.id)
    }
}
