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
    let selection = SideNotesSelection()
    func configure(_ store: Store) {
        self.store = store
        DesktopBridge.notesAction = { [weak self] in self?.toggle() }
        updateEdge()
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
        animation = UUID(); presented = true
        if !wasVisible { panel.setFrame(NSRect(x: screen.maxX+8,y: target.minY,width: target.width,height: target.height),display: false) }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in context.duration = wasVisible ? 0 : 0.18; panel.animator().setFrame(target,display: true) }
    }
    func hide() {
        guard let panel else { return }
        presented = false; let token = UUID(); animation = token
        var target = panel.frame; target.origin.x = screen.maxX+8
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; panel.animator().setFrame(target,display: true) } completionHandler: { [weak self] in
            Task { @MainActor in guard let self,self.animation == token else { return }; self.panel?.orderOut(nil) }
        }
    }
    func toggle() {
        if panel?.isVisible == true && presented { hide() }
        else if let store { show(store) }
    }
    func fitContent(_ height: CGFloat) {
        guard height.isFinite,height > 0 else { return }
        // Preserve the top-right anchor while content grows or folds away.
        measuredHeight = height + 24
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,let panel = self.panel,self.presented,!panel.inLiveResize else { return }
            let target = SideNotesDockLayout.frame(screen: self.screen,width: panel.frame.width,contentHeight: self.measuredHeight)
            if abs(target.height-panel.frame.height) > 1 { panel.setFrame(target,display: true) }
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

struct SideNotesView: View {
    @EnvironmentObject private var store: Store
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
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "note.text").foregroundStyle(Color.accentColor)
                Text("便签").font(.system(size: 17,weight: .semibold)); Spacer()
                Button { SideNotesPanel.shared.hide() } label: { Image(systemName: "chevron.right").font(.system(size: 12,weight: .medium)).frame(width: 26,height: 28) }.buttonStyle(.plain).quietHover().help("隐藏便签").accessibilityLabel("隐藏便签")
                Menu {
                    Button("新建文件夹",systemImage: "folder.badge.plus") { folderName = ""; newFolder = true }
                    Toggle("显示屏幕边缘入口",isOn: $showEdge)
                    Toggle("便签回收站",isOn: $trash)
                    if let folderID { Button("删除文件夹，保留便签",systemImage: "folder.badge.minus") { if store.deleteNoteFolder(folderID) { self.folderID = nil } } }
                } label: { Image(systemName: "ellipsis").frame(width: 24,height: 26) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                Button { trash = false; search = ""; selection.selected = store.createSideNote(folderID: folderID); selection.reveal = UUID() } label: { Image(systemName: "square.and.pencil").font(.system(size: 16)).frame(width: 28,height: 28) }.buttonStyle(.plain).help("新建便签").accessibilityLabel("新建便签")
            }.padding(.horizontal,18).padding(.top,18).padding(.bottom,12)
            HStack {
                Menu {
                    Button("所有便签") { folderID = nil }
                    ForEach(folders) { folder in Button(folder.name) { folderID = folder.id } }
                } label: {
                    HStack(spacing: 7) { Image(systemName: "folder").foregroundStyle(ListTheme.secondary); Text(folders.first { $0.id == folderID }?.name ?? ZiloLanguage.text("所有便签")).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9,weight: .semibold)).foregroundStyle(ListTheme.secondary) }.font(.system(size: 12,weight: .medium)).padding(.horizontal,10).padding(.vertical,7).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 8))
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth: 240,alignment: .leading).accessibilityLabel("文件夹")
                Spacer()
                if trash { Text("回收站").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal,16).padding(.bottom,10)
            HStack(spacing: 8) { Image(systemName: "magnifyingglass"); TextField("搜索便签",text: $search).textFieldStyle(.plain); if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) } }.font(.system(size: 12)).foregroundStyle(ListTheme.secondary).padding(9).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal,16).padding(.bottom,12)
            }
            Divider()
            ScrollViewReader { reader in
                ScrollView { VStack(spacing: 12) {
                    if notes.isEmpty { VStack(spacing: 12) { Image(systemName: trash ? "trash" : "note.text").font(.system(size: 26,weight: .light)); Text(trash ? "没有已删除的便签" : search.isEmpty ? "随手记下一个想法" : "没有匹配的便签").font(.subheadline); if !trash && search.isEmpty { Button("新建便签") { selection.selected = store.createSideNote(folderID: folderID); selection.reveal = UUID() } } }.foregroundStyle(ListTheme.secondary).frame(maxWidth: .infinity).padding(.vertical,24) }
                    ForEach(notes) { note in card(note).id(note.id) }
                }.padding(12).fixedSize(horizontal: false,vertical: true) }.onAppear { reveal(reader) }.onChange(of: selection.reveal) { _,_ in reveal(reader) }
            }
            Divider()
            HStack { Text("自动保存"); Spacer(); Text("⌘⌥N").help("显示或隐藏便签") }.font(.system(size: 10)).foregroundStyle(ListTheme.secondary).padding(.horizontal,18).padding(.vertical,10)
        }.background(ListTheme.sidebar).foregroundStyle(ListTheme.text)
            .onAppear { SideNotesPanel.shared.fitContent(requiredHeight) }
            .onChange(of: requiredHeight) { _,height in SideNotesPanel.shared.fitContent(height) }
            .background { GeometryReader { geometry in Color.clear.onAppear { contentWidth = geometry.size.width }.onChange(of: geometry.size.width) { _,width in contentWidth = width } } }
            .onChange(of: showEdge) { _,_ in SideNotesPanel.shared.updateEdge() }
            .onChange(of: store.noteFolders) { _,_ in if let folderID,!folders.contains(where: { $0.id == folderID }) { self.folderID = nil } }
            .sheet(isPresented: $newFolder) { VStack(alignment: .leading,spacing: 16) { Text("新建文件夹").font(.headline); TextField("文件夹名称",text: $folderName).textFieldStyle(.roundedBorder).onSubmit(saveFolder); HStack { Spacer(); Button("取消") { newFolder = false }.keyboardShortcut(.cancelAction); Button("保存",action: saveFolder).keyboardShortcut(.defaultAction).disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }.padding(22).frame(width: 300) }
    }
    @ViewBuilder private func card(_ note: SideNote) -> some View {
        let task = note.document(tasks: store.tasks)
        VStack(alignment: .leading,spacing: 10) {
            HStack(alignment: .top,spacing: 8) {
                Button { store.updateSideNote(note.id) { $0.folded.toggle() } } label: { Image(systemName: note.folded ? "chevron.right" : "chevron.down").font(.system(size: 10,weight: .semibold)).frame(width: 20,height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel(note.folded ? "展开便签" : "折叠便签")
                if !note.deleted,task != nil {
                    TextField("无标题便签",text: Binding(get: { store.sideNotes.first { $0.id == note.id }?.document(tasks: store.tasks)?.title ?? "" },set: { store.updateSideNoteDocument(note.id,title: $0) })).textFieldStyle(.plain).font(.system(size: 14,weight: .semibold)).accessibilityLabel("便签标题")
                } else { Text(task?.title ?? note.title).font(.headline) }
                Spacer(minLength: 0)
                if note.pinned { Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor) }
                Menu { noteActions(note) } label: { Image(systemName: "ellipsis").frame(width: 24,height: 24) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).accessibilityLabel("便签操作")
            }
            if note.taskID != nil || (folderID == nil && folders.contains { $0.id == note.folderID }) {
                HStack(spacing: 6) {
                    if note.taskID != nil { badge("关联任务",symbol: "link",localized: true) }
                    if folderID == nil,let folder = folders.first(where: { $0.id == note.folderID }) { badge(folder.name,symbol: "folder") }
                }
            }
            if !note.folded {
                if let task {
                    if note.deleted { Text(TaskDocument.summary(task)).font(.system(size: 13)).textSelection(.enabled) }
                    else if task.editingMode == .richText {
                        RichTextEditor(text: task.notes,data: task.richText) { text,data in store.updateSideNoteDocument(note.id,text: text,richText: data) }.frame(height: editorHeight(task.notes))
                    } else {
                        Picker("正文编辑方式",selection: Binding(get: { previews.contains(note.id) },set: { if $0 { previews.insert(note.id) } else { previews.remove(note.id) } })) { Text("编辑").tag(false); Text("预览").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width: 118)
                        if previews.contains(note.id) { MarkdownPreviewView(source: task.notes,baseURL: store.persistence.root).frame(height: max(100,editorHeight(task.notes))) }
                        else { TextEditor(text: Binding(get: { store.sideNotes.first { $0.id == note.id }?.document(tasks: store.tasks)?.notes ?? "" },set: { store.updateSideNoteDocument(note.id,text: $0) })).font(.system(size: 13)).scrollContentBackground(.hidden).frame(height: editorHeight(task.notes)).accessibilityLabel("便签内容") }
                    }
                } else { Text("关联任务暂不可用，请同步后重试。").font(.caption).foregroundStyle(ListTheme.secondary) }
            }
        }.padding(13).background(noteColor(note.color),in: RoundedRectangle(cornerRadius: 12)).overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selection.selected == note.id ? ListTheme.accent.opacity(0.45) : ListTheme.separator.opacity(0.6),lineWidth: 1) }
            .onTapGesture { selection.selected = note.id }
            .onDrop(of: [UTType.text,UTType.url],isTargeted: nil) { providers in
                guard !note.deleted,let provider = providers.first else { return false }
                if provider.canLoadObject(ofClass: NSString.self) { _ = provider.loadObject(ofClass: String.self) { text,_ in if let text { append(note.id,text: text) } }; return true }
                if provider.canLoadObject(ofClass: NSURL.self) { _ = provider.loadObject(ofClass: URL.self) { url,_ in if let url { append(note.id,text: url.absoluteString) } }; return true }
                return false
            }
    }
    @ViewBuilder private func noteActions(_ note: SideNote) -> some View {
        if note.deleted { Button("恢复便签",systemImage: "arrow.uturn.backward") { store.updateSideNote(note.id) { $0.deleted = false } } }
        else {
            Button(note.pinned ? "取消置顶" : "置顶",systemImage: "pin") { store.updateSideNote(note.id) { $0.pinned.toggle() } }
            Button(note.folded ? "展开便签" : "折叠便签",systemImage: "rectangle.compress.vertical") { store.updateSideNote(note.id) { $0.folded.toggle() } }
            Menu("颜色") { ForEach(SideNotesLibrary.colors,id: \.self) { color in Button(LocalizedStringKey(colorName(color))) { store.updateSideNote(note.id) { $0.color = color } } } }
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
        withAnimation(.easeOut(duration: 0.18)) { reader.scrollTo(id,anchor: .top) }
    }
    private func saveFolder() { if let id = store.createNoteFolder(folderName) { folderID = id; newFolder = false } }
    private var requiredHeight: CGFloat {
        if notes.isEmpty { return 310 }
        return 194 + CGFloat(max(0,notes.count-1))*12 + notes.reduce(CGFloat(0)) { total,note in
            let badge = note.taskID != nil || (folderID == nil && folders.contains { $0.id == note.folderID })
            var height: CGFloat = 50 + (badge ? 28 : 0)
            if !note.folded,let task = note.document(tasks: store.tasks) {
                height += 10 + (task.editingMode == .markdown ? 34 : 0)
                height += previews.contains(note.id) ? max(100,editorHeight(task.notes)) : editorHeight(task.notes)
            }
            return total+height
        }
    }
    private func editorHeight(_ text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(with: NSSize(width: max(180,contentWidth-62),height: 10000),options: [.usesLineFragmentOrigin,.usesFontLeading],attributes: [.font:NSFont.systemFont(ofSize: 13)])
        return min(260,max(64,ceil(bounds.height)+24))
    }
    private func badge(_ title: String,symbol: String,localized: Bool = false) -> some View {
        HStack(spacing: 4) { Image(systemName: symbol); Text(localized ? ZiloLanguage.text(title) : title).lineLimit(1).truncationMode(.middle) }
            .font(.system(size: 10,weight: .medium)).foregroundStyle(ListTheme.secondary).padding(.horizontal,8).padding(.vertical,4).background(ListTheme.input,in: Capsule())
    }
    private func append(_ id: UUID,text: String) {
        DispatchQueue.main.async { let old = store.sideNotes.first { $0.id == id }?.document(tasks: store.tasks)?.notes ?? ""; store.updateSideNoteDocument(id,text: old + (old.isEmpty ? "" : "\n") + text) }
    }
    private func export(_ task: TaskItem) {
        let save = NSSavePanel(); save.allowedContentTypes = [.html]; save.nameFieldStringValue = HTMLDocument.filename(task.title)
        if save.runModal() == .OK,let url = save.url { do { try HTMLDocument.data(task: task,baseURL: store.persistence.root).write(to: url,options: .atomic) } catch { store.error = error.localizedDescription } }
    }
    private func noteColor(_ name: String) -> Color { name == "none" ? ListTheme.canvas : name.listColor.opacity(0.12) }
    private func colorName(_ name: String) -> String { ["none":"无颜色","yellow":"黄色","blue":"蓝色","green":"绿色","purple":"紫色","pink":"粉色"][name] ?? "无颜色" }
}
