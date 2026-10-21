import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TaskDetailView: View {
    var selection: Binding<UUID?>? = nil
    var startInPreview = false
    var initialSplitPreview = false
    @AppStorage("accent") private var applicationTheme = "blue"
    @EnvironmentObject var store: Store
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var focus: FocusTimer
    @StateObject private var document = DocumentEditorController()
    @State private var showMindMap = false
    @State private var mindMapOutline = ""
    @State private var mindMapRange: NSRange?
    @State private var showDate = false
    @State private var showOrganization = false
    @State private var showFormatting = false
    @State private var showChecks = false
    @State private var showChildren = false
    @State private var previewMarkdown = false
    @State private var previewSidebar = false
    @State private var bodyHeight: CGFloat = 26
    @State private var hoveredCheck: UUID?
    @State private var reminderCheck: UUID?
    @State private var childTitle = ""
    @State private var checkTitle = ""
    @State private var showHistory = false
    @State private var showLink = false
    @State private var linkTitle = ""
    @State private var linkAddress = ""
    @State private var customReminder = 45.0
    @FocusState private var focusedEntry: String?
    var selectedID: UUID? { selection == nil ? store.selectedTask : selection?.wrappedValue }
    var task: TaskItem? { store.tasks.first { $0.id == selectedID } }
    func selectTask(_ id: UUID) {
        commitDocument()
        if let selection { selection.wrappedValue = id }
        else { store.selectedTask = id }
    }
    func commitDocument() {
        document.editor?.unmarkText(); document.editor?.didChangeText()
        document.editor?.window?.makeFirstResponder(nil)
    }
    func binding<T>(_ path: WritableKeyPath<TaskItem,T>,default value: T) -> Binding<T> {
        Binding(get: { task?[keyPath: path] ?? value },set: { new in if let id = task?.id { store.mutate(id) { $0[keyPath: path] = new } } })
    }
    var body: some View {
        let _ = applicationTheme

        Group {
            if let task {
                GeometryReader { geometry in
                    detailContent(task,documentHeight: max(220,geometry.size.height - (showFormatting && !previewMarkdown ? 270 : 225)))
                        .frame(minWidth: 300,maxWidth: .infinity,maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showHistory) { HistoryView(taskID: task.id).environmentObject(store) }
                .sheet(isPresented: $showLink) { linkEditor }
                .sheet(isPresented: $showMindMap) { MindMapEditor(outline:$mindMapOutline,replacing:mindMapRange != nil,onSave:saveMindMap) }
            } else {
                QuietEmptyState(title: "选择一个任务",message: "查看详细内容、安排时间或开始专注",symbol: "square.and.pencil")
            }
        }.frame(minWidth: previewSidebar ? 520 : 340,maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
            .background(ListTheme.canvas)
            .onAppear(perform: resetEditor)
            .onChange(of: selectedID) { _,_ in resetEditor() }
    }
    func resetEditor() {
        childTitle = ""; checkTitle = ""; focusedEntry = nil
        showDate = false; showOrganization = false; showChecks = false; showChildren = false; showLink = false
        bodyHeight = 26; hoveredCheck = nil
        previewSidebar = initialSplitPreview && task?.editingMode == .markdown
        previewMarkdown = !previewSidebar && startInPreview && task?.editingMode == .markdown
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
                        if let parent = task.parentID { Button("返回父任务") { selectTask(parent) } }
                    }.padding(.horizontal,24).padding(.top,18).padding(.bottom,24)
                }
                .onChange(of: focusedEntry) { _,entry in if let entry { reader.scrollTo(entry,anchor: .bottom) } }
            }.id(task.id)
            if showFormatting && !previewMarkdown { formattingBar(task).padding(.horizontal,20).padding(.bottom,12) }
            footer(task)
        }
    }
    func changeMode(_ mode: DocumentEditingMode) {
        guard let id = task?.id, task?.editingMode != mode else { return }
        document.editor?.unmarkText(); document.editor?.didChangeText()
        guard var current = store.tasks.first(where: { $0.id == id }) else { return }
        do { TaskDocument.switchMode(&current,to: mode,baseURL: store.persistence.root); try store.externalizeDocumentImages(&current); store.save(current) } catch { store.error = error.localizedDescription }
        document.activeFormats = []; previewMarkdown = false; previewSidebar = false
    }
    var previewSelection: Binding<Int> {
        Binding(get: { previewSidebar ? 2 : previewMarkdown ? 1 : 0 },set: { value in
            commitDocument()
            previewMarkdown = value == 1; previewSidebar = value == 2
        })
    }
    func beginEntry(_ entry: String) {
        if entry == "check" { showChecks = true } else { showChildren = true }
        DispatchQueue.main.async { focusedEntry = entry }
    }
    func header(_ task: TaskItem) -> some View {
        HStack(spacing: 12) {
            Button { store.complete(task.id) } label: { Image(systemName: task.isNote == true ? "doc.text" : task.abandoned == true ? "xmark.square" : task.completed ? "checkmark.square.fill" : "square").font(.system(size: 19)).foregroundStyle(task.completed ? Color.accentColor : ListTheme.secondary) }
                .disabled(task.isNote == true || task.abandoned == true).accessibilityLabel(task.isNote == true ? "笔记" : task.abandoned == true ? "已放弃" : task.completed ? "取消完成" : "完成任务").frame(width: 22,height: 30)
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
        VStack(alignment: .leading,spacing: 12) {
            if task.editingMode == .markdown {
                HStack(spacing: 10) {
                    Spacer()
                    Picker("正文编辑方式",selection: previewSelection) {
                        Text("编辑").tag(0)
                        Text("预览").tag(1)
                        Image(systemName: "rectangle.split.2x1").tag(2).help("并排预览").accessibilityLabel("并排预览")
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 174)
                }
            }
            HStack(alignment: .top,spacing: 0) {
            ZStack(alignment: .topLeading) {
            HStack(alignment: .top,spacing: 6) {
                Menu {
                    Button("检查项",systemImage: "checklist") { beginEntry("check") }
                    Button("子任务",systemImage: "arrow.turn.down.right") { beginEntry("child") }
                    Button("附件",systemImage: "paperclip") { attach(task) }
                    Button("图片",systemImage: "photo") { insertImages() }
                    Button("Markdown 文件",systemImage: "doc.text") { insertMarkdown() }
                    Button("思维导图",systemImage:"point.3.connected.trianglepath.dotted") { beginMindMap() }
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
            }.padding(.leading,-20).opacity(previewMarkdown ? 0 : 1).allowsHitTesting(!previewMarkdown).accessibilityHidden(previewMarkdown)
            if task.editingMode == .markdown && previewMarkdown {
                MarkdownPreviewView(source: task.notes,baseURL: store.persistence.root,onChangeLanguage: { source in store.mutate(task.id) { $0.notes = source } }).frame(height: height).accessibilityLabel("Markdown 预览")
            }
            }.frame(maxWidth: .infinity,alignment: .topLeading)
            if task.editingMode == .markdown && previewSidebar {
                Divider().padding(.horizontal,16).frame(height: height)
                MarkdownPreviewView(source: task.notes,baseURL: store.persistence.root,onChangeLanguage: { source in store.mutate(task.id) { $0.notes = source } })
                    .frame(maxWidth: .infinity).frame(height: height).accessibilityLabel("Markdown 侧栏预览")
            }
            }
        }
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
                    Button(child.title) { selectTask(child.id) }.strikethrough(child.completed).foregroundStyle(child.completed ? .secondary : .primary)
                    Spacer()
                    Button { store.mutate(child.id) { $0.deleted = true } } label: { Image(systemName: "xmark").font(.caption).foregroundStyle(.tertiary) }.help("移除子任务")
                } }
                if showChildren { HStack {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                    TextField("添加子任务，回车保存",text: $childTitle).textFieldStyle(.plain).focused($focusedEntry,equals: "child").onSubmit {
                        let title = childTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        if store.add(title,listID: task.listID,parentID: task.id) != nil { childTitle = ""; showChildren = true; focusedEntry = "child" }
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
                Button { reminderCheck = check.id } label: { Image(systemName: check.due == nil ? "bell" : "bell.fill").font(.system(size: 12)).foregroundStyle(check.due == nil ? ListTheme.secondary : ListTheme.accent).frame(width: 22,height: 26) }
                    .opacity(check.due != nil || hoveredCheck == check.id || focusedEntry == check.id.uuidString ? 1 : 0).accessibilityLabel("检查项提醒")
                    .popover(isPresented: Binding(get: { reminderCheck == check.id },set: { if !$0 { reminderCheck = nil } })) {
                        CheckReminderSettings(check: Binding(get: { self.task?.checks.first { $0.id == check.id } ?? check },set: { updated in store.mutate(task.id) { item in if let index = item.checks.firstIndex(where: { $0.id == check.id }) { item.checks[index] = updated } } })).frame(width: 320).padding(20)
                    }
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
            } label: { HStack(spacing: 6) { Image(systemName: "tray.and.arrow.down"); Text(store.lists.first { $0.id == task.listID }?.name ?? ZiloLanguage.text("收集箱")).lineLimit(1) } }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.primary).fixedSize().accessibilityLabel("所属清单")
            Spacer()
            Button { if previewMarkdown { previewSelection.wrappedValue = 0 }; showFormatting.toggle() } label: { Text("A").font(.system(size: 18)).underline().frame(width: 28,height: 28).background(showFormatting ? Color.secondary.opacity(0.1) : .clear,in: RoundedRectangle(cornerRadius: 7)) }.accessibilityLabel("格式工具栏").help("格式工具栏")
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
            }.help(ZiloLanguage.text(format.title)).accessibilityLabel(format.title)
        }
        Button { beginEntry("check") } label: { Image(systemName: "checklist").frame(width: 28,height: 28) }.help("添加检查项").accessibilityLabel("添加检查项")
        Button { attach(task) } label: { Image(systemName: "paperclip").frame(width: 28,height: 28) }.help("上传附件").accessibilityLabel("上传附件")
        Button { beginMindMap() } label: { Image(systemName:"point.3.connected.trianglepath.dotted").frame(width:28,height:28) }.help("插入或编辑思维导图").accessibilityLabel("插入或编辑思维导图")
        Button { insertImages() } label: { Image(systemName: "photo").frame(width: 28,height: 28) }.help("插入图片").accessibilityLabel("插入图片")
    }
    func beginMindMap() {
        mindMapOutline = MindMapDocument.example; mindMapRange = nil
        guard let editor = document.editor else { showMindMap = true; return }
        editor.unmarkText(); editor.didChangeText()
        let selection = editor.selectedRange()
        if task?.editingMode == .richText,let storage = editor.textStorage,storage.length > 0 {
            let index = min(selection.location,storage.length-1); var range = NSRange()
            if let m = storage.attribute(.ziloBlock,at:index,effectiveRange:&range) as? [String:String],m["kind"] == "mindmap",let source = m["source"] {
                mindMapOutline = source; mindMapRange = range
            }
        } else if let re = try? NSRegularExpression(pattern:#"(?ms)^```mermaid[ \t]*\n(mindmap\b.*?)^```[ \t]*(?:\n|$)"#) {
            for match in re.matches(in:editor.string,range:NSRange(location:0,length:editor.string.utf16.count)) where selection.location >= match.range.location && selection.location <= NSMaxRange(match.range) {
                mindMapOutline = (editor.string as NSString).substring(with:match.range(at:1)); mindMapRange = match.range; break
            }
        }
        showMindMap = true
    }
    func saveMindMap(_ source: String) {
        guard let editor = document.editor,let task else { return }
        do {
            let diagram = try MindMapDocument.parse(source)
            let range = mindMapRange ?? editor.selectedRange()
            if task.editingMode == .markdown {
                let prefix = range.location > 0 && (editor.string as NSString).character(at:range.location-1) != 10 ? "\n\n":""
                editor.insertText(prefix+"```mermaid\n"+diagram.source+"\n```\n",replacementRange:range)
            } else {
                let text = NSMutableAttributedString(attributedString:try MindMapDocument.attachment(diagram.source))
                text.append(NSAttributedString(string:"\n",attributes:DocumentStyle.body)); editor.insertText(text,replacementRange:range)
            }
            editor.didChangeText()
        } catch { store.error = error.localizedDescription }
    }
    func applyFormat(_ format: DocumentFormat) {
        if format == .link { linkTitle = document.selectedText; linkAddress = ""; showLink = true }
        else { document.apply(format) }
    }
    var linkURL: URL? { DocumentLink.url(linkAddress) }
    var linkEditor: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text("插入链接").font(.title2.bold())
            VStack(alignment: .leading,spacing: 6) {
                Text("链接地址").font(.callout)
                TextField("https://example.com",text: $linkAddress).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("链接地址")
            }
            VStack(alignment: .leading,spacing: 6) {
                Text("显示文字（可选）").font(.callout)
                TextField("留空使用链接地址",text: $linkTitle).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("链接显示文字")
            }
            if !linkAddress.isEmpty && linkURL == nil {
                Text("请输入有效的网址，例如 https://example.com").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("取消") { showLink = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("插入") {
                    if let url = linkURL {
                        document.insertLink(title: DocumentLink.title(linkTitle,url: url),url: url)
                        showLink = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(linkURL == nil)
            }
        }.padding(24).frame(width: 420)
    }
    @ViewBuilder func moreActions(_ task: TaskItem) -> some View {
        Picker("正文编辑方式",selection: Binding(get: { task.editingMode },set: { changeMode($0) })) {
            ForEach(DocumentEditingMode.allCases,id: \.self) { mode in Text(mode.title).tag(mode) }
        }
        if task.editingMode == .richText { Button("字体设置") { document.editor?.window?.makeFirstResponder(document.editor); NSFontManager.shared.orderFrontFontPanel(nil) } }
        Divider()
        Button("添加子任务",systemImage: "arrow.turn.down.right") { beginEntry("child") }
        if task.parentID != nil {
            Button("移为顶层任务",systemImage: "arrow.up.left") { _ = store.promoteTask(task.id) }
        }
        Button("添加检查项",systemImage: "checklist") { beginEntry("check") }
        Button(task.starred ? "取消收藏" : "收藏任务",systemImage: "star") { store.mutate(task.id) { $0.starred.toggle() } }
        Button("标签与分组",systemImage: "tag") { showOrganization = true }
        Button("上传附件",systemImage: "paperclip") { attach(task) }
        Divider()
        Button("任务动态",systemImage: "clock.arrow.circlepath") { showHistory = true }
        Button("保存为模板",systemImage: "doc.badge.plus") { store.duplicate(task.id,asTemplate: true) }
        Button("创建副本",systemImage: "doc.on.doc") { store.duplicate(task.id) }
        Button("复制链接",systemImage: "link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("ownlist://task?id=\(task.id)",forType: .string) }
        Button("打开便签",systemImage: "note.text") { SideNotesPanel.shared.show(store,taskID: task.id) }
        Button("插入或编辑思维导图",systemImage:"point.3.connected.trianglepath.dotted") { beginMindMap() }
        Menu("导出文档",systemImage: "square.and.arrow.up") {
            Button("Word 文档（.docx）") { exportDocument(task,format: .word) }
            Button("PDF 文档（.pdf）") { exportDocument(task,format: .pdf) }
            Button("Markdown 文件（.md）") { exportDocument(task,format: .markdown) }
            Button("HTML 网页（.html）") { exportDocument(task,format: .html) }
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
        Toggle("设置日期",isOn: Binding(get: { task.due != nil },set: { value in store.mutate(task.id) { $0.setDue(value ? Date() : nil) } }))
        if task.due != nil {
            DatePicker("截止",selection: Binding(get: { task.due ?? Date() },set: { new in store.mutate(task.id) { $0.setDue(new) } }),displayedComponents: task.allDay ? .date : [.date,.hourAndMinute])
            Toggle("全天",isOn: binding(\.allDay,default: true))
            Toggle("设置开始时间",isOn: Binding(get: { task.start != nil },set: { value in store.mutate(task.id) { $0.setStart(value ? (task.due ?? Date()).addingTimeInterval(-max(60,task.duration)) : nil) } }))
            if task.start != nil { DatePicker("开始",selection: Binding(get: { task.start ?? Date() },set: { new in store.mutate(task.id) { $0.setStart(new) } })) }
            Stepper("时长 \(Int(task.duration / 60)) 分钟",value: Binding(get: { self.task?.duration ?? 1800 },set: { value in store.mutate(task.id) { $0.duration = value; if let start = $0.start { $0.due = start.addingTimeInterval(value) } } }),in: 300...86400,step: 300)
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
    @AppStorage("accent") private var applicationTheme = "blue"
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var existing: TaskList?
    var onSaved: (TaskList) -> Void = { _ in }
    @State private var name = ""
    @State private var folder = ""
    @State private var color = "blue"
    @State private var sections = ""
    @State private var defaultView = "列表"
    @State private var showsSections = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool
    var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private let views: [(name: String, symbol: String)] = [
        ("列表","list.bullet.rectangle"),("看板","rectangle.split.3x1"),("时间线","chart.bar.xaxis")
    ]
    var body: some View {
        let _ = applicationTheme

        HStack(spacing: 0) {
            VStack(alignment: .leading,spacing: 0) {
                Text(existing == nil ? "新建清单" : "编辑清单")
                    .font(.system(size: 20,weight: .semibold)).padding(.bottom,16)
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal").foregroundStyle(ListTheme.secondary)
                    TextField("清单名称",text: $name).textFieldStyle(.plain).focused($nameFocused)
                        .font(.system(size: 17)).accessibilityLabel("清单名称")
                }
                .padding(.horizontal,14).frame(height: 42)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(nameFocused ? ListTheme.accent : ListTheme.separator,lineWidth: nameFocused ? 1.5 : 1))
                .padding(.bottom,16)

                HStack(spacing: 8) {
                    Text("清单颜色").foregroundStyle(ListTheme.secondary).frame(width: 74,alignment: .leading)
                    ListColorChoices(selection: $color)
                }.padding(.bottom,15)

                HStack(spacing: 8) {
                    Text("视图类型").foregroundStyle(ListTheme.secondary).frame(width: 74,alignment: .leading)
                    HStack(spacing: 10) {
                        ForEach(views,id: \.name) { view in
                            Button { defaultView = view.name } label: {
                                Image(systemName: view.symbol).font(.system(size: 20))
                                    .foregroundStyle(defaultView == view.name ? ListTheme.accent : ListTheme.secondary)
                                    .frame(width: 48,height: 42)
                                    .background(defaultView == view.name ? ListTheme.accent.opacity(0.10) : ListTheme.input,in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(defaultView == view.name ? ListTheme.accent : .clear))
                            }.buttonStyle(.plain).help(view.name).accessibilityLabel(view.name)
                                .accessibilityAddTraits(defaultView == view.name ? .isSelected : [])
                        }
                    }
                }.padding(.bottom,13)

                HStack(spacing: 8) {
                    Text("文件夹").foregroundStyle(ListTheme.secondary).frame(width: 74,alignment: .leading)
                    HStack(spacing: 4) {
                        TextField("无",text: $folder).textFieldStyle(.plain)
                            .accessibilityLabel("文件夹，可输入新名称")
                        Menu {
                            Button("无") { folder = "" }
                            ForEach(Array(Set(store.lists.filter { !$0.deleted && !$0.folder.isEmpty }.map(\.folder))).sorted(),id: \.self) { value in
                                Button(value) { folder = value }
                            }
                        } label: { Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(ListTheme.secondary) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("选择已有文件夹")
                    }
                    .padding(.horizontal,12).frame(height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ListTheme.separator))
                }

                DisclosureGroup("任务分组",isExpanded: $showsSections) {
                    TextField("例如：待办，进行中，完成",text: $sections).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("任务分组")
                }.font(.system(size: 12)).foregroundStyle(ListTheme.secondary).padding(.top,18)

                if let failure {
                    Text(failure).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false,vertical: true)
                        .padding(.top,8).accessibilityLabel("保存失败：" + failure)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Spacer()
                    Button { dismiss() } label: {
                        Text("取消").frame(width: 78,height: 32)
                            .background(ListTheme.canvas,in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ListTheme.separator))
                    }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    Button(action: submit) {
                        Text(existing == nil ? "创建" : "保存").foregroundStyle(.white)
                            .frame(width: 78,height: 32)
                            .background(ListTheme.accent,in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(cleanName.isEmpty)
                        .opacity(cleanName.isEmpty ? 0.45 : 1)
                }
            }
            .padding(.horizontal,28).padding(.top,20).padding(.bottom,24)
            .frame(width: 395,height: 430)
            Rectangle().fill(ListTheme.separator).frame(width: 1)
            ListEditorPreview(name: cleanName,color: color,view: defaultView)
                .frame(width: 370,height: 430)
        }
        .background(ListTheme.canvas)
        .onAppear {
            if let value = existing {
                name = value.name; folder = value.folder; color = value.color
                sections = value.sections.joined(separator: "，")
                defaultView = value.defaultView ?? "列表"
                showsSections = !value.sections.isEmpty
            }
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

private struct ListColorChoices: View {
    @Binding var selection: String
    @State private var colorPanel = ListColorPanelController()
    private let colors = ["none","red","orange","yellow","lime","green","blue","purple"]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(colors,id: \.self) { value in
                Button { selection = value } label: {
                    ZStack {
                        Circle().fill(value == "none" ? ListTheme.canvas : value.listColor)
                            .frame(width: 22,height: 22)
                        if value == "none" {
                            Circle().strokeBorder(ListTheme.separator,lineWidth: 1).frame(width: 22,height: 22)
                            Rectangle().fill(Color.red.opacity(0.75)).frame(width: 25,height: 1.5).rotationEffect(.degrees(-45))
                        } else if selection == value {
                            Image(systemName: "checkmark").font(.system(size: 10,weight: .bold))
                                .foregroundStyle(["yellow","lime"].contains(value) ? ListTheme.text : .white)
                        }
                        if selection == value {
                            Circle().strokeBorder(ListTheme.accent.opacity(0.45),lineWidth: 1.5).frame(width: 28,height: 28)
                        }
                    }.frame(width: 28,height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).help(value.colorLabel).accessibilityLabel(value.colorLabel)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
            Button { colorPanel.open(color: selection.hasPrefix("#") ? selection.listColor : "green".listColor,selection: $selection) } label: {
                ZStack {
                    Circle().strokeBorder(
                        AngularGradient(colors: [.red,.orange,.yellow,.green,.blue,.purple,.red],center: .center),
                        lineWidth: 2
                    ).frame(width: 25,height: 25)
                    Circle().fill(selection.hasPrefix("#") ? selection.listColor : "green".listColor)
                        .frame(width: 17,height: 17)
                }.frame(width: 28,height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).help("自定义颜色").accessibilityLabel("自定义颜色")
                .accessibilityAddTraits(selection.hasPrefix("#") ? .isSelected : [])
        }
        .onDisappear { colorPanel.detach() }
    }
}

private final class ListColorPanelController: NSObject {
    private var selection: Binding<String>?
    func open(color: Color,selection: Binding<String>) {
        self.selection = selection
        let panel = NSColorPanel.shared
        panel.color = NSColor(color)
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }
    func detach() {
        guard selection != nil else { return }
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        selection = nil
    }
    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let rgb = sender.color.usingColorSpace(.deviceRGB) else { return }
        selection?.wrappedValue = String(format: "#%02X%02X%02X",
                                          Int((rgb.redComponent * 255).rounded()),
                                          Int((rgb.greenComponent * 255).rounded()),
                                          Int((rgb.blueComponent * 255).rounded()))
    }
}

private struct ListEditorPreview: View {
    let name: String
    let color: String
    let view: String
    private var tint: Color { color == "none" ? ListTheme.secondary : color.listColor }
    private func line(_ width: CGFloat,_ height: CGFloat = 7) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(ListTheme.separator.opacity(0.7)).frame(width: width,height: height)
    }
    private func taskRow(_ width: CGFloat) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3).strokeBorder(tint,lineWidth: 1.5).frame(width: 12,height: 12)
            line(width)
        }.frame(maxWidth: .infinity,alignment: .leading)
    }
    var body: some View {
        ZStack {
            tint.opacity(0.055)
            VStack(alignment: .leading,spacing: 0) {
                Text("实时预览").font(.system(size: 11)).foregroundStyle(ListTheme.secondary)
                    .padding(.bottom,14)
                VStack(alignment: .leading,spacing: 18) {
                    HStack(spacing: 9) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(tint)
                        Text(name.isEmpty ? "清单名称" : name).font(.system(size: 15,weight: .semibold)).lineLimit(1)
                    }
                    line(230,22)
                    if view == "看板" {
                        HStack(alignment: .top,spacing: 8) {
                            previewColumn("待办")
                            previewColumn("进行中")
                        }
                    } else if view == "时间线" {
                        ForEach(0..<3,id: \.self) { index in
                            HStack(spacing: 10) {
                                line(28)
                                RoundedRectangle(cornerRadius: 4).fill(tint.opacity(index == 1 ? 0.38 : 0.17))
                                    .frame(width: index == 1 ? 125 : 88,height: 17)
                            }
                        }
                    } else {
                        line(50)
                        taskRow(128); taskRow(98); taskRow(165)
                        line(42).padding(.top,10)
                        taskRow(147); taskRow(112)
                    }
                    Spacer(minLength: 0)
                }
                .padding(20).frame(height: 320,alignment: .topLeading)
                .frame(maxWidth: .infinity,alignment: .topLeading)
                .background(ListTheme.canvas,in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ListTheme.separator.opacity(0.7)))
            }.padding(24)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("清单预览，\(name.isEmpty ? "清单名称" : name)，\(color.colorLabel)，\(view)视图")
    }
    private func previewColumn(_ title: String) -> some View {
        VStack(alignment: .leading,spacing: 12) {
            Text(LocalizedStringKey(title)).font(.system(size: 10,weight: .medium)).foregroundStyle(ListTheme.secondary)
            taskRow(58); taskRow(78)
        }.padding(10).frame(maxWidth: .infinity,alignment: .leading)
            .background(ListTheme.input,in: RoundedRectangle(cornerRadius: 7))
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
            for item in preview.backup.sideNotes ?? [] where !store.sideNotes.contains(where: { $0.id == item.id }) { store.save(item) }; for item in preview.backup.noteFolders ?? [] where !store.noteFolders.contains(where: { $0.id == item.id }) { store.save(item) }
            for item in preview.backup.countdowns ?? [] where !store.countdowns.contains(where: { $0.id == item.id }) { store.save(item) }; for item in preview.backup.filters where !store.filters.contains(where: { $0.id == item.id }) { store.save(item) }; for item in preview.backup.habits where !store.habits.contains(where: { $0.id == item.id }) { store.save(item) }; for item in preview.backup.focus where !store.focus.contains(where: { $0.id == item.id }) { store.save(item) }; for item in preview.backup.subscriptions where !store.subscriptions.contains(where: { $0.id == item.id }) { store.save(item) }
            result = "已导入 \(count) 条任务，跳过 \(skipped) 条重复；原数据已备份"
        } catch { store.error = error.localizedDescription }
    }
}


