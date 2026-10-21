import Foundation
import SwiftUI

struct SideNoteFolder: ListRecord, Hashable {
    static let kind = "sideNoteFolder"
    var id = UUID(); var deleted = false; var name = ""; var order = Date().timeIntervalSince1970
}
struct SideNote: ListRecord, Hashable {
    static let kind = "sideNote"
    var id = UUID(); var deleted = false; var title = ""; var text = ""
    var richText: Data?; var documentMode: DocumentEditingMode = .markdown
    var folderID: UUID?; var taskID: UUID?
    var color = "none"; var pinned = false; var folded = false
    var created = Date(); var modified = Date(); var order = Date().timeIntervalSince1970
    var attachments: [Attachment] = []
    func document(tasks: [TaskItem]) -> TaskItem? {
        if let taskID { return tasks.first { $0.id == taskID && !$0.deleted } }
        var task = TaskItem(); task.id = id; task.title = title; task.notes = text
        task.richText = richText; task.documentMode = documentMode; task.attachments = attachments
        task.isNote = true; task.created = created; return task
    }
}
enum SideNotesLibrary {
    static let colors = SideNotePaper.allCases.map(\.rawValue)
    static func visible(_ notes: [SideNote],tasks: [TaskItem],folderID: UUID? = nil,search: String = "",trash: Bool = false) -> [SideNote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.filter { note in
            guard note.deleted == trash,folderID == nil || note.folderID == folderID else { return false }
            let document = note.document(tasks: tasks)
            return query.isEmpty || ((document?.title ?? note.title) + "\n" + (document?.notes ?? note.text)).localizedCaseInsensitiveContains(query)
        }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.order == $1.order ? $0.created < $1.created : $0.order > $1.order
        }
    }
}

@MainActor protocol SideNotesStore: AnyObject {
    var sideNotes: [SideNote] { get }
    var noteFolders: [SideNoteFolder] { get }
    var tasks: [TaskItem] { get }
    var persistence: Persistence { get }
    var error: String? { get set }
    @discardableResult func persistSideNote(_ note: SideNote) -> Bool
    @discardableResult func persistSideNoteFolder(_ folder: SideNoteFolder) -> Bool
    @discardableResult func persistNoteTask(_ task: TaskItem) -> Bool
    func reload()
}
@MainActor extension SideNotesStore {
    @discardableResult func createSideNote(folderID: UUID? = nil,text: String = "") -> UUID? {
        var note = SideNote(); note.folderID = validNoteFolder(folderID); note.text = text
        return persistSideNote(note) ? note.id : nil
    }
    @discardableResult func linkSideNote(taskID: UUID) -> UUID? {
        guard let task = tasks.first(where: { $0.id == taskID && !$0.deleted }) else { return nil }
        if let existing = sideNotes.first(where: { $0.taskID == taskID && !$0.deleted }) { return existing.id }
        var note = SideNote(); note.taskID = taskID; note.title = task.title
        return persistSideNote(note) ? note.id : nil
    }
    func updateSideNote(_ id: UUID,_ body: (inout SideNote) -> Void) {
        guard var note = sideNotes.first(where: { $0.id == id }) else { return }
        let before = note; body(&note); guard before != note else { return }
        note.modified = Date(); _ = persistSideNote(note)
    }
    func updateSideNoteDocument(_ id: UUID,title: String? = nil,text: String? = nil,richText: Data? = nil,mode: DocumentEditingMode? = nil) {
        guard var note = sideNotes.first(where: { $0.id == id && !$0.deleted }),var document = note.document(tasks: tasks) else { return }
        if let title { document.title = title }
        if let text { document.notes = text }
        if let mode { document.documentMode = mode }
        if richText != nil { document.richText = richText }
        if note.taskID != nil { _ = persistNoteTask(document) }
        else {
            note.title = document.title; note.text = document.notes; note.richText = document.richText
            note.documentMode = document.editingMode; note.modified = Date(); _ = persistSideNote(note)
        }
    }
    @discardableResult func createNoteFolder(_ name: String) -> UUID? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let existing = noteFolders.first(where: { !$0.deleted && $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame }) { return existing.id }
        var folder = SideNoteFolder(); folder.name = value
        return persistSideNoteFolder(folder) ? folder.id : nil
    }
    @discardableResult func deleteNoteFolder(_ id: UUID) -> Bool {
        guard var folder = noteFolders.first(where: { $0.id == id && !$0.deleted }) else { return false }
        folder.deleted = true
        do {
            try persistence.transaction {
                try persistence.save(folder)
                for var note in sideNotes where note.folderID == id { note.folderID = nil; try persistence.save(note) }
            }
            reload(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func validNoteFolder(_ id: UUID?) -> UUID? { noteFolders.contains { $0.id == id && !$0.deleted } ? id : nil }
}

/// Stable storage keys preserve existing notes while both platforms share paper colors.
enum SideNotePaper: String, CaseIterable, Identifiable {
    case none, yellow, blue, green, purple, pink, orange, teal
    var id: String { rawValue }
    init(stored: String) { self = Self(rawValue: stored) ?? .none }
    var title: String {
        switch self {
        case .none: return "纯白"
        case .yellow: return "奶油黄"
        case .blue: return "雾蓝"
        case .green: return "鼠尾草绿"
        case .purple: return "薰衣草紫"
        case .pink: return "玫瑰粉"
        case .orange: return "杏桃橙"
        case .teal: return "海盐青"
        }
    }
    func hex(dark: Bool) -> UInt32 {
        switch self {
        case .none: return dark ? 0x292A2D : 0xFFFFFF
        case .yellow: return dark ? 0x383326 : 0xFFF5D8
        case .blue: return dark ? 0x283340 : 0xEAF2FC
        case .green: return dark ? 0x2C372E : 0xEDF3E7
        case .purple: return dark ? 0x332E40 : 0xF1ECFA
        case .pink: return dark ? 0x3D2D34 : 0xFBECEF
        case .orange: return dark ? 0x403125 : 0xFFF0E3
        case .teal: return dark ? 0x253A38 : 0xE6F4F0
        }
    }
    var swatchHex: UInt32 {
        switch self {
        case .none: return 0xFFFFFF
        case .yellow: return 0xE8C56D
        case .blue: return 0x91B4DD
        case .green: return 0xA7BD94
        case .purple: return 0xB9A6D7
        case .pink: return 0xDDA6B3
        case .orange: return 0xE8B087
        case .teal: return 0x8BBFB4
        }
    }
    func color(dark: Bool) -> Color { Self.color(hex(dark: dark)) }
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255)/255,green: Double((hex >> 8) & 255)/255,blue: Double(hex & 255)/255)
    }
    var swatch: Image {
        Image(size: CGSize(width: 14,height: 14)) { context in
            let shape = Path(ellipseIn: CGRect(x: 1,y: 1,width: 12,height: 12))
            context.fill(shape,with: .color(Self.color(swatchHex)))
            context.stroke(shape,with: .color(.black.opacity(0.12)),lineWidth: 0.5)
        }.renderingMode(.original)
    }
}
