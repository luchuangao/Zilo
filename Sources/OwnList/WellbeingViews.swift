import SwiftUI
import Charts
import UserNotifications

struct ModuleIconButton: View {
    var symbol: String; var title: String; var action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: symbol).font(.system(size: 17)).frame(width: 30,height: 30).contentShape(Rectangle()) }.buttonStyle(.plain).quietHover().help(title).accessibilityLabel(title) }
}
struct WellbeingMetric: View {
    var title: String; var value: String; var unit = ""
    var body: some View { VStack(alignment: .leading,spacing: 10) { Text(LocalizedStringKey(title)).font(.system(size: 12)).foregroundStyle(ListTheme.secondary); HStack(alignment: .firstTextBaseline,spacing: 4) { Text(value).font(.system(size: 28,weight: .medium)).monospacedDigit(); Text(LocalizedStringKey(unit)).font(.system(size: 12)) } }.padding(16).frame(maxWidth: .infinity,alignment: .leading).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 12)) }
}
struct FocusView: View {
    @AppStorage("accent") private var applicationTheme = "blue"
    @AppStorage("focusSound") private var sound = true
    @EnvironmentObject var store: Store; @EnvironmentObject var timer: FocusTimer
    @State private var addRecord = false; @State private var settings = false
    var records: [FocusRecord] { store.focus.filter { !$0.deleted }.sorted { $0.started > $1.started } }
    var today: [FocusRecord] { records.filter { Calendar.current.isDateInToday($0.started) } }
    var days: [Date] { Array(Set(records.map { Calendar.current.startOfDay(for: $0.started) })).sorted(by: >) }
    var body: some View {
        let _ = applicationTheme
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("番茄专注").font(.system(size: 20,weight: .semibold)); Spacer(minLength: 0)
                    ModuleIconButton(symbol: sound ? "speaker.wave.2" : "speaker.slash",title: sound ? "关闭结束提示音" : "开启结束提示音") { sound.toggle() }
                    ModuleIconButton(symbol: "ellipsis",title: "专注设置") { settings.toggle() }.popover(isPresented: $settings) { durationSettings }
                }.padding(.horizontal,20).frame(height: 52)
                Picker("计时方式",selection: Binding(get: { timer.mode },set: { timer.changeMode($0) })) { Text("番茄计时").tag("番茄"); Text("正计时").tag("正计时") }.pickerStyle(.segmented).labelsHidden().frame(width: 210).disabled(timer.running || timer.elapsed > 0).padding(.top,12)
                Spacer(minLength: 20)
                Picker("关联任务",selection: $timer.taskID) { Text("自由专注").tag(nil as UUID?); ForEach(store.tasks.filter { !$0.deleted && ($0.isPendingTask || $0.id == timer.taskID) }) { Text($0.title).tag(Optional($0.id)) } }.labelsHidden().frame(maxWidth: 260).disabled(timer.running || timer.elapsed > 0).padding(.bottom,30)
                ZStack {
                    Circle().stroke(ListTheme.separator,lineWidth: 4)
                    if timer.elapsed > 0 { Circle().trim(from: 0,to: timer.mode == "番茄" ? min(1,timer.elapsed / timer.phaseLength) : 1).stroke(ListTheme.accent,style: StrokeStyle(lineWidth: 4,lineCap: .round)).rotationEffect(.degrees(-90)) }
                    VStack(spacing: 12) { Text(timer.display).font(.system(size: 54,weight: .light)).monospacedDigit(); Text(timer.phase == "休息" ? "休息 · 第 \(timer.rounds) 轮" : timer.mode == "番茄" ? "专注" : "正计时").font(.system(size: 12)).foregroundStyle(ListTheme.secondary) }
                }.frame(width: 250,height: 250)
                HStack(spacing: 16) {
                    Button { timer.running ? timer.pause() : timer.start() } label: { Text(timer.running ? "暂停" : timer.elapsed > 0 ? "继续" : "开始").frame(width: 84).padding(.vertical,4) }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).frame(minWidth: 100)
                    if timer.elapsed > 0 || timer.phase == "休息" { Button("结束") { timer.stop() }.buttonStyle(.bordered).controlSize(.large) }
                }.padding(.top,48)
                Spacer(minLength: 24)
                Button("小窗口") { DesktopBridge.panel(title: "专注",view: FocusMiniView().environmentObject(timer).themeAppearance(),size: NSSize(width: 260,height: 180)) }.buttonStyle(.plain).foregroundStyle(ListTheme.secondary).padding(.bottom,20)
            }.ignoresSafeArea(.container,edges: .top).frame(minWidth: 340,idealWidth: 430,maxWidth: 540,maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading,spacing: 20) {
                    Text("概览").font(.system(size: 20,weight: .semibold))
                    LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible())],spacing: 12) {
                        WellbeingMetric(title: "今日番茄",value: "\(today.filter(\.isPomodoro).count)")
                        WellbeingMetric(title: "今日专注时长",value: "\(Int(today.reduce(0) { $0 + $1.seconds } / 60))",unit: "分钟")
                        WellbeingMetric(title: "总番茄",value: "\(records.filter(\.isPomodoro).count)")
                        WellbeingMetric(title: "总专注时长",value: "\(Int(records.reduce(0) { $0 + $1.seconds } / 60))",unit: "分钟")
                    }
                    HStack { Text("专注记录").font(.system(size: 18,weight: .semibold)); Spacer(); ModuleIconButton(symbol: "plus",title: "补记专注") { addRecord = true } }.padding(.top,16)
                    if records.isEmpty { ContentUnavailableView("还没有专注记录",systemImage: "timer",description: Text("开始一次专注，或补记已经完成的专注。")) }
                    ForEach(days,id: \.self) { day in
                        VStack(alignment: .leading,spacing: 10) {
                            Text(day,format: .dateTime.year().month().day()).font(.system(size: 12)).foregroundStyle(ListTheme.secondary)
                            ForEach(records.filter { Calendar.current.isDate($0.started,inSameDayAs: day) }) { record in focusRow(record) }
                        }
                    }
                }.padding(24)
            }.ignoresSafeArea(.container,edges: .top).frame(minWidth: 400,idealWidth: 570,maxWidth: .infinity,maxHeight: .infinity)
        }.background(ListTheme.canvas).sheet(isPresented: $addRecord) { FocusRecordEditor(taskID: timer.taskID).environmentObject(store).themeAppearance() }
    }
    var durationSettings: some View {
        VStack(alignment: .leading,spacing: 18) {
            Text("专注设置").font(.headline)
            Stepper("专注 \(timer.minutes) 分钟",value: $timer.minutes,in: 1...180)
            Stepper("短休息 \(timer.breakMinutes) 分钟",value: $timer.breakMinutes,in: 1...60)
            Stepper("长休息 \(timer.longBreakMinutes) 分钟",value: $timer.longBreakMinutes,in: 1...90)
            Text("每完成 4 个番茄后进入长休息。计时结束后手动开始下一阶段。").font(.caption).foregroundStyle(ListTheme.secondary)
        }.padding(20).frame(width: 290).disabled(timer.running || timer.elapsed > 0)
            .onChange(of: timer.minutes) { _,_ in timer.saveDurations() }.onChange(of: timer.breakMinutes) { _,_ in timer.saveDurations() }.onChange(of: timer.longBreakMinutes) { _,_ in timer.saveDurations() }
    }
    func focusRow(_ record: FocusRecord) -> some View {
        HStack(alignment: .top,spacing: 12) {
            Image(systemName: record.isPomodoro ? "timer" : "clock").foregroundStyle(ListTheme.accent).frame(width: 22).padding(.top,3)
            VStack(alignment: .leading,spacing: 7) {
                HStack { Text(record.started,format: .dateTime.hour().minute()); Text("–"); Text((record.ended ?? record.started.addingTimeInterval(record.seconds)),format: .dateTime.hour().minute()) }.font(.system(size: 11)).foregroundStyle(ListTheme.secondary)
                Text(store.tasks.first { $0.id == record.taskID }?.title ?? ZiloLanguage.text("自由专注")).font(.system(size: 14)).lineLimit(2)
            }; Spacer(minLength: 8)
            Text(record.seconds >= 60 ? "\(Int(record.seconds / 60)) 分钟" : "\(Int(record.seconds)) 秒").font(.system(size: 12)).foregroundStyle(ListTheme.secondary)
        }.padding(.vertical,12).contextMenu { Button("删除记录",role: .destructive) { var value = record; value.deleted = true; store.save(value) } }
    }
}
struct FocusRecordEditor: View {
    @EnvironmentObject var store: Store; @Environment(\.dismiss) var dismiss
    @State var taskID: UUID?; @State private var minutes = 25; @State private var ended = Date()
    var body: some View { VStack(alignment: .leading,spacing: 20) {
        Text("补记专注").font(.title2.bold())
        Form {
            Picker("关联任务",selection: $taskID) { Text("自由专注").tag(nil as UUID?); ForEach(store.tasks.filter { !$0.deleted && !$0.isTemplate }) { Text($0.title).tag(Optional($0.id)) } }
            Stepper("专注时长：\(minutes) 分钟",value: $minutes,in: 1...720)
            DatePicker("结束时间",selection: $ended,in: ...Date())
        }
        HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { if store.save(FocusRecord(taskID: taskID,started: ended.addingTimeInterval(Double(-minutes * 60)),seconds: Double(minutes * 60),mode: "补记",completedPomodoro: false,ended: ended)) { dismiss() } }.buttonStyle(.borderedProminent) }
    }.padding(24).frame(width: 420) }
}
struct FocusMiniView: View { @EnvironmentObject var timer: FocusTimer; var body: some View { VStack(spacing: 12) { Text(LocalizedStringKey(timer.phase)).foregroundStyle(.secondary); Text(timer.display).font(.system(size: 40,design: .rounded)).monospacedDigit(); HStack { Button(timer.running ? "暂停" : "开始") { if timer.running { timer.pause() } else { timer.start() } }; Button("结束") { timer.stop() } } }.padding().frame(maxWidth: .infinity,maxHeight: .infinity) } }