/// Keep a native field in the row so hovering and clicking never swap the view.
struct TaskNameField: NSViewRepresentable {
    var title: String
    var completed: Bool
    var fontSize: Double
    var requestFocus: Bool
    var onBegin: () -> Void
    var onEnd: (String?) -> Void
    var onDoubleClick: () -> Void = {}
    var dragPayload: String? = nil
    var onDragBegin: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> TaskNameTextField {
        let field = TaskNameTextField()
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none; field.isEditable = true; field.isSelectable = true
        field.usesSingleLineMode = true; field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.onActivate = { [weak coordinator = context.coordinator] field in coordinator?.begin(field) }
        field.onDoubleClick = { [weak coordinator = context.coordinator] in coordinator?.parent.onDoubleClick() }
        field.setContentHuggingPriority(.defaultLow,for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow,for: .horizontal)
        field.setAccessibilityLabel("任务名称")
        return field
    }
    func updateNSView(_ field: TaskNameTextField,context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.dragPayload = dragPayload; field.onDragBegin = onDragBegin
        if !coordinator.editing {
            let font = NSFont.systemFont(ofSize: fontSize)
            field.font = font; field.textColor = completed ? .secondaryLabelColor : .labelColor
            field.attributedStringValue = NSAttributedString(string: title,attributes: [
                .font: font,.foregroundColor: completed ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .strikethroughStyle: completed ? NSUnderlineStyle.single.rawValue : 0])
        }
        if requestFocus && !coordinator.editing {
            DispatchQueue.main.async { [weak field,weak coordinator] in
                guard let field,let coordinator,coordinator.parent.requestFocus,!coordinator.editing else { return }
                field.window?.makeFirstResponder(field)
                coordinator.begin(field)
            }
        }
    }
    final class Coordinator: NSObject,NSTextFieldDelegate {
        var parent: TaskNameField
        var editing = false
        var original = ""
        var cancelled = false
        init(_ parent: TaskNameField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            begin(field)
        }
        func begin(_ field: NSTextField) {
            (field as? TaskNameTextField)?.trackDoubleClick()
            if let editor = field.currentEditor() as? NSTextView {
                editor.drawsBackground = false; editor.backgroundColor = .clear
            }
            guard !editing else { return }
            original = field.stringValue; editing = true; cancelled = false
            parent.onBegin()
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,editing else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            editing = false
            if cancelled || value.isEmpty { field.stringValue = original }
            parent.onEnd(cancelled || value.isEmpty ? nil : value)
        }
        func control(_ control: NSControl,textView: NSTextView,doCommandBy selector: Selector) -> Bool {
            // Leave Return to the input method while it is composing Chinese text.
            if selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
                control.window?.makeFirstResponder(nil); return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                cancelled = true
                (control as? NSTextField)?.stringValue = original
                control.window?.makeFirstResponder(nil); return true
            }
            return false
        }
    }
}

