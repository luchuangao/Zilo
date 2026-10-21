import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuartzCore

extension Store: SideNotesStore {
    @discardableResult func persistSideNote(_ note: SideNote) -> Bool { save(note,undoable: false) }
    @discardableResult func persistSideNoteFolder(_ folder: SideNoteFolder) -> Bool { save(folder) }
    @discardableResult func persistNoteTask(_ task: TaskItem) -> Bool { save(task,undoable: false) }
}

@MainActor final class SideNotesSelection: ObservableObject {
    @Published var selected: UUID?
    @Published var reveal = UUID()
}
enum SideNotesDockLayout {
    static func frame(screen: NSRect,width: CGFloat = 320,contentHeight: CGFloat) -> NSRect {
        let width = min(max(280,width),min(480,screen.width))
        let height = min(max(240,contentHeight),max(240,screen.height-32))
        return NSRect(x: screen.maxX-width,y: screen.maxY-16-height,width: width,height: height)
    }
}

/// Keep rapid reversals based on the intended height, not a transient animation frame.
struct SideNotesFoldResize {
    private(set) var target: CGFloat?
    private var generation = UUID()
    mutating func begin(height: CGFloat,delta: CGFloat) -> UUID {
        generation = UUID(); target = max(1,(target ?? height)+delta); return generation
    }
    mutating func finish(_ token: UUID) -> Bool {
        guard generation == token else { return false }
        target = nil; return true
    }
    mutating func cancel() { generation = UUID(); target = nil }
}

/// Debounce edge visits and protect editing/menu interactions from auto-hide.
@MainActor final class SideNotesHoverBehavior {
    var containsPointer: () -> Bool = { false }
    var canHide: () -> Bool = { true }
    var onShow: () -> Void = {}
    var onHide: () -> Void = {}
    private let openDelay: UInt64
    private let closeDelay: UInt64
    private var openTask: Task<Void,Never>?
    private var closeTask: Task<Void,Never>?
    init(openDelay: UInt64 = 150_000_000,closeDelay: UInt64 = 350_000_000) {
        self.openDelay = openDelay; self.closeDelay = closeDelay
    }
    func enterEdge() {
        cancel()
        openTask = Task { [weak self] in
            guard let delay = self?.openDelay else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,let self,self.containsPointer() else { return }
            self.onShow()
        }
    }
    func enterPanel() { cancel() }
    func leave() {
        cancel()
        closeTask = Task { [weak self] in
            guard let delay = self?.closeDelay else { return }
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,let self,!self.containsPointer(),self.canHide() else { return }
            self.onHide()
        }
    }
    func cancel() { openTask?.cancel(); closeTask?.cancel(); openTask = nil; closeTask = nil }
}

