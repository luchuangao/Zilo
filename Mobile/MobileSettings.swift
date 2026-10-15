import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

struct MobileSettings: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore; @Environment(\.dismiss) var dismiss
    @AppStorage("accent") private var accent = "blue"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "system"
    @AppStorage("showCountdownsToday") private var showCountdownsToday = true
    @AppStorage("restoreLastWorkspace") private var restoreLastWorkspace = true
    @AppStorage("mobileStartupModule") private var startupModule = "tasks"
    @AppStorage("mobileStartupSmartList") private var startupView = "today"
    @AppStorage("cloudEnabled") private var cloud = true
    @AppStorage("recognizeDates") private var dates = true
    @AppStorage("removeDateText") private var removeDate = true
    @AppStorage("removeTagText") private var removeTag = true
    @State private var importFile = false; @State private var exportURL: URL?; @State private var share = false; @State private var pendingImport: URL?; @State private var confirmImport = false
    var body: some View { Form {
        Section {
            HStack(spacing: 14) { Image("ZiloLogo").resizable().frame(width: 46,height: 46).clipShape(RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading,spacing: 5) { Text("Zilo").font(.headline); Text("让日常更有条理").font(.caption).foregroundStyle(.secondary) } }
        }
        Section("外观") {
            Picker("语言",selection: $interfaceLanguage) { Text("跟随系统语言").tag("system"); Text("中文").tag("zh-Hans"); Text("English").tag("en") }
                .onChange(of: interfaceLanguage) { _,value in ZiloLanguage.select(value) }
            Text("切换语言后，请重新打开 Zilo。").font(.footnote).foregroundStyle(.secondary)
            Picker("界面外观",selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()),count: 6),spacing: 14) {
                ForEach(Array(MobileTheme.colors.enumerated()),id: \.element) { i,color in Button { accent = color } label: {
                    VStack(spacing: 6) { RoundedRectangle(cornerRadius: 10).fill(MobileTheme.color(color)).frame(height: 43).overlay { if accent == color { Image(systemName: "checkmark").foregroundStyle(.white).fontWeight(.semibold) } }; Text(LocalizedStringKey(MobileTheme.names[i])).font(.system(size: 10)).foregroundStyle(.secondary) }
                }.buttonStyle(.plain).accessibilityLabel(MobileTheme.names[i]) }
            }.padding(.vertical,8)
        }
        Section("任务") {
            NavigationLink("功能模块") { MobileModuleSettings() }
            NavigationLink("智能清单") { MobileSmartListSettings() }
            Toggle("在今天显示倒数纪念日",isOn: $showCountdownsToday)
            Toggle("识别日期和时间",isOn: $dates); Toggle("移除任务名中的日期",isOn: $removeDate); Toggle("移除任务名中的标签",isOn: $removeTag)
        }
        Section("启动") {
            Toggle("启动时恢复上次页面",isOn: $restoreLastWorkspace)
            Text("恢复上次打开的模块、清单和任务详情。关闭后使用固定启动页。").font(.footnote).foregroundStyle(.secondary)
            Picker("启动时打开",selection: $startupModule) { Text("任务").tag("tasks"); Text("日历").tag("calendar"); Text("专注").tag("focus"); Text("习惯").tag("habits"); Text("更多").tag("more") }.disabled(restoreLastWorkspace)
            Picker("默认任务视图",selection: $startupView) { ForEach(SmartListOption.primary) { option in Text(LocalizedStringKey(option.title)).tag(option.id) } }.disabled(restoreLastWorkspace)
        }
        Section("同步与通知") {
            Toggle("iCloud 同步",isOn: $cloud)
            Text(ZiloLanguage.status(store.syncStatus)).font(.footnote).foregroundStyle(.secondary)
            Button("检查同步") { Task { await store.sync() } }
            Text("更改同步开关后，请重新打开 Zilo。使用同一个 Apple 账户，可以同步 Mac 与 iPhone 的任务、习惯、专注、纪念日和附件。").font(.footnote).foregroundStyle(.secondary)
            NavigationLink("提醒与通知") { MobileReminderSettings() }
        }
        Section("数据与备份") {
            Button("导出完整备份") { do { exportURL = try store.exportBackup(); share = true } catch { store.error = error.localizedDescription } }
            Button("导入 Zilo 备份") { importFile = true }
            Text("支持 Mac 和 iPhone 的 .ownlist.json 备份。导入会按记录 ID 合并，保留其他已有记录。").font(.footnote).foregroundStyle(.secondary)
        }
        Section("关于") { HStack { Text("版本"); Spacer(); Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "32"))").foregroundStyle(.secondary) }; Text("Zilo iPhone 版 · 原生 SwiftUI\n数据保存在本机和你自己的 iCloud 中。").font(.footnote).foregroundStyle(.secondary) }
    }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .fileImporter(isPresented: $importFile,allowedContentTypes: [.json]) { result in
            switch result { case .success(let url): pendingImport = url; confirmImport = true; case .failure(let error): store.error = error.localizedDescription }
        }.alert("合并备份",isPresented: $confirmImport) { Button("取消",role: .cancel) { pendingImport = nil }; Button("导入") { if let url = pendingImport { do { try store.importBackup(url) } catch { store.error = error.localizedDescription } }; pendingImport = nil } } message: { Text("备份中同一个 ID 的记录会覆盖本机对应记录。其余本机记录会保留。") }
        .sheet(isPresented: $share) { if let exportURL { MobileShare(items: [exportURL]) } }
    }
}
struct MobileShare: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items,applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController,context: Context) { }
}
struct MobileSmartListSettings: View {
    @Environment(\.mobileAccent) private var appAccent
    @AppStorage("smartListVisibility") private var raw = ""
    var body: some View { Form { ForEach([SmartListOption.primary,SmartListOption.organization,SmartListOption.secondary],id: \.first?.id) { group in Section {
        ForEach(group) { option in Picker(selection: Binding(get: { SmartListPreferences(rawValue: raw).visibility(for: option.id) },set: { raw = SmartListPreferences(rawValue: raw).updating(option.id,to: $0) })) { ForEach(SmartListVisibility.allCases,id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) } } label: { Label(LocalizedStringKey(option.title),systemImage: option.icon) } }
    } } }.navigationTitle("智能清单").navigationBarTitleDisplayMode(.inline) }
}
struct MobileReminderSettings: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    @AppStorage("taskNotifications") private var tasks = true
    @AppStorage("habitNotifications") private var habits = true
    @AppStorage("focusNotifications") private var focus = true
    @AppStorage("countdownNotifications") private var countdown = true
    @AppStorage("notificationSound") private var sound = true
    @State private var status = ""
    var body: some View { Form {
        Section { Text(ZiloLanguage.status(status)).foregroundStyle(.secondary); Button("允许系统通知") { Task { do { _ = try await MobileNotifications.shared.request(); refresh(); store.reload() } catch { store.error = error.localizedDescription } } }; Button("打开 iPhone 通知设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } }
        Section { Toggle("任务提醒",isOn: $tasks); Toggle("习惯提醒",isOn: $habits); Toggle("专注结束",isOn: $focus); Toggle("纪念日提醒",isOn: $countdown); Toggle("提示音",isOn: $sound) }
        Section { Text("iOS 最多保留 64 个待发送提醒。Zilo 优先安排最近的提醒，并在打开应用或数据变化时更新。").font(.footnote).foregroundStyle(.secondary) }
    }.navigationTitle("提醒与通知").navigationBarTitleDisplayMode(.inline).onAppear(perform: refresh).onDisappear { store.reload() } }
    func refresh() { Task { let value = await UNUserNotificationCenter.current().notificationSettings(); status = value.authorizationStatus == .authorized ? "系统通知已允许" : "系统通知尚未允许" } }
}
struct MobileNotificationInbox: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    @State private var tab = 0; @State private var notifications: [UNNotification] = []
    @AppStorage("mobileNotificationRead") private var read = ""
    func key(_ item: UNNotification) -> String { item.request.identifier + "@" + String(item.date.timeIntervalSince1970) }
    var body: some View { VStack(spacing: 0) {
        Picker("通知与活动",selection: $tab) { Text("通知").tag(0); Text("活动").tag(1) }.pickerStyle(.segmented).frame(width: 180).padding(16)
        if tab == 0 && notifications.isEmpty || tab == 1 && store.activity.isEmpty {
            MobileEmpty(title: tab == 0 ? "没有通知" : "没有活动",detail: tab == 0 ? "已送达的提醒会显示在这里。" : "任务更新、打卡和同步记录会显示在这里。",icon: tab == 0 ? "megaphone" : "clock.arrow.circlepath")
        } else { List {
            if tab == 0 {
                ForEach(notifications.sorted { $0.date > $1.date },id: \.request.identifier) { item in Button {
                    let ids = read.split(separator: "\n").map(String.init); read = (ids.filter { $0 != key(item) } + [key(item)]).suffix(300).joined(separator: "\n")
                    let info = item.request.content.userInfo; dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MobileNotifications.shared.onOpen?(info) }
                } label: { HStack(alignment: .top,spacing: 10) {
                    Circle().fill(read.split(separator: "\n").contains(Substring(key(item))) ? .clear : appAccent).frame(width: 6,height: 6).padding(.top,6)
                    message(item.request.content.title,item.request.content.body,item.date)
                } }.buttonStyle(.plain) }
            } else { ForEach(store.activity) { item in message(item.title,item.detail,item.date) } }
        }.listStyle(.plain).refreshable { await refresh() } }
    }.navigationTitle("通知与活动").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .topBarTrailing) { if tab == 0 && !notifications.isEmpty { Button("全部已读") { read = notifications.map(key).joined(separator: "\n") } } }
    }.task { await refresh() }
    }
    func message(_ title: String,_ body: String,_ date: Date) -> some View { VStack(alignment: .leading,spacing: 7) { Text(title).font(.subheadline.weight(.medium)); if !body.isEmpty { Text(body).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }; Text(date,format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary) }.padding(.vertical,10) }
    func refresh() async { notifications = await UNUserNotificationCenter.current().deliveredNotifications() }
}
struct MobileFilterEditor: View {
    var existing: SavedFilter?
    @EnvironmentObject var store: MobileStore; @Environment(\.dismiss) var dismiss
    @State private var name = ""; @State private var query = ""; @State private var tag = ""; @State private var priority = -1; @State private var listID: UUID?; @State private var days = -1; @State private var starred = false
    var body: some View { Form {
        Section { TextField("过滤器名称",text: $name); TextField("包含文字",text: $query); TextField("标签",text: $tag) }
        Section {
            Picker("优先级",selection: $priority) { Text("不限").tag(-1); Text("无").tag(0); Text("低").tag(1); Text("中").tag(2); Text("高").tag(3) }
            Picker("清单",selection: $listID) { Text("所有清单").tag(nil as UUID?); ForEach(store.lists.filter { !$0.deleted }) { Text($0.name).tag(Optional($0.id)) } }
            Picker("截止日期",selection: $days) { Text("不限").tag(-1); Text("今天及以前").tag(0); Text("未来 7 天").tag(7); Text("未来 30 天").tag(30) }
            Toggle("仅收藏",isOn: $starred)
        }
    }.navigationTitle(existing == nil ? "新建过滤器" : "编辑过滤器").navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("保存") { var filter = existing ?? SavedFilter(name: name); filter.name = name; filter.text = query; filter.tag = tag; filter.priority = priority; filter.listID = listID; filter.days = days; filter.starredOnly = starred; if store.save(filter) { dismiss() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }.onAppear { if let existing { name = existing.name; query = existing.text; tag = existing.tag; priority = existing.priority; listID = existing.listID; days = existing.days; starred = existing.starredOnly } } }
}
struct MobileModuleSettings: View {
    @AppStorage("moduleVisibility") private var modules = ""
    var body: some View { Form {
        Section { ForEach(Module.allCases.filter { $0 != .tasks && $0 != .stats },id: \.self) { module in Toggle(isOn: Binding(get: { ModulePreferences(rawValue: modules).isVisible(module) },set: { modules = ModulePreferences(rawValue: modules).updating(module,to: $0) })) { Label(LocalizedStringKey(module.rawValue),systemImage: module.icon) } } }
        Section { Text("关闭模块只会隐藏入口，已有数据会保留。").font(.footnote).foregroundStyle(.secondary) }
    }.navigationTitle("功能模块").navigationBarTitleDisplayMode(.inline) }
}
