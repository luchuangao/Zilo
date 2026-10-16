import SwiftUI
import AppKit

@main struct OwnListApp: App {
    @StateObject private var store = Store()
    @StateObject private var focus = FocusTimer()
    @StateObject private var calendar = CalendarService()
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("appearance") private var appearance = "system"
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Zilo", id: "main") {
            MainView().environmentObject(store).environmentObject(focus).environmentObject(calendar).environment(\.locale,ZiloLanguage.locale)
                .themeAppearance()
                .onAppear {
                    NotificationService.shared.configure(); NotificationService.shared.onComplete = { id in if store.tasks.first(where: { $0.id == id })?.completed == false { store.complete(id) } }
                    NotificationService.shared.onCompleteCheck = { id,check in Task { @MainActor in store.mutate(id) { task in if let index = task.checks.firstIndex(where: { $0.id == check }) { task.checks[index].done = true } } } }
                    NotificationService.shared.onOpen = { info in
                        if let raw = info["taskID"] as? String { store.notificationTask = UUID(uuidString: raw) }
                        if let raw = info["habitID"] as? String { store.notificationHabit = UUID(uuidString: raw); store.notificationModule = .habits }
                        if let raw = info["countdownID"] as? String { store.notificationCountdown = UUID(uuidString: raw); store.notificationModule = .countdown }
                        if info["focus"] as? Bool == true { store.notificationModule = .focus }
                    }
                    focus.onRecord = { store.save($0) }; focus.rescheduleNotification()
                    DesktopBridge.quickAction = { DesktopBridge.panel(title: "快速添加",view: QuickAddPanel().environmentObject(store).themeAppearance(),size: NSSize(width: 480,height: 170)) }
                    SideNotesPanel.shared.configure(store); DesktopBridge.registerHotkey(); delegate.store = store
                }
                .onOpenURL { url in
                    guard url.scheme == "ownlist" else { return }; let parts = URLComponents(url: url,resolvingAgainstBaseURL: false); let params = Dictionary((parts?.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith: { _,new in new })
                    if url.host == "quick" { DesktopBridge.quickAction?() }; if url.host == "add", let title = params["title"] { store.add(title) }
                    if url.host == "task", let raw = params["id"], let id = UUID(uuidString: raw) { store.selectedTask = id }
                }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1350,height: 850).commands {
            CommandGroup(replacing: .undoRedo) { Button("撤销") { undoDocumentOrTask() }.keyboardShortcut("z"); Button("重做") { undoDocumentOrTask(redo: true) }.keyboardShortcut("z",modifiers: [.command,.shift]) }
            CommandGroup(after: .newItem) { Button("快速添加任务") { DesktopBridge.quickAction?() }.keyboardShortcut("n"); Button("桌面便签") { SideNotesPanel.shared.toggle() }.keyboardShortcut("n",modifiers: [.command,.option]) }
        }
        WindowGroup("任务详情", id: "task-detail", for: UUID.self) { taskID in
            TaskWindow(taskID: taskID)
                .environmentObject(store).environmentObject(focus).environmentObject(calendar)
                .environment(\.locale,ZiloLanguage.locale).themeAppearance()
        }.defaultSize(width: 980,height: 780)
        Settings { SettingsView().environmentObject(store).environmentObject(calendar).environmentObject(focus) }.windowResizability(.contentSize)
        MenuBarExtra("Zilo",systemImage: "checkmark.circle.fill",isInserted: $showMenuBar) { MenuPanel().environmentObject(store).environmentObject(focus).themeAppearance() }.menuBarExtraStyle(.window)
    }
    private func undoDocumentOrTask(redo: Bool = false) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, let coordinator = editor.delegate as? DetailDocumentEditor.Coordinator {
            coordinator.performUndo(in: editor,redo: redo)
        } else if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,editor.isEditable,let undo = editor.undoManager {
            if redo { undo.redo() } else { undo.undo() }
        } else if redo { store.redo() } else { store.undo() }
    }

}