@MainActor final class SideNotesPanel: NSObject, NSWindowDelegate {
    static let shared = SideNotesPanel()
    private var panel: NSPanel?
    private var edge: NSPanel?
    private weak var store: Store?
    private var presented = false
    private var animation = UUID()
    private var measuredHeight: CGFloat = 300
    private var resizeWork: DispatchWorkItem?
    private var foldResize = SideNotesFoldResize()
    private let hover = SideNotesHoverBehavior()
    private var menuDepth = 0
    private var hoverPreview = false
    private var pointerVisitedPanel = false
    private var observers: [NSObjectProtocol] = []
    let selection = SideNotesSelection()
    func configure(_ store: Store) {
        self.store = store
        DesktopBridge.notesAction = { [weak self] in self?.toggle() }
        hover.containsPointer = { [weak self] in self?.containsPointer == true }
        hover.canHide = { [weak self] in
            guard let self else { return false }
            let editing = self.panel?.isKeyWindow == true && self.panel?.firstResponder is NSTextView
            return !editing && self.menuDepth == 0
        }
        hover.onShow = { [weak self] in
            guard let self,!self.presented,let store = self.store else { return }
            self.show(store,activate: false)
        }
        hover.onHide = { [weak self] in self?.hide() }
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification,object: nil,queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuDepth += 1 }
            })
            observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification,object: nil,queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.menuDepth = max(0,self.menuDepth-1); self.hover.leave() }
            })
            observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,object: nil,queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEdge() }
            })
        }
        // The drawer starts tucked away; only its thin edge handle is visible.
        updateEdge()
    }
    private var chromeHeight: CGFloat {
        guard let panel else { return 28 }
        return panel.frame.height-panel.contentRect(forFrameRect: panel.frame).height
    }
    private var screen: NSRect { panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0,y: 0,width: 1440,height: 900) }
    private var containsPointer: Bool {
        let point = NSEvent.mouseLocation
        return (edge?.isVisible == true && edge?.frame.contains(point) == true)
            || (presented && panel?.isVisible == true && panel?.frame.contains(point) == true)
    }
    func windowDidResignKey(_ notification: Notification) { hover.leave() }
    func windowWillClose(_ notification: Notification) { presented = false; hover.cancel() }
    func show(_ store: Store,taskID: UUID? = nil,activate: Bool = true) {
        self.store = store
        hover.cancel(); cancelFoldResize(); hoverPreview = !activate; pointerVisitedPanel = containsPointer
        if let taskID { selection.selected = store.linkSideNote(taskID: taskID); selection.reveal = UUID() }
        if panel == nil {
            let window = NSPanel(contentRect: SideNotesDockLayout.frame(screen: screen,contentHeight: measuredHeight),styleMask: [.titled,.closable,.resizable,.nonactivatingPanel],backing: .buffered,defer: false)
            window.title = ZiloLanguage.text("便签"); window.isReleasedWhenClosed = false
            window.becomesKeyOnlyIfNeeded = true; window.delegate = self
            window.minSize = NSSize(width: 280,height: 240); window.maxSize = NSSize(width: 480,height: screen.height)
            window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; window.hidesOnDeactivate = false
            let host = NotesHostingView(rootView: SideNotesView(selection: selection).environmentObject(store).environment(\.locale,ZiloLanguage.locale).themeAppearance())
            host.onHide = { [weak self] in self?.hide() }
            host.onEnter = { [weak self] in self?.pointerVisitedPanel = true; self?.hover.enterPanel() }
            host.onLeave = { [weak self] in
                guard let self,self.hoverPreview || self.pointerVisitedPanel else { return }
                self.hover.leave()
            }
            window.contentView = host
            panel = window
        }
        guard let panel else { return }
        let target = SideNotesDockLayout.frame(screen: screen,width: panel.frame.width,contentHeight: measuredHeight)
        let wasVisible = panel.isVisible && presented
        let token = UUID(); animation = token; presented = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !wasVisible && !reduceMotion { panel.setFrame(NSRect(x: screen.maxX+8,y: target.minY,width: target.width,height: target.height),display: false) }
        if activate { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in context.duration = wasVisible || reduceMotion ? 0 : 0.18; panel.animator().setFrame(target,display: true) } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,self.animation == token,self.presented else { return }
                // The view can report its content height during the slide-in.
                // Apply it after the animation so its original target cannot undo the resize.
                self.fitContent(self.measuredHeight-self.chromeHeight)
            }
        }
    }
    func hide() {
        hover.cancel(); cancelFoldResize()
        guard let panel else { return }
        presented = false; let token = UUID(); animation = token
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.orderOut(nil); return }
        var target = panel.frame; target.origin.x = screen.maxX+8
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; panel.animator().setFrame(target,display: true) } completionHandler: { [weak self] in
            Task { @MainActor in guard let self,self.animation == token else { return }; self.panel?.orderOut(nil) }
        }
    }
    func toggle() {
        if panel?.isVisible == true && presented { hide() }
        else if let store { show(store) }
    }
    func updateTitle(trash: Bool) {
        panel?.title = ZiloLanguage.text(trash ? "已删除便签" : "便签")
        cancelFoldResize(); fitContent(measuredHeight-chromeHeight)
    }
    private func cancelFoldResize() {
        foldResize.cancel(); resizeWork?.cancel()
    }
    func animateFoldResize(by delta: CGFloat) {
        guard delta.isFinite,let panel,presented,!panel.inLiveResize,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        resizeWork?.cancel()
        let token = foldResize.begin(height: measuredHeight,delta: delta)
        let target = SideNotesDockLayout.frame(screen: screen,width: panel.frame.width,contentHeight: foldResize.target!)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.42,0,0.58,1)
            panel.animator().setFrame(target,display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self,self.foldResize.finish(token) else { return }
                self.fitContent(self.measuredHeight-self.chromeHeight)
            }
        }
    }
    func fitContent(_ height: CGFloat) {
        guard height.isFinite,height > 0 else { return }
        measuredHeight = height + chromeHeight
        // SwiftUI and the window animate to the same target. Intermediate layout
        // measurements must not restart or jump over the in-flight transition.
        guard foldResize.target == nil else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,let panel = self.panel,self.presented,!panel.inLiveResize,self.foldResize.target == nil else { return }
            let target = SideNotesDockLayout.frame(screen: self.screen,width: panel.frame.width,contentHeight: self.measuredHeight)
            if abs(target.height-panel.frame.height) > 1 { panel.setFrame(target,display: true) }
        }
        resizeWork = work; DispatchQueue.main.asyncAfter(deadline: .now()+0.01,execute: work)
    }
    func updateEdge() {
        guard let screen = NSScreen.main?.visibleFrame else { edge?.orderOut(nil); return }
        if edge == nil {
            let tab = NSPanel(contentRect: .zero,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
            tab.backgroundColor = .clear; tab.isOpaque = false; tab.hasShadow = false; tab.level = .floating
            tab.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; tab.hidesOnDeactivate = false
            let handle = NotesEdgeHandle(); handle.open = { [weak self] in if let self,let store = self.store { self.show(store) } }
            handle.toggle = { [weak self] in self?.toggle() }
            handle.onEnter = { [weak self] in self?.hover.enterEdge() }
            handle.onLeave = { [weak self] in self?.hover.leave() }
            handle.toolTip = ZiloLanguage.text("悬停显示便签")
            tab.contentView = handle; edge = tab
        }
        edge?.setFrame(NSRect(x: screen.maxX-10,y: screen.maxY-176,width: 10,height: 80),display: true)
        edge?.orderFrontRegardless()
    }
}

