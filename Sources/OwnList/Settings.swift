import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var focus: FocusTimer
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "system"
    @AppStorage("accent") private var accent = "blue"
    @AppStorage("fontScale") private var fontScale = 14.0
    @AppStorage("cloudEnabled") private var cloudEnabled = false
    @AppStorage("defaultDocumentMode") private var defaultDocumentMode = DocumentEditingMode.richText.rawValue
    @AppStorage("moduleVisibility") private var moduleVisibility = ""
    @AppStorage("startupModule") private var startupModule = Module.tasks.rawValue
    @AppStorage("startupSmartList") private var startupSmartList = "today"
    @AppStorage("showCountdownsToday") private var showCountdownsToday = true
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("completionSound") private var completionSound = false
    @AppStorage("focusSound") private var focusSound = true
    @AppStorage("taskNotifications") private var taskNotifications = true
    @AppStorage("habitNotifications") private var habitNotifications = true
    @AppStorage("countdownNotifications") private var countdownNotifications = true
    @AppStorage("focusNotifications") private var focusNotifications = true
    @AppStorage("notificationSound") private var notificationSound = true
    @AppStorage("firstWeekday") private var firstWeekday = Calendar.current.firstWeekday
    @AppStorage("showLunar") private var showLunar = false
    @AppStorage("showWeekNumbers") private var showWeekNumbers = false
    @AppStorage("recognizeDates") private var recognizeDates = true
    @AppStorage("removeDateText") private var removeDateText = true
    @AppStorage("removeTagText") private var removeTagText = true
    @AppStorage("defaultTaskDate") private var defaultTaskDate = "none"
    @AppStorage("defaultPriority") private var defaultPriority = 0
    @AppStorage("defaultTimedReminder") private var defaultTimedReminder = 0.0
    @AppStorage("defaultAllDayReminder") private var defaultAllDayReminder = 0.0
    @AppStorage("quickEnabled") private var quickEnabled = true
    @AppStorage("settingsPage") private var page = "通用"
    @State private var status = ""
    @State private var login = false
    @State private var notificationStatus = "正在检查…"
    @State private var subscriptionName = ""
    @State private var subscriptionURL = ""
    @State private var importPreview: ImportPreview?
    @State private var showImport = false
    private let pages = [("通用","gearshape"),("功能模块","square.grid.2x2"),("智能清单","line.3.horizontal.decrease.circle"),("提醒与通知","bell"),("日期与时间","clock"),("外观","paintbrush"),("数据与备份","externaldrive"),("关联与导入","puzzlepiece.extension"),("快捷键","keyboard"),("关于","info.circle")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading,spacing: 4) {
                Text("设置").font(.system(size: 19,weight: .bold)).padding(.horizontal,14).padding(.top,20).padding(.bottom,14)
                ForEach(pages,id: \.0) { item in
                    Button { page = item.0; status = "" } label: {
                        Label(LocalizedStringKey(item.0),systemImage: item.1).font(.system(size: 13)).frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,14).frame(height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain).quietHover(selected: page == item.0).accessibilityAddTraits(page == item.0 ? .isSelected : [])
                }
                Spacer()
            }.padding(.horizontal,8).frame(width: 174).background(ListTheme.sidebar)
            Divider().overlay(ListTheme.separator)
            VStack(alignment: .leading,spacing: 16) {
                Text(LocalizedStringKey(page)).font(.system(size: 19,weight: .semibold)).padding(.top,22)
                Group {
                    switch page {
                    case "功能模块": moduleSettings
                    case "智能清单": SmartListSettings()
                    case "提醒与通知": notificationSettings
                    case "日期与时间": dateSettings
                    case "外观": appearanceSettings
                    case "数据与备份": dataSettings
                    case "关联与导入": integrationSettings
                    case "快捷键": shortcutSettings
                    case "关于": aboutSettings
                    default: generalSettings
                    }
                }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
            }.padding(.horizontal,16).padding(.bottom,18).frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading).background(ListTheme.canvas)
        }.frame(width: 780,height: 600).foregroundStyle(ListTheme.text).themeAppearance()

            .onAppear { login = SMAppService.mainApp.status == .enabled }
            .task { await refreshNotificationStatus() }
            .onChange(of: taskNotifications) { _,_ in store.reschedule() }
            .onChange(of: countdownNotifications) { _,_ in store.reschedule() }
            .onChange(of: habitNotifications) { _,_ in store.reschedule() }
            .onChange(of: notificationSound) { _,_ in store.reschedule(); focus.rescheduleNotification() }
            .onChange(of: focusNotifications) { _,_ in focus.rescheduleNotification() }
            .onChange(of: moduleVisibility) { _,_ in if let module = Module(rawValue: startupModule),!ModulePreferences(rawValue: moduleVisibility).isVisible(module) { startupModule = Module.tasks.rawValue } }
            .sheet(isPresented: $showImport) { if let preview = importPreview { ImportView(preview: preview).environmentObject(store) } }
    }
    var generalSettings: some View {
        SettingsScroll {
            SettingsCard {
                SettingsRow("语言") {
                    SettingsValuePicker("语言",selection: $interfaceLanguage,choices: [("跟随系统语言","system"),("中文","zh-Hans"),("English","en")])
                        .onChange(of: interfaceLanguage) { _,value in ZiloLanguage.select(value) }
                }
                note("切换语言后，请重新打开 Zilo。")
                SettingsRow("启动时打开") {
                    SettingsValuePicker("启动时打开",selection: $startupModule,choices: Module.allCases.filter { ModulePreferences(rawValue: moduleVisibility).isVisible($0) }.map { ($0.rawValue,$0.rawValue) })
                }
                SettingsRow("默认任务视图") { SettingsValuePicker("默认任务视图",selection: $startupSmartList,choices: SmartListOption.primary.map { ($0.title,$0.id) }) }
                settingToggle("登录时启动",$login).onChange(of: login) { _,value in do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { login = SMAppService.mainApp.status == .enabled; status = error.localizedDescription } }
                settingToggle("在菜单栏显示 Zilo",$showMenuBar)
                settingToggle("在今天显示倒数纪念日",$showCountdownsToday)
            }
            sectionTitle("智能识别")
            SettingsCard {
                settingToggle("识别日期和时间",$recognizeDates)
                settingToggle("移除任务名中的日期",$removeDateText).disabled(!recognizeDates)
                settingToggle("移除任务名中的标签",$removeTagText)
                note("添加任务时识别“明天下午 3 点”和 #标签；保留文本时仍会设置对应日期或标签。")
            }
            sectionTitle("新任务默认值")
            SettingsCard {
                SettingsRow("正文编辑方式") { SettingsValuePicker("正文编辑方式",selection: $defaultDocumentMode,choices: DocumentEditingMode.allCases.map { ($0.title,$0.rawValue) }) }
                SettingsRow("默认日期") { SettingsValuePicker("默认日期",selection: $defaultTaskDate,choices: [("无","none"),("今天","today"),("明天","tomorrow")]) }
                SettingsRow("默认优先级") { SettingsValuePicker("默认优先级",selection: $defaultPriority,choices: [("无",0),("低",1),("中",2),("高",3)]) }
                reminderPicker("有时间的任务",$defaultTimedReminder)
                reminderPicker("全天任务",$defaultAllDayReminder)
                note("仅用于新建任务；输入的日期、优先级或当前清单的日期会优先采用。已有任务不受影响。")
            }
            feedback
        }
    }
    var moduleSettings: some View {
        SettingsScroll {
            SettingsCard {
                ForEach([Module.calendar,.matrix,.focus,.habits,.countdown],id: \.self) { item in
                    HStack(spacing: 16) {
                        Image(systemName: item.icon).font(.system(size: 23)).foregroundStyle(ListTheme.accent).frame(width: 42,height: 42).background(ListTheme.accent.opacity(0.09),in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading,spacing: 5) { Text(LocalizedStringKey(item.rawValue)).font(.system(size: 15,weight: .medium)); Text(LocalizedStringKey(moduleDescription(item))).font(.system(size: 12)).foregroundStyle(ListTheme.secondary) }
                        Spacer()
                        Toggle(LocalizedStringKey(item.rawValue),isOn: Binding(get: { ModulePreferences(rawValue: moduleVisibility).isVisible(item) },set: { moduleVisibility = ModulePreferences(rawValue: moduleVisibility).updating(item,to: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("显示" + item.rawValue + "模块")
                    }.padding(.horizontal,16).padding(.vertical,12)
                }
            }
            note("关闭后隐藏左侧入口，已有任务、习惯和专注记录继续保留。统计可以从左上角 Zilo 菜单打开。")
        }
    }
    var notificationSettings: some View {
        SettingsScroll {
            SettingsCard {
                SettingsRow("系统通知权限") { Text(ZiloLanguage.status(notificationStatus)).foregroundStyle(ListTheme.secondary); Button("检查") { Task { await refreshNotificationStatus() } } }
                HStack { Button("开启系统通知") { Task { do { let enabled = try await NotificationService.shared.request(); status = enabled ? "通知已开启" : "请在系统设置中允许 Zilo 通知"; store.reschedule(); await refreshNotificationStatus() } catch { status = error.localizedDescription } } }; Spacer(); Button("系统通知设置") { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } } }.padding(.horizontal,16).padding(.bottom,16)
            }
            SettingsCard { HStack { Button("发送测试通知") { Task { do { if try await NotificationService.shared.request() { NotificationService.shared.notify("Zilo 测试通知"); status = "测试通知已发送" } else { status = "请在系统设置中允许 Zilo 通知" }; await refreshNotificationStatus() } catch { status = error.localizedDescription } } }; Spacer() }.padding(16) }
            SettingsCard { settingToggle("任务提醒",$taskNotifications); settingToggle("习惯提醒",$habitNotifications); settingToggle("纪念日提醒",$countdownNotifications); settingToggle("专注结束通知",$focusNotifications); settingToggle("通知声音",$notificationSound) }
            SettingsCard { settingToggle("完成任务提示音",$completionSound); settingToggle("专注结束提示音",$focusSound) }
            note("关闭任务或习惯提醒会取消对应的待发送通知；任务里的提醒时间会保留。")
            feedback
        }
    }
    var dateSettings: some View {
        SettingsScroll {
            SettingsCard {
                SettingsRow("每周开始于") { SettingsValuePicker("每周开始于",selection: $firstWeekday,choices: ["周日","周一","周二","周三","周四","周五","周六"].enumerated().map { ($0.element,$0.offset + 1) }) }
            }
            SettingsCard { settingToggle("显示农历",$showLunar); settingToggle("显示周数",$showWeekNumbers) }
            SettingsCard { SettingsRow("本地时区") { Text(TimeZone.current.identifier).foregroundStyle(ListTheme.secondary) }; note("任务日期使用 Mac 的本地时区。日历时间轴可在显示选项中选择辅助时区。") }
            note("每周起始日同时应用到月视图与周视图；农历和周数会显示在日历日期中。")
        }
    }
    var appearanceSettings: some View {
        SettingsScroll {
            SettingsCard {
                SettingsRow("界面外观") { SettingsValuePicker("界面外观",selection: $appearance,choices: [("跟随系统","system"),("浅色","light"),("深色","dark")]) }
                SettingsRow("任务字号") { Text("\(Int(fontScale))").monospacedDigit().foregroundStyle(ListTheme.secondary); Slider(value: $fontScale,in: 12...20,step: 1).frame(width: 180).accessibilityLabel("任务字号") }
            }
            sectionTitle("颜色主题")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 14),count: 7),spacing: 16) {
                ForEach(AppTheme.all) { theme in
                    Button { accent = theme.id } label: {
                        VStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(colors: [AppTheme.color(theme.top),AppTheme.color(theme.bottom)],startPoint: .top,endPoint: .bottom))
                                .frame(height: 58)
                                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ListTheme.separator,lineWidth: theme.id == "default" ? 1 : 0) }
                                .overlay(alignment: .bottomTrailing) {
                                    if accent == theme.id { Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).symbolRenderingMode(.palette).foregroundStyle(.white,AppTheme.color(theme.accent)).background(.white,in: Circle()).offset(x: 3,y: 3) }
                                }
                            Text(LocalizedStringKey(theme.name)).font(.system(size: 11)).foregroundStyle(accent == theme.id ? ListTheme.accent : ListTheme.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(theme.name + "主题").accessibilityAddTraits(accent == theme.id ? .isSelected : [])
                }
            }.padding(.vertical,4)
            note("主题立即应用到导航栏、侧栏、选中背景及控件。清单保留各自的颜色。")
            SettingsCard {
                HStack(spacing: 0) {
                    VStack(spacing: 9) { Image(systemName: "checkmark.square.fill"); Image(systemName: "calendar"); Image(systemName: "square.grid.2x2") }.font(.system(size: 15)).foregroundStyle(ListTheme.railForeground).frame(width: 42).frame(maxHeight: .infinity).background(ListTheme.rail)
                    VStack(alignment: .leading,spacing: 9) { Label("今天",systemImage: "calendar").padding(6).frame(maxWidth: .infinity,alignment: .leading).background(ListTheme.selection,in: RoundedRectangle(cornerRadius: 5)); Text("清单").font(.caption).foregroundStyle(ListTheme.secondary); HStack { Text("工作"); Spacer(); Circle().fill("green".listColor).frame(width: 6,height: 6) } }.padding(10).frame(width: 110).frame(maxHeight: .infinity).background(ListTheme.sidebar)
                    VStack(alignment: .leading,spacing: 12) { Text("今天的任务").font(.headline); HStack { Image(systemName: "checkmark.square.fill").foregroundStyle(ListTheme.accent); Text("完成今日计划"); Spacer() }.padding(8).background(ListTheme.selection,in: RoundedRectangle(cornerRadius: 5)) }.padding(12).frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading).background(ListTheme.canvas)
                }.frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 10))
            }

        }
    }
    var dataSettings: some View {
        SettingsScroll {
            SettingsCard {
                settingToggle("启用 iCloud 同步",$cloudEnabled).disabled(!Capability.cloudAvailable)
                if !Capability.cloudAvailable { note("当前构建暂不支持 iCloud 同步；数据已保存在本机。") }
                SettingsRow("同步状态") { Text(ZiloLanguage.status(store.syncStatus)).foregroundStyle(ListTheme.secondary).font(.system(size: 12)) }
                HStack { Button("检查同步") { Task { await store.checkSync() } }.disabled(store.checkingSync); Spacer() }.padding(.horizontal,16).padding(.bottom,16)
                note("更改同步开关后重启应用生效。")
            }
            SettingsCard {
                HStack(spacing: 16) { Button("导出备份",action: export); Button("导入 / 恢复",action: importFile); Spacer() }.padding(16)
                HStack { Button("立即备份") { do { try store.manualBackup(); status = "已保存长期备份" } catch { status = error.localizedDescription } }; Spacer(); Button("打开备份文件夹") { NSWorkspace.shared.open(store.persistence.root) } }.padding(.horizontal,16).padding(.bottom,16)
                note("自动备份保留最近 30 天；手动备份长期保留。恢复前会显示导入内容。")
            }
            feedback
        }
    }
    var integrationSettings: some View {
        SettingsScroll {
            SettingsCard {
                HStack(spacing: 16) { Button("连接系统日历") { Task { await calendar.authorize() } }; Button("导入 Apple 提醒事项") { Task { await calendar.importReminders(into: store) } }; Spacer() }.padding(16)
                if !calendar.message.isEmpty { note(calendar.message) }
            }
            sectionTitle("ICS 日历订阅")
            SettingsCard {
                VStack(alignment: .leading,spacing: 12) {
                    TextField("订阅名称",text: $subscriptionName).textFieldStyle(.roundedBorder)
                    TextField("https://…/calendar.ics",text: $subscriptionURL).textFieldStyle(.roundedBorder)
                    Button("添加订阅") { Task { do { try await calendar.subscribe(subscriptionURL,name: subscriptionName); store.save(CalendarSubscription(name: subscriptionName,url: subscriptionURL)); subscriptionName = ""; subscriptionURL = "" } catch { calendar.message = error.localizedDescription } } }.disabled(subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(16)
                ForEach(store.subscriptions.filter { !$0.deleted }) { sub in
                    HStack { Text(sub.name); Spacer(); Button("刷新") { Task { do { try await calendar.subscribe(sub.url,name: sub.name) } catch { calendar.message = error.localizedDescription } } }; Button("移除") { var s = sub; s.deleted = true; store.save(s); calendar.events.removeAll { $0.source == sub.name } } }.padding(.horizontal,16).padding(.bottom,16)
                }
                note("支持日期、时区及常用重复规则。")
            }
        }
    }
    var shortcutSettings: some View {
        SettingsScroll {
            SettingsCard {
                settingToggle("全局快速添加",$quickEnabled).onChange(of: quickEnabled) { _,_ in DesktopBridge.registerHotkey() }
                ShortcutRecorder().padding(.horizontal,16).padding(.bottom,18).disabled(!quickEnabled)
            }
            SettingsCard {
                shortcutRow("快速添加任务","⌘ N")
                shortcutRow("新建清单","⇧ ⌘ L")
                shortcutRow("搜索任务","⌘ F")
                shortcutRow("打开设置","⌘ ,")
                shortcutRow("撤销 / 重做","⌘ Z / ⇧ ⌘ Z")
            }
            sectionTitle("编辑任务与文档")
            SettingsCard { shortcutRow("保存任务名称","回车"); shortcutRow("取消名称修改","Esc"); shortcutRow("列表内换行","⇧ 回车"); shortcutRow("缩进 / 减少缩进","Tab / ⇧ Tab") }
        }
    }
    var aboutSettings: some View {
        VStack(spacing: 18) {
            BrandIcon(size: 80); Text("Zilo").font(.system(size: 26,weight: .bold))
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "开发版")）").foregroundStyle(ListTheme.secondary)
            Text("任务、文档与专注，安排每一天。").font(.system(size: 14))
            Link("开源项目",destination: URL(string: "https://github.com/luchuangao/Zilo")!)
            Text("数据目录：\(store.persistence.root.path)").font(.caption).foregroundStyle(ListTheme.secondary).textSelection(.enabled)
            Text("MIT 开源许可").font(.caption).foregroundStyle(ListTheme.secondary)
        }.padding(.top,32).frame(maxWidth: .infinity)
    }
    func settingToggle(_ title: String,_ binding: Binding<Bool>) -> some View { SettingsRow(title) { Toggle(LocalizedStringKey(title),isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title) } }
    func reminderPicker(_ title: String,_ binding: Binding<Double>) -> some View {
        SettingsRow(title + "默认提醒") { SettingsValuePicker(title + "默认提醒",selection: binding,choices: [("无",-1.0),("准时",0.0),("提前 5 分钟",300.0),("提前 15 分钟",900.0),("提前 30 分钟",1800.0),("提前 1 小时",3600.0),("提前 1 天",86400.0)]) }
    }
    func shortcutRow(_ title: String,_ shortcut: String) -> some View { SettingsRow(title) { Text(shortcut).font(.system(size: 13)).foregroundStyle(ListTheme.secondary) } }
    func sectionTitle(_ title: String) -> some View { Text(LocalizedStringKey(title)).font(.system(size: 15,weight: .semibold)).padding(.top,6) }
    func note(_ text: String) -> some View { Text(LocalizedStringKey(text)).font(.system(size: 12)).foregroundStyle(ListTheme.secondary).lineSpacing(3).frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,16).padding(.top,2).padding(.bottom,8) }
    @ViewBuilder var feedback: some View { if !status.isEmpty { Text(ZiloLanguage.status(status)).font(.system(size: 12)).foregroundStyle(ListTheme.secondary).textSelection(.enabled) } }
    func moduleDescription(_ module: Module) -> String { switch module { case .calendar: return "在月、周与时间轴中规划任务。"; case .matrix: return "按重要性和紧急性安排任务。"; case .focus: return "使用番茄计时与计时器保持专注。"; case .habits: return "记录每日习惯，查看打卡进度。"; case .countdown: return "记录重要日期，设置倒数和每年重复提醒。"; default: return "" } }
    func refreshNotificationStatus() async { let settings = await UNUserNotificationCenter.current().notificationSettings(); switch settings.authorizationStatus { case .authorized,.provisional,.ephemeral: notificationStatus = "已允许"; case .denied: notificationStatus = "未允许"; case .notDetermined: notificationStatus = "尚未开启"; @unknown default: notificationStatus = "未知" } }
    func export() { let p = NSSavePanel(); p.nameFieldStringValue = "Zilo-\(Day.key(Date())).ownlist.json"; p.allowedContentTypes = [.json]; if p.runModal() == .OK, let url = p.url { do { try store.export(to: url); status = "备份已导出" } catch { status = error.localizedDescription } } }
    func importFile() { let p = NSOpenPanel(); p.allowedContentTypes = [.json,.commaSeparatedText,.plainText]; if p.runModal() == .OK, let url = p.url { do { importPreview = try ImportService.preview(url); showImport = true } catch { status = error.localizedDescription } } }
}

struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { ScrollView { VStack(alignment: .leading,spacing: 14) { content }.padding(.bottom,12) }.font(.system(size: 13)) }
}
struct SettingsCard<Content: View>: View {
    @AppStorage("accent") private var applicationTheme = "blue"
    @ViewBuilder var content: Content
    var body: some View {
        let _ = applicationTheme
 VStack(spacing: 0) { content }.padding(.vertical,8).frame(maxWidth: .infinity,alignment: .leading).background(ListTheme.input.opacity(0.45),in: RoundedRectangle(cornerRadius: 10)).overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ListTheme.separator.opacity(0.55),lineWidth: 0.5) } }
}
struct SettingsRow<Control: View>: View {
    var title: String
    var control: Control
    init(_ title: String,@ViewBuilder control: () -> Control) { self.title = title; self.control = control() }
    var body: some View { HStack(spacing: 12) { Text(LocalizedStringKey(title)); Spacer(minLength: 8); control }.padding(.horizontal,16).frame(minHeight: 40) }
}

struct SmartListSettings: View {
    @AppStorage("accent") private var applicationTheme = "blue"
    @AppStorage("smartListVisibility") private var rawVisibility = ""
    var body: some View {
        let _ = applicationTheme

        ScrollView {
            VStack(spacing: 14) {
                choices(SmartListOption.primary)
                choices(SmartListOption.organization)
                choices(SmartListOption.secondary)
            }.padding(.bottom,12)
        }
    }
    func choices(_ items: [SmartListOption]) -> some View {
        SettingsCard {
            ForEach(items) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.icon).font(.system(size: 16)).frame(width: 22)
                    Text(LocalizedStringKey(item.title)).font(.system(size: 13))
                    Spacer()
                    SettingsValuePicker(item.title,selection: Binding(get: { SmartListPreferences(rawValue: rawVisibility).visibility(for: item.id) },set: {
                        rawVisibility = SmartListPreferences(rawValue: rawVisibility).updating(item.id,to: $0)
                    }),choices: SmartListVisibility.allCases.map { ($0.title,$0) })

                }.padding(.horizontal,16).frame(height: 38)
            }
        }
    }
}

