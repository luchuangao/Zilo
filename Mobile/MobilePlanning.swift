import SwiftUI
import Charts

struct MobileCalendarView: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    @State private var month = Date(); @State private var selected = Date(); @State private var add = false
    @State private var mode = "月"
    @State private var addDate: Date?
    private var calendar: Calendar { CalendarPreferences.calendar(firstWeekday: UserDefaults.standard.integer(forKey: "firstWeekday")) }
    var days: [Date] {
        let start = calendar.dateInterval(of: .month,for: month)!.start; let grid = calendar.dateInterval(of: .weekOfYear,for: start)!.start
        return (0..<42).map { calendar.date(byAdding: .day,value: $0,to: grid)! }
    }
    var tasks: [TaskItem] { store.active.filter { $0.due.map { calendar.isDate($0,inSameDayAs: selected) } == true }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) } }
    var body: some View { NavigationStack { VStack(spacing: 0) {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").padding(10) }.accessibilityLabel("上一月")
            Spacer(); Text(month,format: .dateTime.year().month(.wide)).font(.headline); Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").padding(10) }.accessibilityLabel("下一月")
        }.padding(.horizontal,12)
        Picker("视图",selection: $mode) { Text("月").tag("月"); Text("时间轴").tag("时间轴") }.pickerStyle(.segmented).padding(.horizontal,18).padding(.bottom,12)
        if mode == "月" {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 0),count: 7),spacing: 7) {
            ForEach(0..<7,id: \.self) { i in Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + i) % 7]).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical,5) }
            ForEach(days,id: \.self) { day in
                let same = calendar.isDate(day,inSameDayAs: selected)
                Button { selected = day } label: { VStack(spacing: 4) {
                    Text("\(calendar.component(.day,from: day))").font(.system(size: 15,weight: calendar.isDateInToday(day) ? .semibold : .regular)).foregroundStyle(same ? Color.white : calendar.isDate(day,equalTo: month,toGranularity: .month) ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: 32,height: 32).background(same ? appAccent : .clear,in: Circle())
                    HStack(spacing: 2) { ForEach(Array(store.active.filter { $0.due.map { calendar.isDate($0,inSameDayAs: day) } == true }.prefix(3))) { task in Circle().fill(task.listID.flatMap { id in store.lists.first { $0.id == id } }.map { MobileTheme.color($0.color) } ?? appAccent).frame(width: 4,height: 4) } }.frame(height: 4)
                }.frame(maxWidth: .infinity) }.buttonStyle(.plain).accessibilityLabel(day.formatted(date: .complete,time: .omitted))
            }
        }.padding(.horizontal,14).padding(.bottom,18)
        Divider()
        List {
            Section(selected.formatted(date: .complete,time: .omitted)) {
                if tasks.isEmpty { Text("这一天没有任务").foregroundStyle(.secondary).padding(.vertical,20) }
                ForEach(tasks) { task in MobileTaskRow(task: task) }
            }
        }.listStyle(.plain)
        } else { timeline }
    }.navigationTitle("日历").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItemGroup(placement: .topBarTrailing) { Button("今天") { month = Date(); selected = Date() }; Button { addDate = calendar.startOfDay(for: selected); add = true } label: { Image(systemName: "plus") } } }
    }.sheet(isPresented: $add) { MobileAddTask(defaultDate: addDate ?? calendar.startOfDay(for: selected)) } }
    var timeline: some View {
        VStack(spacing: 0) {
            HStack { Button { selected = calendar.date(byAdding: .day,value: -1,to: selected)!; month = selected } label: { Image(systemName: "chevron.left") }; Spacer(); Text(selected,format: .dateTime.month().day().weekday()).font(.subheadline.weight(.medium)); Spacer(); Button { selected = calendar.date(byAdding: .day,value: 1,to: selected)!; month = selected } label: { Image(systemName: "chevron.right") } }.padding(18)
            ScrollViewReader { reader in ScrollView { LazyVStack(spacing: 0) {
                let allDay = tasks.filter(\.allDay)
                if !allDay.isEmpty { HStack(alignment: .top,spacing: 12) { Text("全天").font(.caption).foregroundStyle(.secondary).frame(width: 44); VStack { ForEach(allDay) { MobileTaskRow(task: $0) } } }.padding(.horizontal,18).padding(.bottom,12) }
                ForEach(0..<24,id: \.self) { hour in
                    HStack(alignment: .top,spacing: 12) {
                        Text(String(format: "%02d:00",hour)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44).padding(.top,10)
                        VStack(alignment: .leading,spacing: 6) {
                            Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5)
                            ForEach(timelineTasks(hour)) { task in
                                VStack(alignment: .leading,spacing: 3) { MobileTaskRow(task: task); if let start = task.start,let end = task.due { Text(start.formatted(date: .omitted,time: .shortened) + " – " + end.formatted(date: .omitted,time: .shortened)).font(.caption).foregroundStyle(.secondary) } }.padding(8).background(appAccent.opacity(0.07),in: RoundedRectangle(cornerRadius: 8))
                            }
                            if timelineTasks(hour).isEmpty { Button { addDate = calendar.date(bySettingHour: hour,minute: 0,second: 0,of: selected); add = true } label: { Color.clear.frame(maxWidth: .infinity,minHeight: 38).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel(ZiloLanguage.format("在 %lld 点添加任务",hour)) }
                        }
                    }.padding(.horizontal,18).frame(minHeight: 54).id(hour)
                }
            } }.onAppear { reader.scrollTo(8,anchor: .top) } }
        }
    }
    func timelineTasks(_ hour: Int) -> [TaskItem] {
        let day = calendar.startOfDay(for: selected), end = calendar.date(byAdding: .day,value: 1,to: day)!
        return store.active.filter { task in
            guard !task.allDay, let due = task.due else { return false }
            let start = task.start ?? due
            guard start < end && due >= day else { return false }
            return calendar.component(.hour,from: max(day,start)) == hour
        }.sorted { ($0.start ?? $0.due ?? .distantFuture) < ($1.start ?? $1.due ?? .distantFuture) }
    }
    func shift(_ offset: Int) { month = calendar.date(byAdding: .month,value: offset,to: month)!; if mode != "月" { selected = month } }
}
struct MobileMatrixView: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    @State private var selected = 3
    let titles = ["重要且紧急","重要不紧急","不重要但紧急","不重要不紧急"]
    let colors: [Color] = [.red,.orange,.blue,.green]
    func quadrant(_ item: TaskItem) -> Int { let important = item.priority >= 2; let urgent = item.due.map { $0 < Calendar.current.date(byAdding: .day,value: 1,to: Calendar.current.startOfDay(for: Date()))! } ?? false; return important ? (urgent ? 0 : 1) : (urgent ? 2 : 3) }
    var body: some View { ScrollView { VStack(spacing: 18) {
        LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible())],spacing: 12) {
            ForEach(0..<4,id: \.self) { i in Button { selected = i } label: {
                VStack(alignment: .leading,spacing: 14) { Text(["Ⅰ","Ⅱ","Ⅲ","Ⅳ"][i] + " " + ZiloLanguage.text(titles[i])).font(.system(size: 13,weight: .semibold)); Text("\(store.active.filter { quadrant($0) == i }.count)").font(.system(size: 30,weight: .light)) }.foregroundStyle(colors[i]).frame(maxWidth: .infinity,alignment: .leading).padding(16).background(colors[i].opacity(selected == i ? 0.12 : 0.05),in: RoundedRectangle(cornerRadius: 14)).overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(selected == i ? colors[i].opacity(0.35) : .clear) }
            }.buttonStyle(.plain) }
        }
        HStack { Text(LocalizedStringKey(titles[selected])).font(.headline).foregroundStyle(colors[selected]); Spacer() }.padding(.top,8)
        if store.active.filter({ quadrant($0) == selected }).isEmpty { MobileEmpty(title: "没有任务",detail: "调整任务优先级与日期，即可安排到对应象限。",icon: "square.grid.2x2") }
        ForEach(store.active.filter { quadrant($0) == selected }) { task in
            MobileTaskRow(task: task,quadrantActions: true).padding(.vertical,8)
            Divider()
        }
    }.padding(18) }.navigationTitle("四象限").navigationBarTitleDisplayMode(.inline) }
}
struct MobileFocusView: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore; @EnvironmentObject var timer: MobileFocusTimer
    @State private var settings = false; @State private var records = false
    var today: [FocusRecord] { store.focus.filter { !$0.deleted && Calendar.current.isDateInToday($0.started) } }
    var body: some View { NavigationStack { ScrollView { VStack(spacing: 26) {
        Picker("计时方式",selection: Binding(get: { timer.mode },set: { timer.selectMode($0) })) { Text("番茄计时").tag("番茄"); Text("正计时").tag("正计时") }.pickerStyle(.segmented).frame(maxWidth: 240).disabled(timer.running || timer.elapsed > 0)
        Picker("关联任务",selection: $timer.taskID) { Text("自由专注").tag(nil as UUID?); ForEach(store.active) { Text($0.title).tag(Optional($0.id)) } }.disabled(timer.running || timer.elapsed > 0).padding(.top,15)
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.1),lineWidth: 4)
            Circle().trim(from: 0,to: timer.mode == "番茄" ? min(1,timer.elapsed / timer.length) : timer.running ? 1 : 0).stroke(appAccent,style: StrokeStyle(lineWidth: 4,lineCap: .round)).rotationEffect(.degrees(-90))
            VStack(spacing: 10) { Text(timer.display).font(.system(size: 52,weight: .light)).monospacedDigit(); Text(!timer.running && timer.elapsed > 0 ? "已暂停" : timer.phase == "休息" ? "休息 · 第 \(timer.rounds) 轮" : timer.running ? "保持专注" : "准备开始").font(.subheadline).foregroundStyle(.secondary) }
        }.frame(width: 260,height: 260).padding(.vertical,16)
        HStack(spacing: 16) {
            Button(timer.running ? "暂停" : timer.elapsed > 0 ? "继续" : timer.phase == "休息" ? "开始休息" : "开始") { timer.running ? timer.pause() : timer.start() }.font(.headline).frame(width: 120,height: 48).background(appAccent,in: Capsule()).foregroundStyle(.white)
            if timer.elapsed > 0 { Button("结束") { timer.pause(); timer.finish() }.font(.subheadline).padding(12) }
        }
        HStack(spacing: 14) {
            metric("今日番茄","\(today.filter(\.isPomodoro).count)")
            metric("今日专注",ZiloLanguage.format("%lld 分钟",Int(today.reduce(0) { $0 + $1.seconds } / 60)))
        }.padding(.top,20)
        Button("查看专注记录") { records = true }.font(.subheadline)
    }.padding(24) }.navigationTitle("番茄专注").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "ellipsis") }.accessibilityLabel("专注设置") } }
    }.sheet(isPresented: $settings) { NavigationStack { Form { Stepper("专注 \(timer.minutes) 分钟",value: $timer.minutes,in: 1...180).disabled(timer.running || timer.elapsed > 0); Stepper("短休息 \(timer.shortBreak) 分钟",value: $timer.shortBreak,in: 1...60); Stepper("长休息 \(timer.longBreak) 分钟",value: $timer.longBreak,in: 1...90); Text("每完成 4 个番茄，进入长休息。计时结束后手动开始下一阶段。切到后台或锁屏后，计时仍会继续。").font(.footnote).foregroundStyle(.secondary) }.disabled(timer.running || timer.elapsed > 0).navigationTitle("专注设置").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { timer.persist(); settings = false } } } }.presentationDetents([.medium]) }
        .sheet(isPresented: $records) { NavigationStack { List {
            ForEach(store.focus.filter { !$0.deleted }.sorted { $0.started > $1.started }) { record in VStack(alignment: .leading,spacing: 7) { Text(store.tasks.first { $0.id == record.taskID }?.title ?? ZiloLanguage.text("自由专注")); HStack { Text(record.started,format: .dateTime.month().day().hour().minute()); Spacer(); Text(record.seconds >= 60 ? "\(Int(record.seconds / 60)) 分钟" : "\(Int(record.seconds)) 秒") }.font(.caption).foregroundStyle(.secondary) }.padding(.vertical,6) }
        }.navigationTitle("专注记录").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { records = false } } } } }
    }
    func metric(_ title: String,_ value: String) -> some View { VStack(alignment: .leading,spacing: 10) { Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.weight(.medium)) }.padding(16).frame(maxWidth: .infinity,alignment: .leading).background(Color(uiColor: .secondarySystemGroupedBackground),in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.1)) } }
}
struct MobileHabitsView: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    @State private var editor = false; @State private var existing: Habit?; @State private var selected = Date()
    var week: [Date] { let cal = CalendarPreferences.calendar(firstWeekday: 2); let start = cal.dateInterval(of: .weekOfYear,for: selected)!.start; return (0..<7).map { cal.date(byAdding: .day,value: $0,to: start)! } }
    var body: some View { NavigationStack { VStack(spacing: 0) {
        HStack(spacing: 0) { ForEach(week,id: \.self) { date in Button { selected = date } label: { VStack(spacing: 7) {
            Text(date,format: .dateTime.weekday(.narrow)).font(.caption).foregroundStyle(.secondary)
            Text(date,format: .dateTime.day()).font(.subheadline.weight(.medium)).frame(width: 32,height: 32).background(Calendar.current.isDate(date,inSameDayAs: selected) ? appAccent : .clear,in: Circle()).foregroundStyle(Calendar.current.isDate(date,inSameDayAs: selected) ? Color.white : Color.primary)
        }.frame(maxWidth: .infinity) }.buttonStyle(.plain) } }.padding(.horizontal,14).padding(.vertical,16)
        List {
            if store.habits.filter({ !$0.deleted }).isEmpty { MobileEmpty(title: "来一起养成习惯吧",detail: "每天一点点，坚持让我们闪闪发光。",icon: "leaf").listRowSeparator(.hidden) }
            ForEach(store.habits.filter { !$0.deleted }) { habit in
                HStack(spacing: 14) {
                    Text(habit.emoji).font(.title).frame(width: 46,height: 46).background(appAccent.opacity(0.08),in: RoundedRectangle(cornerRadius: 12))
                    Button { existing = habit; editor = true } label: { VStack(alignment: .leading,spacing: 6) {
                        Text(habit.name).font(.system(size: 16,weight: .medium)).foregroundStyle(.primary)
                        Text("连续 \(habit.streak()) 天 · \(habit.count(on: selected))/\(habit.goal)").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity,alignment: .leading) }.buttonStyle(.borderless)
                    Button { var value = habit; let day = Day.key(selected); value.logs[day] = min(value.goal,value.count(on: selected) + 1); if store.save(value) { store.log("习惯打卡",habit.name,owner: habit.id) } } label: { Image(systemName: habit.count(on: selected) >= habit.goal ? "checkmark.circle.fill" : "plus.circle").font(.system(size: 28)).foregroundStyle(.tint) }
                        .buttonStyle(.borderless).disabled(selected > Date() || !habit.weekdays.contains(Calendar.current.component(.weekday,from: selected)) || habit.count(on: selected) >= habit.goal).accessibilityLabel("打卡 \(habit.name)")
                }.padding(.vertical,10).contextMenu {
                    Button("撤销这一天的打卡") { var value = habit; value.logs[Day.key(selected)] = max(0,value.count(on: selected) - 1); store.save(value) }
                    Button("删除习惯",role: .destructive) { var value = habit; value.deleted = true; store.save(value) }
                }
            }
        }.listStyle(.plain)
    }.navigationTitle("习惯").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { Button { existing = nil; editor = true } label: { Image(systemName: "plus") }.accessibilityLabel("新建习惯") } }
    }.sheet(isPresented: $editor) { NavigationStack { MobileHabitEditor(existing: existing) } } }
}
struct MobileHabitEditor: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore; @Environment(\.dismiss) var dismiss
    var existing: Habit?
    @State private var name = ""; @State private var emoji = "🌱"; @State private var goal = 1; @State private var weekdays = [1,2,3,4,5,6,7]; @State private var hour = -1
    var body: some View { Form {
        Section { TextField("习惯名称",text: $name); TextField("图标",text: $emoji); Stepper("每日目标 \(goal) 次",value: $goal,in: 1...100) }
        Section("重复日") { ForEach(1...7,id: \.self) { day in Toggle(Calendar.current.weekdaySymbols[day - 1],isOn: Binding(get: { weekdays.contains(day) },set: { value in if value { weekdays.append(day) } else { weekdays.removeAll { $0 == day } } })) } }
        Section { Picker("提醒",selection: $hour) { Text("不提醒").tag(-1); ForEach(0..<24,id: \.self) { hour in Text(String(format: "%02d:00",hour)).tag(hour) } } }
    }.navigationTitle(existing == nil ? "新建习惯" : "编辑习惯").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("保存") { var item = existing ?? Habit(name: name); item.name = name; item.emoji = emoji; item.goal = goal; item.weekdays = Array(Set(weekdays)).sorted(); item.reminderHour = hour; if store.save(item) { dismiss() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || weekdays.isEmpty) }
    }.onAppear { if let existing { name = existing.name; emoji = existing.emoji; goal = existing.goal; weekdays = existing.weekdays; hour = existing.reminderHour } } }
}
struct MobileCountdownView: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    @State private var category = "所有"; @State private var editor = false; @State private var existing: Countdown?
    var items: [Countdown] { store.countdowns.filter { !$0.deleted && (category == "所有" || $0.category == category) }.sorted { $0.pinned == $1.pinned ? abs($0.days()) < abs($1.days()) : $0.pinned } }
    var body: some View { ScrollView { VStack(spacing: 18) {
        Picker("类别",selection: $category) { ForEach(["所有","纪念日","倒数日","节日"],id: \.self) { Text(LocalizedStringKey($0)).tag($0) } }.pickerStyle(.segmented)
        if items.isEmpty { MobileEmpty(title: "留住重要的日子",detail: "添加生日、纪念日，或下一次期待。",icon: "calendar.badge.clock").padding(.top,40) }
        ForEach(items) { day in Button { existing = day; editor = true } label: {
            VStack(spacing: 18) {
                HStack { Text(day.emoji); Text(day.displayName).font(.headline); if day.pinned { Image(systemName: "pin.fill").font(.caption) } }.foregroundStyle(.primary)
                Text("\(abs(day.days()))").font(.system(size: 58,weight: .light,design: .rounded)).foregroundStyle(appAccent)
                Text(day.days() == 0 ? ZiloLanguage.text("就是今天") : ZiloLanguage.format(day.days() > 0 ? "还有 %lld 天" : "已经 %lld 天",abs(day.days()))).font(.subheadline).foregroundStyle(.secondary)
                Text(day.occurrence(),format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(26).background(Color(uiColor: .secondarySystemGroupedBackground),in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).contextMenu { Button("删除",role: .destructive) { var value = day; value.deleted = true; store.save(value) } } }
    }.padding(18) }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("倒数纪念日").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { existing = nil; editor = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加纪念日") } }
        .sheet(isPresented: $editor) { NavigationStack { MobileCountdownEditor(existing: existing) } }
    }
}
struct MobileCountdownEditor: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore; @Environment(\.dismiss) var dismiss
    var existing: Countdown?
    @State private var preset: String?
    @State private var name = ""; @State private var emoji = "🎉"; @State private var category = "倒数日"; @State private var date = Date(); @State private var yearly = false; @State private var pinned = false; @State private var reminder = -1; @State private var hour = 9
    var body: some View { Form {
        Section { TextField("名称",text: $name); TextField("图标",text: $emoji); Picker("类型",selection: $category) { ForEach(["纪念日","倒数日","节日"],id: \.self) { Text(LocalizedStringKey($0)).tag($0) } }; DatePicker("日期",selection: $date,displayedComponents: .date).disabled(preset == "weekend" || preset == "springFestival"); if preset == "weekend" || preset == "springFestival" { Text(preset == "weekend" ? "每周六自动更新" : "按农历正月初一自动更新").font(.footnote).foregroundStyle(.secondary); Button("改为自定义日期") { preset = nil; yearly = false } }; Toggle("每年重复",isOn: $yearly).disabled(preset == "weekend" || preset == "springFestival"); Toggle("在今天显示",isOn: $pinned) }
        Section("提醒") { Picker("提前提醒",selection: $reminder) { Text("无").tag(-1); Text("当天").tag(0); Text("提前 1 天").tag(1); Text("提前 3 天").tag(3); Text("提前 7 天").tag(7) }; if reminder >= 0 { Picker("时间",selection: $hour) { ForEach(0..<24,id: \.self) { Text(String(format: "%02d:00",$0)).tag($0) } } } }
    }.navigationTitle(existing == nil ? "添加纪念日" : "编辑纪念日").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("保存") { var item = existing ?? Countdown(); item.name = name; item.emoji = emoji; item.category = category; item.date = date; item.yearly = yearly; item.pinned = pinned; item.reminderDays = reminder; item.reminderHour = hour; item.preset = preset; if store.save(item) { dismiss() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }.onAppear { if let existing { name = existing.name; emoji = existing.emoji; category = existing.category; date = existing.occurrence(); preset = existing.preset; yearly = existing.yearly; pinned = existing.pinned; reminder = existing.reminderDays; hour = existing.reminderHour } } }
}
struct MobileStatisticsView: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    @State private var days = 7
    var completed: [TaskItem] { store.tasks.filter { !$0.deleted && $0.completed && $0.completedAt.map { $0 >= Date().addingTimeInterval(Double(-days) * 86400) } == true } }
    var body: some View { ScrollView { VStack(alignment: .leading,spacing: 22) {
        Picker("范围",selection: $days) { Text("7 天").tag(7); Text("30 天").tag(30); Text("90 天").tag(90) }.pickerStyle(.segmented)
        HStack { stat("完成任务","\(completed.count)"); stat("专注分钟","\(Int(store.focus.filter { !$0.deleted && $0.started >= Date().addingTimeInterval(Double(-days) * 86400) }.reduce(0) { $0 + $1.seconds } / 60))") }
        Text("每天完成任务").font(.headline)
        Chart { ForEach(0..<days,id: \.self) { i in let date = Calendar.current.date(byAdding: .day,value: i - days + 1,to: Calendar.current.startOfDay(for: Date()))!; BarMark(x: .value("日期",date,unit: .day),y: .value("完成",completed.filter { $0.completedAt.map { Calendar.current.isDate($0,inSameDayAs: date) } == true }.count)).foregroundStyle(appAccent) } }.frame(height: 210)
        Text("清单完成情况").font(.headline)
        ForEach(store.lists.filter { !$0.deleted }) { list in HStack { Circle().fill(MobileTheme.color(list.color)).frame(width: 9,height: 9); Text(list.name); Spacer(); Text("\(completed.filter { $0.listID == list.id }.count) 项").foregroundStyle(.secondary) } }
    }.padding(22) }.navigationTitle("统计与回顾").navigationBarTitleDisplayMode(.inline) }
    func stat(_ title: String,_ value: String) -> some View { VStack(alignment: .leading,spacing: 12) { Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary); Text(value).font(.largeTitle) }.padding(18).frame(maxWidth: .infinity,alignment: .leading).background(appAccent.opacity(0.06),in: RoundedRectangle(cornerRadius: 14)) }
}
struct MobileMoreView: View {
    @AppStorage("moduleVisibility") private var modules = ""
    @EnvironmentObject private var store: MobileStore
    var body: some View {
        NavigationStack(path: $store.morePath) {
            List {
                Section {
                    if ModulePreferences(rawValue: modules).isVisible(.matrix) { NavigationLink(value: "matrix") { Label("四象限",systemImage: "square.grid.2x2") } }
                    if ModulePreferences(rawValue: modules).isVisible(.countdown) { NavigationLink(value: "countdown") { Label("倒数纪念日",systemImage: "calendar.badge.clock") } }
                    NavigationLink(value: "statistics") { Label("统计与回顾",systemImage: "chart.bar") }
                }
                Section {
                    NavigationLink(value: "notifications") { Label("通知与活动",systemImage: "bell") }
                    NavigationLink(value: "settings") { Label("设置",systemImage: "gearshape") }
                }
            }.navigationTitle("更多")
                .navigationDestination(for: String.self) { page in
                    switch page {
                    case "matrix": MobileMatrixView()
                    case "countdown": MobileCountdownView()
                    case "statistics": MobileStatisticsView()
                    case "notifications": MobileNotificationInbox()
                    case "settings": MobileSettings()
                    default: EmptyView()
                    }
                }
        }
    }
}
