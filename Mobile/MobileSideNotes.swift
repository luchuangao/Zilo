import SwiftUI
import UIKit

extension MobileStore: SideNotesStore {
    @discardableResult func persistSideNote(_ note: SideNote) -> Bool { save(note) }
    @discardableResult func persistSideNoteFolder(_ folder: SideNoteFolder) -> Bool { save(folder) }
    @discardableResult func persistNoteTask(_ task: TaskItem) -> Bool { save(task) }
}
private struct MobileSideNoteSelection: Identifiable { var id: UUID }
struct MobileSideNotesView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var store: MobileStore
    @Environment(\.mobileAccent) private var accent
    @State private var folderID: UUID?
    @State private var search = ""
    @State private var trash = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var selected: MobileSideNoteSelection?
    @State private var exportFile: MobileHTMLFile?
    private var folders: [SideNoteFolder] { store.noteFolders.filter { !$0.deleted }.sorted { $0.order < $1.order } }
    private var notes: [SideNote] { SideNotesLibrary.visible(store.sideNotes,tasks: store.tasks,folderID: folderID,search: search,trash: trash) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 14) {
                HStack {
                    Menu {
                        Button("所有便签") { folderID = nil }
                        ForEach(folders) { folder in Button(folder.name) { folderID = folder.id } }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(folders.first { $0.id == folderID }?.name ?? ZiloLanguage.text("所有便签")).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.system(size: 10,weight: .semibold)).foregroundStyle(.secondary)
                        }.font(.subheadline.weight(.medium)).foregroundStyle(.primary).padding(.horizontal,12).padding(.vertical,9).background(Color(uiColor: .secondarySystemGroupedBackground),in: Capsule())
                    }.accessibilityLabel("文件夹")
                    Spacer()
                    if trash { Text("回收站").font(.caption).foregroundStyle(.secondary) }
                }
                if notes.isEmpty { MobileEmpty(title: trash ? "没有已删除的便签" : search.isEmpty ? "随手记下一个想法" : "没有匹配的便签",detail: "独立记录想法，也可以从任务菜单打开关联便签。",icon: "note.text").frame(minHeight: 330) }
                ForEach(notes) { note in
                    let document = note.document(tasks: store.tasks)
                    Button { selected = MobileSideNoteSelection(id: note.id) } label: {
                        VStack(alignment: .leading,spacing: 10) {
                            HStack {
                                Text(document?.title.isEmpty == false ? document!.title : ZiloLanguage.text("无标题便签")).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                Spacer()
                                if note.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(accent) }
                                if note.folded { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                            }
                            if !note.folded { Text(document?.notes ?? ZiloLanguage.text("关联任务暂不可用，请同步后重试。")).font(.subheadline).foregroundStyle(.secondary).lineLimit(5).frame(maxWidth: .infinity,alignment: .leading) }
                            if note.taskID != nil || (folderID == nil && folders.contains { $0.id == note.folderID }) {
                                HStack(spacing: 6) {
                                    if note.taskID != nil { badge(ZiloLanguage.text("关联任务"),symbol: "link") }
                                    if folderID == nil,let folder = folders.first(where: { $0.id == note.folderID }) { badge(folder.name,symbol: "folder") }
                                }
                            }
                        }.padding(17).frame(maxWidth: .infinity,alignment: .leading).background(SideNotePaper(stored: note.color).color(dark: scheme == .dark),in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).contextMenu {
                        if note.deleted { Button("恢复便签",systemImage: "arrow.uturn.backward") { store.updateSideNote(note.id) { $0.deleted = false } } }
                        else {
                            Button(note.pinned ? "取消置顶" : "置顶",systemImage: "pin") { store.updateSideNote(note.id) { $0.pinned.toggle() } }
                            Button(note.folded ? "展开便签" : "折叠便签",systemImage: "rectangle.compress.vertical") { store.updateSideNote(note.id) { $0.folded.toggle() } }
                            MobileNoteColorMenu(current: note.color) { color in store.updateSideNote(note.id) { $0.color = color } }
                            Menu("移动到文件夹") { Button("未分类") { store.updateSideNote(note.id) { $0.folderID = nil } }; ForEach(folders) { folder in Button(folder.name) { store.updateSideNote(note.id) { $0.folderID = folder.id } } } }
                            if let document { Button("HTML 网页（.html）",systemImage: "square.and.arrow.up") { export(document) } }
                            Button("删除便签",systemImage: "trash",role: .destructive) { store.updateSideNote(note.id) { $0.deleted = true } }
                        }
                    }
                }
            }.padding(18)
        }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("便签").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search,prompt: "搜索便签")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Menu {
                    Button("新建文件夹",systemImage: "folder.badge.plus") { folderName = ""; newFolder = true }
                    Toggle("便签回收站",isOn: $trash)
                    if let folderID { Button("删除文件夹，保留便签",systemImage: "folder.badge.minus") { if store.deleteNoteFolder(folderID) { self.folderID = nil } } }
                } label: { Image(systemName: "ellipsis") } }
                ToolbarItem(placement: .topBarTrailing) { Button { if let id = store.createSideNote(folderID: folderID) { trash = false; search = ""; selected = MobileSideNoteSelection(id: id) } } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("新建便签") }
            }
            .alert("新建文件夹",isPresented: $newFolder) { TextField("文件夹名称",text: $folderName); Button("取消",role: .cancel) {}; Button("保存") { if let id = store.createNoteFolder(folderName) { folderID = id } } }
            .sheet(item: $selected) { selection in NavigationStack { MobileSideNoteEditor(noteID: selection.id) } }
            .sheet(item: $exportFile) { MobileShare(items: [$0.url]) }
    }
    private func export(_ document: TaskItem) { do { exportFile = MobileHTMLFile(url: try HTMLDocument.temporaryFile(task: document,baseURL: store.persistence.root)) } catch { store.error = error.localizedDescription } }
    private func badge(_ title: String,symbol: String) -> some View {
        HStack(spacing: 4) { Image(systemName: symbol); Text(title).lineLimit(1).truncationMode(.middle) }.font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal,8).padding(.vertical,4).background(accent.opacity(0.06),in: Capsule())
    }
}