/// Each scene keeps its task and editor state while sharing the live records.
struct TaskWindow: View {
    @Binding var taskID: UUID?
    @EnvironmentObject private var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var notificationsVisible = false
    private var task: TaskItem? { store.tasks.first { $0.id == taskID && !$0.deleted } }
    var body: some View {
        Group {
            if let task {
                TaskDetailView(selection: $taskID,initialSplitPreview: true)
            } else {
                QuietEmptyState(title: "任务不可用",message: "任务可能已删除，请从主窗口选择其他任务。",symbol: "doc")
            }
        }.frame(minWidth: 420,minHeight: 560)
            .navigationTitle(task?.title ?? ZiloLanguage.text("任务详情"))
            .toolbar {
                ToolbarItem {
                    Button { notificationsVisible.toggle() } label: { Image(systemName: "bell") }
                        .help("通知与活动").accessibilityLabel("通知与活动")
                        .popover(isPresented: $notificationsVisible) {
                            NotificationInbox(onOpenTask: { id in notificationsVisible = false; taskID = id },onOpenModule: { module in
                                notificationsVisible = false; store.notificationModule = module; openWindow(id: "main")
                            }).environmentObject(store)
                        }
                }
            }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    func applicationDidBecomeActive(_ notification: Notification) { MainActor.assumeIsolated { guard let store, Capability.groupAvailable, let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Capability.groupID) else { return }; let queue = root.appendingPathComponent("SharedInbox"); for file in (try? FileManager.default.contentsOfDirectory(at: queue,includingPropertiesForKeys: nil)) ?? [] { if let text = try? String(contentsOf: file,encoding: .utf8), store.add(text) != nil { try? FileManager.default.removeItem(at: file) } } } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { store?.automaticBackup() } }
}
struct QuickAddPanel: View {
    @EnvironmentObject var store: Store
    var embedded = false
    @State private var title = ""
    @State private var listID: UUID?
    @FocusState private var focused: Bool
    private var canAdd: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var selectedList: TaskList? { store.lists.first { $0.id == listID && !$0.deleted } }
    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 15)).foregroundStyle(ListTheme.secondary)
                TextField("添加任务",text: $title).textFieldStyle(.plain).font(.system(size: 14))
                    .focused($focused).onSubmit(add).help("明天下午3点 写周报 #工作 !3")
            }.padding(.horizontal,12).frame(height: 44)
                .background(ListTheme.input,in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? ListTheme.accent.opacity(0.55) : ListTheme.separator,lineWidth: 1) }
            HStack(spacing: 10) {
                QuickAddListMenu(lists: store.lists.filter { !$0.deleted },selection: $listID)
                    .frame(width: 158,height: 30).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 8))
                Spacer(minLength: 8)
                Button(action: add) {
                    HStack(spacing: 8) { Text("添加"); Image(systemName: "return").font(.system(size: 10,weight: .medium)) }
                        .font(.system(size: 12,weight: .semibold)).padding(.horizontal,12).frame(height: 30)
                        .foregroundStyle(canAdd ? ListTheme.adaptive(0xFFFFFF,0x202126) : ListTheme.secondary.opacity(0.65))
                        .background(canAdd ? ListTheme.accent : ListTheme.input,in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(!canAdd)
            }
            Text("识别日期、#标签、!1 至 !3 优先级").font(.system(size: 11)).foregroundStyle(ListTheme.secondary)
                .fixedSize(horizontal: false,vertical: true)
        }.padding(embedded ? 0 : 20).foregroundStyle(ListTheme.text).environment(\.locale,ZiloLanguage.locale)
            .onAppear { focused = true }
    }
    private func add() { guard canAdd else { return }; if store.add(title,listID: selectedList?.id) != nil { title = ""; focused = true } }
}
private struct QuickAddListMenu: NSViewRepresentable {
    var lists: [TaskList]
    @Binding var selection: UUID?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero,pullsDown: false)
        button.isBordered = false; button.controlSize = .small; button.font = .systemFont(ofSize: 12)
        button.cell?.alignment = .left; button.setContentHuggingPriority(.defaultLow,for: .horizontal)
        button.target = context.coordinator; button.action = #selector(Coordinator.select(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton,context: Context) {
        context.coordinator.parent = self
        let titles = [ZiloLanguage.text("收集箱")] + lists.map(\.name)
        let ids: [UUID?] = [nil] + lists.map { Optional($0.id) }
        if button.itemTitles != titles || context.coordinator.ids != ids {
            button.removeAllItems(); button.addItems(withTitles: titles)
            for index in titles.indices { button.item(at: index)?.image = NSImage(systemSymbolName: index == 0 ? "tray" : "line.3.horizontal",accessibilityDescription: nil) }
            context.coordinator.ids = ids
        }
        button.selectItem(at: ids.firstIndex(of: selection) ?? 0)
        button.contentTintColor = NSColor(ListTheme.text)
        button.setAccessibilityLabel(ZiloLanguage.text("清单"))
    }
    final class Coordinator: NSObject {
        var parent: QuickAddListMenu
        var ids: [UUID?] = []
        init(_ parent: QuickAddListMenu) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) { guard ids.indices.contains(sender.indexOfSelectedItem) else { return }; parent.selection = ids[sender.indexOfSelectedItem] }
    }
}
struct MenuPanel: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var focus: FocusTimer
    @Environment(\.openWindow) private var openWindow
    private var todayTasks: [TaskItem] { store.tasks.filter { !$0.deleted && !$0.completed && !$0.isTemplate && $0.archived != true && $0.due.map { Calendar.current.isDateInToday($0) } == true } }
    private var focusTitle: String { focus.mode == "番茄" && focus.phase == "专注" ? "番茄专注" : focus.mode == "番茄" ? focus.phase : "正计时" }
    private var focusAction: String { focus.running ? "暂停" : focus.elapsed > 0 ? "继续" : focus.phase == "专注" ? "开始专注" : "开始休息" }
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack(spacing: 9) {
                BrandIcon(size: 28).accessibilityHidden(true)
                Text("Zilo").font(.system(size: 17,weight: .semibold))
                Spacer(minLength: 8)
                Button(action: openMain) {
                    HStack(spacing: 5) { Text("打开"); Image(systemName: "arrow.up.right").font(.system(size: 10,weight: .medium)) }
                        .font(.system(size: 12)).padding(.horizontal,9).frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(ListTheme.secondary).quietHover().accessibilityLabel("打开")
                Menu { Button("打开便签",systemImage: "note.text") { SideNotesPanel.shared.show(store) }; Button("退出 Zilo",role: .destructive) { NSApp.terminate(nil) } } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14)).frame(width: 24,height: 28).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(ListTheme.secondary).quietHover().accessibilityLabel("Zilo 菜单")
            }
            QuickAddPanel(embedded: true)
            ListTheme.separator.frame(height: 0.5)
            VStack(alignment: .leading,spacing: 10) {
                HStack(spacing: 7) {
                    Text("今天").font(.system(size: 13,weight: .semibold))
                    Text("\(todayTasks.count)").font(.system(size: 11,weight: .medium)).monospacedDigit().foregroundStyle(ListTheme.secondary)
                        .padding(.horizontal,6).padding(.vertical,2).background(ListTheme.input,in: Capsule())
                        .accessibilityLabel(ZiloLanguage.format("%lld 项",todayTasks.count))
                    Spacer()
                }
                if todayTasks.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle").font(.system(size: 20,weight: .light)).foregroundStyle(ListTheme.accent)
                            .frame(width: 36,height: 36).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading,spacing: 4) {
                            Text("今天没有待办").font(.system(size: 12,weight: .medium))
                            Text("从上方添加，开始安排今天。").font(.system(size: 11)).foregroundStyle(ListTheme.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical,8)
                } else {
                    ScrollView {
                        VStack(spacing: 2) { ForEach(Array(todayTasks.prefix(8))) { task in todayRow(task) } }
                    }.frame(height: min(CGFloat(min(todayTasks.count,8)) * 38,220))
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "timer").font(.system(size: 22,weight: .light)).foregroundStyle(ListTheme.accent).frame(width: 28)
                VStack(alignment: .leading,spacing: 3) {
                    Text(LocalizedStringKey(focusTitle)).font(.system(size: 11)).foregroundStyle(ListTheme.secondary)
                    Text(focus.display).font(.system(size: 23,weight: .medium,design: .rounded)).monospacedDigit()
                }
                Spacer(minLength: 8)
                Button { if focus.running { focus.pause() } else { focus.start() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: focus.running ? "pause.fill" : "play.fill").font(.system(size: 10))
                        Text(LocalizedStringKey(focusAction))
                    }.font(.system(size: 12,weight: .medium)).padding(.horizontal,11).frame(height: 32)
                        .foregroundStyle(ListTheme.adaptive(0xFFFFFF,0x202126)).background(ListTheme.accent,in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }.padding(12).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 12))
        }.padding(16).frame(width: 360).background(ListTheme.canvas).foregroundStyle(ListTheme.text)
            .environment(\.locale,ZiloLanguage.locale)
    }
    private func todayRow(_ task: TaskItem) -> some View {
        HStack(spacing: 6) {
            Button { store.complete(task.id) } label: {
                Image(systemName: "circle").font(.system(size: 16)).foregroundStyle(ListTheme.secondary)
                    .frame(width: 28,height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(ZiloLanguage.text("完成任务") + "：" + task.title)
            Text(task.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            if let due = task.due,!task.allDay { Text(due.formatted(date: .omitted,time: .shortened)).font(.system(size: 11)).foregroundStyle(ListTheme.secondary) }
        }.padding(.horizontal,4).frame(height: 36).quietHover()
    }
    private func openMain() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}
struct StickyView: View { @EnvironmentObject var store: Store; var listID: UUID? = nil; @State private var input = ""; var body: some View { VStack(alignment: .leading) { Text(store.lists.first { $0.id == listID }?.name ?? "今天要做").font(.title2.bold()); TextField("添加任务",text: $input).onSubmit { store.add(listID == nil ? input + " 今天" : input,listID: listID); input = "" }; ScrollView { ForEach(store.tasks.filter { !$0.deleted && !$0.completed && !$0.isTemplate && (listID != nil ? $0.listID == listID : $0.due.map { Calendar.current.isDateInToday($0) } == true) }) { task in HStack { Button { store.complete(task.id) } label: { Image(systemName: "circle") }.buttonStyle(.plain); Text(task.title); Spacer() }.padding(.vertical,8) } } }.padding().background(Color.yellow.opacity(0.12)) } }
/// A theme changes navigation surfaces and controls, independently of list colors.
struct AppTheme: Identifiable {
    let id: String
    let name: String
    let top: UInt32
    let bottom: UInt32
    let accent: UInt32
    var forcesDark: Bool { id == "night" }
    static let all: [AppTheme] = [
        .init(id: "default",name: "默认",top: 0xFFFFFF,bottom: 0xF4F5F7,accent: 0x526AE8),
        .init(id: "blue",name: "晴蓝",top: 0x799AFF,bottom: 0x4669E8,accent: 0x405AC9),
        .init(id: "teal",name: "松石",top: 0x83DBCA,bottom: 0x26A68F,accent: 0x147C6B),
        .init(id: "cyan",name: "秘青",top: 0x9CD9DD,bottom: 0x4F9EA9,accent: 0x277984),
        .init(id: "green",name: "蒹葭",top: 0xC6D5BD,bottom: 0x78956B,accent: 0x4C7544),
        .init(id: "orange",name: "杏黄",top: 0xFFD38B,bottom: 0xECA16B,accent: 0xA05E27),
        .init(id: "pink",name: "桃夭",top: 0xFFB7B5,bottom: 0xEE7CA9,accent: 0xAD3E6E),
        .init(id: "purple",name: "暮山紫",top: 0xD4BFDE,bottom: 0x9395CF,accent: 0x6A60A6),
        .init(id: "brown",name: "沉香",top: 0xCCB2A2,bottom: 0xA78060,accent: 0x896043),
        .init(id: "navy",name: "藏蓝",top: 0x495782,bottom: 0x252F51,accent: 0x4C609B),
        .init(id: "gray",name: "灰色",top: 0x555A63,bottom: 0x333741,accent: 0x526179),
        .init(id: "night",name: "夜间",top: 0x292A30,bottom: 0x17181D,accent: 0x526AE8),
        .init(id: "yellow",name: "暖黄",top: 0xF9DE88,bottom: 0xCBA94A,accent: 0x8B6C20),
        .init(id: "red",name: "珊瑚",top: 0xF7A59D,bottom: 0xD66561,accent: 0xB14945),
        .init(id: "spring",name: "春日",top: 0xDCF0C5,bottom: 0x81A975,accent: 0x4C7544),
        .init(id: "summer",name: "夏海",top: 0xB3E8ED,bottom: 0x56AAC5,accent: 0x277984),
        .init(id: "autumn",name: "秋叶",top: 0xF8D8A8,bottom: 0xC48357,accent: 0xA05E27),
        .init(id: "winter",name: "冬雪",top: 0xD8E4F9,bottom: 0x91A4CD,accent: 0x465780)
    ]
    static func resolve(_ id: String) -> AppTheme { all.first { $0.id == id } ?? all[1] }
    static func blend(_ first: UInt32,_ second: UInt32,_ fraction: Double) -> UInt32 {
        [16,8,0].reduce(0) { result,shift in
            let a = Double((first >> shift) & 255), b = Double((second >> shift) & 255)
            return result | (UInt32((a + (b - a) * fraction).rounded()) << shift)
        }
    }
    static func luminance(_ color: UInt32) -> Double {
        let components = [16,8,0].map { shift -> Double in
            let value = Double((color >> shift) & 255) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055,2.4)
        }
        return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
    }
    func value(_ surface: String,dark: Bool) -> UInt32 {
        switch surface {
        case "canvas": return dark ? 0x202126 : 0xFFFFFF
        case "rail": return id == "default" ? (dark ? 0x191A1F : 0xF4F5F7) : dark ? Self.blend(bottom,0x14151B,0.55) : bottom
        case "railForeground": return id == "default" ? (dark ? 0xB1B5C0 : 0x656B78) : (!dark && Self.luminance(bottom) > 0.30 ? 0x242730 : 0xFFFFFF)
        case "sidebar": return id == "default" ? (dark ? 0x24252B : 0xFBFBFC) : Self.blend(dark ? 0x24252B : 0xFFFFFF,bottom,dark ? 0.12 : 0.08)
        case "sidebarHover": return Self.blend(value("sidebar",dark: dark),dark ? 0xFFFFFF : 0x000000,dark ? 0.07 : 0.05)
        case "input": return Self.blend(dark ? 0x2B2D35 : 0xF4F5F7,bottom,dark ? 0.08 : 0.04)
        case "selection": return Self.blend(dark ? 0x343743 : 0xFFFFFF,bottom,dark ? 0.23 : 0.17)
        case "hover": return Self.blend(dark ? 0x2D2F38 : 0xFFFFFF,bottom,dark ? 0.14 : 0.08)
        case "separator": return dark ? 0x383A44 : 0xE9EBF0
        case "text": return dark ? 0xECEEF4 : 0x242730
        case "secondary": return dark ? 0xB1B5C0 : 0x656B78
        default: return dark ? Self.blend(accent,0xFFFFFF,0.55) : accent
        }
    }
    static func color(_ value: UInt32) -> Color { Color(nsColor: nsColor(value)) }
    static func nsColor(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,green: CGFloat((value >> 8) & 255) / 255,blue: CGFloat(value & 255) / 255,alpha: 1)
    }
}
enum ListTheme {
    static func adaptive(_ light: UInt32,_ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in AppTheme.nsColor(appearance.bestMatch(from: [.darkAqua,.aqua]) == .darkAqua ? dark : light) })
    }
    static func themed(_ surface: String) -> Color {
        // Resolve on drawing as well as view updates, including native popovers.
        Color(nsColor: NSColor(name: nil) { appearance in
            let theme = AppTheme.resolve(UserDefaults.standard.string(forKey: "accent") ?? "blue")
            return AppTheme.nsColor(theme.value(surface,dark: theme.forcesDark || appearance.bestMatch(from: [.darkAqua,.aqua]) == .darkAqua))
        })
    }
    static var canvas: Color { themed("canvas") }
    static var rail: Color { themed("rail") }
    static var railForeground: Color { themed("railForeground") }
    static var sidebar: Color { themed("sidebar") }
    static var sidebarHover: Color { themed("sidebarHover") }
    static var input: Color { themed("input") }
    static var selection: Color { themed("selection") }
    static var hover: Color { themed("hover") }
    static var separator: Color { themed("separator") }
    static var text: Color { themed("text") }
    static var secondary: Color { themed("secondary") }
    static var accent: Color { themed("accent") }
}
struct ThemeAppearance: ViewModifier {
    @AppStorage("accent") private var accent = "blue"
    @AppStorage("appearance") private var appearance = "system"
    func body(content: Content) -> some View {
        let theme = AppTheme.resolve(accent)
        content.tint(ListTheme.accent).accentColor(ListTheme.accent)
            .preferredColorScheme(theme.forcesDark || appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
    }
}
extension String {
    var listColor: Color {
        if hasPrefix("#"), count == 7, let value = Int(dropFirst(),radix: 16) {
            return Color(red: Double((value >> 16) & 255) / 255,
                         green: Double((value >> 8) & 255) / 255,
                         blue: Double(value & 255) / 255)
        }
        switch self {
    case "none": return ListTheme.secondary
    case "red": return Color(red: 237 / 255,green: 108 / 255,blue: 103 / 255)
    case "orange": return Color(red: 243 / 255,green: 176 / 255,blue: 82 / 255)
    case "yellow": return Color(red: 248 / 255,green: 213 / 255,blue: 80 / 255)
    case "lime": return Color(red: 231 / 255,green: 234 / 255,blue: 103 / 255)
    case "green": return Color(red: 108 / 255,green: 213 / 255,blue: 123 / 255)
    case "blue": return Color(red: 98 / 255,green: 159 / 255,blue: 248 / 255)
    case "purple": return Color(red: 112 / 255,green: 117 / 255,blue: 237 / 255)
    case "pink": return ListTheme.adaptive(0xC76093,0xEDA8CB)
    default: return ListTheme.accent
        }
    }
}
struct QuietHover: ViewModifier {
    var selected = false
    var rail = false
    @AppStorage("accent") private var accent = "blue"
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.background(rail ? (selected ? ListTheme.railForeground.opacity(0.22) : hovering ? ListTheme.railForeground.opacity(0.12) : .clear) : (selected ? ListTheme.selection : hovering ? ListTheme.hover : .clear),in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: accent) { _,_ in }
            .onHover { hovering = $0 }
    }
}
struct SidebarHover: ViewModifier {
    var selected: Bool
    @AppStorage("accent") private var accent = "blue"
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(selected ? ListTheme.selection : hovering ? ListTheme.sidebarHover : .clear,in: RoundedRectangle(cornerRadius: 8))
            // Passive native tracking also sees pointer movement over the list's drag surface.
            .background { TaskRowHover { hovering = $0 } }
            .onHover { hovering = $0 }
            .onChange(of: accent) { _,_ in }
            .onDisappear { hovering = false }
    }
}
extension View {
    func quietHover(selected: Bool = false,rail: Bool = false) -> some View { modifier(QuietHover(selected: selected,rail: rail)) }
    func sidebarHover(selected: Bool = false) -> some View { modifier(SidebarHover(selected: selected)) }
    func themeAppearance() -> some View { modifier(ThemeAppearance()) }
}
struct QuietEmptyState: View {
    var title: String
    var message: String
    var symbol = "list.bullet.rectangle"
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 38,weight: .ultraLight)).foregroundStyle(ListTheme.secondary.opacity(0.55)).padding(.bottom,4)
            Text(LocalizedStringKey(title)).font(.system(size: 16,weight: .medium)).foregroundStyle(ListTheme.secondary)
            Text(LocalizedStringKey(message)).font(.system(size: 12)).foregroundStyle(ListTheme.secondary).multilineTextAlignment(.center).lineSpacing(4)
        }.padding(32).frame(maxWidth: .infinity,maxHeight: .infinity)
    }
}