private final class NotesEdgeHandle: NSView {
    var open: (() -> Void)?; var toggle: (() -> Void)?
    var onEnter: (() -> Void)?; var onLeave: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hovering = false
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,options: [.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner: self,userInfo: nil)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; onEnter?() }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true; onLeave?() }
    private var start: NSPoint?; private var dragged = false; private var travel: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.65) : NSColor.secondaryLabelColor.withAlphaComponent(0.35)).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.maxX-4,y: 12,width: 3,height: bounds.height-24),xRadius: 1.5,yRadius: 1.5).fill()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation; dragged = false }
    override func mouseDragged(with event: NSEvent) { if !dragged,let start,NSEvent.mouseLocation.x-start.x < -14 { dragged = true; open?() } }
    override func mouseUp(with event: NSEvent) { if !dragged { toggle?() }; start = nil }
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        if event.phase == .began { travel = 0 }
        travel += abs(event.scrollingDeltaX)
        if travel > 16 { open?(); travel = 0 }
    }
    override func swipe(with event: NSEvent) { if event.deltaX != 0 { open?() } }
    override func accessibilityLabel() -> String? { ZiloLanguage.text("悬停显示便签") }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { toggle?(); return true }
}
private final class NotesHostingView<Content: View>: NSHostingView<Content> {
    var onHide: (() -> Void)?
    var onEnter: (() -> Void)?; var onLeave: (() -> Void)?
    private var tracking: NSTrackingArea?
    private weak var trackingView: NSView?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTrackingAreas() }
    override func updateTrackingAreas() {
        if let tracking { trackingView?.removeTrackingArea(tracking) }
        // Track the native title bar too, so leaving through its top edge also tucks the drawer away.
        let target = window?.contentView?.superview ?? self
        let area = NSTrackingArea(rect: .zero,options: [.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner: self,userInfo: nil)
        target.addTrackingArea(area); tracking = area; trackingView = target; super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onLeave?() }
    override func swipe(with event: NSEvent) { if event.deltaX > 0 { onHide?() } else { super.swipe(with: event) } }
}

private struct NotesHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat],nextValue: () -> [String: CGFloat]) { value.merge(nextValue(),uniquingKeysWith: { _,new in new }) }
}
private extension View {
    func notesHeight(_ key: String) -> some View {
        background { GeometryReader { geometry in Color.clear.preference(key: NotesHeightKey.self,value: [key: geometry.size.height]) } }
    }
}

