import SwiftUI
import AppKit

@main struct OwnListApp: App {
    @StateObject private var store = Store()
    @StateObject private var focus = FocusTimer()
    @StateObject private var calendar = CalendarService()
    @AppStorage("appearance") private var appearance = "system"
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Zilo", id: "main") {
            MainView().environmentObject(store).environmentObject(focus).environmentObject(calendar)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .onAppear {
                    NotificationService.shared.configure(); NotificationService.shared.onComplete = { id in store.complete(id) }
                    focus.onRecord = { store.save($0) }
                    DesktopBridge.quickAction = { DesktopBridge.panel(title: "快速添加",view: QuickAddPanel().environmentObject(store),size: NSSize(width: 480,height: 170)) }
                    DesktopBridge.registerHotkey(); delegate.store = store
                }
                .onOpenURL { url in
                    guard url.scheme == "ownlist" else { return }; let parts = URLComponents(url: url,resolvingAgainstBaseURL: false); let params = Dictionary((parts?.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith: { _,new in new })
                    if url.host == "quick" { DesktopBridge.quickAction?() }; if url.host == "add", let title = params["title"] { store.add(title) }
                    if url.host == "task", let raw = params["id"], let id = UUID(uuidString: raw) { store.selectedTask = id }
                }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1350,height: 850).commands {
            CommandGroup(replacing: .undoRedo) { Button("撤销") { undoDocumentOrTask() }.keyboardShortcut("z"); Button("重做") { undoDocumentOrTask(redo: true) }.keyboardShortcut("z",modifiers: [.command,.shift]) }
            CommandGroup(after: .newItem) { Button("快速添加任务") { DesktopBridge.quickAction?() }.keyboardShortcut("n"); Button("桌面便签") { DesktopBridge.panel(title: "今日便签",view: StickyView().environmentObject(store),size: NSSize(width: 340,height: 480)) } }
        }
        Settings { SettingsView().environmentObject(store).environmentObject(calendar).environmentObject(focus) }
        MenuBarExtra("Zilo",systemImage: "checkmark.circle.fill") { MenuPanel().environmentObject(store).environmentObject(focus) }.menuBarExtraStyle(.window)
    }
    private func undoDocumentOrTask(redo: Bool = false) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, let coordinator = editor.delegate as? DetailDocumentEditor.Coordinator {
            coordinator.performUndo(in: editor,redo: redo)
        } else if redo { store.redo() } else { store.undo() }
    }

}
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    func applicationDidBecomeActive(_ notification: Notification) { MainActor.assumeIsolated { guard let store, Capability.groupAvailable, let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Capability.groupID) else { return }; let queue = root.appendingPathComponent("SharedInbox"); for file in (try? FileManager.default.contentsOfDirectory(at: queue,includingPropertiesForKeys: nil)) ?? [] { if let text = try? String(contentsOf: file,encoding: .utf8), store.add(text) != nil { try? FileManager.default.removeItem(at: file) } } } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { store?.automaticBackup() } }
}
struct QuickAddPanel: View {
    @EnvironmentObject var store: Store; @State private var title = ""; @State private var listID: UUID?; @FocusState private var focused: Bool
    var body: some View { VStack(alignment: .leading,spacing: 15) { TextField("明天下午3点 写周报 #工作 !3",text: $title).textFieldStyle(.roundedBorder).focused($focused).onSubmit(add); HStack { Picker("清单",selection: $listID) { Text("收集箱").tag(nil as UUID?); ForEach(store.lists.filter { !$0.deleted }) { Text($0.name).tag(Optional($0.id)) } }; Spacer(); Button("添加",action: add).buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty) }; Text("识别日期、#标签、!1 至 !3 优先级").font(.caption).foregroundStyle(.secondary) }.padding(20).onAppear { focused = true } }
    func add() { if store.add(title,listID: listID) != nil { title = "" } }
}
struct MenuPanel: View {
    @EnvironmentObject var store: Store; @EnvironmentObject var focus: FocusTimer; @Environment(\.openWindow) var openWindow
    var body: some View { VStack(alignment: .leading,spacing: 12) { HStack { Label("Zilo",systemImage: "checkmark.circle.fill").font(.headline); Spacer(); Button("打开") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } }; QuickAddPanel(); Divider(); Text("今天").font(.headline); ForEach(store.tasks.filter { !$0.deleted && !$0.completed && !$0.isTemplate && $0.due.map { Calendar.current.isDateInToday($0) } == true }.prefix(8)) { task in HStack { Button { store.complete(task.id) } label: { Image(systemName: "circle") }.buttonStyle(.plain); Text(task.title).lineLimit(1) } }; Divider(); HStack { Text(focus.display).monospacedDigit(); Button(focus.running ? "暂停" : "专注") { if focus.running { focus.pause() } else { focus.start() } }; Button("退出") { NSApp.terminate(nil) } } }.padding().frame(width: 370) }
}
struct StickyView: View { @EnvironmentObject var store: Store; var listID: UUID? = nil; @State private var input = ""; var body: some View { VStack(alignment: .leading) { Text(store.lists.first { $0.id == listID }?.name ?? "今天要做").font(.title2.bold()); TextField("添加任务",text: $input).onSubmit { store.add(listID == nil ? input + " 今天" : input,listID: listID); input = "" }; ScrollView { ForEach(store.tasks.filter { !$0.deleted && !$0.completed && !$0.isTemplate && (listID != nil ? $0.listID == listID : $0.due.map { Calendar.current.isDateInToday($0) } == true) }) { task in HStack { Button { store.complete(task.id) } label: { Image(systemName: "circle") }.buttonStyle(.plain); Text(task.title); Spacer() }.padding(.vertical,8) } } }.padding().background(Color.yellow.opacity(0.12)) } }
/// Shared surface and accent colors adapt to the application's appearance.
enum ListTheme {
    static func adaptive(_ light: UInt32,_ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua,.aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,green: CGFloat((value >> 8) & 255) / 255,blue: CGFloat(value & 255) / 255,alpha: 1)
        })
    }
    static var canvas: Color { adaptive(0xFFFFFF,0x202126) }
    static var rail: Color { adaptive(0xF4F5F7,0x191A1F) }
    static var sidebar: Color { adaptive(0xFBFBFC,0x24252B) }
    static var input: Color { adaptive(0xF4F5F7,0x2B2D35) }
    static var selection: Color { adaptive(0xEEF0F5,0x343743) }
    static var hover: Color { adaptive(0xF3F4F7,0x2D2F38) }
    static var separator: Color { adaptive(0xE9EBF0,0x383A44) }
    static var text: Color { adaptive(0x242730,0xECEEF4) }
    static var secondary: Color { adaptive(0x656B78,0xB1B5C0) }
    static var accent: Color { adaptive(0x526AE8,0x9BAAFF) }
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
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.background(selected ? ListTheme.selection : hovering ? ListTheme.hover : .clear,in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}
extension View {
    func quietHover(selected: Bool = false) -> some View { modifier(QuietHover(selected: selected)) }
}
struct QuietEmptyState: View {
    var title: String
    var message: String
    var symbol = "list.bullet.rectangle"
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 38,weight: .ultraLight)).foregroundStyle(ListTheme.secondary.opacity(0.55)).padding(.bottom,4)
            Text(title).font(.system(size: 16,weight: .medium)).foregroundStyle(ListTheme.secondary)
            Text(message).font(.system(size: 12)).foregroundStyle(ListTheme.secondary).multilineTextAlignment(.center).lineSpacing(4)
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
