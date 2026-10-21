import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

@MainActor final class SideNotesPanel {
    static let shared = SideNotesPanel()
    private var panel: NSPanel?
    private var edge: NSPanel?
    private weak var store: Store?
    private var presented = false
    private var animation = UUID()
    private var measuredHeight: CGFloat = 300
    private var resizeWork: DispatchWorkItem?
    private var animateResize = false
    let selection = SideNotesSelection()
    func configure(_ store: Store) {
        self.store = store
        DesktopBridge.notesAction = { [weak self] in self?.toggle() }
        updateEdge()
    }
    private var chromeHeight: CGFloat {
        guard let panel else { return 28 }
        return panel.frame.height-panel.contentRect(forFrameRect: panel.frame).height
    }
    private var screen: NSRect { panel?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0,y: 0,width: 1440,height: 900) }
    func show(_ store: Store,taskID: UUID? = nil) {
        self.store = store
        if let taskID { selection.selected = store.linkSideNote(taskID: taskID); selection.reveal = UUID() }
        if panel == nil {
            let window = NSPanel(contentRect: SideNotesDockLayout.frame(screen: screen,contentHeight: measuredHeight),styleMask: [.titled,.closable,.resizable,.nonactivatingPanel],backing: .buffered,defer: false)
            window.title = ZiloLanguage.text("便签"); window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 280,height: 240); window.maxSize = NSSize(width: 480,height: screen.height)
            window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; window.hidesOnDeactivate = false
            let host = NotesHostingView(rootView: SideNotesView(selection: selection).environmentObject(store).environment(\.locale,ZiloLanguage.locale).themeAppearance())
            host.onHide = { [weak self] in self?.hide() }; window.contentView = host
            panel = window
        }
        guard let panel else { return }
        let target = SideNotesDockLayout.frame(screen: screen,width: panel.frame.width,contentHeight: measuredHeight)
        let wasVisible = panel.isVisible && presented
        let token = UUID(); animation = token; presented = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !wasVisible && !reduceMotion { panel.setFrame(NSRect(x: screen.maxX+8,y: target.minY,width: target.width,height: target.height),display: false) }
        panel.makeKeyAndOrderFront(nil)
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
    func animateNextResize() { animateResize = true }
    func fitContent(_ height: CGFloat) {
        guard height.isFinite,height > 0 else { return }
        // Preserve the top-right anchor while content grows or folds away.
        measuredHeight = height + chromeHeight
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,let panel = self.panel,self.presented,!panel.inLiveResize else { return }
            let target = SideNotesDockLayout.frame(screen: self.screen,width: panel.frame.width,contentHeight: self.measuredHeight)
            let animated = self.animateResize && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.animateResize = false
            if abs(target.height-panel.frame.height) > 1 {
                if animated {
                    let token = self.animation
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.18; panel.animator().setFrame(target,display: true)
                    } completionHandler: { [weak self] in
                        Task { @MainActor in
                            guard let self,self.animation == token,self.presented,let panel = self.panel,!panel.inLiveResize else { return }
                            // Typing or another fold can update the measured size mid-animation.
                            let fitted = SideNotesDockLayout.frame(screen: self.screen,width: panel.frame.width,contentHeight: self.measuredHeight)
                            if abs(fitted.height-panel.frame.height) > 1 { panel.setFrame(fitted,display: true) }
                        }
                    }
                } else { panel.setFrame(target,display: true) }
            }
        }
        resizeWork = work; DispatchQueue.main.asyncAfter(deadline: .now()+0.06,execute: work)
    }
    func updateEdge() {
        guard UserDefaults.standard.object(forKey: "sideNotesEdgeEnabled") as? Bool != false,let screen = NSScreen.main?.visibleFrame else { edge?.orderOut(nil); return }
        if edge == nil {
            let tab = NSPanel(contentRect: .zero,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
            tab.backgroundColor = .clear; tab.isOpaque = false; tab.hasShadow = false; tab.level = .floating
            tab.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; tab.hidesOnDeactivate = false
            let handle = NotesEdgeHandle(); handle.open = { [weak self] in if let self,let store = self.store { self.show(store) } }
            handle.toggle = { [weak self] in self?.toggle() }; tab.contentView = handle; edge = tab
        }
        edge?.setFrame(NSRect(x: screen.maxX-18,y: screen.midY-32,width: 18,height: 64),display: true)
        edge?.orderFrontRegardless()
    }
}