struct SideNotesView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var selection: SideNotesSelection
    @State private var search = ""
    @State private var trash = false
    @State private var trashHover = false
    @State private var previews = Set<UUID>()
    @State private var contentWidth: CGFloat = 320
    private var notes: [SideNote] { SideNotesLibrary.visible(store.sideNotes,tasks: store.tasks,search: search,trash: trash) }
    var body: some View {
        VStack(spacing: 0) {
            header.notesHeight("header")
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 10) {
                        if notes.isEmpty { emptyState }
                        ForEach(notes) { note in
                            PaperNoteCard(note: note,selection: selection,contentWidth: contentWidth,
                                          preview: Binding(get: { previews.contains(note.id) },set: { if $0 { previews.insert(note.id) } else { previews.remove(note.id) } })) { noteActions(note) }
                                .id(note.id)
                        }
                    }.padding(12).frame(maxWidth: .infinity).fixedSize(horizontal: false,vertical: true).notesHeight("cards")
                }.onAppear { reveal(reader) }.onChange(of: selection.reveal) { _,_ in reveal(reader) }
            }
        }
        .background(ListTheme.adaptive(0xFFFFFF,0x212225)).foregroundStyle(ListTheme.text)
        .onChange(of: trash) { _,value in SideNotesPanel.shared.updateTitle(trash: value) }
        .onPreferenceChange(NotesHeightKey.self) { heights in
            if let header = heights["header"],let cards = heights["cards"] { SideNotesPanel.shared.fitContent(header+cards) }
        }
        .background { GeometryReader { geometry in Color.clear.onAppear { contentWidth = geometry.size.width }.onChange(of: geometry.size.width) { _,width in contentWidth = width } } }
    }
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                TextField(trash ? "搜索已删除便签" : "搜索便签",text: $search).textFieldStyle(.plain).foregroundStyle(ListTheme.text).accessibilityLabel("搜索便签")
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
            }.font(.system(size: 12)).foregroundStyle(ListTheme.secondary).padding(.horizontal,10).frame(height: 32)
                .background(ListTheme.adaptive(0xF3F4F6,0x2C2D31),in: RoundedRectangle(cornerRadius: 8))
            Button(action: createNote) { Image(systemName: "square.and.pencil").font(.system(size: 15)).frame(width: 28,height: 32).contentShape(Rectangle()) }
                .buttonStyle(.plain).quietHover().help("新建便签").accessibilityLabel("新建便签")
            Button { trash.toggle(); search = "" } label: {
                Image(systemName: "trash").font(.system(size: 13,weight: .regular))
                    .foregroundStyle(trash ? ListTheme.accent : ListTheme.secondary).frame(width: 32,height: 32)
                    .background(trash ? ListTheme.accent.opacity(trashHover ? 0.16 : 0.1) : ListTheme.adaptive(trashHover ? 0xE9EBEF : 0xF3F4F6,trashHover ? 0x373940 : 0x2C2D31),in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(trash ? ListTheme.accent.opacity(0.12) : ListTheme.text.opacity(0.04),lineWidth: 0.5) }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).onHover { trashHover = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12),value: trashHover)
                .help(trash ? "返回便签" : "已删除便签").accessibilityLabel(trash ? "返回便签" : "已删除便签")
                .accessibilityAddTraits(trash ? .isSelected : [])
        }.padding(.horizontal,14).padding(.top,12).padding(.bottom,2)
    }
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: trash ? "trash" : "note.text").font(.system(size: 24,weight: .light)).foregroundStyle(ListTheme.secondary.opacity(0.7))
            Text(trash ? "没有已删除的便签" : search.isEmpty ? "随手记下一个想法" : "没有匹配的便签").font(.system(size: 12))
            if !trash && search.isEmpty { Button("新建便签",action: createNote).buttonStyle(.borderless) }
        }.foregroundStyle(ListTheme.secondary).frame(maxWidth: .infinity).frame(minHeight: 120)
    }
    private func createNote() { trash = false; search = ""; selection.selected = store.createSideNote(); selection.reveal = UUID() }
    @ViewBuilder private func noteActions(_ note: SideNote) -> some View {
        if note.deleted { Button("恢复便签",systemImage: "arrow.uturn.backward") { store.updateSideNote(note.id) { $0.deleted = false } } }
        else {
            Button(note.pinned ? "取消置顶" : "置顶",systemImage: "pin") { store.updateSideNote(note.id) { $0.pinned.toggle() } }
            Menu("颜色") {
                ForEach(SideNotePaper.allCases) { paper in
                    Toggle(isOn: Binding(get: { SideNotePaper(stored: note.color) == paper },set: { if $0 { store.updateSideNote(note.id) { $0.color = paper.rawValue } } })) {
                        Label { Text(LocalizedStringKey(paper.title)) } icon: { paper.swatch }
                    }
                }
            }
            if let task = note.document(tasks: store.tasks) {
                Button("复制内容",systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(task.notes,forType: .string) }
                Button("HTML 网页（.html）",systemImage: "square.and.arrow.up") { export(task) }
            }
            if let id = note.taskID { Button("打开关联任务",systemImage: "arrow.up.forward") { store.notificationTask = id; NSApp.activate(ignoringOtherApps: true) } }
            Divider(); Button("删除便签",systemImage: "trash",role: .destructive) { store.updateSideNote(note.id) { $0.deleted = true } }
        }
    }
    private func reveal(_ reader: ScrollViewProxy) {
        guard let id = selection.selected,let note = store.sideNotes.first(where: { $0.id == id }) else { return }
        trash = false; SideNotesPanel.shared.updateTitle(trash: false); search = ""; store.updateSideNote(id) { $0.folded = false }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { reader.scrollTo(id,anchor: .top) }
    }
    private func export(_ task: TaskItem) {
        let save = NSSavePanel(); save.allowedContentTypes = [.html]; save.nameFieldStringValue = HTMLDocument.filename(task.title)
        if save.runModal() == .OK,let url = save.url { do { try HTMLDocument.data(task: task,baseURL: store.persistence.root).write(to: url,options: .atomic) } catch { store.error = error.localizedDescription } }
    }
}

