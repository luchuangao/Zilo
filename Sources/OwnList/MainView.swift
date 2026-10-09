import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Module: String, CaseIterable { case tasks = "任务", calendar = "日历", matrix = "四象限", focus = "专注", habits = "习惯", stats = "统计"
    var icon: String { switch self { case .tasks: return "checkmark.square.fill"; case .calendar: return "calendar"; case .matrix: return "square.grid.2x2"; case .focus: return "timer"; case .habits: return "leaf"; case .stats: return "chart.bar" } }
}
struct ListEditorRequest: Identifiable { let id = UUID(); var existing: TaskList? }
struct MainView: View {
    @AppStorage("markdownPreviewVisible") private var previewMarkdown = true
    var showingMarkdownPreview: Bool { detailsVisible && previewMarkdown && store.tasks.first { $0.id == store.selectedTask }?.editingMode == .markdown }
    @EnvironmentObject var store: Store
    @State private var module: Module = .tasks; @State private var selection = "today"; @State private var search = ""; @State private var viewMode = "列表"; @State private var sort = "手动"; @State private var showCompleted = true; @State private var parallel = false
    @State private var listOptionsVisible = false; @State private var displayOptionsVisible = false; @State private var showSummaries = true;
    @State private var searchVisible = false; @FocusState private var searchFocused: Bool
    @State private var sidebarVisible = true; @State private var detailsVisible = true
    @FocusState private var sidebarFocused: Bool
    @State private var listEditorRequest: ListEditorRequest?; @State private var expandedFolders = Set<String>(); @State private var showFilter = false; @State private var editFilter: SavedFilter?; @State private var importPreview: ImportPreview?; @State private var showImport = false
    @AppStorage("fontScale") var fontScale = 14.0; @AppStorage("accent") var accent = "blue"
    var body: some View {
        GeometryReader { geometry in
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                BrandIcon(size: 36).padding(.top,42).padding(.bottom,4)
                ForEach(Module.allCases,id: \.self) { item in
                    Button { module = item } label: {
                        Image(systemName: item.icon).font(.system(size: 20,weight: .regular))
                            .frame(width: 38,height: 38)
                            .foregroundStyle(module == item ? accent.listColor : ListTheme.secondary)
                    }.buttonStyle(.plain).quietHover(selected: module == item)
                        .help(item.rawValue).accessibilityLabel(item.rawValue)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 19)).frame(width: 34,height: 34) }
                    .buttonStyle(.plain).quietHover().help("设置").accessibilityLabel("设置")
                Button { importFile() } label: { Image(systemName: "square.and.arrow.down").font(.system(size: 17)).frame(width: 34,height: 34) }
                    .buttonStyle(.plain).quietHover().help("导入备份")
                Text("个人版").font(.system(size: 10)).foregroundStyle(ListTheme.secondary)
            }.foregroundStyle(ListTheme.secondary).padding(.bottom,16).frame(width: 64).background(ListTheme.rail)
            Divider().overlay(ListTheme.separator)
            if module == .tasks {
                HSplitView {
                    if sidebarVisible { sidebar.ignoresSafeArea(.container,edges: .top).frame(minWidth: 196,idealWidth: 216,maxWidth: 224).frame(maxHeight: .infinity) }
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left").font(.system(size: 16)).frame(width: 24,height: 28) }
                                .buttonStyle(.plain).foregroundStyle(ListTheme.secondary).quietHover().help("显示或隐藏清单导航")
                            Text(title).font(.system(size: 20,weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Menu {
                                Picker("排序",selection: $sort) { ForEach(["手动","日期","优先级","标题","创建时间"],id: \.self) { Text($0) } }
                            } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 16)).frame(width: 32,height: 32).contentShape(Rectangle()) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().quietHover().foregroundStyle(ListTheme.secondary).tint(ListTheme.secondary).help("排序").accessibilityLabel("任务排序")
                            Button { listOptionsVisible.toggle() } label: { Image(systemName: "ellipsis").font(.system(size: 17)).frame(width: 32,height: 32).contentShape(Rectangle()) }
                                .buttonStyle(.plain).quietHover(selected: listOptionsVisible).foregroundStyle(ListTheme.secondary).help("清单选项").accessibilityLabel("清单选项")
                                .popover(isPresented: $listOptionsVisible,arrowEdge: .bottom) { listOptions }
                        }.padding(.horizontal,20).frame(height: 52)
                        if searchVisible {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").foregroundStyle(ListTheme.secondary)
                                TextField("搜索任务、描述、标签",text: $search).textFieldStyle(.plain).focused($searchFocused)
                                Button { search = ""; searchVisible = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ListTheme.secondary) }.buttonStyle(.plain).help("关闭搜索")
                            }.padding(.horizontal,12).frame(height: 36).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal,20).padding(.bottom,10)
                        }
                        TaskWorkspace(tasks: sortedTasks,viewMode: viewMode,showCompleted: showCompleted,listID: selectedListID,isTrash: selection == "trash",isTemplates: selection == "templates",sort: sort,creationContext: selection,showSummaries: showSummaries).id(selection)
                    }.ignoresSafeArea(.container,edges: .top).frame(minWidth: 320,idealWidth: 380,maxWidth: detailsVisible ? max(320,(geometry.size.width - 65 - (sidebarVisible ? 220 : 0) - (parallel ? 310 : 0)) * 0.40) : .infinity,maxHeight: .infinity,alignment: .top)
                    if parallel { CalendarView(compact: true).frame(minWidth: 310,idealWidth: 380) }
                    if detailsVisible { TaskDetailView().ignoresSafeArea(.container,edges: .top).frame(minWidth: showingMarkdownPreview ? 620 : 340,idealWidth: 480,maxWidth: .infinity,maxHeight: .infinity) }
                }
            } else { Group { switch module { case .calendar: CalendarView(); case .matrix: MatrixView(); case .focus: FocusView(); case .habits: HabitsView(); case .stats: StatisticsView(); case .tasks: EmptyView() } }.frame(maxWidth: .infinity,maxHeight: .infinity) }
        }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
        }.ignoresSafeArea(.container,edges: .top).background(WindowChrome()).background(ListTheme.canvas).foregroundStyle(ListTheme.text).font(.system(size: fontScale)).tint(accent.listColor).accentColor(accent.listColor).frame(minWidth: (parallel ? 1240 : 1000) + (showingMarkdownPreview ? 260 : 0),minHeight: 620)
            .onChange(of: selection) { _,_ in listOptionsVisible = false; store.selectedTask = nil; search = ""; viewMode = store.lists.first { $0.id == selectedListID }?.defaultView ?? "列表" }
            .onChange(of: viewMode) { _,value in if let id = selectedListID, var list = store.lists.first(where: { $0.id == id }), list.defaultView != value { list.defaultView = value; store.save(list,undoable: false) } }
            .onChange(of: searchVisible) { _,visible in if visible { DispatchQueue.main.async { searchFocused = true } } else { search = "" } }
            .background(Button("搜索任务") { if searchVisible { searchFocused = true } else { searchVisible = true } }.keyboardShortcut("f",modifiers: .command).hidden())
            .sheet(item: $listEditorRequest) { request in
                ListEditor(existing: request.existing) { list in
                    if !list.folder.isEmpty { expandedFolders.insert(list.folder) }
                    selection = "list:" + list.id.uuidString; search = ""; viewMode = list.defaultView ?? "列表"; store.selectedTask = nil
                }.environmentObject(store)
            }
            .sheet(isPresented: $showFilter) { FilterEditor(existing: editFilter).environmentObject(store) }
            .sheet(isPresented: $showImport) { if let preview = importPreview { ImportView(preview: preview).environmentObject(store) } }
            .alert("操作未完成",isPresented: Binding(get: { store.error != nil },set: { if !$0 { store.error = nil } })) { Button("好") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    var listOptions: some View {
        VStack(alignment: .leading,spacing: 2) {
            Text("视图").font(.system(size: 11)).foregroundStyle(ListTheme.secondary).padding(.horizontal,10).padding(.top,6)
            HStack(spacing: 8) {
                ForEach(["列表","看板","时间线"],id: \.self) { mode in
                    Button { viewMode = mode; listOptionsVisible = false } label: {
                        Image(systemName: mode == "列表" ? "list.bullet.rectangle" : mode == "看板" ? "rectangle.split.3x1" : "chart.bar.xaxis")
                            .font(.system(size: 21)).frame(maxWidth: .infinity).frame(height: 38)
                            .foregroundStyle(viewMode == mode ? Color.accentColor : ListTheme.text)
                            .background(viewMode == mode ? Color.accentColor.opacity(0.08) : .clear,in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).help(mode).accessibilityLabel("切换到" + mode).accessibilityAddTraits(viewMode == mode ? [.isSelected] : [])
                }
            }.padding(.horizontal,6).padding(.bottom,4)
            Divider().padding(.vertical,4)
            optionRow(showCompleted ? "隐藏已完成" : "显示已完成","checkmark.square") { showCompleted.toggle(); listOptionsVisible = false }
            optionRow(showSummaries ? "隐藏摘要" : "显示摘要","list.bullet") { showSummaries.toggle(); listOptionsVisible = false }
            optionRow("显示设置","slider.horizontal.3") { displayOptionsVisible.toggle() }
            if displayOptionsVisible {
                VStack(alignment: .leading,spacing: 10) {
                    Toggle("任务详情",isOn: $detailsVisible)
                    Toggle("并列日历",isOn: $parallel)
                }.toggleStyle(.checkbox).font(.system(size: 12)).padding(10)
            }
            Divider().padding(.vertical,4)
            if let list = store.lists.first(where: { $0.id == selectedListID }) {
                optionRow("添加分组","plus") { listOptionsVisible = false; listEditorRequest = ListEditorRequest(existing: list) }
                optionRow("编辑清单","square.and.pencil") { listOptionsVisible = false; listEditorRequest = ListEditorRequest(existing: list) }
            }
            optionRow("搜索任务","magnifyingglass") { listOptionsVisible = false; searchVisible = true }
            optionRow("桌面便签","note.text") { listOptionsVisible = false; DesktopBridge.panel(title: title,view: StickyView(listID: selectedListID).environmentObject(store)) }
            optionRow("打印","printer") { listOptionsVisible = false; printList() }
            if let id = selectedListID {
                Divider().padding(.vertical,4)
                optionRow("删除清单","trash") { listOptionsVisible = false; if store.deleteList(id) { selection = "trash" } }
            }
        }.padding(8).frame(width: 200).background(ListTheme.canvas)
    }
    func optionRow(_ title: String,_ symbol: String,action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 12) { Image(systemName: symbol).font(.system(size: 16)).frame(width: 20); Text(title).font(.system(size: 13)); Spacer(minLength: 0) }.padding(.horizontal,10).frame(height: 34).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(ListTheme.text).quietHover()
    }
    func printList() {
        var task = TaskItem(); task.title = title
        let content = NSMutableAttributedString(string: "")
        for item in sortedTasks where showCompleted || !item.completed {
            content.append(NSAttributedString(string: "\(item.completed ? "☑" : "☐") \(item.title)\n",attributes: [.font: NSFont.boldSystemFont(ofSize: 16)]))
            if showSummaries { content.append(item.richText.flatMap(RichDocument.decode) ?? MarkdownDocument.parse(item.notes,baseURL: store.persistence.root).content) }
            content.append(NSAttributedString(string: "\n\n",attributes: MarkdownTyping.bodyAttributes))
        }
        task.notes = content.string; task.richText = RichDocument.encode(content)
        NSPrintOperation(view: TaskPrintDocument.makeView(task: task,children: [],baseURL: store.persistence.root)).run()
    }
    var sidebar: some View {
        VStack(alignment: .leading,spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading,spacing: 3) {
                        nav("今天","calendar","today")
                        nav("最近 7 天","calendar.badge.clock","week")
                        nav("收集箱","tray","inbox")
                        nav("全部任务","square.stack","all")
                        nav("收藏","star","starred")
                        sidebarHeading("清单") { listEditorRequest = ListEditorRequest(existing: nil) }
                        ForEach(folders,id: \.self) { folder in
                            DisclosureGroup(isExpanded: Binding(get: { expandedFolders.contains(folder) },set: { if $0 { expandedFolders.insert(folder) } else { expandedFolders.remove(folder) } })) {
                                ForEach(store.lists.filter { !$0.deleted && $0.folder == folder }.sorted { $0.order < $1.order }) { listRow($0) }
                            } label: {
                                Label(folder,systemImage: "folder").font(.system(size: 12)).foregroundStyle(ListTheme.secondary)
                                    .contextMenu { Button("重命名文件夹") { renameFolder(folder) } }
                            }.padding(.horizontal,8).padding(.vertical,5)
                        }
                        ForEach(store.lists.filter { !$0.deleted && $0.folder.isEmpty }.sorted { $0.order < $1.order }) { listRow($0) }
                        sidebarHeading("过滤器") { editFilter = nil; showFilter = true }
                        ForEach(store.filters.filter { !$0.deleted }) { filter in
                            sidebarChoice(filter.name,"line.3.horizontal.decrease.circle","filter:" + filter.id.uuidString)
                                .contextMenu { Button("编辑") { editFilter = filter; showFilter = true }; Button("删除",role: .destructive) { var f = filter; f.deleted = true; store.save(f) } }
                        }
                        Text("标签").font(.system(size: 11,weight: .medium)).foregroundStyle(ListTheme.secondary).padding(.horizontal,12).padding(.top,18).padding(.bottom,6)
                        ForEach(tags,id: \.self) { tag in sidebarChoice(tag,"tag","tag:" + tag) }
                        Divider().overlay(ListTheme.separator).padding(.vertical,12).padding(.horizontal,8)
                        nav("任务模板","doc.on.doc","templates")
                        nav("已完成","checkmark.square","completed")
                        nav("归档任务","archivebox","archived")
                        nav("回收站","trash","trash")
                    }.padding(.horizontal,10).padding(.top,16).padding(.bottom,12)
                }.focusable().focused($sidebarFocused).focusEffectDisabled()
                    .onMoveCommand { direction in
                        let keys = sidebarKeys
                        guard let index = keys.firstIndex(of: selection) else { return }
                        if direction == .down && index + 1 < keys.count { selection = keys[index + 1] }
                        else if direction == .up && index > 0 { selection = keys[index - 1] }
                    }
                    .onChange(of: selection) { _,key in reader.scrollTo(key) }
            }
            Divider().overlay(ListTheme.separator)
            Button { listEditorRequest = ListEditorRequest(existing: nil) } label: {
                Label("新建清单",systemImage: "plus").font(.system(size: 12)).frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,12).frame(height: 34)
            }.buttonStyle(.plain).quietHover().keyboardShortcut("l",modifiers: [.command,.shift]).padding(.horizontal,10).padding(.top,6)
            HStack(alignment: .top,spacing: 6) {
                Circle().fill(store.syncStatus.contains("失败") ? Color.orange : Color.green).frame(width: 5,height: 5).padding(.top,5)
                Text(store.syncStatus.contains("失败") ? "同步暂不可用 · 已保存在本机" : store.syncStatus).font(.system(size: 10)).foregroundStyle(ListTheme.secondary).lineLimit(2).help(store.syncStatus)
            }.padding(.horizontal,18).padding(.top,4).padding(.bottom,12)
        }.background(ListTheme.sidebar)
    }
    var folders: [String] { Array(Set(store.lists.filter { !$0.deleted && !$0.folder.isEmpty }.map(\.folder))).sorted() }
    var tags: [String] { Array(Set(store.tasks.filter { !$0.deleted }.flatMap(\.tags))).sorted() }
    var sidebarKeys: [String] {
        var keys = ["today","week","inbox","all","starred"]
        for folder in folders where expandedFolders.contains(folder) {
            let lists = store.lists.filter { !$0.deleted && $0.folder == folder }.sorted { $0.order < $1.order }
            keys += lists.map { "list:" + $0.id.uuidString }
        }
        let unfiled = store.lists.filter { !$0.deleted && $0.folder.isEmpty }.sorted { $0.order < $1.order }
        keys += unfiled.map { "list:" + $0.id.uuidString }
        keys += store.filters.filter { !$0.deleted }.map { "filter:" + $0.id.uuidString }
        keys += tags.map { "tag:" + $0 }
        return keys + ["templates","completed","archived","trash"]
    }
    func sidebarHeading(_ title: String,action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 11,weight: .medium)).foregroundStyle(ListTheme.secondary)
            Spacer()
            Button(action: action) { Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(ListTheme.secondary).frame(width: 28,height: 28).contentShape(Rectangle()) }
                .buttonStyle(.plain).quietHover().help("新建" + title).accessibilityLabel("新建" + title)
        }.padding(.leading,12).padding(.trailing,4).padding(.top,16).padding(.bottom,4)
    }
    func sidebarChoice(_ text: String,_ icon: String,_ key: String,color: Color? = nil,count: Int = 0) -> some View {
        Button { selection = key; sidebarFocused = true } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 20).foregroundStyle(ListTheme.text)
                Text(text).lineLimit(1)
                Spacer(minLength: 4)
                if let color { Circle().fill(color).frame(width: 7,height: 7) }
                if count > 0 { Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(ListTheme.secondary) }
            }.padding(.horizontal,12).frame(minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(ListTheme.text).quietHover(selected: selection == key)
            .id(key).accessibilityAddTraits(selection == key ? .isSelected : [])
    }
    func nav(_ text: String,_ icon: String,_ key: String) -> some View { sidebarChoice(text,icon,key,count: key == "trash" ? store.trashEntryCount : filtered(key).filter { !$0.completed }.count) }
    func listRow(_ list: TaskList) -> some View {
        let count = store.tasks.filter { $0.listID == list.id && !$0.deleted && !$0.completed && !$0.isTemplate && $0.archived != true && $0.parentID == nil }.count
        return sidebarChoice(list.name,"line.3.horizontal","list:" + list.id.uuidString,color: list.color == "none" ? nil : list.color.listColor,count: count)
            .contextMenu { Button("编辑清单") { listEditorRequest = ListEditorRequest(existing: list) }; Button("删除清单",role: .destructive) { if store.deleteList(list.id) { selection = "trash" } } }
            .dropDestination(for: String.self) { values,_ in for value in values { if let id = UUID(uuidString: value) { store.mutate(id) { $0.listID = list.id } } }; return true }
    }
    var selectedListID: UUID? { selection.hasPrefix("list:") ? UUID(uuidString: String(selection.dropFirst(5))) : nil }
    var title: String { switch selection { case "today": return "今天"; case "week": return "最近 7 天"; case "inbox": return "收集箱"; case "all": return "全部任务"; case "completed": return "已完成"; case "archived": return "归档任务"; case "trash": return "回收站"; case "starred": return "收藏"; case "templates": return "任务模板"; default: if let id = selectedListID { return store.lists.first { $0.id == id }?.name ?? "清单" }; if selection.hasPrefix("tag:") { return "#" + selection.dropFirst(4) }; return store.filters.first { "filter:" + $0.id.uuidString == selection }?.name ?? "任务" } }
    func filtered(_ key: String) -> [TaskItem] {
        store.tasks.filter { t in
            if key == "trash" { return t.deleted }; guard !t.deleted else { return false }
            if key == "archived" { return t.archived == true }; if key == "templates" { return t.isTemplate && t.parentID == nil }; guard t.archived != true else { return false }; guard !t.isTemplate && t.parentID == nil else { return false }
            switch key { case "today": return t.due.map { $0 < Calendar.current.date(byAdding: .day,value: 1,to: Calendar.current.startOfDay(for: Date()))! } == true && !t.completed
            case "week": return t.due.map { $0 < Calendar.current.date(byAdding: .day,value: 7,to: Calendar.current.startOfDay(for: Date()))! } == true && !t.completed
            case "inbox": return t.listID == nil
            case "all": return true
            case "completed": return t.completed
            case "starred": return t.starred
            default: if key.hasPrefix("list:") { return t.listID?.uuidString == String(key.dropFirst(5)) }; if key.hasPrefix("tag:") { return t.tags.contains(String(key.dropFirst(4))) }; if let filter = store.filters.first(where: { "filter:" + $0.id.uuidString == key }) { return filter.matches(t) }; return false }
        }
    }
    var sortedTasks: [TaskItem] { filtered(selection).filter { search.isEmpty || ($0.title + " " + $0.notes + " " + $0.tags.joined(separator: " ")).localizedCaseInsensitiveContains(search) }.sorted { a,b in switch sort { case "日期": return (a.due ?? .distantFuture) < (b.due ?? .distantFuture); case "优先级": return a.priority > b.priority; case "标题": return a.title.localizedStandardCompare(b.title) == .orderedAscending; case "创建时间": return a.created > b.created; default: return a.order < b.order } } }
    func importFile() { let p = NSOpenPanel(); p.allowedContentTypes = [.json,.commaSeparatedText,.plainText]; if p.runModal() == .OK, let url = p.url { do { importPreview = try ImportService.preview(url); showImport = true } catch { store.error = error.localizedDescription } } }
    func renameFolder(_ old: String) { let alert = NSAlert(); alert.messageText = "重命名文件夹"; let field = NSTextField(string: old); field.frame = NSRect(x: 0,y: 0,width: 260,height: 24); alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); if alert.runModal() == .alertFirstButtonReturn { for var list in store.lists.filter({ $0.folder == old }) { list.folder = field.stringValue.trimmingCharacters(in: .whitespaces); store.save(list) } } }
}
struct TaskWorkspace: View {
    @EnvironmentObject var store: Store; var tasks: [TaskItem]; var viewMode: String; var showCompleted: Bool; var listID: UUID?; var isTrash: Bool; var isTemplates: Bool; var sort: String; var creationContext = "all"; var showSummaries = true
    @State private var input = ""; @State private var multi = Set<UUID>(); @State private var batchMode = false; @State private var completedExpanded = false; @State private var entrySection = ""; @FocusState private var inputFocused: Bool
    var trashLists: [TaskList] { isTrash ? store.lists.filter(\.deleted).sorted { $0.order < $1.order } : [] }
    var visible: [TaskItem] { tasks.filter { task in
        (showCompleted || !task.completed || isTrash) && !(isTrash && trashLists.contains { $0.id == task.trashedWithList })
    } }
    var body: some View { VStack(spacing: 0) {
        if !isTrash && creationContext != "completed" && creationContext != "archived" { HStack { Image(systemName: "plus"); TextField(entryPlaceholder,text: $input).foregroundStyle(ListTheme.text).textFieldStyle(.plain).focused($inputFocused).onSubmit { addTask(section: entrySection) }; Button { batchMode.toggle(); multi = [] } label: { Image(systemName: batchMode ? "checkmark.circle.fill" : "checklist") }.buttonStyle(.plain).help("批量编辑") }.foregroundStyle(ListTheme.secondary).padding(.horizontal,12).frame(height: 40).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal,20).padding(.top,6).padding(.bottom,8) }
        if batchMode && !multi.isEmpty { HStack { Text("已选 \(multi.count) 项"); Menu("移动") { Button("收集箱") { store.move(multi,to: nil) }; ForEach(store.lists.filter { !$0.deleted }) { l in Button(l.name) { store.move(multi,to: l.id) } } }; Menu("优先级") { ForEach(0...3,id: \.self) { p in Button("\(p)") { batch { $0.priority = p } } } }; Button("今天") { batch { $0.due = Calendar.current.startOfDay(for: Date()) } }; Button("完成") { let before = store.backup; for id in multi { store.complete(id) }; store.groupUndo(before) }; Button("删除",role: .destructive) { batch { $0.deleted = true }; multi = [] } }.font(.caption).padding(8) }
        if visible.isEmpty && trashLists.isEmpty && (viewMode != "列表" || (store.lists.first { $0.id == listID }?.sections.isEmpty ?? true)) { QuietEmptyState(title: isTrash ? "回收站为空" : "清单很清爽",message: "把想做的事情记下来，一件一件完成。",symbol: "checkmark.circle") }
        else if viewMode == "看板" && !isTrash { ScrollView(.horizontal) { HStack(alignment: .top,spacing: 12) { ForEach(["待安排","进行中","已完成"],id: \.self) { column in VStack(alignment: .leading) { Text(column).font(.headline).padding(10); ForEach(visible.filter { column == "已完成" ? $0.completed : column == "进行中" ? !$0.completed && $0.start != nil : !$0.completed && $0.start == nil }) { t in row(t).padding(10).background(.background,in: RoundedRectangle(cornerRadius: 10)) }; Spacer() }.padding(8).frame(width: 260).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 10)).dropDestination(for: String.self) { values,_ in for raw in values { if let id = UUID(uuidString: raw) { store.mutate(id) { $0.completed = column == "已完成"; $0.completedAt = $0.completed ? Date() : nil; $0.start = column == "进行中" ? Date() : nil } } }; return true } } }.padding(20) } }
        else if viewMode == "时间线" && !isTrash { TimelineViewContent(tasks: visible) }
        else { List {
            if !trashLists.isEmpty {
                Section("已删除的清单") {
                    ForEach(trashLists) { list in
                        HStack(spacing: 10) {
                            Image(systemName: "list.bullet.rectangle").foregroundStyle(list.color.listColor)
                            VStack(alignment: .leading,spacing: 4) {
                                Text(list.name).fontWeight(.medium)
                                Text((list.folder.isEmpty ? "" : list.folder + " · ") + "\(store.tasks.filter { $0.trashedWithList == list.id }.count) 个任务").font(.caption).foregroundStyle(ListTheme.secondary)
                            }
                            Spacer()
                            Button("恢复清单") { store.restoreList(list.id) }.buttonStyle(.bordered).accessibilityLabel("恢复清单“" + list.name + "”")
                        }.padding(.vertical,8).contextMenu { Button("恢复清单及任务") { store.restoreList(list.id) } }
                    }
                }
            }
            let configured = store.lists.first { $0.id == listID }?.sections ?? []; let extras = Set(visible.filter { !$0.completed }.map(\.section)).subtracting(configured); let sections = (extras.contains("") ? [""] : []) + configured + extras.filter { !$0.isEmpty }.sorted()
            ForEach(sections,id: \.self) { section in
                if section.isEmpty && configured.isEmpty {
                    sectionRows(section)
                } else {
                    Section { sectionRows(section) } header: {
                        HStack {
                            Text(section.isEmpty ? "待完成" : section)
                            Spacer()
                            Button { addTask(section: section) } label: { Image(systemName: "plus") }.buttonStyle(.plain)
                        }.foregroundStyle(ListTheme.secondary).font(.system(size: 12))
                            .dropDestination(for: String.self) { values,_ in
                                for raw in values { if let id = UUID(uuidString: raw) { store.mutate(id) { $0.section = section } } }
                                return true
                            }
                    }
                }
            }
            let completed = visible.filter(\.completed)
            if (showCompleted || isTrash) && !completed.isEmpty { Section {
                if completedExpanded { ForEach(completed) { row($0).listRowSeparator(.hidden) } }
            } header: { Button { completedExpanded.toggle() } label: { HStack { Image(systemName: completedExpanded ? "chevron.down" : "chevron.right"); Text("已完成").fontWeight(.semibold); Text("\(completed.count)").foregroundStyle(.tertiary) } }.foregroundStyle(ListTheme.secondary).font(.system(size: 12)).buttonStyle(.plain).accessibilityLabel(completedExpanded ? "收起已完成任务" : "展开已完成任务") } }
        }.listStyle(.inset).scrollContentBackground(.hidden) }
    }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading).onAppear { completedExpanded = creationContext == "completed" || isTrash } }
    func sectionRows(_ section: String) -> some View {
        ForEach(visible.filter { !$0.completed && $0.section == section }) { row($0).listRowSeparator(.hidden) }
            .onMove { from,to in reorder(section,from,to) }
    }
    var entryPlaceholder: String { if isTemplates { return "添加模板，回车创建" }; if let list = store.lists.first(where: { $0.id == listID }) { return "添加任务至“\(list.name)”，回车创建" }; if creationContext == "today" { return "添加今天的任务，回车创建" }; if creationContext == "week" { return "添加任务，默认安排在今天" }; return "添加任务至收集箱，回车创建" }
    func addTask(section: String = "") {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { entrySection = section; inputFocused = true; return }
        let due = ["today","week"].contains(creationContext) ? Calendar.current.startOfDay(for: Date()) : nil
        if let id = store.add(text,listID: listID,defaultDue: due,section: section,starred: creationContext == "starred") { if isTemplates { store.mutate(id) { $0.isTemplate = true } }; if creationContext.hasPrefix("tag:") { let tag = String(creationContext.dropFirst(4)); store.mutate(id) { if !$0.tags.contains(tag) { $0.tags.append(tag) } } }; input = ""; entrySection = ""; inputFocused = true }
    }
    func batch(_ body: (inout TaskItem) -> Void) { let before = store.backup; for id in multi { store.mutate(id,body) }; store.groupUndo(before) }
    func reorder(_ section: String,_ from: IndexSet,_ to: Int) { guard sort == "手动" else { return }; var data = visible.filter { !$0.completed && $0.section == section }; data.move(fromOffsets: from,toOffset: to); let before = store.backup; for (index,t) in data.enumerated() { store.mutate(t.id) { $0.order = Double(index) } }; store.groupUndo(before) }
    func row(_ t: TaskItem) -> some View { HStack(alignment: .top,spacing: 12) {
        if batchMode { Toggle("选择",isOn: Binding(get: { multi.contains(t.id) },set: { if $0 { multi.insert(t.id) } else { multi.remove(t.id) } })).labelsHidden().toggleStyle(.checkbox) }
        Button { store.complete(t.id) } label: { Image(systemName: t.completed ? "checkmark.square.fill" : "square").font(.system(size: 17)).foregroundStyle(t.completed ? ListTheme.secondary.opacity(0.7) : t.priority == 3 ? "red".listColor : t.priority == 2 ? "orange".listColor : t.priority == 1 ? Color.accentColor : ListTheme.secondary) }.buttonStyle(.plain).accessibilityLabel(t.completed ? "取消完成" : "完成任务")
        VStack(alignment: .leading,spacing: 5) { Text(t.title).strikethrough(t.completed).foregroundStyle(t.completed ? ListTheme.secondary : ListTheme.text).lineLimit(2); if showSummaries && !TaskDocument.summary(t).isEmpty { Text(TaskDocument.summary(t)).font(.caption).foregroundStyle(ListTheme.secondary).lineLimit(1) }; if t.due != nil || !t.tags.isEmpty || !t.attachments.isEmpty || t.repeatRule.frequency != "none" || store.tasks.contains(where: { $0.parentID == t.id && !$0.deleted }) { HStack(spacing: 8) { if let due = t.due { Text(due.formatted(date: .abbreviated,time: t.allDay ? .omitted : .shortened)).foregroundStyle(Scheduling.isOverdue(t) ? .red : .secondary) }; if !t.tags.isEmpty { Text(t.tags.map { "#" + $0 }.joined(separator: " ")).foregroundStyle(Color.accentColor) }; if !t.attachments.isEmpty { Image(systemName: "paperclip") }; let children = store.tasks.filter { $0.parentID == t.id && !$0.deleted }; if !children.isEmpty { Text("\(children.filter(\.completed).count)/\(children.count)") }; if t.repeatRule.frequency != "none" { Image(systemName: "repeat") } }.font(.caption).foregroundStyle(ListTheme.secondary) } }
        Spacer(); if t.starred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
    }.padding(.vertical,10).padding(.horizontal,8).quietHover(selected: store.selectedTask == t.id).overlay(alignment: .bottom) { if store.selectedTask != t.id { ListTheme.separator.frame(height: 0.5).padding(.leading,34) } }.contentShape(Rectangle()).onTapGesture { store.selectedTask = t.id }.draggable(t.id.uuidString).dropDestination(for: String.self) { values,_ in guard sort == "手动" else { return false }; for raw in values { if let id = UUID(uuidString: raw), id != t.id { let previous = visible.filter { $0.id != id && $0.order < t.order }.map(\.order).max() ?? (t.order - 2); store.mutate(id) { $0.order = (previous + t.order) / 2; $0.section = t.section; $0.listID = t.listID } } }; return true }.contextMenu {
        Button("打开详情") { store.selectedTask = t.id }; Button(t.starred ? "取消收藏" : "收藏") { store.mutate(t.id) { $0.starred.toggle() } }
        if t.isTemplate { Button("从模板创建任务") { store.duplicate(t.id) } }
        else { Button(t.archived == true ? "取消归档" : "归档") { store.mutate(t.id) { $0.archived = t.archived != true } }; Button("保存为模板") { store.duplicate(t.id,asTemplate: true) }; Button("复制") { store.duplicate(t.id) } }
        if t.deleted { Button("恢复") { store.restoreTask(t.id) } } else { Button("移入回收站",role: .destructive) { store.mutate(t.id) { $0.deleted = true } } }
    } }
}
struct TimelineViewContent: View {
    @EnvironmentObject var store: Store; var tasks: [TaskItem]
    var body: some View { ScrollView([.horizontal,.vertical]) { VStack(alignment: .leading,spacing: 12) { HStack { Text("任务").frame(width: 180,alignment: .leading); ForEach(0..<14,id: \.self) { i in Text(Calendar.current.date(byAdding: .day,value: i,to: Calendar.current.startOfDay(for: Date()))!,format: .dateTime.month().day()).frame(width: 60) } }
        ForEach(tasks) { t in HStack(spacing: 0) { Text(t.title).lineLimit(1).frame(width: 180,alignment: .leading).onTapGesture { store.selectedTask = t.id }; ForEach(0..<14,id: \.self) { i in let day = Calendar.current.date(byAdding: .day,value: i,to: Calendar.current.startOfDay(for: Date()))!; let active = t.due.map { Calendar.current.startOfDay(for: $0) >= day && Calendar.current.startOfDay(for: t.start ?? $0) <= day } ?? false; Rectangle().fill(active ? Color.accentColor.opacity(t.completed ? 0.25 : 0.75) : Color.gray.opacity(0.05)).frame(width: 64,height: 25).dropDestination(for: String.self) { values,_ in for raw in values { if let id = UUID(uuidString: raw) { store.mutate(id) { $0.due = day } } }; return true } } }.draggable(t.id.uuidString) }
    }.padding(20) } }
}
