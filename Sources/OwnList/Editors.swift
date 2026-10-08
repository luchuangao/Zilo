import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TaskDetailView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var focus: FocusTimer
    @StateObject private var document = DocumentEditorController()
    @State private var showDate = false
    @State private var showOrganization = false
    @State private var showFormatting = false
    @State private var showChecks = false
    @State private var showChildren = false
    @AppStorage("markdownPreviewVisible") private var previewMarkdown = true
    @State private var bodyHeight: CGFloat = 26
    @State private var hoveredCheck: UUID?
    @State private var childTitle = ""
    @State private var checkTitle = ""
    @State private var showHistory = false
    @State private var showLink = false
    @State private var linkTitle = ""
    @State private var linkAddress = ""
    @State private var customReminder = 45.0
    @FocusState private var focusedEntry: String?
    var task: TaskItem? { store.tasks.first { $0.id == store.selectedTask } }
    func binding<T>(_ path: WritableKeyPath<TaskItem,T>,default value: T) -> Binding<T> {
        Binding(get: { task?[keyPath: path] ?? value },set: { new in if let id = task?.id { store.mutate(id) { $0[keyPath: path] = new } } })
    }
    var body: some View {
        Group {
            if let task {
                GeometryReader { geometry in
                    HSplitView {
                        detailContent(task,documentHeight: max(220,geometry.size.height - (showFormatting ? 270 : 225)))
                            .ignoresSafeArea(.container,edges: .top).frame(minWidth: 300,maxWidth: .infinity,maxHeight: .infinity)
                        if task.editingMode == .markdown && previewMarkdown {
                            previewPane(task).ignoresSafeArea(.container,edges: .top).frame(minWidth: 260,idealWidth: 340,maxWidth: .infinity,maxHeight: .infinity)
                        }
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showHistory) { HistoryView(taskID: task.id).environmentObject(store) }
                .sheet(isPresented: $showLink) { linkEditor }
            } else {
                QuietEmptyState(title: "选择一个任务",message: "查看详细内容、安排时间或开始专注",symbol: "square.and.pencil")
            }
        }.frame(minWidth: task?.editingMode == .markdown && previewMarkdown ? 540 : 340,maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
            .background(ListTheme.canvas)
            .onAppear(perform: resetEditor)
            .onChange(of: store.selectedTask) { _,_ in resetEditor() }
    }
    func resetEditor() {
        childTitle = ""; checkTitle = ""; focusedEntry = nil
        showDate = false; showOrganization = false; showChecks = false; showChildren = false; showLink = false
        bodyHeight = 26; hoveredCheck = nil
    }
    func detailContent(_ task: TaskItem,documentHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            header(task)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading,spacing: 10) {
                        HStack(alignment: .top) {
                            TextField("任务标题",text: binding(\.title,default: ""),axis: .vertical)
                                .font(.system(size: 18,weight: .semibold)).textFieldStyle(.plain)
                            Button { beginEntry("check") } label: { Image(systemName: "checklist").font(.system(size: 16)) }
                                .help("添加检查项").accessibilityLabel("添加检查项").foregroundStyle(.secondary)
                        }.padding(.bottom,2)
                        documentBody(task,height: documentHeight)
                        relatedItems(task)
                        if !task.tags.isEmpty {
                            Button { showOrganization = true } label: { Label(task.tags.map { "#" + $0 }.joined(separator: "  "),systemImage: "tag").font(.callout).foregroundStyle(.secondary) }
                        }
                        if let parent = task.parentID { Button("返回父任务") { store.selectedTask = parent } }
                    }.padding(.horizontal,24).padding(.top,18).padding(.bottom,24)
                }
                .onChange(of: focusedEntry) { _,entry in if let entry { reader.scrollTo(entry,anchor: .bottom) } }
            }.id(task.id)
            if showFormatting { formattingBar(task).padding(.horizontal,20).padding(.bottom,12) }
            footer(task)
        }
    }
    func changeMode(_ mode: DocumentEditingMode) {
        guard let id = task?.id, task?.editingMode != mode else { return }
        document.editor?.unmarkText(); document.editor?.didChangeText()
        guard var current = store.tasks.first(where: { $0.id == id }) else { return }
        do { TaskDocument.switchMode(&current,to: mode,baseURL: store.persistence.root); try store.externalizeDocumentImages(&current); store.save(current) } catch { store.error = error.localizedDescription }
        document.activeFormats = []
    }
    func previewPane(_ task: TaskItem) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label("Markdown 预览",systemImage: "doc.richtext").font(.system(size: 13,weight: .medium))
                Spacer()
                Button { previewMarkdown = false } label: { Image(systemName: "xmark").font(.system(size: 11)) }.accessibilityLabel("关闭右侧预览")
            }.foregroundStyle(.secondary).padding(.horizontal,18).frame(height: 52)
            Divider()
            MarkdownPreviewView(source: task.notes,baseURL: store.persistence.root).padding(20)
        }.background(ListTheme.canvas)
    }
    func beginEntry(_ entry: String) {
        if entry == "check" { showChecks = true } else { showChildren = true }
        DispatchQueue.main.async { focusedEntry = entry }
    }
    func header(_ task: TaskItem) -> some View {
        HStack(spacing: 12) {
            Button { store.complete(task.id) } label: { Image(systemName: task.completed ? "checkmark.square.fill" : "square").font(.system(size: 19)).foregroundStyle(task.completed ? Color.accentColor : ListTheme.secondary) }
                .accessibilityLabel(task.completed ? "取消完成" : "完成任务").frame(width: 22,height: 30)
            Rectangle().fill(ListTheme.separator).frame(width: 1,height: 20)
            Button { showDate.toggle() } label: {
                Label(task.due.map { $0.formatted(date: .numeric,time: task.allDay ? .omitted : .shortened) } ?? "设置日期",systemImage: "calendar")
                    .foregroundStyle(task.due == nil ? ListTheme.secondary : .accentColor).lineLimit(1)
            }.popover(isPresented: $showDate) { ScrollView { dateSettings(task).padding(20) }.frame(width: 370,height: 540) }
            Spacer(minLength: 12)
            Menu {
                ForEach(0...3,id: \.self) { value in Button(["无优先级","低优先级","中优先级","高优先级"][value]) { store.mutate(task.id) { $0.priority = value } } }
            } label: {
                Image(systemName: task.priority == 0 ? "flag" : "flag.fill").font(.system(size: 18))
                    .foregroundStyle(task.priority == 3 ? "red".listColor : task.priority == 2 ? "orange".listColor : task.priority == 1 ? Color.accentColor : ListTheme.secondary)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(task.priority == 3 ? .red : task.priority == 2 ? .orange : task.priority == 1 ? .blue : .gray).fixedSize().help("优先级").accessibilityLabel("优先级")
        }.padding(.horizontal,24).frame(height: 52)
    }
    @ViewBuilder func documentBody(_ task: TaskItem,height: CGFloat) -> some View {
            HStack(alignment: .top,spacing: 6) {
                Menu {
                    Button("检查项",systemImage: "checklist") { beginEntry("check") }
                    Button("子任务",systemImage: "arrow.turn.down.right") { beginEntry("child") }
                    Button("附件",systemImage: "paperclip") { attach(task) }
                    Button("图片",systemImage: "photo") { insertImages() }
                    Button("Markdown 文件",systemImage: "doc.text") { insertMarkdown() }
                    Divider()
                    ForEach([DocumentFormat.heading,.bullet,.numbered,.quote,.codeBlock,.link],id: \.self) { format in
                        Button(format.title,systemImage: format.symbol) { applyFormat(format) }
                    }
                } label: { Image(systemName: "plus").foregroundStyle(.tertiary).frame(width: 14,height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.gray).fixedSize().help("插入内容").accessibilityLabel("插入内容")
                DetailDocumentEditor(text: task.notes,data: task.richText,rich: task.editingMode == .richText,scrolling: true,onError: { store.error = $0 },imageReference: { try store.saveDocumentImage($0,name: $1,to: task.id) },baseURL: store.persistence.root,controller: document,height: $bodyHeight) { text,data in
                    store.mutate(task.id) { $0.notes = text; $0.richText = data }
                }.id(task.editingMode).frame(height: height).overlay(alignment: .topLeading) {
                    if task.notes.isEmpty { Text(task.editingMode == .markdown ? "输入 Markdown 源码…" : "输入内容，支持 Markdown 快捷语法…").font(.system(size: 14)).foregroundStyle(.tertiary).padding(.top,3).allowsHitTesting(false) }
                }
            }.padding(.leading,-20)
    }
    @ViewBuilder func relatedItems(_ task: TaskItem) -> some View {
        if !task.checks.isEmpty || showChecks {
            VStack(alignment: .leading,spacing: 0) {
                ForEach(task.checks) { check in checkRow(task,check: check) }
                if showChecks {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").foregroundStyle(.tertiary).frame(width: 18)
                        TextField("添加检查项，回车继续",text: $checkTitle).textFieldStyle(.plain).focused($focusedEntry,equals: "check")
                            .onSubmit { submitChecks(task) }
                            .onExitCommand { closeCheckEntry() }
                        Button { closeCheckEntry() } label: { Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary) }
                            .help("关闭检查项输入").accessibilityLabel("关闭检查项输入")
                    }.frame(minHeight: 36).id("check")
                } else {
                    Button { beginEntry("check") } label: { Label("添加检查项",systemImage: "plus").foregroundStyle(.tertiary) }
                        .padding(.vertical,8).accessibilityLabel("继续添加检查项")
                }
            }
        }
        let children = store.tasks.filter { $0.parentID == task.id && !$0.deleted }
        if !children.isEmpty || showChildren {
            VStack(alignment: .leading,spacing: 10) {
                Divider()
                ForEach(children) { child in HStack {
                    Button { store.complete(child.id) } label: { Image(systemName: child.completed ? "checkmark.square.fill" : "square").foregroundStyle(.secondary) }.accessibilityLabel("完成子任务")
                    Button(child.title) { store.selectedTask = child.id }.strikethrough(child.completed).foregroundStyle(child.completed ? .secondary : .primary)
                    Spacer()
                    Button { store.mutate(child.id) { $0.deleted = true } } label: { Image(systemName: "xmark").font(.caption).foregroundStyle(.tertiary) }.help("移除子任务")
                } }
                if showChildren { HStack {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                    TextField("添加子任务，回车保存",text: $childTitle).textFieldStyle(.plain).focused($focusedEntry,equals: "child").onSubmit {
                        let title = childTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        if store.add(title,listID: task.listID,parentID: task.id) != nil { childTitle = ""; store.selectedTask = task.id; showChildren = true; focusedEntry = "child" }
                    }
                    Button { showChildren = false; childTitle = ""; focusedEntry = nil } label: { Image(systemName: "xmark").font(.caption) }.help("关闭子任务输入")
                }.id("child") }
            }
        }
        if !task.attachments.isEmpty {
            VStack(alignment: .leading,spacing: 10) {
                Divider()
                ForEach(task.attachments) { attachment in HStack {
                    Button { NSWorkspace.shared.open(store.persistence.root.appendingPathComponent(attachment.relativePath)) } label: { Label(attachment.name,systemImage: "paperclip").lineLimit(1) }
                    Spacer()
                    Button { store.mutate(task.id) { $0.attachments.removeAll { $0.id == attachment.id } } } label: { Image(systemName: "xmark").font(.caption).foregroundStyle(.tertiary) }.help("移除附件")
                } }
            }
        }
    }
    func closeCheckEntry() { showChecks = false; checkTitle = ""; focusedEntry = nil }
    func submitChecks(_ task: TaskItem) {
        if checkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { closeCheckEntry(); return }
        guard !store.addChecks(task.id,input: checkTitle).isEmpty else { return }
        checkTitle = ""; focusedEntry = "check"
    }
    func continueAfter(_ task: TaskItem,check: CheckItem) {
        if let index = task.checks.firstIndex(where: { $0.id == check.id }), index + 1 < task.checks.count { focusedEntry = task.checks[index + 1].id.uuidString }
        else { beginEntry("check") }
    }
    func endCheckEditing() { focusedEntry = nil; NSApp.keyWindow?.makeFirstResponder(nil) }
    func checkRow(_ task: TaskItem,check: CheckItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { store.mutate(task.id) { value in if let i = value.checks.firstIndex(where: { $0.id == check.id }) { value.checks[i].done.toggle() } } } label: {
                    Image(systemName: check.done ? "checkmark.square.fill" : "square").font(.system(size: 17))
                        .foregroundStyle(check.done ? Color.accentColor : .secondary).frame(width: 18)
                }.accessibilityLabel(check.done ? "取消完成检查项" : "完成检查项")
                TextField("检查项",text: Binding(get: { self.task?.checks.first { $0.id == check.id }?.title ?? "" },set: { text in
                    store.mutate(task.id) { value in if let i = value.checks.firstIndex(where: { $0.id == check.id }) { value.checks[i].title = text } }
                }),axis: .vertical).textFieldStyle(.plain).strikethrough(check.done).foregroundStyle(check.done ? .secondary : .primary)
                    .focused($focusedEntry,equals: check.id.uuidString).onSubmit { continueAfter(task,check: check) }
                    .accessibilityLabel("检查项内容")
                Menu {
                    Button("上移",systemImage: "arrow.up") { endCheckEditing(); store.moveCheck(task.id,checkID: check.id,offset: -1) }.disabled(task.checks.first?.id == check.id)
                    Button("下移",systemImage: "arrow.down") { endCheckEditing(); store.moveCheck(task.id,checkID: check.id,offset: 1) }.disabled(task.checks.last?.id == check.id)
                    Button("移除检查项",systemImage: "trash") { endCheckEditing(); store.mutate(task.id) { $0.checks.removeAll { $0.id == check.id } } }
                } label: { Image(systemName: "ellipsis").font(.caption).frame(width: 20,height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(.secondary)
                    .opacity(hoveredCheck == check.id || focusedEntry == check.id.uuidString ? 1 : 0)
                    .help("检查项操作").accessibilityLabel("检查项操作")
            }.padding(.vertical,4).frame(minHeight: 36).contentShape(Rectangle())
                .onHover { if $0 { hoveredCheck = check.id } else if hoveredCheck == check.id { hoveredCheck = nil } }
            Rectangle().fill(Color.secondary.opacity(0.10)).frame(height: 0.5).padding(.leading,28)
        }.id(check.id.uuidString)
    }
    func footer(_ task: TaskItem) -> some View {
        HStack(spacing: 12) {
            Menu {
                Button("收集箱") { store.mutate(task.id) { $0.listID = nil; $0.section = "" } }
                ForEach(store.lists.filter { !$0.deleted }) { list in Button(list.name) { store.mutate(task.id) { $0.listID = list.id; $0.section = "" } } }
            } label: { HStack(spacing: 6) { Image(systemName: "tray.and.arrow.down"); Text(store.lists.first { $0.id == task.listID }?.name ?? "收集箱").lineLimit(1) } }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).fixedSize().accessibilityLabel("所属清单")
            Spacer()
            Button { showFormatting.toggle() } label: { Text("A").font(.system(size: 18)).underline().frame(width: 28,height: 28).background(showFormatting ? Color.secondary.opacity(0.1) : .clear,in: RoundedRectangle(cornerRadius: 7)) }.accessibilityLabel("格式工具栏").help("格式工具栏")
            Menu { moreActions(task) } label: { Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 32,height: 32).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).fixedSize().accessibilityLabel("任务更多操作").help("任务更多操作")
        }.foregroundStyle(.secondary).padding(.horizontal,24).padding(.vertical,12)
            .popover(isPresented: $showOrganization) { organization(task).padding(20).frame(width: 340) }
    }
    func formattingBar(_ task: TaskItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 1) { formatButtons(task) }
            ScrollView(.horizontal) { HStack(spacing: 1) { formatButtons(task) } }.scrollIndicators(.hidden)
        }.padding(7).background(ListTheme.canvas,in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ListTheme.separator))
            .shadow(color: .black.opacity(0.07),radius: 8,y: 2).fixedSize(horizontal: false,vertical: true)
    }
    @ViewBuilder func formatButtons(_ task: TaskItem) -> some View {
        ForEach(DocumentFormat.allCases.filter { task.editingMode == .richText || $0 != .underline },id: \.self) { format in
            if format == .bold || format == .bullet || format == .link { Divider().frame(height: 18).padding(.horizontal,3) }
            Button { applyFormat(format) } label: {
                Group { if format == .heading { Text("H").font(.system(size: 17)) } else { Image(systemName: format.symbol) } }.frame(width: 27,height: 28)
                    .foregroundStyle(document.activeFormats.contains(format) ? Color.accentColor : .primary)
                    .background(document.activeFormats.contains(format) ? Color.accentColor.opacity(0.10) : .clear,in: RoundedRectangle(cornerRadius: 5))
            }.help(format.title).accessibilityLabel(format.title)
        }
        Button { beginEntry("check") } label: { Image(systemName: "checklist").frame(width: 28,height: 28) }.help("添加检查项").accessibilityLabel("添加检查项")
        Button { attach(task) } label: { Image(systemName: "paperclip").frame(width: 28,height: 28) }.help("上传附件").accessibilityLabel("上传附件")
        Button { insertImages() } label: { Image(systemName: "photo").frame(width: 28,height: 28) }.help("插入图片").accessibilityLabel("插入图片")
    }
    func applyFormat(_ format: DocumentFormat) {
        if format == .link { linkTitle = document.selectedText; linkAddress = ""; showLink = true }
        else { document.apply(format) }
    }
    var linkURL: URL? {
        guard let url = URL(string: linkAddress.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(), ["https","http","mailto","ownlist"].contains(scheme), scheme != "https" && scheme != "http" || url.host?.isEmpty == false else { return nil }
        return url
    }
    var linkEditor: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text("插入链接").font(.title2.bold())
            TextField("显示文字",text: $linkTitle).textFieldStyle(.roundedBorder)
            TextField("链接地址，例如 https://example.com",text: $linkAddress).textFieldStyle(.roundedBorder)
            HStack { Button("取消") { showLink = false }.keyboardShortcut(.cancelAction); Spacer(); Button("插入") { if let url = linkURL { document.insertLink(title: linkTitle.trimmingCharacters(in: .whitespacesAndNewlines),url: url); showLink = false } }.keyboardShortcut(.defaultAction).disabled(linkURL == nil || linkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 420)
    }
    @ViewBuilder func moreActions(_ task: TaskItem) -> some View {
        Picker("正文编辑方式",selection: Binding(get: { task.editingMode },set: { changeMode($0) })) {
            ForEach(DocumentEditingMode.allCases,id: \.self) { mode in Text(mode.title).tag(mode) }
        }
        if task.editingMode == .markdown { Toggle("右侧 Markdown 预览",isOn: $previewMarkdown) }
        if task.editingMode == .richText { Button("字体设置") { document.editor?.window?.makeFirstResponder(document.editor); NSFontManager.shared.orderFrontFontPanel(nil) } }
        Divider()
        Button("添加子任务",systemImage: "arrow.turn.down.right") { beginEntry("child") }
        Button("添加检查项",systemImage: "checklist") { beginEntry("check") }
        Button(task.starred ? "取消收藏" : "收藏任务",systemImage: "star") { store.mutate(task.id) { $0.starred.toggle() } }
        Button("标签与分组",systemImage: "tag") { showOrganization = true }
        Button("上传附件",systemImage: "paperclip") { attach(task) }
        Divider()
        Button("任务动态",systemImage: "clock.arrow.circlepath") { showHistory = true }
        Button("保存为模板",systemImage: "doc.badge.plus") { store.duplicate(task.id,asTemplate: true) }
        Button("创建副本",systemImage: "doc.on.doc") { store.duplicate(task.id) }
        Button("复制链接",systemImage: "link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("ownlist://task?id=\(task.id)",forType: .string) }
        Button("打开便签",systemImage: "note.text") { DesktopBridge.panel(title: task.title,view: TaskNoteView(taskID: task.id).environmentObject(store)) }
        Menu("导出文档",systemImage: "square.and.arrow.up") {
            Button("Word 文档（.docx）") { exportDocument(task,format: .word) }
            Button("PDF 文档（.pdf）") { exportDocument(task,format: .pdf) }
            Button("Markdown 文件（.md）") { exportDocument(task,format: .markdown) }
        }
        Button("打印",systemImage: "printer") { printTask(task) }
        Divider()
        Button("添加到系统日历",systemImage: "calendar.badge.plus") { do { try calendar.exportTask(task) } catch { store.error = error.localizedDescription } }
        Button("开始专注",systemImage: "timer") { focus.taskID = task.id; focus.start(); DesktopBridge.panel(title: "专注",view: FocusMiniView().environmentObject(focus),size: NSSize(width: 260,height: 180)) }
        Button(task.archived == true ? "取消归档" : "归档任务",systemImage: "archivebox") { store.mutate(task.id) { $0.archived = !($0.archived ?? false) } }
        Divider()
        Button(task.deleted ? "恢复任务" : "移入回收站",systemImage: task.deleted ? "arrow.uturn.backward" : "trash",role: task.deleted ? nil : .destructive) { if task.deleted { store.restoreTask(task.id) } else { store.mutate(task.id) { $0.deleted = true } } }
    }
    func organization(_ task: TaskItem) -> some View {
        VStack(alignment: .leading,spacing: 14) {
            HStack { Text("标签与分组").font(.headline); Spacer(); Button("完成") { showOrganization = false } }
            TextField("分组",text: binding(\.section,default: ""))
            TextField("标签，以逗号分隔",text: Binding(get: { self.task?.tags.joined(separator: ", ") ?? "" },set: { raw in store.mutate(task.id) { $0.tags = raw.split(whereSeparator: { $0 == "," || $0 == "，" }).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } } }))
            Picker("任务类型",selection: binding(\.special,default: "")) { Text("普通任务").tag(""); Text("纪念日").tag("anniversary"); Text("课程").tag("course") }
            Text("创建于 \(task.created.formatted())").font(.caption).foregroundStyle(.tertiary)
        }
    }
    func printTask(_ task: TaskItem) {
        let view = TaskPrintDocument.makeView(task: task,children: store.tasks.filter { $0.parentID == task.id && !$0.deleted },baseURL: store.persistence.root)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        let operation = NSPrintOperation(view: view,printInfo: info); operation.jobTitle = task.title; operation.run()
    }
    func attach(_ task: TaskItem) { let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; if panel.runModal() == .OK { store.attach(panel.urls,to: task.id) } }
    func insertImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true; panel.message = "选择要插入正文的图片"
        if panel.runModal() == .OK { do { try document.insertImages(panel.urls) } catch { store.error = error.localizedDescription } }
    }
    func insertMarkdown() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText,UTType(filenameExtension: "markdown") ?? .plainText]; panel.allowsMultipleSelection = true; panel.message = "将 Markdown 文件内容插入当前正文"
        if panel.runModal() == .OK {
            do { let warnings = try document.insertMarkdown(panel.urls); if !warnings.isEmpty { store.error = warnings.joined(separator: "\n") } }
            catch { store.error = error.localizedDescription }
        }
    }
    func exportDocument(_ task: TaskItem,format: DocumentExport.Format) {
        let name = task.title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/",with: "-").replacingOccurrences(of: ":",with: "-")
        if format == .markdown, task.richText.flatMap(RichDocument.decode).map(RichDocument.hasImages) == true {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "导出"
            panel.message = "选择导出位置。Markdown 文件和配套图片会保存在一个新文件夹中。"
            if panel.runModal() == .OK, let folder = panel.url {
                do {
                    let filename = name.isEmpty ? "文档" : String(name.prefix(80))
                    let directory = folder.appendingPathComponent(filename + "-Markdown-" + UUID().uuidString.prefix(8),isDirectory: true)
                    try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent(filename + ".md")
                    try DocumentExport.write(task: task,children: store.tasks.filter { $0.parentID == task.id && !$0.deleted },format: format,to: url,baseURL: store.persistence.root)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch { store.error = error.localizedDescription }
            }
            return
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .data]
        panel.nameFieldStringValue = (name.isEmpty ? "文档" : String(name.prefix(80))) + "." + format.rawValue
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try DocumentExport.write(task: task,children: store.tasks.filter { $0.parentID == task.id && !$0.deleted },format: format,to: url,baseURL: store.persistence.root) }
            catch { store.error = error.localizedDescription }
        }
    }
    func dateSettings(_ task: TaskItem) -> some View { VStack(alignment: .leading,spacing: 14) {
        HStack { Text("日期、重复与提醒").font(.headline); Spacer(); Button("完成") { showDate = false } }
        Toggle("设置日期",isOn: Binding(get: { task.due != nil },set: { value in store.mutate(task.id) { $0.due = value ? Date() : nil; if !value { $0.reminders = [] } } }))
        if task.due != nil {
            DatePicker("截止",selection: Binding(get: { task.due ?? Date() },set: { new in store.mutate(task.id) { $0.due = new } }),displayedComponents: task.allDay ? .date : [.date,.hourAndMinute])
            Toggle("全天",isOn: binding(\.allDay,default: true))
            Toggle("设置开始时间",isOn: Binding(get: { task.start != nil },set: { value in store.mutate(task.id) { $0.start = value ? task.due : nil } }))
            if task.start != nil { DatePicker("开始",selection: Binding(get: { task.start ?? Date() },set: { new in store.mutate(task.id) { $0.start = new } })) }
            Stepper("时长 \(Int(task.duration / 60)) 分钟",value: binding(\.duration,default: 1800),in: 300...86400,step: 300)
            RepeatEditor(rule: binding(\.repeatRule,default: RepeatRule()))
            VStack(alignment: .leading) {
                Text("提醒").font(.headline)
                HStack { Stepper("提前 \(Int(customReminder)) 分钟",value: $customReminder,in: 1...43200); Button("添加") { store.mutate(task.id) { if !$0.reminders.contains(customReminder * 60) { $0.reminders.append(customReminder * 60) } } } }
                ForEach(task.reminders.filter { ![0.0,300,900,1800,3600,86400].contains($0) },id: \.self) { offset in HStack { Text("提前 \(Int(offset / 60)) 分钟"); Spacer(); Button("移除") { store.mutate(task.id) { $0.reminders.removeAll { $0 == offset } } } } }
                ForEach([0.0,300,900,1800,3600,86400],id: \.self) { offset in Toggle(offset == 0 ? "到时提醒" : "提前 \(Int(offset / 60)) 分钟",isOn: Binding(get: { task.reminders.contains(offset) },set: { value in store.mutate(task.id) { if value { $0.reminders.append(offset) } else { $0.reminders.removeAll { $0 == offset } } } })) }
            }
        }
    } }
}
struct TaskNoteView: View {
    @EnvironmentObject var store: Store
    var taskID: UUID
    var body: some View { if let task = store.tasks.first(where: { $0.id == taskID }) {
        VStack(alignment: .leading,spacing: 12) {
            Text(task.title).font(.headline)
            if task.richText != nil { RichTextEditor(text: task.notes,data: task.richText) { text,data in store.mutate(taskID) { $0.notes = text; $0.richText = data } } }
            else { TextEditor(text: Binding(get: { store.tasks.first { $0.id == taskID }?.notes ?? "" },set: { text in store.mutate(taskID) { $0.notes = text } })).accessibilityLabel("便签内容") }
        }.padding(16).frame(minWidth: 300,minHeight: 240)
    } }
}
struct RepeatEditor: View {
    @Binding var rule: RepeatRule
    let choices = [("none","不重复"),("daily","每天"),("weekly","每周"),("workdays","工作日"),("monthly","每月"),("monthEnd","月末"),("monthlyDay","每月指定日"),("monthlyWeekday","每月第 N 个星期"),("yearly","每年"),("lunar","农历每年")]
    var body: some View { VStack(alignment: .leading) { Picker("重复",selection: $rule.frequency) { ForEach(choices,id: \.0) { Text($0.1).tag($0.0) } }; if rule.frequency != "none" { if !["workdays","lunar"].contains(rule.frequency) { Stepper("每 \(rule.interval) 个周期",value: $rule.interval,in: 1...365) }; Toggle("完成后计算下一次",isOn: $rule.afterCompletion); if rule.frequency == "weekly" { WeekdayPicker(days: $rule.weekdays) }; if rule.frequency == "monthlyDay" { Stepper("每月第 \(rule.monthDay ?? 1) 天（负数从月末计）",value: Binding(get: { rule.monthDay ?? 1 },set: { rule.monthDay = $0 == 0 ? 1 : $0 }),in: -31...31) }; if rule.frequency == "monthlyWeekday" { Picker("第几个",selection: Binding(get: { rule.ordinal ?? 1 },set: { rule.ordinal = $0 })) { ForEach([-1,1,2,3,4,5],id: \.self) { Text($0 == -1 ? "最后一个" : "第 \($0) 个").tag($0) } }; Picker("星期",selection: Binding(get: { rule.weekday ?? 2 },set: { rule.weekday = $0 })) { ForEach(1...7,id: \.self) { Text(["日","一","二","三","四","五","六"][$0-1]).tag($0) } } }; if rule.frequency == "lunar" { Stepper("农历 \(rule.lunarMonth) 月",value: $rule.lunarMonth,in: 1...12); Stepper("第 \(rule.lunarDay) 天",value: $rule.lunarDay,in: 1...30) }; Toggle("限制重复次数",isOn: Binding(get: { rule.remainingCount != nil },set: { rule.remainingCount = $0 ? 10 : nil })); if rule.remainingCount != nil { Stepper("剩余 \(rule.remainingCount ?? 10) 次",value: Binding(get: { rule.remainingCount ?? 10 },set: { rule.remainingCount = $0 }),in: 1...10000) }; Toggle("设置结束日期",isOn: Binding(get: { rule.until != nil },set: { rule.until = $0 ? Calendar.current.date(byAdding: .year,value: 1,to: Date()) : nil })); if rule.until != nil { DatePicker("重复至",selection: Binding(get: { rule.until ?? Date() },set: { rule.until = $0 }),displayedComponents: .date) } } } }
}
struct WeekdayPicker: View { @Binding var days: [Int]; var body: some View { HStack(spacing: 4) { ForEach(1...7,id: \.self) { i in Button(["日","一","二","三","四","五","六"][i-1]) { if days.contains(i) { days.removeAll { $0 == i } } else { days.append(i) } }.buttonStyle(.bordered).tint(days.contains(i) ? .accentColor : .gray) } } } }
struct ListEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var existing: TaskList?
    var onSaved: (TaskList) -> Void = { _ in }
    @State private var name = ""
    @State private var folder = ""
    @State private var color = "blue"
    @State private var sections = ""
    @State private var defaultView = "列表"
    @State private var failure: String?
    @FocusState private var nameFocused: Bool
    var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text(existing == nil ? "新建清单" : "编辑清单").font(.title2.bold())
            Form {
                TextField("清单名称",text: $name).focused($nameFocused)
                HStack {
                    TextField("文件夹",text: $folder)
                    Menu {
                        Button("不放入文件夹") { folder = "" }
                        ForEach(Array(Set(store.lists.filter { !$0.deleted && !$0.folder.isEmpty }.map(\.folder))).sorted(),id: \.self) { value in Button(value) { folder = value } }
                    } label: { Image(systemName: "folder") }.help("选择已有文件夹")
                }
                Text("留空放在顶层，也可以输入新的文件夹名称。").font(.caption).foregroundStyle(.secondary)
                ThemeColorChoices(title: "颜色",selection: $color)
                Picker("默认视图",selection: $defaultView) { ForEach(["列表","看板","时间线"],id: \.self) { Text($0).tag($0) } }
                TextField("任务分组",text: $sections)
                Text("使用逗号、中文逗号或换行分隔；空白和重复分组会自动整理。").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).frame(height: 320)
            if let failure { Text(failure).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false,vertical: true).accessibilityLabel("保存失败：" + failure) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(existing == nil ? "创建清单" : "保存修改",action: submit)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(cleanName.isEmpty)
            }
        }.padding(24).frame(width: 480).onAppear {
            if let value = existing { name = value.name; folder = value.folder; color = value.color; sections = value.sections.joined(separator: "，"); defaultView = value.defaultView ?? "列表" }
            nameFocused = true
        }
    }
    func submit() {
        do {
            let value = try store.commitList(existing: existing,name: name,folder: folder,color: color,sections: sections,defaultView: defaultView)
            onSaved(value); dismiss()
        } catch { failure = error.localizedDescription }
    }
}
struct FilterEditor: View {
    @EnvironmentObject var store: Store; @Environment(\.dismiss) var dismiss; var existing: SavedFilter?; @State private var filter = SavedFilter(name: "")
    var body: some View { VStack(alignment: .leading,spacing: 18) { Text("自定义过滤器").font(.title2.bold()); Form { TextField("名称",text: $filter.name); TextField("包含文字",text: $filter.text); TextField("标签",text: $filter.tag); Picker("清单",selection: $filter.listID) { Text("所有清单").tag(nil as UUID?); ForEach(store.lists.filter { !$0.deleted }) { Text($0.name).tag(Optional($0.id)) } }; Picker("优先级",selection: $filter.priority) { Text("任意").tag(-1); ForEach(0...3,id: \.self) { Text("\($0)").tag($0) } }; Picker("截止范围",selection: $filter.days) { Text("不限").tag(-1); Text("今天及逾期").tag(0); Text("未来 7 天及逾期").tag(6); Text("未来 30 天及逾期").tag(29) }; Toggle("仅收藏",isOn: $filter.starredOnly) }; Text("条件同时满足时显示任务").font(.caption).foregroundStyle(.secondary); HStack { Button("取消") { dismiss() }; Spacer(); Button("保存") { store.save(filter); dismiss() }.buttonStyle(.borderedProminent).disabled(filter.name.isEmpty) } }.padding(24).frame(width: 450).onAppear { if let existing { filter = existing } } }
}
struct HistoryView: View {
    @EnvironmentObject var store: Store; @Environment(\.dismiss) var dismiss; var taskID: UUID
    @State private var versions: [FieldVersion] = []
    var body: some View { VStack { HStack { Text("修改历史").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() } }.padding(); List(versions.reversed()) { v in VStack(alignment: .leading,spacing: 6) { HStack { Text(v.field).font(.headline); Spacer(); Text(v.timestamp,format: .dateTime).font(.caption) }; Text(v.json).font(.caption).lineLimit(4); Button("恢复这个字段") { do { try store.persistence.restoreField(v); store.reload(); store.reschedule(); dismiss() } catch { store.error = error.localizedDescription } } } } }.frame(width: 650,height: 500).onAppear { versions = (try? store.persistence.versions(owner: taskID)) ?? [] } }
}
struct ImportView: View {
    @EnvironmentObject var store: Store; @Environment(\.dismiss) var dismiss; var preview: ImportPreview; @State private var result: String?; @State private var replace = false
    var duplicates: Int { preview.backup.tasks.filter { incoming in store.tasks.contains { $0.id == incoming.id || (incoming.sourceID != nil && $0.sourceID == incoming.sourceID) } }.count }
    var body: some View { VStack(alignment: .leading,spacing: 16) { Text("导入预览").font(.title2.bold()); Text("\(preview.source) · \(preview.count) 条任务 · \(preview.backup.lists.count) 个清单 · \(duplicates) 条重复")
        if preview.source == "Zilo备份" { Toggle("恢复备份并替换当前数据",isOn: $replace); Text("默认合并；替换会把当前备份中不存在的记录移入回收站。").font(.caption).foregroundStyle(.secondary) }
        ScrollView { VStack(alignment: .leading,spacing: 10) { ForEach(preview.warnings,id: \.self) { Label($0,systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }; ForEach(preview.backup.tasks.prefix(50)) { t in HStack { Text(t.title); Spacer(); if let due = t.due { Text(due,format: .dateTime.year().month().day()).foregroundStyle(.secondary) } } }; if preview.count > 50 { Text("其余 \(preview.count - 50) 条任务也将导入").foregroundStyle(.secondary) } } }
        if let result { Text(result).foregroundStyle(.green) }; HStack { Button(result == nil ? "取消" : "关闭") { dismiss() }; Spacer(); Button("确认导入") { performImport() }.buttonStyle(.borderedProminent).disabled(result != nil) }
    }.padding(24).frame(width: 650,height: 520) }
    func performImport() {
        do { try store.manualBackup(); try store.restoreFiles(preview.backup.attachmentFiles ?? [:]); if replace { store.apply(preview.backup); result = "备份已恢复，原数据已自动备份"; return }
            var mapping: [UUID: UUID] = [:]
            for list in preview.backup.lists { if let existing = store.lists.first(where: { !$0.deleted && $0.name == list.name && $0.folder == list.folder }) { mapping[list.id] = existing.id } else { store.save(list); mapping[list.id] = list.id } }
            var count = 0; var skipped = 0
            for var task in preview.backup.tasks { if store.tasks.contains(where: { $0.id == task.id || (task.sourceID != nil && $0.sourceID == task.sourceID) }) { skipped += 1; continue }; if let list = task.listID { task.listID = mapping[list] ?? list }; store.save(task); count += 1 }
            for item in preview.backup.filters where !store.filters.contains(where: { $0.id == item.id }) { store.save(item) }; for item in preview.backup.habits where !store.habits.contains(where: { $0.id == item.id }) { store.save(item) }; for item in preview.backup.focus where !store.focus.contains(where: { $0.id == item.id }) { store.save(item) }; for item in preview.backup.subscriptions where !store.subscriptions.contains(where: { $0.id == item.id }) { store.save(item) }
            result = "已导入 \(count) 条任务，跳过 \(skipped) 条重复；原数据已备份"
        } catch { store.error = error.localizedDescription }
    }
}