extension String { var colorLabel: String { ["none":"无颜色","blue":"蓝色","green":"绿色","orange":"橙色","yellow":"黄色","lime":"黄绿色","purple":"紫色","red":"红色","pink":"粉色"][self] ?? (hasPrefix("#") ? "自定义颜色" : self) } }

/// Keep swatches in SwiftUI; native menu images otherwise become monochrome.
struct ThemeColorChoices: View {
    var title: String
    @Binding var selection: String
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                ForEach(["blue","green","orange","purple","red","pink"],id: \.self) { color in
                    Button { selection = color } label: {
                        ZStack {
                            Circle().fill(color.listColor).frame(width: 18,height: 18)
                            if selection == color { Image(systemName: "checkmark").font(.system(size: 9,weight: .bold)).foregroundStyle(ListTheme.adaptive(0xFFFFFF,0x202126)) }
                        }.frame(width: 27,height: 28)
                    }.buttonStyle(.plain).quietHover().help(color.colorLabel).accessibilityLabel(color.colorLabel)
                        .accessibilityAddTraits(selection == color ? .isSelected : [])
                }
            }
        }
    }
}

struct BrandIcon: View {
    var size: CGFloat = 36
    private static let image = Bundle.main.url(forResource: "AppIcon-zhixing",withExtension: "icns").flatMap { NSImage(contentsOf: $0) } ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 32,height: 32))
    var body: some View { Image(nsImage: Self.image).resizable().interpolation(.high).scaledToFit().frame(width: size,height: size).accessibilityLabel("Zilo") }
}
