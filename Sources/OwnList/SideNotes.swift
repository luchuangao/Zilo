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
    @Published var expanded: UUID?
}
enum SideNotesDockLayout {
    static func frame(screen: NSRect,width: CGFloat = 320,contentHeight: CGFloat) -> NSRect {
        let width = min(max(280,width),min(480,screen.width))
        let height = min(max(100,contentHeight),max(100,screen.height-32))
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
@MainActor final class SideNotesHoverBehavior: ObservableObject {
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
            guard !Task.isCancelled,let self else { return }
            // Leaving during editing or menu tracking must not lose the pending
            // close. Retry after protection ends without requiring another exit.
            while !Task.isCancelled && !self.containsPointer() {
                if self.canHide() { self.onHide(); return }
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            }
        }
    }
    func cancel() { openTask?.cancel(); closeTask?.cancel(); openTask = nil; closeTask = nil }
}

private final class FloatingNotesWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
            return !editing && self.menuDepth == 0 && self.panel?.inLiveResize != true && NSApp.modalWindow == nil
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
    var protectsNoteInteraction: Bool {
        menuDepth > 0 || NSApp.modalWindow != nil || panel?.inLiveResize == true
            || (panel?.isKeyWindow == true && panel?.firstResponder is NSTextView)
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
        if let taskID { selection.selected = store.linkSideNote(taskID: taskID); selection.expanded = selection.selected; selection.reveal = UUID() }
        if panel == nil {
            let window = FloatingNotesWindow(contentRect: SideNotesDockLayout.frame(screen: screen,contentHeight: measuredHeight),styleMask: [.borderless,.resizable,.nonactivatingPanel],backing: .buffered,defer: false)
            window.title = ZiloLanguage.text("便签"); window.isReleasedWhenClosed = false
            window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
            window.becomesKeyOnlyIfNeeded = true; window.delegate = self
            window.minSize = NSSize(width: 280,height: 100); window.maxSize = NSSize(width: 480,height: screen.height)
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
        presented = false; selection.expanded = nil; let token = UUID(); animation = token
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
    @State private var deletingNote: UUID?
    @State private var contentWidth: CGFloat = 320
    private var notes: [SideNote] { SideNotesLibrary.visible(store.sideNotes,tasks: store.tasks,search: search,trash: trash) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 4) {
                        if trash {
                            Button(action: returnToNotes) {
                                Label("返回便签",systemImage: "chevron.left")
                                    .font(.system(size: 12,weight: .medium))
                                    .frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,12).frame(height: 32)
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).foregroundStyle(ListTheme.accent)
                                .background(ListTheme.adaptive(0xFFFFFF,0x292A2D),in: RoundedRectangle(cornerRadius: 8))
                                .quietHover().accessibilityLabel("返回便签")
                        }
                        if notes.isEmpty { emptyState }
                        ForEach(notes) { note in
                            PaperNoteCard(note: note,selection: selection,contentWidth: contentWidth) { noteActions(note) }
                                .id(note.id)
                        }
                    }.padding(8).frame(maxWidth: .infinity).fixedSize(horizontal: false,vertical: true).notesHeight("cards")
                }.onAppear { reveal(reader) }.onChange(of: selection.reveal) { _,_ in reveal(reader) }
            }
        }
        .background(Color.clear).foregroundStyle(ListTheme.text)
        .contextMenu {
            Button("新建便签",systemImage: "square.and.pencil",action: createNote)
            Button(trash ? "返回便签" : "已删除便签",systemImage: "trash") { trash.toggle(); search = "" }
        }
        .alert("永久删除便签？",isPresented: Binding(get: { deletingNote != nil },set: { if !$0 { deletingNote = nil } })) {
            Button("取消",role: .cancel) { deletingNote = nil }
            Button("永久删除",role: .destructive) { if let id = deletingNote { _ = store.permanentlyDeleteSideNote(id) }; deletingNote = nil }
        } message: { Text("此操作无法撤销，关联任务会保留。") }
        .onChange(of: trash) { _,value in selection.expanded = nil; SideNotesPanel.shared.updateTitle(trash: value) }
        .onPreferenceChange(NotesHeightKey.self) { heights in
            if let cards = heights["cards"] { SideNotesPanel.shared.fitContent(cards) }
        }
        .background { GeometryReader { geometry in Color.clear.onAppear { contentWidth = geometry.size.width }.onChange(of: geometry.size.width) { _,width in contentWidth = width } } }
    }
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: trash ? "trash" : "note.text").font(.system(size: 24,weight: .light)).foregroundStyle(ListTheme.secondary.opacity(0.7))
            Text(trash ? "没有已删除的便签" : search.isEmpty ? "随手记下一个想法" : "没有匹配的便签").font(.system(size: 12))
            if !trash && search.isEmpty { Button("新建便签",action: createNote).buttonStyle(.borderless) }
        }.foregroundStyle(ListTheme.secondary).frame(maxWidth: .infinity).frame(minHeight: 120)
            .background(ListTheme.adaptive(0xFFFFFF,0x292A2D),in: RoundedRectangle(cornerRadius: 12))
    }
    private func returnToNotes() { trash = false; search = ""; selection.expanded = nil }
    private func createNote() { trash = false; search = ""; selection.selected = store.createSideNote(); selection.expanded = selection.selected; selection.reveal = UUID() }
    @ViewBuilder private func noteActions(_ note: SideNote) -> some View {
        if note.deleted {
            Button("恢复便签",systemImage: "arrow.uturn.backward") { store.updateSideNote(note.id) { $0.deleted = false } }
            Button("返回便签",systemImage: "chevron.left",action: returnToNotes)
            Divider(); Button("永久删除",systemImage: "trash.slash",role: .destructive) { deletingNote = note.id }
        }
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
            }
            if let id = note.taskID { Button("打开关联任务",systemImage: "arrow.up.forward") { store.notificationTask = id; NSApp.activate(ignoringOtherApps: true) } }
            Divider(); Button("新建便签",systemImage: "square.and.pencil",action: createNote)
            Button("已删除便签",systemImage: "trash") { trash = true }
            Divider(); Button("删除便签",systemImage: "trash",role: .destructive) { store.updateSideNote(note.id) { $0.deleted = true } }
        }
    }
    private func reveal(_ reader: ScrollViewProxy) {
        guard let id = selection.selected,store.sideNotes.contains(where: { $0.id == id }) else { return }
        trash = false; SideNotesPanel.shared.updateTitle(trash: false); search = ""
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { reader.scrollTo(id,anchor: .top) }
    }

}