private struct PaperNoteCard<Actions: View>: View {
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var note: SideNote
    @ObservedObject var selection: SideNotesSelection
    var contentWidth: CGFloat
    @Binding var preview: Bool
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false
    private var document: TaskItem? { note.document(tasks: store.tasks) }
    private var displayTitle: String {
        let title = document?.title ?? note.title
        return title.isEmpty ? ZiloLanguage.text("无标题便签") : title
    }
    private var paper: SideNotePaper { SideNotePaper(stored: note.color) }
    private var dark: Bool { scheme == .dark }
    private var selected: Bool { selection.selected == note.id }
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            titleRow
            if !note.folded {
                if let document {
                    if note.taskID != nil || (!note.deleted && document.editingMode == .markdown) { tools(document) }
                    bodyContent(document).transition(.opacity)
                } else { Text("关联任务暂不可用，请同步后重试。").font(.caption).foregroundStyle(ListTheme.secondary).frame(height: 28,alignment: .topLeading) }
            }
        }.padding(12).frame(maxWidth: .infinity,alignment: .leading)
            .background(paper.color(dark: dark),in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? ListTheme.accent.opacity(dark ? 0.5 : 0.32) : ListTheme.text.opacity(hovering ? 0.16 : 0.07),lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(dark ? (hovering ? 0.15 : 0.08) : (hovering ? 0.065 : 0.025)),radius: hovering ? 7 : 3,x: 0,y: 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),value: hovering)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),value: note.color)
            .onHover { hovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture { selectAndExpand() }
            .onDrop(of: [UTType.text,UTType.url],isTargeted: nil) { providers in
                guard !note.deleted,let provider = providers.first else { return false }
                if provider.canLoadObject(ofClass: NSString.self) { _ = provider.loadObject(ofClass: String.self) { text,_ in if let text { append(text) } }; return true }
                if provider.canLoadObject(ofClass: NSURL.self) { _ = provider.loadObject(ofClass: URL.self) { url,_ in if let url { append(url.absoluteString) } }; return true }
                return false
            }
    }
    private var titleRow: some View {
        HStack(spacing: 4) {
            Button {
                setFolded(!note.folded)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10,weight: .semibold))
                    .rotationEffect(.degrees(note.folded ? 0 : 90)).animation(reduceMotion ? nil : .easeInOut(duration: 0.22),value: note.folded)
                    .foregroundStyle(ListTheme.secondary).frame(width: 28,height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).quietHover().accessibilityLabel(note.folded ? "展开便签" : "折叠便签")
            if note.folded {
                Button(action: selectAndExpand) {
                    Text(displayTitle)
                        .font(.system(size: 14,weight: .semibold)).foregroundStyle(ListTheme.text)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity,alignment: .leading).frame(minHeight: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(displayTitle).accessibilityHint("展开便签")
            } else if !note.deleted,document != nil {
                TextField("无标题便签",text: Binding(get: { document?.title ?? "" },set: { store.updateSideNoteDocument(note.id,title: $0) }))
                    .textFieldStyle(.plain).font(.system(size: 14,weight: .semibold)).accessibilityLabel("便签标题")
            } else { Text(displayTitle).font(.system(size: 14,weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity,alignment: .leading) }
            if note.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(ListTheme.secondary).help("置顶") }
            Menu(content: actions) { Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(ListTheme.secondary).frame(width: 28,height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).quietHover().accessibilityLabel("便签操作")
        }
    }
    private func tools(_ task: TaskItem) -> some View {
        HStack(spacing: 5) {
            if note.taskID != nil {
                Image(systemName: "link").font(.system(size: 10,weight: .medium)).frame(width: 22,height: 22)
                    .background(ListTheme.text.opacity(0.045),in: RoundedRectangle(cornerRadius: 5)).help("关联任务").accessibilityLabel("关联任务")
            }
            Spacer(minLength: 0)
            if !note.deleted && task.editingMode == .markdown {
                Picker("正文编辑方式",selection: $preview) { Text("编辑").tag(false); Text("预览").tag(true) }
                    .labelsHidden().pickerStyle(.segmented).frame(width: ZiloLanguage.locale.identifier.hasPrefix("en") ? 130 : 106).fixedSize()
            }
        }.foregroundStyle(ListTheme.secondary).frame(height: 24)
    }
    @ViewBuilder private func bodyContent(_ task: TaskItem) -> some View {
        if note.deleted { Text(TaskDocument.summary(task)).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading).frame(height: bodyHeight(task),alignment: .topLeading) }
        else if task.editingMode == .richText {
            RichTextEditor(text: task.notes,data: task.richText,paperStyle: true) { text,data in store.updateSideNoteDocument(note.id,text: text,richText: data) }.frame(height: editorHeight(task.notes))
        } else if preview {
            MarkdownPreviewView(source: task.notes,baseURL: store.persistence.root,paperBackground: paper.hex(dark: dark),compact: true).frame(height: max(64,editorHeight(task.notes)))
        } else {
            TextEditor(text: Binding(get: { document?.notes ?? "" },set: { store.updateSideNoteDocument(note.id,text: $0) }))
                .font(.system(size: 13)).scrollContentBackground(.hidden).frame(height: editorHeight(task.notes)).accessibilityLabel("便签内容")
        }
    }
    private func selectAndExpand() {
        selection.selected = note.id
        if note.folded { setFolded(false) }
    }
    private func bodyHeight(_ task: TaskItem) -> CGFloat {
        if note.deleted { let text = TaskDocument.summary(task); return text.isEmpty ? 0 : editorHeight(text) }
        return preview && task.editingMode == .markdown ? max(64,editorHeight(task.notes)) : editorHeight(task.notes)
    }
    private func setFolded(_ folded: Bool) {
        guard let current = store.sideNotes.first(where: { $0.id == note.id }),current.folded != folded else { return }
        let expansion: CGFloat
        if let task = document {
            let toolbar: CGFloat = note.taskID != nil || (!note.deleted && task.editingMode == .markdown) ? 32 : 0
            expansion = 8 + toolbar + bodyHeight(task)
        } else { expansion = 36 }
        if !reduceMotion { SideNotesPanel.shared.animateFoldResize(by: folded ? -expansion : expansion) }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            store.updateSideNote(note.id) { $0.folded = folded }
        }
    }
    private func editorHeight(_ text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(with: NSSize(width: max(180,contentWidth-58),height: 10000),options: [.usesLineFragmentOrigin,.usesFontLeading],attributes: [.font:NSFont.systemFont(ofSize: 13)])
        return min(260,max(40,ceil(bounds.height)+16))
    }
    private func append(_ text: String) {
        DispatchQueue.main.async {
            let old = document?.notes ?? ""
            store.updateSideNoteDocument(note.id,text: old + (old.isEmpty ? "" : "\n") + text)
        }
    }
}
