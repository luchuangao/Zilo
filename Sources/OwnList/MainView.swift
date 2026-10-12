import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ListEditorRequest: Identifiable { let id = UUID(); var existing: TaskList? }
struct MainView: View {
    @AppStorage("smartListVisibility") private var rawSmartVisibility = ""
    @EnvironmentObject var store: Store
    @Environment(\.openSettings) private var openSettings
    @State private var profileMenuVisible = false
    @State private var syncPanelVisible = false; @State private var notificationPanelVisible = false
    @AppStorage("moduleVisibility") private var moduleVisibility = ""
    @AppStorage("startupModule") private var startupModule = Module.tasks.rawValue
    @AppStorage("startupSmartList") private var startupSmartList = "today"
    @State private var didInitialize = false
    @State private var module: Module = .tasks; @State private var selection = "today"; @State private var search = ""; @State private var viewMode = "列表"; @State private var sort = "手动"; @State private var showCompleted = true; @State private var parallel = false
    @ObservedObject private var dragFeedback = TaskDragFeedback.shared
    @State private var listOptionsVisible = false; @State private var displayOptionsVisible = false
    @AppStorage("showTaskSummaries") private var showSummaries = false
    @State private var advancedSearch = false
    @State private var searchCriteria = TaskSearchCriteria()
    @State private var searchAll = true
    @State private var searchVisible = false; @FocusState private var searchFocused: Bool
    @State private var sidebarVisible = true; @State private var detailsVisible = true
    @FocusState private var sidebarFocused: Bool
    @State private var listEditorRequest: ListEditorRequest?; @State private var expandedFolders = Set<String>(); @State private var showFilter = false; @State private var editFilter: SavedFilter?; @State private var importPreview: ImportPreview?; @State private var showImport = false
    @AppStorage("fontScale") var fontScale = 14.0; @AppStorage("accent") var accent = "blue"
    var body: some View {
        let _ = accent
        GeometryReader { geometry in
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Button { profileMenuVisible.toggle() } label: { BrandIcon(size: 36).frame(width: 44,height: 44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).quietHover(selected: profileMenuVisible,rail: true).help("Zilo 菜单").accessibilityLabel("Zilo 菜单")
                    .popover(isPresented: $profileMenuVisible,arrowEdge: .trailing) { profileMenu }
                    .padding(.top,38).padding(.bottom,4)
                ForEach(Module.allCases.filter { $0 != .stats && ModulePreferences(rawValue: moduleVisibility).isVisible($0) },id: \.self) { item in
                    Button { module = item } label: {
                        Image(systemName: item.icon).font(.system(size: 20,weight: .regular))
                            .frame(width: 38,height: 38)
                            .foregroundStyle(ListTheme.railForeground)
                    }.buttonStyle(.plain).quietHover(selected: module == item,rail: true)
                        .help(ZiloLanguage.text(item.rawValue)).accessibilityLabel(ZiloLanguage.text(item.rawValue))
                }
                Spacer()
                Button { syncPanelVisible.toggle() } label: { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 21)).frame(width: 38,height: 38) }.buttonStyle(.plain).quietHover(selected: syncPanelVisible,rail: true).help("同步").accessibilityLabel("同步").popover(isPresented: $syncPanelVisible,arrowEdge: .trailing) { SyncStatusPanel().environmentObject(store) }
                Button { notificationPanelVisible.toggle() } label: { Image(systemName: "bell").font(.system(size: 21)).frame(width: 38,height: 38) }.buttonStyle(.plain).quietHover(selected: notificationPanelVisible,rail: true).help("通知与活动").accessibilityLabel("通知与活动").popover(isPresented: $notificationPanelVisible,arrowEdge: .trailing) { NotificationInbox(onOpenTask: openNotificationTask,onOpenModule: { target in module = target; notificationPanelVisible = false }).environmentObject(store) }
            }.foregroundStyle(ListTheme.railForeground).padding(.bottom,16).frame(width: 64).background(ListTheme.rail)
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
                            Button { detailsVisible.toggle() } label: { Image(systemName: "sidebar.right").font(.system(size: 16)).frame(width: 32,height: 32) }
                                .buttonStyle(.plain).foregroundStyle(ListTheme.secondary).quietHover(selected: detailsVisible)
                                .help(detailsVisible ? "隐藏右侧栏预览" : "显示右侧栏预览").accessibilityLabel("右侧栏预览")
                                .accessibilityAddTraits(detailsVisible ? .isSelected : [])
                            Menu {
                                Picker("排序",selection: $sort) { ForEach(["手动","日期","优先级","标题","创建时间"],id: \.self) { Text(LocalizedStringKey($0)) } }
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
                                Button { advancedSearch.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(searchCriteria.isActive ? ListTheme.accent : ListTheme.secondary) }.buttonStyle(.plain).accessibilityLabel("高级搜索")
                                    .popover(isPresented: $advancedSearch) { AdvancedTaskSearch(criteria: $searchCriteria,allTasks: $searchAll).environmentObject(store).frame(width: 350).padding(20) }
                                Button { search = ""; searchVisible = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ListTheme.secondary) }.buttonStyle(.plain).help("关闭搜索")
                            }.padding(.horizontal,12).frame(height: 36).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal,20).padding(.bottom,10)
                        }
                        TaskWorkspace(tasks: sortedTasks,viewMode: viewMode,showCompleted: searchVisible ? true : showCompleted,listID: selectedListID,isTrash: selection == "trash",isTemplates: selection == "templates",sort: sort,creationContext: searchVisible ? "search" : selection,showSummaries: showSummaries,onManualSort: { sort = "手动" }).id(selection)
                    }.ignoresSafeArea(.container,edges: .top).frame(minWidth: 320,idealWidth: 380,maxWidth: detailsVisible ? max(320,(geometry.size.width - 65 - (sidebarVisible ? 220 : 0) - (parallel ? 310 : 0)) * 0.40) : .infinity,maxHeight: .infinity,alignment: .top)
                    if parallel { CalendarView(compact: true).frame(minWidth: 310,idealWidth: 380) }
                    if detailsVisible { TaskDetailView(startInPreview: true).ignoresSafeArea(.container,edges: .top).frame(minWidth: 340,idealWidth: 480,maxWidth: .infinity,maxHeight: .infinity) }
                }
            } else { Group { switch module { case .calendar: CalendarView(); case .matrix: MatrixView(); case .focus: FocusView(); case .habits: HabitsView(); case .countdown: CountdownView(); case .stats: StatisticsView(); case .tasks: EmptyView() } }.frame(maxWidth: .infinity,maxHeight: .infinity) }
        }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
        }.ignoresSafeArea(.container,edges: .top).background(WindowChrome()).background(ListTheme.canvas).foregroundStyle(ListTheme.text).font(.system(size: fontScale)).themeAppearance().frame(minWidth: (parallel ? 1240 : 1000),minHeight: 620)
            .onAppear { guard !didInitialize else { return }; didInitialize = true; selection = startupSmartList; module = Module(rawValue: startupModule) ?? .tasks; if !ModulePreferences(rawValue: moduleVisibility).isVisible(module) { module = .tasks }; reconcileSidebarSelection() }
            .onChange(of: store.notificationTask) { _,id in if let id { openNotificationTask(id); store.notificationTask = nil } }
            .onChange(of: store.notificationModule) { _,target in if let target { module = target; store.notificationModule = nil } }
            .onChange(of: moduleVisibility) { _,_ in if !ModulePreferences(rawValue: moduleVisibility).isVisible(module) { module = .tasks } }
            .onChange(of: rawSmartVisibility) { _,_ in reconcileSidebarSelection() }
            .onChange(of: sidebarKeys) { _,_ in reconcileSidebarSelection() }
            .onChange(of: selection) { _,_ in listOptionsVisible = false; store.selectedTask = nil; search = ""; viewMode = store.lists.first { $0.id == selectedListID }?.defaultView ?? "列表" }
            .onChange(of: viewMode) { _,value in if let id = selectedListID, var list = store.lists.first(where: { $0.id == id }), list.defaultView != value { list.defaultView = value; store.save(list,undoable: false) } }
            .onChange(of: searchVisible) { _,visible in if visible { DispatchQueue.main.async { searchFocused = true } } else { search = ""; searchCriteria = TaskSearchCriteria() } }
            .background(Button("新建清单") { listEditorRequest = ListEditorRequest(existing: nil) }.keyboardShortcut("l",modifiers: [.command,.shift]).hidden())
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
    func openNotificationTask(_ id: UUID) {
        guard let task = store.tasks.first(where: { $0.id == id }) else { return }
        module = .tasks; detailsVisible = true; notificationPanelVisible = false
        selection = task.deleted ? "trash" : task.completed ? "completed" : task.listID.map { "list:" + $0.uuidString } ?? "inbox"
        DispatchQueue.main.async { store.selectedTask = id }
    }
    var profileMenu: some View {
        VStack(alignment: .leading,spacing: 2) {
            Button { profileMenuVisible = false; DispatchQueue.main.async { openSettings(); NSApp.activate(ignoringOtherApps: true) } } label: {
                HStack(spacing: 12) { Image(systemName: "gearshape").font(.system(size: 18)).frame(width: 22); Text("设置").font(.system(size: 14)); Spacer(minLength: 0) }.padding(.horizontal,12).frame(height: 42).contentShape(Rectangle())
            }.buttonStyle(.plain).quietHover()
            profileRow("统计","chart.pie") { module = .stats; profileMenuVisible = false }
            Divider().padding(.vertical,4)
            profileRow("退出 Zilo","rectangle.portrait.and.arrow.right") { NSApp.terminate(nil) }
        }.padding(8).frame(width: 180).background(ListTheme.canvas).foregroundStyle(ListTheme.text)
    }
    func profileRow(_ title: String,_ symbol: String,action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 12) { Image(systemName: symbol).font(.system(size: 18)).frame(width: 22); Text(LocalizedStringKey(title)).font(.system(size: 14)); Spacer(minLength: 0) }.padding(.horizontal,12).frame(height: 42).contentShape(Rectangle()) }.buttonStyle(.plain).quietHover()
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
                    Toggle("右侧栏预览",isOn: $detailsVisible)
                    Toggle("并列日历",isOn: $parallel)
                }.toggleStyle(.checkbox).font(.system(size: 12)).padding(10)
            }
            Divider().padding(.vertical,4)
            if let list = store.lists.first(where: { $0.id == selectedListID }) {
                optionRow("添加分组","plus") { listOptionsVisible = false; listEditorRequest = ListEditorRequest(existing: list) }
                optionRow("编辑清单","square.and.pencil") { listOptionsVisible = false; listEditorRequest = ListEditorRequest(existing: list) }
            }
            Menu {
                Button("全部任务",systemImage: "square.stack") { openTaskView("all") }
                Button("收藏",systemImage: "star") { openTaskView("starred") }
                Button("任务模板",systemImage: "doc.on.doc") { openTaskView("templates") }
                Button("归档任务",systemImage: "archivebox") { openTaskView("archived") }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack").font(.system(size: 16)).frame(width: 20)
                    Text("其他任务视图").font(.system(size: 13))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10))
                }.padding(.horizontal,10).frame(height: 34).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).foregroundStyle(ListTheme.text).quietHover()
            optionRow("搜索任务","magnifyingglass") { listOptionsVisible = false; searchVisible = true }
            optionRow("桌面便签","note.text") { listOptionsVisible = false; DesktopBridge.panel(title: title,view: StickyView(listID: selectedListID).environmentObject(store)) }
            optionRow("打印","printer") { listOptionsVisible = false; printList() }
            if let id = selectedListID {
                Divider().padding(.vertical,4)
                optionRow("删除清单","trash") { listOptionsVisible = false; if store.deleteList(id) { selection = "trash" } }
            }
        }.padding(8).frame(width: 200).background(ListTheme.canvas)
    }
    func openTaskView(_ key: String) {
        selection = key; listOptionsVisible = false; sidebarFocused = false
    }
    func optionRow(_ title: String,_ symbol: String,action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 12) { Image(systemName: symbol).font(.system(size: 16)).frame(width: 20); Text(LocalizedStringKey(title)).font(.system(size: 13)); Spacer(minLength: 0) }.padding(.horizontal,10).frame(height: 34).contentShape(Rectangle()) }
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
                        ForEach(SmartListOption.primary.filter { smartVisible($0.id) }) { item in nav(item.title,item.icon,item.id) }
                        sidebarHeading("清单") { listEditorRequest = ListEditorRequest(existing: nil) }
                            .dropDestination(for: String.self) { values,_ in
                                values.contains { value in guard value.hasPrefix("zilo-list:"), let id = UUID(uuidString: String(value.dropFirst(10))) else { return false }; return store.placeList(id,folder: "") }
                            }.help("拖动清单到这里可移出文件夹")
                        ForEach(folders,id: \.self) { folder in
                            DisclosureGroup(isExpanded: Binding(get: { expandedFolders.contains(folder) },set: { if $0 { expandedFolders.insert(folder) } else { expandedFolders.remove(folder) } })) {
                                ForEach(store.lists.filter { !$0.deleted && $0.folder == folder }.sorted { $0.order < $1.order }) { listRow($0) }
                            } label: {
                                Label(folder,systemImage: "folder").font(.system(size: 12)).foregroundStyle(ListTheme.secondary)
                                    .contextMenu { Button("重命名文件夹") { renameFolder(folder) } }
                                    .dropDestination(for: String.self) { values,_ in
                                        let moved = values.contains { value in guard value.hasPrefix("zilo-list:"), let id = UUID(uuidString: String(value.dropFirst(10))) else { return false }; return store.placeList(id,folder: folder) }; if moved { expandedFolders.insert(folder) }; return moved
                                    }.help("拖动清单到此文件夹")
                            }.padding(.horizontal,8).padding(.vertical,5)
                        }
                        ForEach(store.lists.filter { !$0.deleted && $0.folder.isEmpty }.sorted { $0.order < $1.order }) { listRow($0) }
                        if smartVisible("filters") {
                            sidebarHeading("过滤器") { editFilter = nil; showFilter = true }
                            ForEach(store.filters.filter { !$0.deleted }) { filter in
                                sidebarChoice(filter.name,"line.3.horizontal.decrease.circle","filter:" + filter.id.uuidString)
                                    .contextMenu { Button("编辑") { editFilter = filter; showFilter = true }; Button("删除",role: .destructive) { var f = filter; f.deleted = true; store.save(f) } }
                            }
                        }
                        if smartVisible("tags") {
                            Text("标签").font(.system(size: 11,weight: .medium)).foregroundStyle(ListTheme.secondary).padding(.horizontal,12).padding(.top,18).padding(.bottom,6)
                            ForEach(tags,id: \.self) { tag in sidebarChoice(tag,"tag","tag:" + tag) }
                        }
                        if SmartListOption.secondary.contains(where: { smartVisible($0.id) }) {
                            Divider().overlay(ListTheme.separator).padding(.vertical,12).padding(.horizontal,8)
                            ForEach(SmartListOption.secondary.filter { smartVisible($0.id) }) { item in nav(item.title,item.icon,item.id) }
                        }
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
            HStack(alignment: .top,spacing: 6) {
                Circle().fill(store.syncStatus.contains("失败") ? Color.orange : Color.green).frame(width: 5,height: 5).padding(.top,5)
                Text(ZiloLanguage.status(store.syncStatus.contains("失败") ? "同步暂不可用 · 已保存在本机" : store.syncStatus)).font(.system(size: 10)).foregroundStyle(ListTheme.secondary).lineLimit(2).help(store.syncStatus)
            }.padding(.horizontal,18).padding(.top,4).padding(.bottom,12)
        }.background(ListTheme.sidebar)
    }
    var folders: [String] { Array(Set(store.lists.filter { !$0.deleted && !$0.folder.isEmpty }.map(\.folder))).sorted() }
    var tags: [String] { Array(Set(store.tasks.filter { !$0.deleted }.flatMap(\.tags))).sorted() }
    var sidebarKeys: [String] {
        var keys = SmartListOption.primary.filter { smartVisible($0.id) }.map(\.id)
        for folder in folders where expandedFolders.contains(folder) {
            let lists = store.lists.filter { !$0.deleted && $0.folder == folder }.sorted { $0.order < $1.order }
            keys += lists.map { "list:" + $0.id.uuidString }
        }
        let unfiled = store.lists.filter { !$0.deleted && $0.folder.isEmpty }.sorted { $0.order < $1.order }
        keys += unfiled.map { "list:" + $0.id.uuidString }
        if smartVisible("filters") { keys += store.filters.filter { !$0.deleted }.map { "filter:" + $0.id.uuidString } }
        if smartVisible("tags") { keys += tags.map { "tag:" + $0 } }
        return keys + SmartListOption.secondary.filter { smartVisible($0.id) }.map(\.id)
    }
    func smartVisible(_ key: String) -> Bool {
        let count: Int
        switch key {
        case "tags": count = tags.count
        case "filters": count = store.filters.filter { !$0.deleted }.count
        case "trash": count = store.trashEntryCount
        default: count = filtered(key).count
        }
        return SmartListPreferences(rawValue: rawSmartVisibility).isVisible(key,count: count)
    }
    func reconcileSidebarSelection() {
        let smartKey = selection.hasPrefix("tag:") ? "tags" : selection.hasPrefix("filter:") ? "filters" : selection
        guard SmartListOption.all.contains(where: { $0.id == smartKey }), !smartVisible(smartKey) else { return }
        selection = sidebarKeys.first ?? "all"
    }
    func sidebarHeading(_ title: String,action: @escaping () -> Void) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.system(size: 11,weight: .medium)).foregroundStyle(ListTheme.secondary)
            Spacer()
            Button(action: action) { Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(ListTheme.secondary).frame(width: 28,height: 28).contentShape(Rectangle()) }
                .buttonStyle(.plain).quietHover().help("新建" + title).accessibilityLabel("新建" + title)
        }.padding(.leading,12).padding(.trailing,4).padding(.top,16).padding(.bottom,4)
    }
    func sidebarChoice(_ text: String,_ icon: String,_ key: String,color: Color? = nil,count: Int = 0) -> some View {
        Button { selection = key; sidebarFocused = true } label: {
            HStack(spacing: 10) {
                if key.hasPrefix("list:") {
                    Image(systemName: "line.3.horizontal").font(.system(size: 16)).frame(width: 20).foregroundStyle(ListTheme.text)
                } else {
                    Image(systemName: icon).font(.system(size: 16)).frame(width: 20).foregroundStyle(ListTheme.text)
                }
                Text(key.hasPrefix("list:") || key.hasPrefix("filter:") || key.hasPrefix("tag:") ? text : ZiloLanguage.text(text)).lineLimit(1)
                Spacer(minLength: 4)
                if let color { Circle().fill(color).frame(width: 7,height: 7) }
                if count > 0 { Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(ListTheme.secondary) }
            }.padding(.horizontal,12).frame(minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(ListTheme.text).quietHover(selected: selection == key)
            .overlay {
                if key.hasPrefix("list:") {
                    TaskDragHandle(payload: "zilo-list:" + key.dropFirst(5),visible: false,onBegin: {},
                        onClick: { selection = key; sidebarFocused = true },accessibilityName: "拖动清单“" + text + "”")
                        .frame(maxWidth: .infinity,maxHeight: .infinity)
                        .help("拖动调整清单顺序或文件夹")
                }
            }
            .id(key).accessibilityAddTraits(selection == key ? .isSelected : [])
    }
    func nav(_ text: String,_ icon: String,_ key: String) -> some View { sidebarChoice(text,icon,key,count: key == "trash" ? store.trashEntryCount : ["completed","archived"].contains(key) ? filtered(key).count : filtered(key).filter { !$0.completed }.count) }
    func listRow(_ list: TaskList) -> some View {
        let count = store.tasks.filter { $0.listID == list.id && !$0.deleted && !$0.completed && !$0.isTemplate && $0.archived != true && $0.parentID == nil }.count
        return sidebarChoice(list.name,"line.3.horizontal","list:" + list.id.uuidString,color: list.color == "none" ? nil : list.color.listColor,count: count)
            .contextMenu { Button("编辑清单") { listEditorRequest = ListEditorRequest(existing: list) }; Button("删除清单",role: .destructive) { if store.deleteList(list.id) { selection = "trash" } } }
            .overlay(alignment: dragFeedback.state?.listAfter == true ? .bottom : .top) { if dragFeedback.state?.listTarget == list.id { ListTheme.accent.frame(height: 2).allowsHitTesting(false) } }
            .onDrop(of: [.text],delegate: RecordDropDelegate(updated: { point in dragFeedback.hoverList(target: list.id,after: point.y > 18) },exited: { dragFeedback.exitList(target: list.id) },dropped: { raw,point in
                if raw.hasPrefix("zilo-list:"), let id = UUID(uuidString: String(raw.dropFirst(10))) { _ = store.placeList(id,relativeTo: list.id,after: point.y > 18) }
                else if let id = UUID(uuidString: raw) { _ = store.moveTaskTree(id,to: list.id) }
            },activePayload: { dragFeedback.state?.payload }))
    }
    var selectedListID: UUID? { selection.hasPrefix("list:") ? UUID(uuidString: String(selection.dropFirst(5))) : nil }
    var title: String { switch selection { case "today": return ZiloLanguage.text("今天"); case "tomorrow": return ZiloLanguage.text("明天"); case "week": return ZiloLanguage.text("最近 7 天"); case "inbox": return ZiloLanguage.text("收集箱"); case "all": return ZiloLanguage.text("全部任务"); case "completed": return ZiloLanguage.text("已完成"); case "archived": return ZiloLanguage.text("归档任务"); case "trash": return ZiloLanguage.text("回收站"); case "starred": return ZiloLanguage.text("收藏"); case "templates": return ZiloLanguage.text("任务模板"); default: if let id = selectedListID { return store.lists.first { $0.id == id }?.name ?? "清单" }; if selection.hasPrefix("tag:") { return "#" + selection.dropFirst(4) }; return store.filters.first { "filter:" + $0.id.uuidString == selection }?.name ?? "任务" } }
    func filtered(_ key: String) -> [TaskItem] {
        store.tasks.filter { t in
            if key == "trash" { return t.deleted }; guard !t.deleted else { return false }
            if key == "archived" { return t.archived == true }; if key == "templates" { return t.isTemplate && t.parentID == nil }; guard t.archived != true else { return false }; guard !t.isTemplate && t.parentID == nil else { return false }
            switch key { case "today": return t.due.map { $0 < Calendar.current.date(byAdding: .day,value: 1,to: Calendar.current.startOfDay(for: Date()))! } == true && !t.completed
            case "tomorrow": return t.due.map { Calendar.current.isDateInTomorrow($0) } == true && !t.completed
            case "week": return t.due.map { $0 < Calendar.current.date(byAdding: .day,value: 7,to: Calendar.current.startOfDay(for: Date()))! } == true && !t.completed
            case "inbox": return t.listID == nil
            case "all": return true
            case "completed": return t.completed
            case "starred": return t.starred
            default: if key.hasPrefix("list:") { return t.listID?.uuidString == String(key.dropFirst(5)) }; if key.hasPrefix("tag:") { return t.tags.contains(String(key.dropFirst(4))) }; if let filter = store.filters.first(where: { "filter:" + $0.id.uuidString == key }) { return filter.matches(t) }; return false }
        }
    }
    var sortedTasks: [TaskItem] { (searchVisible && searchAll ? store.tasks.filter { !$0.deleted && !$0.isTemplate } : filtered(selection)).filter { searchVisible ? searchCriteria.matches($0,query: search) : true }.sorted { a,b in switch sort { case "日期": return (a.due ?? .distantFuture) < (b.due ?? .distantFuture); case "优先级": return a.priority > b.priority; case "标题": return a.title.localizedStandardCompare(b.title) == .orderedAscending; case "创建时间": return a.created > b.created; default: return a.order < b.order } } }
    func importFile() { let p = NSOpenPanel(); p.allowedContentTypes = [.json,.commaSeparatedText,.plainText]; if p.runModal() == .OK, let url = p.url { do { importPreview = try ImportService.preview(url); showImport = true } catch { store.error = error.localizedDescription } } }
    func renameFolder(_ old: String) { let alert = NSAlert(); alert.messageText = ZiloLanguage.text("重命名文件夹"); let field = NSTextField(string: old); field.frame = NSRect(x: 0,y: 0,width: 260,height: 24); alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); if alert.runModal() == .alertFirstButtonReturn { for var list in store.lists.filter({ $0.folder == old }) { list.folder = field.stringValue.trimmingCharacters(in: .whitespaces); store.save(list) } } }
}
struct TaskWorkspace: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("accent") private var applicationTheme = "blue"
    @EnvironmentObject var store: Store; var tasks: [TaskItem]; var viewMode: String; var showCompleted: Bool; var listID: UUID?; var isTrash: Bool; var isTemplates: Bool; var sort: String; var creationContext = "all"; var showSummaries = false; var onManualSort: (() -> Void)? = nil
    @State private var countdownsExpanded = true
    @State private var countdownEditor: Countdown?
    @AppStorage("showCountdownsToday") private var showCountdownsToday = true
    var todayCountdowns: [Countdown] { creationContext == "today" && showCountdownsToday ? store.countdowns.filter { !$0.deleted && $0.pinned }.sorted { $0.days() < $1.days() } : [] }
    @State private var hoveredTaskHandle: UUID?
    @ObservedObject private var dragFeedback = TaskDragFeedback.shared
    @State private var rowHeights: [UUID:CGFloat] = [:]
    @State private var collapsedTasks = Set<UUID>()
    @State private var editingTitle: UUID?
    @AppStorage("fontScale") private var taskFontSize = 14.0
    @State private var input = ""; @State private var multi = Set<UUID>(); @State private var batchMode = false; @State private var completedExpanded = false; @State private var entrySection = ""; @FocusState private var inputFocused: Bool
    var trashLists: [TaskList] { isTrash ? store.lists.filter(\.deleted).sorted { $0.order < $1.order } : [] }
    var visible: [TaskItem] { tasks.filter { task in
        (showCompleted || !task.completed || isTrash) && !(isTrash && trashLists.contains { $0.id == task.trashedWithList })
    } }
    var body: some View {
        let _ = applicationTheme
 VStack(spacing: 0) {
        if !isTrash && creationContext != "completed" && creationContext != "archived" { HStack { Image(systemName: "plus"); TextField(entryPlaceholder,text: $input).foregroundStyle(ListTheme.text).textFieldStyle(.plain).focused($inputFocused).onSubmit { addTask(section: entrySection) } }.foregroundStyle(ListTheme.secondary).padding(.horizontal,12).frame(height: 40).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal,20).padding(.top,6).padding(.bottom,8) }
        if batchMode && !multi.isEmpty { HStack { Text("已选 \(multi.count) 项"); Menu("移动") { Button("收集箱") { store.move(multi,to: nil) }; ForEach(store.lists.filter { !$0.deleted }) { l in Button(l.name) { store.move(multi,to: l.id) } } }; Menu("优先级") { ForEach(0...3,id: \.self) { p in Button("\(p)") { batch { $0.priority = p } } } }; Button("今天") { batch { $0.due = Calendar.current.startOfDay(for: Date()) } }; Button("完成") { let before = store.backup; for id in multi { store.complete(id) }; store.groupUndo(before) }; Button("删除",role: .destructive) { batch { $0.deleted = true }; multi = [] } }.font(.caption).padding(8) }
        if todayCountdowns.isEmpty && visible.isEmpty && trashLists.isEmpty && (viewMode != "列表" || (store.lists.first { $0.id == listID }?.sections.isEmpty ?? true)) { QuietEmptyState(title: isTrash ? "回收站为空" : "清单很清爽",message: "把想做的事情记下来，一件一件完成。",symbol: "checkmark.circle") }
        else if viewMode == "看板" && !isTrash { ScrollView(.horizontal) { HStack(alignment: .top,spacing: 12) { ForEach(["待安排","进行中","已完成"],id: \.self) { column in VStack(alignment: .leading) { Text(column).font(.headline).padding(10); ForEach(visible.filter { column == "已完成" ? $0.completed : column == "进行中" ? !$0.completed && $0.start != nil : !$0.completed && $0.start == nil }) { t in row(t).padding(10).background(.background,in: RoundedRectangle(cornerRadius: 10)) }; Spacer() }.padding(8).frame(width: 260).background(ListTheme.input,in: RoundedRectangle(cornerRadius: 10)).dropDestination(for: String.self) { values,_ in for raw in values { if let id = UUID(uuidString: raw) { store.mutate(id) { $0.completed = column == "已完成"; $0.completedAt = $0.completed ? Date() : nil; $0.start = column == "进行中" ? Date() : nil } } }; return true } } }.padding(20) } }
        else if viewMode == "时间线" && !isTrash { TimelineViewContent(tasks: visible) }
        else { ScrollView {
            LazyVStack(alignment: .leading,spacing: 0) {
                if !todayCountdowns.isEmpty {
                    Button { countdownsExpanded.toggle() } label: { HStack(spacing: 8) { Image(systemName: countdownsExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10)); Text("倒数纪念日").fontWeight(.semibold); Text("\(todayCountdowns.count)").foregroundStyle(.tertiary); Spacer() } }.buttonStyle(.plain).padding(.leading,20).padding(.vertical,14)
                    if countdownsExpanded {
                        ForEach(todayCountdowns) { day in
                            Button { countdownEditor = day } label: {
                                HStack(spacing: 12) { Text(day.emoji).font(.system(size: 19)); Text(day.displayName); Spacer(); Text(day.days() == 0 ? ZiloLanguage.text("就是今天") : ZiloLanguage.format(day.days() > 0 ? "还有 %lld 天" : "已经 %lld 天",abs(day.days()))).font(.system(size: 12)).foregroundStyle(day.days() < 0 ? "green".listColor : ListTheme.accent) }.frame(minHeight: 42).contentShape(Rectangle())
                            }.buttonStyle(.plain).padding(.leading,36).padding(.trailing,8)
                            Rectangle().fill(ListTheme.separator).frame(height: 0.5).padding(.leading,66)
                        }
                    }
                }
                if !trashLists.isEmpty {
                    Text("已删除的清单").font(.system(size: 12)).foregroundStyle(ListTheme.secondary).padding(.vertical,12)
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
                let configured = store.lists.first { $0.id == listID }?.sections ?? []; let extras = Set(visible.filter { !$0.completed }.map(\.section)).subtracting(configured); let sections = (extras.contains("") ? [""] : []) + configured + extras.filter { !$0.isEmpty }.sorted()
                ForEach(sections,id: \.self) { section in
                    if !section.isEmpty || !configured.isEmpty {
                        HStack {
                            Text(section.isEmpty ? "待完成" : section)
                            Spacer()
                            Button { addTask(section: section) } label: { Image(systemName: "plus") }.buttonStyle(.plain)
                        }.foregroundStyle(ListTheme.secondary).font(.system(size: 12)).padding(.vertical,12).padding(.leading,12)
                            .dropDestination(for: String.self) { values,_ in
                                for raw in values { if let id = UUID(uuidString: raw) { store.mutate(id) { $0.section = section } } }
                                return true
                            }
                    }
                    sectionRows(section)
                }
                let completed = visible.filter(\.completed)
                if (showCompleted || isTrash) && !completed.isEmpty {
                    Button { completedExpanded.toggle() } label: {
                        HStack { Image(systemName: completedExpanded ? "chevron.down" : "chevron.right"); Text("已完成").fontWeight(.semibold); Text("\(completed.count)").foregroundStyle(.tertiary); Spacer() }
                    }.foregroundStyle(ListTheme.secondary).font(.system(size: 12)).buttonStyle(.plain).padding(.vertical,18).padding(.leading,12).accessibilityLabel(completedExpanded ? "收起已完成任务" : "展开已完成任务")
                    if completedExpanded { ForEach(completed) { hierarchyRows($0) } }
                }
            }.padding(.trailing,12).padding(.top,8).padding(.bottom,20)
        } }
    }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
        .onAppear { completedExpanded = creationContext == "completed" || isTrash }
        .onChange(of: store.selectedTask) { _,id in if let id { collapsedTasks.remove(id) } }
    }
    func sectionRows(_ section: String) -> some View {
        ForEach(visible.filter { !$0.completed && $0.section == section }) { hierarchyRows($0) }
    }
    var entryPlaceholder: String { if isTemplates { return ZiloLanguage.text("添加模板，回车创建") }; if let list = store.lists.first(where: { $0.id == listID }) { return ZiloLanguage.format("添加任务至“%@”，回车创建",list.name) }; if creationContext == "today" { return ZiloLanguage.text("添加今天的任务，回车创建") }; if creationContext == "tomorrow" { return ZiloLanguage.text("添加明天的任务，回车创建") }; if creationContext == "week" { return ZiloLanguage.text("添加任务，默认安排在今天") }; return ZiloLanguage.text("添加任务至收集箱，回车创建") }
    func addTask(section: String = "") {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { entrySection = section; inputFocused = true; return }
        let due = creationContext == "tomorrow" ? Calendar.current.date(byAdding: .day,value: 1,to: Calendar.current.startOfDay(for: Date())) : ["today","week"].contains(creationContext) ? Calendar.current.startOfDay(for: Date()) : nil
        if let id = store.add(text,listID: listID,defaultDue: due,section: section,starred: creationContext == "starred") { if isTemplates { store.mutate(id) { $0.isTemplate = true } }; if creationContext.hasPrefix("tag:") { let tag = String(creationContext.dropFirst(4)); store.mutate(id) { if !$0.tags.contains(tag) { $0.tags.append(tag) } } }; input = ""; entrySection = ""; inputFocused = true }
    }
    func batch(_ body: (inout TaskItem) -> Void) { let before = store.backup; for id in multi { store.mutate(id,body) }; store.groupUndo(before) }
    func reorder(_ section: String,_ from: IndexSet,_ to: Int) { guard sort == "手动" else { return }; var data = visible.filter { !$0.completed && $0.section == section }; data.move(fromOffsets: from,toOffset: to); let before = store.backup; for (index,t) in data.enumerated() { store.mutate(t.id) { $0.order = Double(index) } }; store.groupUndo(before) }
    func hierarchyRows(_ root: TaskItem) -> some View {
        VStack(alignment: .leading,spacing: 0) {
            ForEach(isTrash ? [TaskHierarchy.Row(task: root,depth: 0)] : TaskHierarchy.rows(root: root,tasks: store.tasks,collapsed: collapsedTasks)) { entry in
                row(entry.task).padding(.leading,CGFloat(entry.depth) * 24)
            }
            if !isTrash,
               let raw = dragFeedback.state?.payload,
               let source = UUID(uuidString: raw),
               store.tasks.contains(where: { $0.id == source && $0.parentID != nil }) {
                topLevelDropTarget(after: root)
            }
        }
    }
    func topLevelDropTarget(after root: TaskItem) -> some View {
        let highlighted = dragFeedback.state?.topLevelTarget == root.id
        return HStack(spacing: 8) {
            Rectangle().fill(highlighted ? ListTheme.accent : .clear).frame(height: 2)
            if highlighted { Text("移为顶层任务").font(.caption2).foregroundStyle(ListTheme.accent).fixedSize() }
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .onDrop(of: [.text],delegate: RecordDropDelegate(updated: { _ in
            dragFeedback.hoverTopLevel(after: root.id)
        },exited: {
            dragFeedback.exitTopLevel(after: root.id)
        },dropped: { raw,_ in
            guard let id = UUID(uuidString: raw),id != root.id else { return }
            finishRenaming()
            if store.placeTask(id,relativeTo: root.id,position: .after) {
                store.selectedTask = id; onManualSort?()
            }
        },activePayload: { dragFeedback.state?.payload }))
        .accessibilityLabel("拖到这里，移为顶层任务")
    }
    func startRenaming(_ task: TaskItem) {
        finishRenaming()
        store.selectedTask = task.id; editingTitle = task.id
    }
    func finishRenaming() {
        guard editingTitle != nil else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        editingTitle = nil
    }
    func taskTitle(_ task: TaskItem) -> some View {
        TaskNameField(title: task.title,completed: task.completed,fontSize: taskFontSize,
            requestFocus: editingTitle == task.id,
            onBegin: { store.selectedTask = task.id; collapsedTasks.remove(task.id); editingTitle = task.id },
            onEnd: { value in
                if editingTitle == task.id { editingTitle = nil }
                if let value, !value.isEmpty, store.tasks.first(where: { $0.id == task.id })?.title != value {
                    store.mutate(task.id) { $0.title = value }
                }
            },onDoubleClick: { openTaskWindow(task.id) },dragPayload: task.id.uuidString,onDragBegin: finishRenaming)
            .frame(maxWidth: .infinity).frame(height: max(20,taskFontSize + 6))
            .help("单击修改名称，双击打开独立窗口")
    }
    func openTaskWindow(_ id: UUID) {
        finishRenaming(); openWindow(id: "task-detail",value: id); NSApp.activate(ignoringOtherApps: true)
    }
    func dropPosition(_ point: CGPoint,task: TaskItem) -> TaskPlacement.Position {
        let height = rowHeights[task.id] ?? 48
        if point.y < min(12,height * 0.25) { return .before }
        if point.y > height - min(12,height * 0.25) { return .after }
        return .child
    }
    func row(_ t: TaskItem) -> some View {
        let children = store.tasks.filter { $0.parentID == t.id && !$0.deleted }
        let summary = TaskDocument.summary(t)
        let hasContent = !t.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let statusDescriptions: [String?] = [children.isEmpty ? nil : ZiloLanguage.text("子任务") + " \(children.filter(\.completed).count)/\(children.count)",hasContent ? ZiloLanguage.text("任务正文") : nil,t.attachments.isEmpty ? nil : ZiloLanguage.text("附件")]
        let statusHelp = statusDescriptions.compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .top,spacing: 6) {
        if !children.isEmpty {
            Button { finishRenaming(); if collapsedTasks.contains(t.id) { collapsedTasks.remove(t.id) } else { collapsedTasks.insert(t.id) } } label: {
                Image(systemName: collapsedTasks.contains(t.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11)).offset(y: -3).frame(width: 24,height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).quietHover().help(collapsedTasks.contains(t.id) ? "展开子任务" : "收起子任务")
                .accessibilityLabel(collapsedTasks.contains(t.id) ? "展开子任务" : "收起子任务")
        } else { Color.clear.frame(width: 24,height: 20) }
        if batchMode { Toggle("选择",isOn: Binding(get: { multi.contains(t.id) },set: { if $0 { multi.insert(t.id) } else { multi.remove(t.id) } })).labelsHidden().toggleStyle(.checkbox) }
        Button { store.complete(t.id) } label: { Image(systemName: t.completed ? "checkmark.square.fill" : "square").font(.system(size: 17)).foregroundStyle(t.completed ? ListTheme.secondary.opacity(0.7) : t.priority == 3 ? "red".listColor : t.priority == 2 ? "orange".listColor : t.priority == 1 ? Color.accentColor : ListTheme.secondary) }.buttonStyle(.plain).accessibilityLabel(t.completed ? "取消完成" : "完成任务")
        VStack(alignment: .leading,spacing: 5) {
            HStack(spacing: 8) {
                taskTitle(t)
                if !children.isEmpty || hasContent || !t.attachments.isEmpty {
                    HStack(spacing: 7) {
                        if !children.isEmpty {
                            Image(systemName: "arrow.turn.down.right")
                                .accessibilityLabel(ZiloLanguage.text("子任务") + ", \(children.filter(\.completed).count)/\(children.count)")
                        }
                        if hasContent { Image(systemName: "note.text").accessibilityLabel("任务正文") }
                        if !t.attachments.isEmpty { Image(systemName: "paperclip").accessibilityLabel("附件") }
                    }.font(.system(size: 12)).foregroundStyle(ListTheme.secondary.opacity(0.6)).fixedSize()
                        .overlay {
                            TaskDragHandle(payload: t.id.uuidString,visible: false,onBegin: finishRenaming,
                                onClick: { finishRenaming(); store.selectedTask = t.id; collapsedTasks.remove(t.id) },onDoubleClick: { openTaskWindow(t.id) })
                                .frame(maxWidth: .infinity,maxHeight: .infinity).accessibilityHidden(true)
                                .help(statusHelp)
                        }
                }
            }
            if showSummaries && !summary.isEmpty { Text(summary).font(.caption).foregroundStyle(ListTheme.secondary).lineLimit(1) }
            if t.due != nil || !t.tags.isEmpty || t.repeatRule.frequency != "none" {
                HStack(spacing: 8) {
                    if let due = t.due { Text(due.formatted(date: .abbreviated,time: t.allDay ? .omitted : .shortened)).foregroundStyle(Scheduling.isOverdue(t) ? .red : .secondary) }
                    if !t.tags.isEmpty { Text(t.tags.map { "#" + $0 }.joined(separator: " ")).foregroundStyle(Color.accentColor) }
                    if t.repeatRule.frequency != "none" { Image(systemName: "repeat") }
                }.font(.caption).foregroundStyle(ListTheme.secondary)
            }
        }
        Spacer(); if t.starred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
    }.padding(.vertical,10).padding(.leading,16).padding(.trailing,4).background { RoundedRectangle(cornerRadius: 8).fill(store.selectedTask == t.id ? ListTheme.selection : hoveredTaskHandle == t.id ? ListTheme.hover : .clear).padding(.leading,12) }.background { TaskRowHover { hoveredTaskHandle = $0 ? t.id : (hoveredTaskHandle == t.id ? nil : hoveredTaskHandle) } }.overlay(alignment: .bottom) { if store.selectedTask != t.id { ListTheme.separator.frame(height: 0.5).padding(.leading,57) } }.contentShape(Rectangle()).background { GeometryReader { proxy in Color.clear.onAppear { rowHeights[t.id] = proxy.size.height }.onChange(of: proxy.size.height) { _,height in rowHeights[t.id] = height } } }
        .overlay {
            TaskDragHandle(payload: t.id.uuidString,visible: false,onBegin: finishRenaming,
                onClick: { finishRenaming(); store.selectedTask = t.id; collapsedTasks.remove(t.id) },onDoubleClick: { openTaskWindow(t.id) },excludedTitleHeight: max(children.isEmpty ? 20 : 28,taskFontSize + 6))
                .frame(maxWidth: .infinity,maxHeight: .infinity)
                .accessibilityHidden(true).allowsHitTesting(!batchMode)
        }
        .overlay(alignment: .topLeading) {
            TaskDragHandle(payload: t.id.uuidString,visible: hoveredTaskHandle == t.id,onBegin: finishRenaming)
                .frame(width: 16,height: 24).offset(x: 0,y: 8)
                .help("拖动：上／下方排序，中间放为子任务").accessibilityLabel("拖动任务“" + t.title + "”")
        }
        .overlay {
            if dragFeedback.state?.target == t.id {
                if dragFeedback.state?.position == .child { RoundedRectangle(cornerRadius: 8).strokeBorder(ListTheme.accent,lineWidth: 1.5).overlay(alignment: .trailing) { Text("放为子任务").font(.caption2).padding(5).background(ListTheme.canvas).padding(.trailing,5) }.allowsHitTesting(false) }
                else { VStack { if dragFeedback.state?.position == .after { Spacer() }; ListTheme.accent.frame(height: 2); if dragFeedback.state?.position == .before { Spacer() } }.allowsHitTesting(false) }
            }
        }
        .onDrop(of: [.text],delegate: RecordDropDelegate(updated: { point in
            guard !isTrash else { return }; dragFeedback.hover(target: t.id,position: dropPosition(point,task: t))
        },exited: { dragFeedback.exit(target: t.id) },dropped: { raw,point in
            guard !isTrash, let id = UUID(uuidString: raw) else { return }
            finishRenaming()
            if store.placeTask(id,relativeTo: t.id,position: dropPosition(point,task: t)) { collapsedTasks.remove(t.id); store.selectedTask = id; onManualSort?() }
        },activePayload: { dragFeedback.state?.payload })).contextMenu {
        Button("打开详情") { store.selectedTask = t.id }; Button("修改名称") { startRenaming(t) }; Button(batchMode ? "结束批量编辑" : "批量编辑") { batchMode.toggle(); multi = [] }; Button(t.starred ? "取消收藏" : "收藏") { store.mutate(t.id) { $0.starred.toggle() } }
        if t.parentID != nil {
            Button("移为顶层任务",systemImage: "arrow.up.left") {
                finishRenaming()
                if store.promoteTask(t.id) { store.selectedTask = t.id; onManualSort?() }
            }
        }
        if t.isTemplate { Button("从模板创建任务") { store.duplicate(t.id) } }
        else { Button(t.archived == true ? "取消归档" : "归档") { store.mutate(t.id) { $0.archived = t.archived != true } }; Button("保存为模板") { store.duplicate(t.id,asTemplate: true) }; Button("复制") { store.duplicate(t.id) } }
        if t.deleted { Button("恢复") { store.restoreTask(t.id) } } else { Button("移入回收站",role: .destructive) { store.mutate(t.id) { $0.deleted = true } } }
    } }
}
struct TimelineViewContent: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var store: Store; var tasks: [TaskItem]
    var body: some View { ScrollView([.horizontal,.vertical]) { VStack(alignment: .leading,spacing: 12) { HStack { Text("任务").frame(width: 180,alignment: .leading); ForEach(0..<14,id: \.self) { i in Text(Calendar.current.date(byAdding: .day,value: i,to: Calendar.current.startOfDay(for: Date()))!,format: .dateTime.month().day()).frame(width: 60) } }
        ForEach(tasks) { t in HStack(spacing: 0) { Text(t.title).lineLimit(1).frame(width: 180,alignment: .leading).onTapGesture(count: 2) { openWindow(id: "task-detail",value: t.id); NSApp.activate(ignoringOtherApps: true) }.onTapGesture { store.selectedTask = t.id }; ForEach(0..<14,id: \.self) { i in let day = Calendar.current.date(byAdding: .day,value: i,to: Calendar.current.startOfDay(for: Date()))!; let active = t.due.map { Calendar.current.startOfDay(for: $0) >= day && Calendar.current.startOfDay(for: t.start ?? $0) <= day } ?? false; Rectangle().fill(active ? Color.accentColor.opacity(t.completed ? 0.25 : 0.75) : Color.gray.opacity(0.05)).frame(width: 64,height: 25).dropDestination(for: String.self) { values,_ in for raw in values { if let id = UUID(uuidString: raw) { store.mutate(id) { $0.due = day } } }; return true } } }.draggable(t.id.uuidString) }
    }.padding(20) } }
}