private struct PaperNoteCard<Actions: View>: View {
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var note: SideNote
    @ObservedObject var selection: SideNotesSelection
    var contentWidth: CGFloat
    @State private var preview = false
    // Hover is presentation state: it never writes a note or changes its
    // modification date. Every drawer session starts with folded cards.
    private var folded: Bool { selection.expanded != note.id }
    @StateObject private var hover = SideNotesHoverBehavior(openDelay: 120_000_000,closeDelay: 320_000_000)
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
            if !folded {
                if let document {
                    bodyContent(document).transition(.opacity)
                    if note.taskID != nil || (!note.deleted && document.editingMode == .markdown) { tools(document) }
                } else { Text("关联任务暂不可用，请同步后重试。").font(.caption).foregroundStyle(ListTheme.secondary).frame(height: 28,alignment: .topLeading) }
            }
        }.padding(12).frame(maxWidth: .infinity,alignment: .leading)
            .background(paper.color(dark: dark),in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? ListTheme.accent.opacity(dark ? 0.5 : 0.32) : ListTheme.text.opacity(hovering ? 0.16 : 0.07),lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(dark ? (hovering ? 0.15 : 0.08) : (hovering ? 0.065 : 0.025)),radius: hovering ? 7 : 3,x: 0,y: 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),value: hovering)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),value: note.color)
            .onChange(of: folded) { _,value in animateFoldResize(value) }
            .onChange(of: selection.reveal) { _,_ in if selected { selectAndExpand() } }
            .onDisappear {
                hover.cancel(); hover.onShow = {}; hover.onHide = {}; hover.containsPointer = { false }; hover.canHide = { true }
            }
            .background {
                NotePointerTracking(onChange: trackPointer)
            }
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
                hover.cancel(); setFolded(!folded)
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10,weight: .semibold))
                    .rotationEffect(.degrees(folded ? 0 : 90)).animation(reduceMotion ? nil : .easeInOut(duration: 0.22),value: folded)
                    .foregroundStyle(ListTheme.secondary).frame(width: 28,height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).quietHover().accessibilityLabel(folded ? "展开便签" : "折叠便签")
            if folded {
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
                .font(.system(size: 13)).scrollContentBackground(.hidden).frame(height: max(64,editorHeight(task.notes))).accessibilityLabel("便签内容")
        }
    }
    private func selectAndExpand() {
        if selection.selected != note.id { selection.selected = note.id }
        if folded { setFolded(false) }
    }
    private func bodyHeight(_ task: TaskItem) -> CGFloat {
        if note.deleted { let text = TaskDocument.summary(task); return text.isEmpty ? 0 : editorHeight(text) }
        return task.editingMode == .markdown ? max(64,editorHeight(task.notes)) : editorHeight(task.notes)
    }
    private func trackPointer(_ inside: Bool) {
        hovering = inside
        hover.containsPointer = { hovering }
        hover.canHide = { !SideNotesPanel.shared.protectsNoteInteraction }
        hover.onShow = { setFolded(false) }
        hover.onHide = { setFolded(true) }
        if inside { hover.enterEdge() } else { hover.leave() }
    }
    private func setFolded(_ folded: Bool) {
        guard self.folded != folded else { return }
        if !folded { selection.selected = note.id }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            selection.expanded = folded ? nil : note.id
        }
    }
    private func animateFoldResize(_ folded: Bool) {
        let expansion: CGFloat
        if let task = document {
            let toolbar: CGFloat = note.taskID != nil || (!note.deleted && task.editingMode == .markdown) ? 32 : 0
            expansion = 8 + toolbar + bodyHeight(task)
        } else { expansion = 36 }
        if !reduceMotion { SideNotesPanel.shared.animateFoldResize(by: folded ? -expansion : expansion) }
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

private struct NotePointerTracking: NSViewRepresentable {
    var onChange: (Bool) -> Void
    func makeNSView(context: Context) -> NotePointerView { let view = NotePointerView(); view.changed = onChange; return view }
    func updateNSView(_ view: NotePointerView,context: Context) { view.changed = onChange }
}
private final class NotePointerView: NSView {
    var changed: (Bool) -> Void = { _ in }
    private var area: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero,options: [.activeAlways,.mouseEnteredAndExited,.inVisibleRect],owner: self,userInfo: nil)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { changed(true) }
    override func mouseExited(with event: NSEvent) { changed(false) }
}