final class TaskNameTextField: NSTextField,NSDraggingSource {
    var onActivate: ((NSTextField) -> Void)?
    var onDoubleClick: (() -> Void)?
    var dragPayload: String?
    var onDragBegin: (() -> Void)?
    private var pendingClick: NSEvent?
    private var lastClickPoint = NSPoint.zero
    private var lastClickTime: TimeInterval = 0
    private static weak var activeField: TaskNameTextField?
    private static var doubleClickMonitor: Any?
    func trackDoubleClick() {
        Self.activeField = self
        guard Self.doubleClickMonitor == nil else { return }
        Self.doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let field = Self.activeField,field.window === event.window,field.currentEditor() != nil else { return event }
            if event.clickCount == 1 { field.lastClickPoint = event.locationInWindow; field.lastClickTime = event.timestamp; return event }
            guard event.clickCount == 2,event.timestamp - field.lastClickTime <= NSEvent.doubleClickInterval,
                  hypot(event.locationInWindow.x - field.lastClickPoint.x,event.locationInWindow.y - field.lastClickPoint.y) <= 6 else { return event }
            let action = field.onDoubleClick
            field.window?.makeFirstResponder(nil)
            DispatchQueue.main.async { action?() }
            return nil
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled && isEditable { addCursorRect(bounds,cursor: .iBeam) }
    }
    override func mouseDown(with event: NSEvent) {
        lastClickPoint = event.locationInWindow; lastClickTime = event.timestamp
        if event.clickCount == 2 {
            window?.makeFirstResponder(nil); onDoubleClick?(); return
        }
        if dragPayload != nil && currentEditor() == nil {
            pendingClick = event; return
        }
        super.mouseDown(with: event)
        // NSTextField selects all on its first click. Match the clicked position instead.
        if event.clickCount == 1,let editor = currentEditor() as? NSTextView {
            let point = editor.convert(event.locationInWindow,from: nil)
            let index = min(editor.characterIndexForInsertion(at: point),(editor.string as NSString).length)
            editor.setSelectedRange(NSRange(location: index,length: 0))
        }
        onActivate?(self)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down = pendingClick,let dragPayload else { super.mouseDragged(with: event); return }
        guard hypot(event.locationInWindow.x - down.locationInWindow.x,event.locationInWindow.y - down.locationInWindow.y) >= 4 else { return }
        pendingClick = nil; onDragBegin?()
        beginRecordDrag(in: self,event: event,payload: dragPayload,source: self)
    }
    override func mouseUp(with event: NSEvent) {
        guard pendingClick != nil else { super.mouseUp(with: event); return }
        pendingClick = nil
        window?.makeFirstResponder(self)
        if let editor = currentEditor() as? NSTextView {
            let point = editor.convert(event.locationInWindow,from: nil)
            let index = min(editor.characterIndexForInsertion(at: point),(editor.string as NSString).length)
            editor.setSelectedRange(NSRange(location: index,length: 0))
        }
        onActivate?(self)
    }
    func draggingSession(_ session: NSDraggingSession,willBeginAt screenPoint: NSPoint) { TaskDragFeedback.shared.begin(session: session.draggingSequenceNumber,payload: dragPayload ?? "") }
    func draggingSession(_ session: NSDraggingSession,endedAt screenPoint: NSPoint,operation: NSDragOperation) { TaskDragFeedback.shared.end(session: session.draggingSequenceNumber) }
    func draggingSession(_ session: NSDraggingSession,sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

private func beginRecordDrag(in view: NSView,event: NSEvent,payload: String,source: NSDraggingSource) {
    let point = view.convert(event.locationInWindow,from: nil)
    let writer = NSPasteboardItem(); writer.setString(payload,forType: .string)
    let item = NSDraggingItem(pasteboardWriter: writer)
    // Placement feedback already identifies the destination. Keep AppKit's drag
    // image transparent so a detached grip does not follow the pointer.
    let image = NSImage(size: NSSize(width: 1,height: 1),flipped: false) { _ in true }
    item.setDraggingFrame(NSRect(x: point.x,y: point.y,width: 1,height: 1),contents: image)
    view.beginDraggingSession(with: [item],event: event,source: source)
}

/// Drop feedback lives only for a native drag session, including cancelled drags.
@MainActor final class TaskDragFeedback: ObservableObject {
    static let shared = TaskDragFeedback()
    struct State: Equatable {
        var session: Int
        var payload: String
        var target: UUID? = nil
        var position: TaskPlacement.Position = .before
        var topLevelTarget: UUID?
        var listTarget: UUID?
        var listAfter = false
    }
    @Published private(set) var state: State?
    func begin(session: Int,payload: String = "") { state = State(session: session,payload: payload) }
    func hover(target: UUID,position: TaskPlacement.Position) {
        guard var current = state,!current.payload.hasPrefix("zilo-list:") else { return }
        if current.payload == target.uuidString {
            current.target = nil
            if state != current { state = current }
            return
        }
        current.target = target; current.position = position; current.topLevelTarget = nil; current.listTarget = nil
        if state != current { state = current }
    }
    func exit(target: UUID) {
        guard var current = state,current.target == target else { return }
        current.target = nil; state = current
    }
    func hoverTopLevel(after target: UUID) {
        guard var current = state,!current.payload.hasPrefix("zilo-list:") else { return }
        current.topLevelTarget = target; current.target = nil; current.listTarget = nil
        if state != current { state = current }
    }
    func exitTopLevel(after target: UUID) {
        guard var current = state,current.topLevelTarget == target else { return }
        current.topLevelTarget = nil; state = current
    }
    func hoverList(target: UUID,after: Bool) {
        guard var current = state else { return }
        if current.payload == "zilo-list:" + target.uuidString {
            current.listTarget = nil
            if state != current { state = current }
            return
        }
        current.listTarget = target; current.listAfter = after; current.target = nil; current.topLevelTarget = nil
        if state != current { state = current }
    }
    func exitList(target: UUID) {
        guard var current = state,current.listTarget == target else { return }
        current.listTarget = nil; state = current
    }
    func end(session: Int) {
        guard state?.session == session else { return }
        state = nil
    }
}

/// An AppKit drag source keeps the narrow grip responsive beside editable native fields.
struct TaskDragHandle: NSViewRepresentable {
    var payload: String
    var visible: Bool
    var onBegin: () -> Void
    var onClick: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var accessibilityName = "拖动任务"
    var excludedTitleHeight: CGFloat? = nil
    func makeNSView(context: Context) -> TaskDragHandleView {
        let view = TaskDragHandleView(); view.title = ""; view.isBordered = false
        view.target = view; view.action = #selector(TaskDragHandleView.activate)
        return view
    }
    func updateNSView(_ view: TaskDragHandleView,context: Context) {
        view.payload = payload; view.showsGrip = visible; view.onBegin = onBegin; view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.excludedTitleHeight = excludedTitleHeight
        view.setAccessibilityLabel(accessibilityName); view.needsDisplay = true
    }
}
final class TaskDragHandleView: NSButton,NSDraggingSource {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var payload = ""
    var showsGrip = false
    var onBegin: (() -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var excludedTitleHeight: CGFloat?
    private var mouseDownEvent: NSEvent?
    private var beganDragging = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point,from: superview)
        // Disclosure, completion and the native editable title keep their own input.
        if let height = excludedTitleHeight,local.x >= 16,local.y >= 10,local.y <= 10 + height { return nil }
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        if let height = excludedTitleHeight {
            addCursorRect(NSRect(x: 0,y: 0,width: bounds.width,height: min(10,bounds.height)),cursor: .arrow)
            addCursorRect(NSRect(x: 0,y: 0,width: min(16,bounds.width),height: bounds.height),cursor: .arrow)
            let bottom = min(bounds.height,10 + height)
            addCursorRect(NSRect(x: 0,y: bottom,width: bounds.width,height: bounds.height - bottom),cursor: .arrow)
        } else { addCursorRect(bounds,cursor: .arrow) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard showsGrip,let image = NSImage(systemSymbolName: "line.3.horizontal",accessibilityDescription: "拖动任务") else { return }
        image.draw(in: NSRect(x: (bounds.width - 14) / 2,y: (bounds.height - 12) / 2,width: 14,height: 12),from: .zero,operation: .sourceOver,fraction: 0.65)
    }
    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event; beganDragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent,!beganDragging else { return }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x,event.locationInWindow.y - down.locationInWindow.y)
        guard distance >= 4 else { return }
        beganDragging = true; mouseDownEvent = nil
        onBegin?()
        beginRecordDrag(in: self,event: event,payload: payload,source: self)
    }
    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil && !beganDragging {
            if event.clickCount == 2,let onDoubleClick { onDoubleClick() } else { onClick?() }
        }
        mouseDownEvent = nil
    }
    @objc func activate() { onClick?() }
    func draggingSession(_ session: NSDraggingSession,willBeginAt screenPoint: NSPoint) {
        TaskDragFeedback.shared.begin(session: session.draggingSequenceNumber,payload: payload)
    }
    func draggingSession(_ session: NSDraggingSession,endedAt screenPoint: NSPoint,operation: NSDragOperation) {
        // AppKit sends this for successful drops, Esc, and drops outside the window.
        TaskDragFeedback.shared.end(session: session.draggingSequenceNumber)
    }
    func draggingSession(_ session: NSDraggingSession,sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

struct TaskRowHover: NSViewRepresentable {
    var changed: (Bool) -> Void
    func makeNSView(context: Context) -> TaskRowHoverView { TaskRowHoverView() }
    func updateNSView(_ view: TaskRowHoverView,context: Context) { view.changed = changed }
}
final class TaskRowHoverView: NSView {
    var changed: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,options: [.activeAlways,.inVisibleRect,.mouseEnteredAndExited,.enabledDuringMouseDrag],owner: self,userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { changed?(true) }
    override func mouseExited(with event: NSEvent) { changed?(false) }
}

struct CheckReminderSettings: View {
    @Binding var check: CheckItem
    @State private var minutes = 15.0
    var body: some View { VStack(alignment: .leading,spacing: 14) {
        Text(check.title).font(.headline).lineLimit(2)
        Toggle("检查项提醒",isOn: Binding(get: { check.due != nil },set: { value in check.due = value ? Date().addingTimeInterval(3600) : nil; check.reminders = value ? [0] : nil }))
        if check.due != nil {
            DatePicker("日期与时间",selection: Binding(get: { check.due ?? Date() },set: { check.due = $0 }))
            ForEach([0.0,300,900,1800,3600,86400],id: \.self) { offset in
                Toggle(offset == 0 ? ZiloLanguage.text("到时提醒") : ZiloLanguage.format("提前 %lld 分钟",Int(offset / 60)),isOn: Binding(get: { (check.reminders ?? [0]).contains(offset) },set: { value in var offsets = check.reminders ?? [0]; offsets.removeAll { $0 == offset }; if value { offsets.append(offset) }; check.reminders = offsets }))
            }
            HStack { TextField("分钟",value: $minutes,format: .number).frame(width: 70); Button("添加提醒") { if minutes.isFinite && minutes > 0 { var offsets = check.reminders ?? [0]; if !offsets.contains(minutes * 60) { offsets.append(minutes * 60) }; check.reminders = offsets } } }
            ForEach((check.reminders ?? []).filter { ![0.0,300,900,1800,3600,86400].contains($0) },id: \.self) { offset in HStack { Text(ZiloLanguage.format("提前 %lld 分钟",Int(offset / 60))); Spacer(); Button("移除") { check.reminders?.removeAll { $0 == offset } } } }
        }
    } }
}