struct HabitsView: View {
    @AppStorage("accent") private var applicationTheme = "blue"
    @EnvironmentObject var store: Store
    @State private var date = Date(); @State private var week = Date(); @State private var selected: UUID?
    @State private var editor = false; @State private var existing: Habit?; @State private var showDeleted = false
    var habits: [Habit] { store.habits.filter { $0.deleted == showDeleted } }
    var calendar: Calendar { CalendarPreferences.calendar(firstWeekday: UserDefaults.standard.integer(forKey: "firstWeekday")) }
    var weekDays: [Date] { let start = calendar.dateInterval(of: .weekOfYear,for: week)!.start; return (0..<7).map { calendar.date(byAdding: .day,value: $0,to: start)! } }
    var current: Habit? { habits.first { $0.id == selected } }
    var body: some View {
        let _ = applicationTheme
        HSplitView {
            VStack(spacing: 0) {
                HStack { Text(showDeleted ? "已删除的习惯" : "习惯").font(.system(size: 20,weight: .semibold)); Spacer()
                    ModuleIconButton(symbol: "plus",title: "新建习惯") { existing = nil; editor = true }
                    Menu { Button(showDeleted ? "查看习惯" : "已删除的习惯") { showDeleted.toggle(); selected = nil } } label: { Image(systemName: "ellipsis").frame(width: 28,height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("习惯选项")
                }.padding(.horizontal,20).frame(height: 52)
                HStack { ModuleIconButton(symbol: "chevron.left",title: "上一周") { shiftWeek(-1) }; Text(weekDays[0],format: .dateTime.month().day()); Text("–"); Text(weekDays[6],format: .dateTime.month().day()); Spacer(); Button("本周") { week = Date(); date = Date() }.buttonStyle(.plain).foregroundStyle(ListTheme.accent); ModuleIconButton(symbol: "chevron.right",title: "下一周") { shiftWeek(1) }.disabled(weekDays.contains { calendar.isDateInToday($0) }) }.font(.system(size: 12)).foregroundStyle(ListTheme.secondary).padding(.horizontal,16).padding(.vertical,10)
                HStack(spacing: 0) { ForEach(weekDays,id: \.self) { day in
                    VStack(spacing: 6) { Text(day,format: .dateTime.weekday(.narrow)); Text("\(calendar.component(.day,from: day))").font(.system(size: 14,weight: calendar.isDateInToday(day) ? .semibold : .regular)); Circle().fill(completedDay(day) ? ListTheme.accent : ListTheme.separator).frame(width: 5,height: 5) }.font(.system(size: 11)).foregroundStyle(calendar.isDateInToday(day) ? ListTheme.accent : ListTheme.secondary).frame(maxWidth: .infinity)
                } }.padding(.horizontal,16).padding(.bottom,18)
                if habits.isEmpty { VStack(spacing: 14) { Image(systemName: "leaf.circle").font(.system(size: 62,weight: .ultraLight)).foregroundStyle(ListTheme.secondary); Text(showDeleted ? "没有已删除的习惯" : "来一起养成习惯吧").font(.system(size: 17,weight: .medium)); if !showDeleted { Text("每天一点进步，记录每一次坚持。").foregroundStyle(ListTheme.secondary); Button("新建习惯") { existing = nil; editor = true }.buttonStyle(.borderedProminent) } }.frame(maxWidth: .infinity,maxHeight: .infinity) }
                else { ScrollView { LazyVStack(spacing: 8) { ForEach(habits) { habit in habitRow(habit) } }.padding(.horizontal,16).padding(.bottom,16) } }
            }.ignoresSafeArea(.container,edges: .top).frame(minWidth: 370,idealWidth: 460,maxWidth: 540,maxHeight: .infinity)
            Group { if let current { habitDetails(current) } else { ContentUnavailableView("习惯详情",systemImage: "leaf",description: Text("选择一个习惯，查看进度并补记打卡。")) } }.ignoresSafeArea(.container,edges: .top).frame(minWidth: 360,idealWidth: 500,maxWidth: .infinity,maxHeight: .infinity)
        }.sheet(isPresented: $editor) { HabitEditor(existing: existing).environmentObject(store).themeAppearance() }.onChange(of: showDeleted) { _,_ in selected = nil }.onAppear { if let id = store.notificationHabit { selected = id; store.notificationHabit = nil } }.onChange(of: store.notificationHabit) { _,id in if let id { selected = id; store.notificationHabit = nil } }
    }
    func shiftWeek(_ delta: Int) { week = calendar.date(byAdding: .weekOfYear,value: delta,to: week)! }
    func completedDay(_ day: Date) -> Bool { let scheduled = habits.filter { !$0.deleted && $0.weekdays.contains(calendar.component(.weekday,from: day)) }; return !scheduled.isEmpty && scheduled.allSatisfy { $0.count(on: day) >= $0.goal } }
    func habitRow(_ habit: Habit) -> some View {
        VStack(alignment: .leading,spacing: 14) {
            Button { selected = habit.id } label: { HStack(spacing: 10) { Text(habit.emoji).font(.system(size: 24)); Text(habit.name).font(.system(size: 15,weight: .medium)).lineLimit(1); Spacer(); Text("连续 \(habit.streak()) 次").font(.system(size: 11)).foregroundStyle(ListTheme.secondary) }.contentShape(Rectangle()) }.buttonStyle(.plain)
            HStack(spacing: 0) { ForEach(weekDays,id: \.self) { day in let count = habit.count(on: day); let scheduled = habit.weekdays.contains(calendar.component(.weekday,from: day))
                Button { selected = habit.id; date = day; var value = habit; value.logs[Day.key(day)] = count >= habit.goal ? 0 : habit.goal; store.save(value) } label: {
                    ZStack { Circle().fill(count >= habit.goal ? ListTheme.accent : count > 0 ? ListTheme.accent.opacity(0.18) : ListTheme.input).frame(width: 30,height: 30); Image(systemName: count >= habit.goal ? "checkmark" : scheduled ? "plus" : "minus").font(.system(size: 12)).foregroundStyle(count >= habit.goal ? Color.white : ListTheme.secondary) }.frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(showDeleted || !scheduled || calendar.startOfDay(for: day) > calendar.startOfDay(for: Date())).help("\(Day.key(day))：\(count) / \(habit.goal)").accessibilityLabel("\(habit.name)，\(Day.key(day))，\(count) / \(habit.goal)")
            } }
        }.padding(14).background(selected == habit.id ? ListTheme.selection : ListTheme.canvas,in: RoundedRectangle(cornerRadius: 10)).overlay(alignment: .bottom) { if selected != habit.id { Divider().padding(.horizontal,14) } }
            .contextMenu { if showDeleted { Button("恢复习惯") { var value = habit; value.deleted = false; store.save(value) } } else { Button("编辑") { existing = habit; editor = true }; Button("删除",role: .destructive) { var value = habit; value.deleted = true; store.save(value); selected = nil } } }
    }
    func habitDetails(_ habit: Habit) -> some View {
        ScrollView { VStack(alignment: .leading,spacing: 24) {
            HStack { Text(habit.emoji).font(.system(size: 32)); Text(habit.name).font(.system(size: 22,weight: .semibold)); Spacer(); if !showDeleted { ModuleIconButton(symbol: "ellipsis",title: "编辑习惯") { existing = habit; editor = true } } }
            HStack { WellbeingMetric(title: "连续达标",value: "\(habit.streak())",unit: "次"); WellbeingMetric(title: "累计打卡",value: "\(habit.logs.values.reduce(0,+))",unit: "次") }
            VStack(alignment: .leading,spacing: 18) {
                DatePicker("打卡日期",selection: $date,in: ...Date(),displayedComponents: .date)
                HStack { Text("\(habit.count(on: date)) / \(habit.goal)").font(.system(size: 30,weight: .light)).monospacedDigit(); Spacer(); Button { update(habit,-1) } label: { Image(systemName: "minus") }.disabled(habit.count(on: date) == 0); Button("打卡") { update(habit,1) }.buttonStyle(.borderedProminent) }
            }.padding(18).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 12)).disabled(showDeleted || !habit.weekdays.contains(calendar.component(.weekday,from: date)))
            Text("最近 35 天").font(.system(size: 16,weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()),count: 7),spacing: 8) { ForEach(0..<35,id: \.self) { index in let day = calendar.date(byAdding: .day,value: index - 34,to: calendar.startOfDay(for: Date()))!; let count = habit.count(on: day)
                Button { date = day } label: { Text("\(calendar.component(.day,from: day))").font(.system(size: 12)).frame(maxWidth: .infinity).frame(height: 32).background(count >= habit.goal ? ListTheme.accent : count > 0 ? ListTheme.accent.opacity(0.2) : ListTheme.input,in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(count >= habit.goal ? Color.white : ListTheme.text).overlay { if calendar.isDate(day,inSameDayAs: date) { RoundedRectangle(cornerRadius: 6).stroke(ListTheme.accent,lineWidth: 2) } } }.buttonStyle(.plain).help("\(Day.key(day))：\(count) / \(habit.goal)")
            } }
            Text("点击日期查看或补记；灰色日期尚未打卡。").font(.caption).foregroundStyle(ListTheme.secondary)
            Label(habit.reminderHour < 0 ? "未设置提醒" : "提醒时间 \(habit.reminderHour):00",systemImage: "bell").font(.system(size: 12)).foregroundStyle(ListTheme.secondary)
        }.padding(24) }
    }
    func update(_ habit: Habit,_ amount: Int) { var value = habit; value.logs[Day.key(date)] = max(0,habit.count(on: date) + amount); store.save(value) }
}
struct HabitEditor: View {
    @EnvironmentObject var store: Store; @Environment(\.dismiss) var dismiss; var existing: Habit?; @State private var habit = Habit(name: "")
    var body: some View { VStack(alignment: .leading,spacing: 18) { Text(existing == nil ? "新建习惯" : "习惯设置").font(.title2.bold()); Form { TextField("名称",text: $habit.name); TextField("图标",text: $habit.emoji); Stepper("每次目标 \(habit.goal)",value: $habit.goal,in: 1...1000); WeekdayPicker(days: $habit.weekdays); Picker("提醒时间",selection: $habit.reminderHour) { Text("不提醒").tag(-1); ForEach(0..<24,id: \.self) { Text("\($0):00").tag($0) } } }; HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { habit.name = habit.name.trimmingCharacters(in: .whitespacesAndNewlines); if store.save(habit) { dismiss() } }.buttonStyle(.borderedProminent).disabled(habit.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || habit.weekdays.isEmpty) } }.padding(24).frame(width: 420).onAppear { if let existing { habit = existing } } }
}