/// A native menu with one shared value column, without a permanent button bezel.
struct SettingsValuePicker<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var choices: [(String,Value)]
    init(_ title: String,selection: Binding<Value>,choices: [(String,Value)]) { self.title = title; _selection = selection; self.choices = choices }
    var body: some View {
        SettingsNativeMenu(title: title,selection: $selection,choices: choices).frame(width: 170,height: 28).quietHover()
    }
}
private struct SettingsNativeMenu<Value: Hashable>: NSViewRepresentable {
    var title: String
    @Binding var selection: Value
    var choices: [(String,Value)]
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero,pullsDown: false)
        button.isBordered = false; button.controlSize = .small; button.font = .systemFont(ofSize: 13)
        button.cell?.alignment = .right; button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator; button.action = #selector(Coordinator.select(_:))
        button.setContentHuggingPriority(.defaultLow,for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSPopUpButton,context: Context) {
        context.coordinator.parent = self
        let titles = choices.map { ZiloLanguage.text($0.0) }
        if button.itemTitles != titles { button.removeAllItems(); button.addItems(withTitles: titles) }
        if let index = choices.firstIndex(where: { $0.1 == selection }) { button.selectItem(at: index) }
        button.setAccessibilityLabel(ZiloLanguage.text(title))
    }
    final class Coordinator: NSObject {
        var parent: SettingsNativeMenu
        init(_ parent: SettingsNativeMenu) { self.parent = parent }
        @objc func select(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard parent.choices.indices.contains(index) else { return }
            parent.selection = parent.choices[index].1
        }
    }
}