struct MobileSideNoteEditor: View {
    var noteID: UUID
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var preview = false
    @State private var height: CGFloat = 200
    @State private var exported: MobileHTMLFile?
    private var note: SideNote? { store.sideNotes.first { $0.id == noteID } }
    private var document: TaskItem? { note?.document(tasks: store.tasks) }
    var body: some View {
        Group {
            if let note,let document {
                ScrollView {
                    VStack(alignment: .leading,spacing: 20) {
                        TextField("无标题便签",text: Binding(get: { self.document?.title ?? "" },set: { store.updateSideNoteDocument(noteID,title: $0) }),axis: .vertical).font(.title2.bold()).disabled(note.deleted).accessibilityLabel("便签标题")
                        if note.taskID != nil { Label("关联任务",systemImage: "link").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal,9).padding(.vertical,5).background(Color.secondary.opacity(0.08),in: Capsule()) }
                        if note.deleted { Text(document.notes).textSelection(.enabled) }
                        else if document.editingMode == .richText {
                            MobileRichTextEditor(data: Binding(get: { self.document?.richText },set: { store.updateSideNoteDocument(noteID,richText: $0) }),plain: Binding(get: { self.document?.notes ?? "" },set: { store.updateSideNoteDocument(noteID,text: $0) })).frame(minHeight: 350)
                        } else {
                            Picker("正文编辑方式",selection: $preview) { Text("编辑").tag(false); Text("预览").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                            if preview { MobileMarkdownPreview(source: Binding(get: { self.document?.notes ?? "" },set: { store.updateSideNoteDocument(noteID,text: $0) }),root: store.persistence.root,onContentHeight: { height = max(200,$0) }).frame(height: height) }
                            else { TextEditor(text: Binding(get: { self.document?.notes ?? "" },set: { store.updateSideNoteDocument(noteID,text: $0) })).frame(minHeight: 350).scrollContentBackground(.hidden).accessibilityLabel("便签内容") }
                        }
                        Text("自动保存").font(.caption).foregroundStyle(.secondary)
                    }.padding(20)
                }.background(SideNotePaper(stored: note.color).color(dark: scheme == .dark))
            } else { MobileEmpty(title: "关联任务暂不可用，请同步后重试。",detail: "",icon: "note.text") }
        }.navigationTitle("便签").navigationBarTitleDisplayMode(.inline).toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) { Menu {
                if let note {
                    if note.deleted { Button("恢复便签") { store.updateSideNote(noteID) { $0.deleted = false } } }
                    else {
                        Button(note.pinned ? "取消置顶" : "置顶",systemImage: "pin") { store.updateSideNote(noteID) { $0.pinned.toggle() } }
                        MobileNoteColorMenu(current: note.color) { color in store.updateSideNote(noteID) { $0.color = color } }
                        Menu("移动到文件夹") { Button("未分类") { store.updateSideNote(noteID) { $0.folderID = nil } }; ForEach(store.noteFolders.filter { !$0.deleted }) { folder in Button(folder.name) { store.updateSideNote(noteID) { $0.folderID = folder.id } } } }
                        if let document { Button("复制内容",systemImage: "doc.on.doc") { UIPasteboard.general.string = document.notes }; Button("HTML 网页（.html）",systemImage: "square.and.arrow.up") { do { exported = MobileHTMLFile(url: try HTMLDocument.temporaryFile(task: document,baseURL: store.persistence.root)) } catch { store.error = error.localizedDescription } } }
                        Button("删除便签",systemImage: "trash",role: .destructive) { store.updateSideNote(noteID) { $0.deleted = true }; dismiss() }
                    }
                }
            } label: { Image(systemName: "ellipsis") } }
        }.sheet(item: $exported) { MobileShare(items: [$0.url]) }
    }
}
private struct MobileNoteColorMenu: View {
    var current: String
    var select: (String) -> Void
    var body: some View {
        Menu("颜色") {
            ForEach(SideNotePaper.allCases) { paper in
                Toggle(isOn: Binding(get: { SideNotePaper(stored: current) == paper },set: { if $0 { select(paper.rawValue) } })) {
                    Label { Text(LocalizedStringKey(paper.title)) } icon: { paper.swatch }
                }
            }
        }
    }
}