struct CountdownView: View {
    @AppStorage("accent") private var applicationTheme = "blue"
    @EnvironmentObject var store: Store
    @State private var category = "所有"; @State private var editor = false; @State private var existing: Countdown?; @State private var sort = "日期"; @State private var showDeleted = false
    private let categories = ["所有","纪念日","倒数日","节日"]
    var records: [Countdown] { store.countdowns.filter { $0.deleted == showDeleted && (category == "所有" || $0.category == category) }.sorted { a,b in if a.pinned != b.pinned { return a.pinned }; if sort == "名称" { return a.name.localizedStandardCompare(b.name) == .orderedAscending }; let x = a.occurrence(), y = b.occurrence(); return x == y ? a.id.uuidString < b.id.uuidString : x < y } }
    var body: some View {
        let _ = applicationTheme
        VStack(alignment: .leading,spacing: 0) {
            HStack { Text(showDeleted ? "已删除的纪念日" : "倒数纪念日").font(.system(size: 20,weight: .semibold)); Spacer(); ModuleIconButton(symbol: "plus",title: "新建倒数纪念日") { existing = nil; editor = true }; Menu { Picker("排序",selection: $sort) { Text("日期").tag("日期"); Text("名称").tag("名称") }; Divider(); Button(showDeleted ? "查看纪念日" : "已删除的纪念日") { showDeleted.toggle() } } label: { Image(systemName: "ellipsis").frame(width: 30,height: 30) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("纪念日选项") }.padding(.horizontal,24).frame(height: 52)
            HStack(spacing: 10) { ForEach(categories,id: \.self) { item in Button { category = item } label: { Text(LocalizedStringKey(item)).font(.system(size: 13,weight: category == item ? .medium : .regular)).padding(.horizontal,14).padding(.vertical,8).foregroundStyle(category == item ? ListTheme.accent : ListTheme.secondary).background(category == item ? ListTheme.selection : .clear,in: Capsule()) }.buttonStyle(.plain) } }.padding(.horizontal,24).padding(.vertical,12)
            if records.isEmpty { ContentUnavailableView { Label(showDeleted ? "没有已删除的纪念日" : "记录值得期待的日子",systemImage: "calendar.badge.clock") } description: { Text("记录纪念日、倒数日和节日，设置提醒。") } actions: { if !showDeleted { Button("新建倒数纪念日") { existing = nil; editor = true }.buttonStyle(.borderedProminent) } }.frame(maxWidth: .infinity,maxHeight: .infinity) }
            else { GeometryReader { geometry in ScrollView { LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 18),count: geometry.size.width >= 1100 ? 3 : geometry.size.width >= 650 ? 2 : 1),spacing: 18) { ForEach(records) { day in countdownCard(day) } }.padding(24) } } }
        }.background(ListTheme.input).sheet(isPresented: $editor) { CountdownEditor(existing: existing).environmentObject(store).themeAppearance() }.onAppear { openNotification() }.onChange(of: store.notificationCountdown) { _,_ in openNotification() }
    }
    func openNotification() { if let id = store.notificationCountdown, let day = store.countdowns.first(where: { $0.id == id && !$0.deleted }) { existing = day; editor = true; store.notificationCountdown = nil } }
    func countdownCard(_ day: Countdown) -> some View {
        let days = day.days()
        return Button { existing = day; editor = true } label: {
            VStack(spacing: 20) {
                HStack(spacing: 8) { Text(day.emoji).font(.system(size: 23)); Text(day.displayName).font(.system(size: 16,weight: .medium)).lineLimit(1); if day.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(ListTheme.accent) } }
                Text("\(abs(days))").font(.system(size: 64,weight: .light,design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                Text(days == 0 ? "就是今天" : "\(day.occurrence().formatted(date: .numeric,time: .omitted)) · \(days > 0 ? "还有" : "已经") \(abs(days)) 天").font(.system(size: 12)).foregroundStyle(ListTheme.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }.padding(24).frame(maxWidth: .infinity).frame(height: 230).background(ListTheme.canvas,in: RoundedRectangle(cornerRadius: 14)).contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityLabel("\(day.name)，\(days == 0 ? "今天" : days > 0 ? "还有" : "已经") \(abs(days)) 天")
            .contextMenu { if showDeleted { Button("恢复") { var value = day; value.deleted = false; store.save(value) } } else { Button("编辑") { existing = day; editor = true }; Button(day.pinned ? "取消置顶" : "置顶") { var value = day; value.pinned.toggle(); store.save(value) }; Button("删除",role: .destructive) { var value = day; value.deleted = true; store.save(value) } } }
    }
}
struct CountdownEditor: View {
    @EnvironmentObject var store: Store; @Environment(\.dismiss) var dismiss
    var existing: Countdown?; @State private var value = Countdown()
    var body: some View { VStack(alignment: .leading,spacing: 20) {
        Text(existing == nil ? "新建倒数纪念日" : "编辑倒数纪念日").font(.title2.bold())
        Form {
            TextField("名称",text: $value.name); TextField("图标",text: $value.emoji)
            Picker("分类",selection: $value.category) { ForEach(["纪念日","倒数日","节日"],id: \.self) { Text(LocalizedStringKey($0)) } }
            DatePicker("日期",selection: Binding(get: { value.preset == "weekend" || value.preset == "springFestival" ? value.occurrence() : value.date },set: { value.date = $0 }),displayedComponents: .date).disabled(value.preset == "weekend" || value.preset == "springFestival")
            if value.preset == "weekend" || value.preset == "springFestival" { Text(value.preset == "weekend" ? "每周六自动更新" : "按农历正月初一自动更新").font(.caption).foregroundStyle(.secondary); Button("改为自定义日期") { value.date = value.occurrence(); value.preset = nil; value.yearly = false } }
            Toggle("每年重复",isOn: $value.yearly).disabled(value.preset == "weekend" || value.preset == "springFestival")
            Picker("提醒",selection: $value.reminderDays) { Text("不提醒").tag(-1); Text("当天").tag(0); Text("提前 1 天").tag(1); Text("提前 3 天").tag(3); Text("提前 7 天").tag(7) }
            if value.reminderDays >= 0 { Picker("提醒时间",selection: $value.reminderHour) { ForEach(0..<24,id: \.self) { Text("\($0):00").tag($0) } } }
            Toggle("在今天显示",isOn: $value.pinned)
        }.disabled(value.deleted)
        HStack { Button("取消") { dismiss() }; Spacer(); Button(value.deleted ? "恢复" : "保存") { value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines); value.deleted = false; if store.save(value) { dismiss() } }.buttonStyle(.borderedProminent).disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }.padding(24).frame(width: 420).onAppear { if let existing { value = existing } } }
}

struct SyncStatusPanel: View {
    @EnvironmentObject var store: Store; @Environment(\.openSettings) private var openSettings
    @AppStorage("cloudEnabled") private var enabled = false
    var body: some View { VStack(alignment: .leading,spacing: 18) {
        Label("同步",systemImage: "arrow.triangle.2.circlepath").font(.system(size: 18,weight: .semibold))
        Label(ZiloLanguage.status(store.syncStatus),systemImage: store.syncStatus.hasPrefix("同步失败") ? "exclamationmark.circle" : "externaldrive.badge.icloud").font(.system(size: 13)).fixedSize(horizontal: false,vertical: true)
        Text(enabled ? "任务、清单、习惯、专注记录、纪念日和附件通过 iCloud 自动同步。" : "当前数据保存在本机，可在设置中启用 iCloud 同步。").font(.system(size: 12)).foregroundStyle(ListTheme.secondary)
        HStack { Button("检查同步") { Task { await store.checkSync() } }.disabled(store.checkingSync); if store.checkingSync { ProgressView().controlSize(.small) }; Spacer(); Button("同步设置") { UserDefaults.standard.set("数据与备份",forKey: "settingsPage"); openSettings() } }
    }.padding(20).frame(width: 300).background(ListTheme.canvas).foregroundStyle(ListTheme.text).tint(ListTheme.accent).themeAppearance() }
}
struct NotificationInbox: View {
    var onOpenTask: (UUID) -> Void = { _ in }
    var onOpenModule: (Module) -> Void = { _ in }
    @EnvironmentObject var store: Store
    @State private var tab = "通知"
    @State private var delivered: [UNNotification] = []
    @State private var authorized = false
    @State private var error = ""
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("notificationReadIDs") private var readRaw = ""
    var readIDs: Set<String> { Set(readRaw.split(separator: "\n").map(String.init)) }
    // A recurring reminder may reuse its request identifier on a later day.
    func key(_ item: UNNotification) -> String { item.request.identifier + "@" + String(item.date.timeIntervalSince1970) }
    var unread: [UNNotification] { delivered.filter { !readIDs.contains(key($0)) } }
    func markRead(_ items: [UNNotification]) {
        let new = items.map(key)
        let prior = readRaw.split(separator: "\n").map(String.init).filter { !new.contains($0) }
        readRaw = (prior + new).suffix(300).joined(separator: "\n")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer()
                HStack(spacing: 2) {
                    ForEach(["通知","活动"],id: \.self) { value in
                        Button { tab = value } label: {
                            Text(LocalizedStringKey(value)).font(.system(size: 13,weight: tab == value ? .semibold : .regular))
                                .foregroundStyle(tab == value ? ListTheme.text : ListTheme.secondary)
                                .frame(width: 54,height: 28)
                                .background(tab == value ? ListTheme.canvas : .clear,in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(3).background(ListTheme.input,in: Capsule()).accessibilityLabel("通知与活动")
                Spacer()
            }.padding(.vertical,16)
            if tab == "通知" && delivered.isEmpty || tab == "活动" && store.activity.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ZStack {
                        Circle().fill(ListTheme.input).frame(width: 106,height: 106)
                        Image(systemName: tab == "通知" ? "megaphone" : "clock.arrow.circlepath")
                            .font(.system(size: 40,weight: .light)).foregroundStyle(ListTheme.secondary)
                    }.padding(.bottom,8)
                    Text(tab == "通知" ? "没有通知" : "没有活动").font(.system(size: 16,weight: .medium))
                    Text(tab == "通知" ? "任务、习惯、专注和纪念日提醒\n会显示在这里" : "任务更新、打卡和同步记录\n会显示在这里")
                        .font(.system(size: 12)).foregroundStyle(ListTheme.secondary).multilineTextAlignment(.center).lineSpacing(4)
                    Spacer(); Spacer().frame(height: 25)
                }.frame(maxWidth: .infinity,maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading,spacing: 0) {
                        if tab == "通知" {
                            ForEach(delivered.sorted { $0.date > $1.date },id: \.request.identifier) { item in
                                Button { open(item) } label: {
                                    HStack(alignment: .top,spacing: 10) {
                                        Circle().fill(readIDs.contains(key(item)) ? .clear : ListTheme.accent).frame(width: 5,height: 5).padding(.top,6)
                                        message(item.request.content.title,item.request.content.body,item.date)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).padding(.vertical,14)
                                Divider().padding(.leading,15)
                            }
                        } else {
                            ForEach(store.activity) { item in
                                HStack(alignment: .top,spacing: 10) {
                                    Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(ListTheme.secondary).padding(.top,2)
                                    message(item.title,item.detail,item.date)
                                }.padding(.vertical,14)
                                Divider().padding(.leading,22)
                            }
                        }
                    }.padding(.horizontal,20)
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).padding(10) }
            if tab == "通知" {
                Divider()
                HStack {
                    if authorized {
                        Label("通知已开启",systemImage: "bell.badge").font(.system(size: 11)).foregroundStyle(ListTheme.secondary)
                    } else {
                        Button("开启系统通知") { Task { do { _ = try await NotificationService.shared.request(); store.reschedule(); await refresh() } catch { self.error = error.localizedDescription } } }
                            .font(.system(size: 12)).buttonStyle(.plain)
                    }
                    Spacer()
                    if !unread.isEmpty { Button("全部已读") { markRead(delivered) }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(ListTheme.accent) }
                }.padding(.horizontal,20).frame(height: 42)
            }
        }.frame(width: 350,height: 470)
            .background(ListTheme.canvas).foregroundStyle(ListTheme.text).tint(ListTheme.accent).themeAppearance()
            .task { await refresh() }.onChange(of: tab) { _,_ in Task { await refresh() } }
            .onChange(of: scenePhase) { _,phase in if phase == .active { Task { await refresh() } } }
    }
    func open(_ item: UNNotification) {
        markRead([item]); let info = item.request.content.userInfo
        if let raw = info["taskID"] as? String, let id = UUID(uuidString: raw) { onOpenTask(id) }
        else if let raw = info["habitID"] as? String, let id = UUID(uuidString: raw) { store.notificationHabit = id; onOpenModule(.habits) }
        else if let raw = info["countdownID"] as? String, let id = UUID(uuidString: raw) { store.notificationCountdown = id; onOpenModule(.countdown) }
        else if info["focus"] as? Bool == true { onOpenModule(.focus) }
    }
    func message(_ title: String,_ detail: String,_ date: Date) -> some View {
        VStack(alignment: .leading,spacing: 7) {
            Text(LocalizedStringKey(title)).font(.system(size: 13,weight: .medium)).lineLimit(2)
            if !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(ListTheme.secondary).lineLimit(3) }
            Text(date,format: .dateTime.month().day().hour().minute()).font(.system(size: 10)).foregroundStyle(ListTheme.secondary)
        }.frame(maxWidth: .infinity,alignment: .leading)
    }
    func refresh() async {
        let center = UNUserNotificationCenter.current()
        delivered = await center.deliveredNotifications()
        let settings = await center.notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
}

struct StatisticsView: View {
    @AppStorage("accent") private var applicationTheme = "blue"
    @EnvironmentObject var store: Store; @State private var days = 30
    var body: some View {
        let _ = applicationTheme
 ScrollView { VStack(alignment: .leading,spacing: 25) { HStack { Text("统计与回顾").font(.largeTitle.bold()); Spacer(); Picker("范围",selection: $days) { Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90) }.frame(width: 120) }
        HStack(spacing: 20) { card("完成任务","\(completed.count)","checkmark.circle",.blue); card("专注分钟","\(Int(records.reduce(0) { $0 + $1.seconds } / 60))","timer",.orange); card("习惯达标","\(habitDays)","leaf",.green) }
        Text("每日完成任务").font(.title2.bold()); Chart { ForEach(0..<days,id: \.self) { i in let d = Calendar.current.date(byAdding: .day,value: i - days + 1,to: Calendar.current.startOfDay(for: Date()))!; BarMark(x: .value("日期",d,unit: .day),y: .value("完成",completed.filter { $0.completedAt.map { Calendar.current.isDate($0,inSameDayAs: d) } == true }.count)).foregroundStyle(.blue) } }.frame(height: 230)
        Text("每日专注时长").font(.title2.bold()); Chart { ForEach(0..<days,id: \.self) { i in let d = Calendar.current.date(byAdding: .day,value: i - days + 1,to: Calendar.current.startOfDay(for: Date()))!; LineMark(x: .value("日期",d,unit: .day),y: .value("分钟",records.filter { Calendar.current.isDate($0.started,inSameDayAs: d) }.reduce(0) { $0 + $1.seconds / 60 })).foregroundStyle(.orange) } }.frame(height: 230)
        Text("清单完成分布").font(.title2.bold()); ForEach(store.lists.filter { !$0.deleted }) { l in HStack { Circle().fill(l.color.listColor).frame(width: 10,height: 10); Text(l.name); Spacer(); Text("\(completed.filter { $0.listID == l.id }.count) 项") } }
    }.padding(30) } }
    var cutoff: Date { Calendar.current.date(byAdding: .day,value: 1 - days,to: Calendar.current.startOfDay(for: Date()))! }
    var completed: [TaskItem] { store.tasks.filter { !$0.deleted && $0.completed && $0.completedAt.map { $0 >= cutoff } == true } }
    var records: [FocusRecord] { store.focus.filter { !$0.deleted && $0.started >= cutoff } }
    var habitDays: Int { store.habits.filter { !$0.deleted }.reduce(0) { count,h in count + h.logs.filter { (Day.date($0.key) ?? .distantPast) >= cutoff && $0.value >= h.goal }.count } }
    func card(_ title: String,_ value: String,_ icon: String,_ color: Color) -> some View { VStack(alignment: .leading,spacing: 12) { Label(LocalizedStringKey(title),systemImage: icon).foregroundStyle(color); Text(value).font(.system(size: 36,weight: .semibold,design: .rounded)) }.padding(24).frame(maxWidth: .infinity,alignment: .leading).background(color.opacity(0.08),in: RoundedRectangle(cornerRadius: 16)) }
}