/// Read only this app's plain UUID or list payload; unrelated dropped text is ignored by handlers.
private struct RecordDropDelegate: DropDelegate {
    var updated: (CGPoint) -> Void
    var exited: () -> Void
    var dropped: (String,CGPoint) -> Void
    var activePayload: () -> String? = { nil }
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { updated(info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? { updated(info.location); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { exited() }
    func performDrop(info: DropInfo) -> Bool {
        let location = info.location
        if let raw = activePayload(),!raw.isEmpty {
            exited(); dropped(raw,location)
            return true
        }
        guard let provider = info.itemProviders(for: [.text]).first, provider.canLoadObject(ofClass: NSString.self) else { exited(); return false }
        provider.loadObject(ofClass: NSString.self) { object,_ in
            guard let raw = object as? String else { return }
            DispatchQueue.main.async { dropped(raw,location) }
        }
        exited(); return true
    }
}

struct AdvancedTaskSearch: View {
    @EnvironmentObject var store: Store
    @Binding var criteria: TaskSearchCriteria
    @Binding var allTasks: Bool
    var body: some View { VStack(alignment: .leading,spacing: 14) {
        HStack { Text("高级搜索").font(.headline); Spacer(); Button("重置") { criteria = TaskSearchCriteria(); allTasks = true } }
        Toggle("搜索所有任务",isOn: $allTasks)
        SettingsRow("状态") { SettingsValuePicker("状态",selection: $criteria.status,choices: [("不限","all"),("待完成","active"),("已完成","completed"),("归档任务","archived")]) }
        SettingsRow("清单") { SettingsValuePicker("清单",selection: $criteria.listID,choices: [("所有清单",nil as UUID?)] + store.lists.filter { !$0.deleted }.map { ($0.name,Optional($0.id)) }) }
        SettingsRow("优先级") { SettingsValuePicker("优先级",selection: $criteria.priority,choices: [("不限",-1),("无",0),("低",1),("中",2),("高",3)]) }
        SettingsRow("截止日期") { SettingsValuePicker("截止日期",selection: $criteria.date,choices: [("不限","any"),("今天","today"),("已过期","overdue"),("未来 7 天","week"),("无日期","undated")]) }
        TextField("标签",text: $criteria.tag).textFieldStyle(.roundedBorder)
        Toggle("仅含附件",isOn: $criteria.attachmentsOnly)
        Toggle("仅收藏",isOn: $criteria.starredOnly)
        Text("条件同时满足时显示任务").font(.caption).foregroundStyle(.secondary)
    }.font(.system(size: 13)) }
}