private final class NotesEdgeHandle: NSView {
    var open: (() -> Void)?; var toggle: (() -> Void)?
    private var start: NSPoint?; private var dragged = false; private var travel: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.75).setFill(); NSBezierPath(roundedRect: bounds,xRadius: 6,yRadius: 6).fill()
        NSColor.white.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect: NSRect(x: 7,y: 21,width: 3,height: 22),xRadius: 1.5,yRadius: 1.5).fill()
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
    override func accessibilityLabel() -> String? { ZiloLanguage.text("向左滑出便签") }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { toggle?(); return true }
}
private final class NotesHostingView<Content: View>: NSHostingView<Content> {
    var onHide: (() -> Void)?
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
    @AppStorage("sideNotesEdgeEnabled") private var showEdge = true
    @State private var folderID: UUID?
    @State private var search = ""
    @State private var trash = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var previews = Set<UUID>()
    @State private var contentWidth: CGFloat = 320
    private var notes: [SideNote] { SideNotesLibrary.visible(store.sideNotes,tasks: store.tasks,folderID: folderID,search: search,trash: trash) }
    private var folders: [SideNoteFolder] { store.noteFolders.filter { !$0.deleted }.sorted { $0.order < $1.order } }
    private var folderTitle: String { trash ? ZiloLanguage.text("回收站") : folders.first { $0.id == folderID }?.name ?? ZiloLanguage.text("所有便签") }
    var body: some View {
        VStack(spacing: 0) {
            header.notesHeight("header")
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 10) {
                        if notes.isEmpty { emptyState }
                        ForEach(notes) { note in
                            PaperNoteCard(note: note,selection: selection,
                                          folder: folderID == nil ? folders.first { $0.id == note.folderID }?.name : nil,
                                          contentWidth: contentWidth,
                                          preview: Binding(get: { previews.contains(note.id) },set: { if $0 { previews.insert(note.id) } else { previews.remove(note.id) } })) { noteActions(note) }
                                .id(note.id)
                        }
                    }.padding(12).frame(maxWidth: .infinity).fixedSize(horizontal: false,vertical: true).notesHeight("cards")
                }.onAppear { reveal(reader) }.onChange(of: selection.reveal) { _,_ in reveal(reader) }
            }
        }
        .background(ListTheme.adaptive(0xF5F4F1,0x212225)).foregroundStyle(ListTheme.text)
        .onPreferenceChange(NotesHeightKey.self) { heights in
            if let header = heights["header"],let cards = heights["cards"] { SideNotesPanel.shared.fitContent(header+cards) }
        }
        .background { GeometryReader { geometry in Color.clear.onAppear { contentWidth = geometry.size.width }.onChange(of: geometry.size.width) { _,width in contentWidth = width } } }
        .onChange(of: showEdge) { _,_ in SideNotesPanel.shared.updateEdge() }
        .onChange(of: store.noteFolders) { _,_ in if let folderID,!folders.contains(where: { $0.id == folderID }) { self.folderID = nil } }
        .sheet(isPresented: $newFolder) {
            VStack(alignment: .leading,spacing: 16) {
                Text("新建文件夹").font(.headline)
                TextField("文件夹名称",text: $folderName).textFieldStyle(.roundedBorder).onSubmit(saveFolder)
                HStack { Spacer(); Button("取消") { newFolder = false }.keyboardShortcut(.cancelAction); Button("保存",action: saveFolder).keyboardShortcut(.defaultAction).disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(22).frame(width: 300)
        }
    }
    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                Menu {
                    Button("所有便签") { trash = false; folderID = nil }
                    ForEach(folders) { folder in Button(folder.name) { trash = false; folderID = folder.id } }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: trash ? "trash" : "folder").font(.system(size: 14)).foregroundStyle(ListTheme.secondary)
                        Text(folderTitle).font(.system(size: 14,weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.system(size: 8,weight: .semibold)).foregroundStyle(ListTheme.secondary)
                        Spacer(minLength: 0)
                    }.foregroundStyle(ListTheme.text).frame(height: 28).contentShape(Rectangle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth: .infinity,alignment: .leading).help(folderTitle).accessibilityLabel("文件夹")
                Image(systemName: store.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(ListTheme.secondary.opacity(0.65)).frame(width: 18)
                    .help(store.error ?? ZiloLanguage.text("自动保存")).accessibilityLabel(store.error ?? ZiloLanguage.text("自动保存"))
                Button { SideNotesPanel.shared.hide() } label: { Image(systemName: "chevron.right").font(.system(size: 12,weight: .medium)).frame(width: 28,height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).quietHover().help("隐藏便签").accessibilityLabel("隐藏便签")
                Menu {
                    Button("新建文件夹",systemImage: "folder.badge.plus") { folderName = ""; newFolder = true }
                    Toggle("显示屏幕边缘入口",isOn: $showEdge)
                    Toggle("便签回收站",isOn: $trash)
                    if let folderID { Button("删除文件夹，保留便签",systemImage: "folder.badge.minus") { if store.deleteNoteFolder(folderID) { self.folderID = nil } } }
                    Divider()
                    Button { SideNotesPanel.shared.toggle() } label: { Text("显示或隐藏便签　⌘⌥N") }
                } label: { Image(systemName: "ellipsis").frame(width: 28,height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28).quietHover().accessibilityLabel("便签操作")
                Button(action: createNote) { Image(systemName: "square.and.pencil").font(.system(size: 15)).frame(width: 28,height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).quietHover().help("新建便签").accessibilityLabel("新建便签")
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                TextField("搜索便签",text: $search).textFieldStyle(.plain).foregroundStyle(ListTheme.text).accessibilityLabel("搜索便签")
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
            }.font(.system(size: 12)).foregroundStyle(ListTheme.secondary).padding(.horizontal,10).frame(height: 32)
                .background(ListTheme.adaptive(0xEAE9E5,0x2C2D31).opacity(0.7),in: RoundedRectangle(cornerRadius: 8))
        }.padding(.horizontal,14).padding(.top,12).padding(.bottom,2)
    }
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: trash ? "trash" : "note.text").font(.system(size: 24,weight: .light)).foregroundStyle(ListTheme.secondary.opacity(0.7))
            Text(trash ? "没有已删除的便签" : search.isEmpty ? "随手记下一个想法" : "没有匹配的便签").font(.system(size: 12))
            if !trash && search.isEmpty { Button("新建便签",action: createNote).buttonStyle(.borderless) }
        }.foregroundStyle(ListTheme.secondary).frame(maxWidth: .infinity).frame(minHeight: 120)
    }
    private func createNote() { trash = false; search = ""; selection.selected = store.createSideNote(folderID: folderID); selection.reveal = UUID() }
    @ViewBuilder private func noteActions(_ note: SideNote) -> some View {
        if note.deleted { Button("恢复便签",systemImage: "arrow.uturn.backward") { store.updateSideNote(note.id) { $0.deleted = false } } }
        else {
            Button(note.pinned ? "取消置顶" : "置顶",systemImage: "pin") { store.updateSideNote(note.id) { $0.pinned.toggle() } }
            Button(note.folded ? "展开便签" : "折叠便签",systemImage: "rectangle.compress.vertical") { SideNotesPanel.shared.animateNextResize(); store.updateSideNote(note.id) { $0.folded.toggle() } }
            Menu("颜色") {
                ForEach(SideNotePaper.allCases) { paper in
                    Toggle(isOn: Binding(get: { SideNotePaper(stored: note.color) == paper },set: { if $0 { store.updateSideNote(note.id) { $0.color = paper.rawValue } } })) {
                        Label { Text(LocalizedStringKey(paper.title)) } icon: { paper.swatch }
                    }
                }
            }
            Menu("移动到文件夹") { Button("未分类") { store.updateSideNote(note.id) { $0.folderID = nil } }; ForEach(folders) { folder in Button(folder.name) { store.updateSideNote(note.id) { $0.folderID = folder.id } } } }
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
        folderID = note.folderID; trash = false; search = ""; store.updateSideNote(id) { $0.folded = false }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { reader.scrollTo(id,anchor: .top) }
    }
    private func saveFolder() { if let id = store.createNoteFolder(folderName) { folderID = id; newFolder = false } }
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
    var folder: String?
    var contentWidth: CGFloat
    @Binding var preview: Bool
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false
    private var document: TaskItem? { note.document(tasks: store.tasks) }
    private var paper: SideNotePaper { SideNotePaper(stored: note.color) }
    private var dark: Bool { scheme == .dark }
    private var selected: Bool { selection.selected == note.id }
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            titleRow
            if !note.folded {
                if let document {
                    if note.taskID != nil || folder != nil || (!note.deleted && document.editingMode == .markdown) { tools(document) }
                    bodyContent(document).transition(.opacity)
                } else { Text("关联任务暂不可用，请同步后重试。").font(.caption).foregroundStyle(ListTheme.secondary) }
            }
        }.padding(12).frame(maxWidth: .infinity,alignment: .leading)
            .background(paper.color(dark: dark),in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? ListTheme.accent.opacity(dark ? 0.5 : 0.32) : ListTheme.text.opacity(hovering ? 0.16 : 0.07),lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(dark ? (hovering ? 0.15 : 0.08) : (hovering ? 0.065 : 0.025)),radius: hovering ? 7 : 3,x: 0,y: 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),value: hovering)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),value: note.color)
            .onHover { hovering = $0 }
            .onTapGesture { selection.selected = note.id }
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
                SideNotesPanel.shared.animateNextResize()
                store.updateSideNote(note.id) { $0.folded.toggle() }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 10,weight: .semibold))
                    .rotationEffect(.degrees(note.folded ? 0 : 90)).animation(reduceMotion ? nil : .easeOut(duration: 0.18),value: note.folded)
                    .foregroundStyle(ListTheme.secondary).frame(width: 28,height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).quietHover().accessibilityLabel(note.folded ? "展开便签" : "折叠便签")
            if !note.deleted,document != nil {
                TextField("无标题便签",text: Binding(get: { document?.title ?? "" },set: { store.updateSideNoteDocument(note.id,title: $0) }))
                    .textFieldStyle(.plain).font(.system(size: 14,weight: .semibold)).accessibilityLabel("便签标题")
            } else { Text(document?.title ?? note.title).font(.system(size: 14,weight: .semibold)).lineLimit(1) }
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
            if let folder {
                HStack(spacing: 3) { Image(systemName: "folder"); Text(folder).lineLimit(1).truncationMode(.middle) }
                    .font(.system(size: 10,weight: .medium)).padding(.horizontal,6).frame(height: 22).frame(maxWidth: 80)
                    .background(ListTheme.text.opacity(0.045),in: RoundedRectangle(cornerRadius: 5)).help(folder)
            }
            Spacer(minLength: 0)
            if !note.deleted && task.editingMode == .markdown {
                Picker("正文编辑方式",selection: $preview) { Text("编辑").tag(false); Text("预览").tag(true) }
                    .labelsHidden().pickerStyle(.segmented).frame(width: ZiloLanguage.locale.identifier.hasPrefix("en") ? 130 : 106).fixedSize()
            }
        }.foregroundStyle(ListTheme.secondary).frame(height: 24)
    }
    @ViewBuilder private func bodyContent(_ task: TaskItem) -> some View {
        if note.deleted { Text(TaskDocument.summary(task)).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading) }
        else if task.editingMode == .richText {
            RichTextEditor(text: task.notes,data: task.richText,paperStyle: true) { text,data in store.updateSideNoteDocument(note.id,text: text,richText: data) }.frame(height: editorHeight(task.notes))
        } else if preview {
            MarkdownPreviewView(source: task.notes,baseURL: store.persistence.root,paperBackground: paper.hex(dark: dark),compact: true).frame(height: max(64,editorHeight(task.notes)))
        } else {
            TextEditor(text: Binding(get: { document?.notes ?? "" },set: { store.updateSideNoteDocument(note.id,text: $0) }))
                .font(.system(size: 13)).scrollContentBackground(.hidden).frame(height: editorHeight(task.notes)).accessibilityLabel("便签内容")
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
