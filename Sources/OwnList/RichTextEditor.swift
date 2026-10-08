import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension NSTextView {
    /// Imported documents keep their own fonts; input-method insertion normalizes sizes.
    func insertDocument(_ document: NSAttributedString) {
        let range = selectedRange()
        if performValidatedReplacement(in: range,with: document) {
            setSelectedRange(NSRange(location: range.location + document.length,length: 0))
        }
    }
}

enum TaskPrintDocument {
    static func makeView(task: TaskItem,children: [TaskItem] = [],baseURL: URL? = nil) -> NSTextView {
        let content = NSMutableAttributedString(string: task.title + "\n\n",attributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
        if let rich = task.richText, let attributed = RichDocument.decode(rich) { content.append(attributed) }
        else if task.editingMode == .markdown { content.append(MarkdownDocument.parse(task.notes,baseURL: baseURL).content) }
        else { content.append(NSAttributedString(string: task.notes,attributes: [.font: NSFont.systemFont(ofSize: 14)])) }
        for check in task.checks { content.append(NSAttributedString(string: "\n\(check.done ? "☑" : "☐") \(check.title)",attributes: [.font: NSFont.systemFont(ofSize: 14)])) }
        if !children.isEmpty { content.append(NSAttributedString(string: "\n\n子任务",attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])) }
        for child in children { content.append(NSAttributedString(string: "\n\(child.completed ? "☑" : "☐") \(child.title)",attributes: [.font: NSFont.systemFont(ofSize: 14)])) }
        let range = NSRange(location: 0,length: content.length)
        content.addAttribute(.foregroundColor,value: NSColor.black,range: range)
        content.removeAttribute(.backgroundColor,range: range)
        content.enumerateAttributes(in: range) { attributes,run,_ in
            if MarkdownTyping.isCodeBlock(attributes) { content.addAttribute(.backgroundColor,value: NSColor(white: 0.95,alpha: 1),range: run) }
        }
        RichDocument.fitImages(content,width: 523)
        let view = NSTextView(frame: NSRect(x: 0,y: 0,width: 540,height: 24))
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: 540,height: CGFloat.greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(content)
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: 540,height: max(24,ceil(layout.usedRect(for: container).height))))
        }
        return view
    }
}

enum DocumentFormat: String, CaseIterable {
    case heading, bold, italic, underline, strike, bullet, numbered, quote, code, codeBlock, link
    var title: String { switch self {
    case .heading: return "标题"; case .bold: return "粗体"; case .italic: return "斜体"
    case .underline: return "下划线"; case .strike: return "删除线"; case .bullet: return "项目列表"
    case .numbered: return "编号列表"; case .quote: return "引用"; case .code: return "行内代码"; case .codeBlock: return "代码块"; case .link: return "链接"
    } }
    var symbol: String { switch self {
    case .heading: return "textformat.size"; case .bold: return "bold"; case .italic: return "italic"
    case .underline: return "underline"; case .strike: return "strikethrough"; case .bullet: return "list.bullet"
    case .numbered: return "list.number"; case .quote: return "text.quote"; case .code: return "chevron.left.forwardslash.chevron.right"; case .codeBlock: return "curlybraces"; case .link: return "link"
    } }
    func markdown(_ selected: String) -> String {
        switch self {
        case .heading: return "## " + selected
        case .bold: return "**" + selected + "**"
        case .italic: return "*" + selected + "*"
        case .underline: return "<u>" + selected + "</u>"
        case .strike: return "~~" + selected + "~~"
        case .code: return "`" + selected + "`"
        case .codeBlock: return "```\n" + selected + "\n```"
        case .link: return "[" + (selected.isEmpty ? "链接文字" : selected) + "](https://)"
        case .bullet, .numbered, .quote:
            return selected.components(separatedBy: "\n").enumerated().map { index,line in
                (self == .bullet ? "- " : self == .quote ? "> " : "\(index + 1). ") + line
            }.joined(separator: "\n")
        }
    }
}

/// Commands target this document's text view, including after a toolbar click changes focus.
final class DocumentEditorController: ObservableObject {
    weak var editor: NSTextView?
    var rich = false
    func insertImages(_ urls: [URL]) throws {
        guard let editor = editor as? DocumentTextView else { return }
        editor.window?.makeFirstResponder(editor)
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try editor.insertImage(Data(contentsOf: url), name: url.lastPathComponent)
        }
    }
    func insertMarkdown(_ urls: [URL]) throws -> [String] {
        guard let editor else { return [] }
        editor.window?.makeFirstResponder(editor)
        var warnings: [String] = []
        for url in urls {
            if !rich {
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let editor = editor as? DocumentTextView { try editor.insertMarkdownFile(url) }
                continue
            }
            let result = try MarkdownDocument.read(url,authorizeImages: true); warnings += result.warnings
            editor.insertDocument(result.content)
            editor.typingAttributes = MarkdownTyping.bodyAttributes
        }
        return warnings
    }
    @Published var activeFormats: Set<DocumentFormat> = []
    func refreshSelection() {
        guard rich, let editor else { if !activeFormats.isEmpty { activeFormats = [] }; return }
        let range = editor.selectedRange()
        let attributes = range.length > 0 && range.location < editor.string.utf16.count ? editor.textStorage?.attributes(at: range.location,effectiveRange: nil) ?? [:] : editor.typingAttributes
        var formats = Set<DocumentFormat>()
        if let font = attributes[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { formats.insert(.bold) }
            if traits.contains(.italicFontMask) { formats.insert(.italic) }
            if font.pointSize >= 20 { formats.insert(.heading) }
        }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { formats.insert(.underline) }
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { formats.insert(.strike) }
        if attributes[.link] != nil { formats.insert(.link) }
        if MarkdownTyping.isCodeBlock(attributes) { formats.insert(.codeBlock) }
        if formats != activeFormats { activeFormats = formats }
    }
    var selectedText: String { guard let editor else { return "" }; return (editor.string as NSString).substring(with: editor.selectedRange()) }
    func insertLink(title: String,url: URL) {
        guard let editor else { return }
        editor.window?.makeFirstResponder(editor)
        if rich {
            let attributed = NSAttributedString(string: title,attributes: [.link: url,.font: NSFont.systemFont(ofSize: 14)])
            editor.insertText(attributed,replacementRange: editor.selectedRange())
        } else { editor.insertText("[\(title)](\(url.absoluteString))",replacementRange: editor.selectedRange()) }
        refreshSelection()
    }
    func apply(_ format: DocumentFormat) {
        guard let editor else { return }
        editor.window?.makeFirstResponder(editor)
        let range = editor.selectedRange()
        defer { refreshSelection() }
        if rich && format == .codeBlock { MarkdownTyping.insertCodeBlock(in: editor); return }
        if rich, [.bold,.italic,.heading,.underline,.strike,.code,.quote].contains(format) {
            let attributes = range.length > 0 ? editor.textStorage?.attributes(at: range.location,effectiveRange: nil) ?? [:] : editor.typingAttributes
            var changed: [NSAttributedString.Key: Any] = [:]
            let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
            switch format {
            case .bold, .italic:
                let trait: NSFontTraitMask = format == .bold ? .boldFontMask : .italicFontMask
                changed[.font] = NSFontManager.shared.traits(of: font).contains(trait) ? NSFontManager.shared.convert(font,toNotHaveTrait: trait) : NSFontManager.shared.convert(font,toHaveTrait: trait)
            case .heading: changed[.font] = NSFont.boldSystemFont(ofSize: 20)
            case .underline: changed[.underlineStyle] = (attributes[.underlineStyle] as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : 0
            case .strike: changed[.strikethroughStyle] = (attributes[.strikethroughStyle] as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : 0
            case .code: changed[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize,weight: .regular)
            case .quote:
                let paragraph = NSMutableParagraphStyle(); paragraph.headIndent = 16; paragraph.firstLineHeadIndent = 16
                changed[.paragraphStyle] = paragraph
            default: break
            }
            if range.length == 0 { editor.typingAttributes.merge(changed) { _,new in new } }
            else if editor.shouldChangeText(in: range,replacementString: nil) { editor.textStorage?.addAttributes(changed,range: range); editor.didChangeText() }
        } else {
            let selected = (editor.string as NSString).substring(with: range)
            let replacement = rich && format == .bullet ? selected.components(separatedBy: "\n").map { "• " + $0 }.joined(separator: "\n") : format.markdown(selected)
            editor.insertText(replacement,replacementRange: range)
            if range.length > 0 { editor.setSelectedRange(NSRange(location: range.location,length: (replacement as NSString).length)) }
        }
    }
}

/// Model echoes must not replace an in-progress native edit. Keep the last
/// model read separate from native saves, including changes to formatting only.
struct DocumentEditorSnapshot: Equatable {
    let text: String
    let data: Data?
    let rich: Bool
    init(text: String,data: Data?,rich: Bool) { self.text = text; self.data = data; self.rich = rich }
    init(editor: NSTextView) {
        text = editor.string; rich = editor.isRichText
        data = rich ? editor.textStorage.flatMap(RichDocument.encode) : nil
    }
}
final class DocumentEditorSyncState {
    private var observed: DocumentEditorSnapshot
    private var savedNative: DocumentEditorSnapshot?
    private var emitted: DocumentEditorSnapshot?
    init(_ model: DocumentEditorSnapshot) { observed = model }
    func shouldLoad(_ model: DocumentEditorSnapshot) -> Bool {
        guard model != observed else { return false }
        observed = model
        return model != emitted
    }
    func didLoad(_ editor: NSTextView) {
        savedNative = DocumentEditorSnapshot(editor: editor); emitted = nil
    }
    func shouldSave(_ snapshot: DocumentEditorSnapshot) -> Bool {
        guard snapshot != savedNative else { return false }
        savedNative = snapshot; emitted = snapshot
        return true
    }
}

/// Borderless, height-fitting document editor; the enclosing detail owns scrolling.
struct DetailDocumentEditor: NSViewRepresentable {
    var text: String; var data: Data?; var rich: Bool
    var editable = true
    var scrolling = false
    var accessibilityLabel = "任务正文"
    var onError: (String) -> Void = { _ in }
    var imageReference: ((Data,String) throws -> String)?
    var baseURL: URL?
    var controller: DocumentEditorController
    @Binding var height: CGFloat
    var onChange: (String,Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> DocumentScrollView {
        let scroll = DocumentScrollView()
        let editor = DocumentTextView()
        editor.isEditable = editable; editor.isSelectable = true; editor.allowsUndo = true; editor.importsGraphics = rich
        editor.transferError = onError; editor.imageReference = imageReference; editor.documentBaseURL = baseURL
        editor.drawsBackground = false; editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainerInset = NSSize(width: 0,height: 3)
        editor.textContainer?.lineFragmentPadding = 0; editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = editor
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.fitsContent = !scrolling
        scroll.hasVerticalScroller = scrolling; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        if !scrolling { scroll.onHeight = { [weak coordinator = context.coordinator] value in coordinator?.resize(value) } }
        populate(editor); context.coordinator.attach(editor)
        controller.editor = editor; controller.rich = rich
        return scroll
    }
    func updateNSView(_ view: DocumentScrollView,context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronize(view)
    }
    func populate(_ editor: NSTextView) {
        editor.isRichText = rich
        if rich, let data, let attributed = RichDocument.decode(data) {
            let display = NSMutableAttributedString(attributedString: attributed)
            attributed.enumerateAttribute(.foregroundColor,in: NSRange(location: 0,length: attributed.length)) { value,range,_ in
                guard let color = (value as? NSColor)?.usingColorSpace(.deviceRGB) else { return }
                let gray = abs(color.redComponent - color.greenComponent) < 0.01 && abs(color.greenComponent - color.blueComponent) < 0.01
                if gray && (color.redComponent < 0.02 || color.redComponent > 0.98) { display.addAttribute(.foregroundColor,value: NSColor.labelColor,range: range) }
            }
            editor.textStorage?.setAttributedString(display)
        }
        else { editor.textStorage?.setAttributedString(NSAttributedString(string: text,attributes: [.font: NSFont.systemFont(ofSize: 14),.foregroundColor: NSColor.labelColor])) }
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 14),.foregroundColor: NSColor.labelColor]
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DetailDocumentEditor
        let sync: DocumentEditorSyncState
        var applyingModel = false
        var convertingMarkdown = false
        init(parent: DetailDocumentEditor) {
            self.parent = parent
            sync = DocumentEditorSyncState(DocumentEditorSnapshot(text: parent.text,data: parent.data,rich: parent.rich))
        }
        func attach(_ editor: DocumentTextView) {
            editor.delegate = self
            editor.compositionDidEnd = { [weak self] editor in
                self?.textDidChange(Notification(name: NSText.didChangeNotification,object: editor))
            }
            sync.didLoad(editor)
        }
        func synchronize(_ view: DocumentScrollView) {
            guard let editor = view.documentView as? NSTextView else { return }
            parent.controller.editor = editor
            (editor as? DocumentTextView)?.transferError = parent.onError
            (editor as? DocumentTextView)?.imageReference = parent.imageReference
            (editor as? DocumentTextView)?.documentBaseURL = parent.baseURL
            // Even a height or theme refresh must leave the marked range and
            // input-method session intact until its text is committed.
            guard !editor.hasMarkedText() else { view.needsLayout = true; return }
            let model = DocumentEditorSnapshot(text: parent.text,data: parent.data,rich: parent.rich)
            if sync.shouldLoad(model) {
                applyingModel = true
                let selection = editor.selectedRange()
                parent.populate(editor)
                let count = editor.string.utf16.count
                let location = min(selection.location,count)
                editor.setSelectedRange(NSRange(location: location,length: min(selection.length,count - location)))
                sync.didLoad(editor)
                applyingModel = false
            }
            parent.controller.rich = parent.rich
            if editor.isRichText != parent.rich { editor.isRichText = parent.rich }
            if editor.isEditable != parent.editable { editor.isEditable = parent.editable }
            if editor.importsGraphics != parent.rich { editor.importsGraphics = parent.rich }
            view.needsLayout = true
        }
        func resize(_ value: CGFloat) {
            guard abs(parent.height - value) > 1 else { return }
            DispatchQueue.main.async { [weak self] in if let self, abs(self.parent.height - value) > 1 { self.parent.height = value } }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingModel, let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            if parent.rich, editor.selectedRange().length == 0,
               let storage = editor.textStorage, editor.selectedRange().location < storage.length {
                let attributes = storage.attributes(at: editor.selectedRange().location,effectiveRange: nil)
                if MarkdownTyping.isCodeBlock(attributes) { editor.typingAttributes = MarkdownTyping.codeBlockAttributes }
                else if MarkdownTyping.isCodeBlock(editor.typingAttributes) { editor.typingAttributes = attributes }
            }
            // Recognize syntax on a committed edit, never on cursor movement.
            DispatchQueue.main.async { [weak self] in self?.parent.controller.refreshSelection() }
        }
        func performUndo(in editor: NSTextView,redo: Bool = false) {
            guard !editor.hasMarkedText(), let undo = editor.undoManager, redo ? undo.canRedo : undo.canUndo else { return }
            convertingMarkdown = true
            if redo { undo.redo() } else { undo.undo() }
            convertingMarkdown = false
            persist(editor)
            parent.controller.refreshSelection()
        }
        func persist(_ editor: NSTextView) {
            guard !applyingModel, !editor.hasMarkedText() else { return }
            let snapshot = DocumentEditorSnapshot(editor: editor)
            if sync.shouldSave(snapshot) { parent.onChange(snapshot.text,snapshot.data) }
            editor.enclosingScrollView?.needsLayout = true
        }
        func textView(_ textView: NSTextView,doCommandBy commandSelector: Selector) -> Bool {
            guard parent.rich, !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { return MarkdownTyping.insertNewline(in: textView) }
            if commandSelector == #selector(NSResponder.insertTab(_:)), MarkdownTyping.isCodeBlock(textView.typingAttributes) {
                textView.insertText("\t",replacementRange: textView.selectedRange()); return true
            }
            return false
        }
        func textDidChange(_ notification: Notification) {
            guard !applyingModel, !convertingMarkdown, let editor = notification.object as? NSTextView,
                  !editor.hasMarkedText() else { return }
            if parent.rich, editor.undoManager?.isUndoing != true, editor.undoManager?.isRedoing != true {
                convertingMarkdown = true
                MarkdownTyping.recognize(in: editor)
                convertingMarkdown = false
                parent.controller.refreshSelection()
            }
            persist(editor)
        }
        func textDidEndEditing(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            persist(editor)
        }
    }
}
/// Code blocks use ordinary RTF paragraph attributes, so their boundaries survive
/// app restarts, backups and sync. Paint the panel separately for light/dark mode.
class DocumentTextView: NSTextView {
    var compositionDidEnd: ((DocumentTextView) -> Void)?
    override func insertText(_ insertString: Any,replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        super.insertText(insertString,replacementRange: replacementRange)
        if wasComposing && !hasMarkedText() { compositionDidEnd?(self) }
    }
    override func unmarkText() {
        let wasComposing = hasMarkedText()
        super.unmarkText()
        if wasComposing {
            // AppKit may unmark inside insertText before replacing candidates.
            // Wait until that native operation finishes before saving.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasMarkedText() else { return }
                self.compositionDidEnd?(self)
            }
        }
    }
    var transferError: (String) -> Void = { _ in }
    var imageReference: ((Data,String) throws -> String)?
    var documentBaseURL: URL?
    func insertMarkdownFile(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = try String(contentsOf: url,encoding: .utf8)
        let imported = try MarkdownDocument.rewriteImages(source) { address in
            guard let imageReference, let bytes = MarkdownDocument.imageBytes(address,baseURL: url.deletingLastPathComponent()) else { return address }
            return try imageReference(bytes,URL(fileURLWithPath: address).lastPathComponent)
        }
        insertText(imported,replacementRange: selectedRange())
    }
    func insertImage(_ data: Data, name: String = "图片.png") throws {
        if !isRichText {
            guard let imageReference else { throw ServiceError.message("图片存储尚未就绪，请重新打开任务后重试。") }
            let path = try imageReference(data,name)
            let source = "![图片](" + path + ")"
            let caret = selectedRange().location
            let prefix = caret > 0 && (string as NSString).character(at: caret - 1) != 10 ? "\n" : ""
            insertText(prefix + source + "\n",replacementRange: selectedRange())
            return
        }
        let block = NSMutableAttributedString(string: "")
        let caret = selectedRange().location
        if caret > 0, (string as NSString).character(at: caret - 1) != 10 { block.append(NSAttributedString(string: "\n", attributes: MarkdownTyping.bodyAttributes)) }
        block.append(try RichDocument.image(data, name: name))
        block.append(NSAttributedString(string: "\n", attributes: MarkdownTyping.bodyAttributes))
        RichDocument.fitImages(block,width: max(80,bounds.width - 8))
        insertDocument(block); typingAttributes = MarkdownTyping.bodyAttributes
    }
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        do {
            if !urls.isEmpty, urls.allSatisfy({ ["md","markdown","mdown"].contains($0.pathExtension.lowercased()) }) {
                var warnings: [String] = []
                for url in urls {
                    if isRichText { let document = try MarkdownDocument.read(url,authorizeImages: true); insertDocument(document.content); warnings += document.warnings }
                    else {
                        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try insertMarkdownFile(url)
                    }
                }
                typingAttributes = MarkdownTyping.bodyAttributes
                if !warnings.isEmpty { transferError(warnings.joined(separator: "\n")) }; return
            }
            if !urls.isEmpty, urls.allSatisfy({ UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) {
                for url in urls { let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }; try insertImage(Data(contentsOf: url),name: url.lastPathComponent) }; return
            }
            if (!isRichText || pasteboard.availableType(from: [.rtfd,.rtf,.html]) == nil), let type = pasteboard.availableType(from: [.png,.tiff]), let data = pasteboard.data(forType: type) { try insertImage(data); return }
            if isRichText, !MarkdownTyping.isCodeBlock(typingAttributes), pasteboard.availableType(from: [.rtfd,.rtf,.html]) == nil,
               let source = pasteboard.string(forType: .string), source.contains("\n") {
                let document = MarkdownDocument.parse(source)
                insertDocument(document.content); typingAttributes = MarkdownTyping.bodyAttributes
                if !document.warnings.isEmpty { transferError(document.warnings.joined(separator: "\n")) }; return
            }
            super.paste(sender)
        } catch { transferError(error.localizedDescription) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if let storage = textStorage, let manager = layoutManager, let container = textContainer {
            manager.ensureLayout(for: container)
            var ranges: [NSRange] = []
            storage.enumerateAttributes(in: NSRange(location: 0,length: storage.length)) { attributes,range,_ in
                guard MarkdownTyping.isCodeBlock(attributes) else { return }
                if let last = ranges.last, NSMaxRange(last) == range.location { ranges[ranges.count - 1].length += range.length }
                else { ranges.append(range) }
            }
            for range in ranges {
                let glyphs = manager.glyphRange(forCharacterRange: range,actualCharacterRange: nil)
                var panel = NSRect.null
                manager.enumerateLineFragments(forGlyphRange: glyphs) { rect,_,_,_,_ in panel = panel.union(rect) }
                guard !panel.isNull else { continue }
                panel.origin = NSPoint(x: 2,y: panel.minY + textContainerOrigin.y)
                panel.size.width = max(0,bounds.width - 4)
                NSColor.labelColor.withAlphaComponent(0.055).setFill()
                NSBezierPath(roundedRect: panel,xRadius: 6,yRadius: 6).fill()
            }
        }
        super.draw(dirtyRect)
    }
}
final class DocumentScrollView: NSScrollView {
    var fitsContent = true
    var onHeight: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat?
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView, let container = editor.textContainer, let manager = editor.layoutManager else { return }
        let width = max(1,contentSize.width)
        if let storage = editor.textStorage, RichDocument.fitImages(storage,width: min(520,max(40,width - 8)),maxHeight: 360) {
            manager.invalidateLayout(forCharacterRange: NSRange(location: 0,length: storage.length),actualCharacterRange: nil)
        }
        if container.containerSize.width != width { container.containerSize = NSSize(width: width,height: CGFloat.greatestFiniteMagnitude) }
        if abs(editor.frame.width - width) > 0.5 { editor.setFrameSize(NSSize(width: width,height: max(26,editor.frame.height))) }
        manager.ensureLayout(for: container)
        // usedRect excludes the empty line after a trailing Return. Including
        // that line prevents the caret from scrolling before height catches up.
        let bottom = max(manager.usedRect(for: container).maxY,manager.extraLineFragmentRect.maxY)
        let fitted = max(26,ceil(bottom + editor.textContainerInset.height * 2))
        let nativeHeight = fitsContent ? fitted : max(contentSize.height,fitted)
        if abs(editor.frame.height - nativeHeight) > 0.5 { editor.setFrameSize(NSSize(width: width,height: nativeHeight)) }
        if fitsContent, reportedHeight != fitted { reportedHeight = fitted; onHeight?(fitted) }
    }
}

struct RichTextEditor: NSViewRepresentable {
    var text: String; var data: Data?; var onChange: (String,Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let editor = DocumentTextView(); editor.isRichText = true; editor.importsGraphics = true; editor.isEditable = true; editor.isSelectable = true; editor.allowsUndo = true; editor.usesFontPanel = true; editor.isAutomaticLinkDetectionEnabled = true; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = NSSize(width: 8,height: 8)
        scroll.documentView = editor; populate(editor); context.coordinator.attach(editor)
        return scroll
    }
    func updateNSView(_ view: NSScrollView,context: Context) {
        context.coordinator.parent = self
        context.coordinator.synchronize(view)
    }
    func populate(_ editor: NSTextView) {
        if let data, let rich = RichDocument.decode(data) { RichDocument.fitImages(rich,width: max(80,editor.bounds.width - 16)); editor.textStorage?.setAttributedString(rich) }
        else { editor.string = text; editor.font = .systemFont(ofSize: 14); editor.textColor = .labelColor }
    }
    final class Coordinator: NSObject,NSTextViewDelegate {
        var parent: RichTextEditor
        let sync: DocumentEditorSyncState
        var applyingModel = false
        init(parent: RichTextEditor) {
            self.parent = parent
            sync = DocumentEditorSyncState(DocumentEditorSnapshot(text: parent.text,data: parent.data,rich: true))
        }
        func attach(_ editor: DocumentTextView) {
            editor.delegate = self
            editor.compositionDidEnd = { [weak self] editor in self?.persist(editor) }
            sync.didLoad(editor)
        }
        func synchronize(_ view: NSScrollView) {
            guard let editor = view.documentView as? NSTextView, !editor.hasMarkedText() else { return }
            if sync.shouldLoad(DocumentEditorSnapshot(text: parent.text,data: parent.data,rich: true)) {
                applyingModel = true
                let selection = editor.selectedRange(); parent.populate(editor)
                let count = editor.string.utf16.count
                let location = min(selection.location,count)
                editor.setSelectedRange(NSRange(location: location,length: min(selection.length,count - location)))
                sync.didLoad(editor)
                applyingModel = false
            }
        }
        func persist(_ editor: NSTextView) {
            guard !applyingModel, !editor.hasMarkedText() else { return }
            let snapshot = DocumentEditorSnapshot(editor: editor)
            if sync.shouldSave(snapshot) { parent.onChange(snapshot.text,snapshot.data) }
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            persist(editor)
        }
        func textDidEndEditing(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            persist(editor)
        }
    }
}

/// Markdown shortcuts in the default document editor. Only the active, committed
/// insertion is transformed; opening a document never rewrites existing content.
enum MarkdownTyping {
    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 14),.foregroundColor: NSColor.labelColor,.paragraphStyle: NSParagraphStyle.default]
    }
    static func listAttributes() -> [NSAttributedString.Key: Any] {
        var attributes = bodyAttributes
        let paragraph = NSMutableParagraphStyle(); paragraph.headIndent = 18; paragraph.firstLineHeadIndent = 0
        attributes[.paragraphStyle] = paragraph
        return attributes
    }
    static var codeBlockAttributes: [NSAttributedString.Key: Any] {
        var attributes = bodyAttributes
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 12; paragraph.firstLineHeadIndent = 12; paragraph.lineSpacing = 3
        attributes[.paragraphStyle] = paragraph
        attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13,weight: .regular)
        return attributes
    }
    static func isCodeBlock(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        guard let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle else { return false }
        return paragraph.headIndent == 12 && paragraph.firstLineHeadIndent == 12 && paragraph.lineSpacing == 3
    }
    static func insertCodeBlock(in editor: NSTextView) {
        let range = editor.selectedRange(); let text = editor.string as NSString
        let selected = text.substring(with: range)
        let block = NSMutableAttributedString(string: "")
        if range.location > 0 && text.character(at: range.location - 1) != 10 { block.append(NSAttributedString(string: "\n",attributes: bodyAttributes)) }
        let start = range.location + block.length
        block.append(NSAttributedString(string: selected + (selected.hasSuffix("\n") ? "" : "\n"),attributes: codeBlockAttributes))
        block.append(NSAttributedString(string: "\n",attributes: bodyAttributes))
        editor.insertText(block,replacementRange: range)
        editor.setSelectedRange(NSRange(location: start,length: 0)); editor.typingAttributes = codeBlockAttributes
    }
    private static func convertPastedCodeBlock(in editor: NSTextView,caret: Int) -> Bool {
        let text = editor.string as NSString
        guard caret <= text.length else { return false }
        let prefix = text.substring(to: caret)
        // Convert only a complete fenced block ending at this insertion. Code is
        // literal, including indentation, blank lines and Markdown punctuation.
        let source = prefix as NSString
        var lines: [(range: NSRange,value: String)] = []
        var location = 0
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location,length: 0))
            let value = source.substring(with: range).trimmingCharacters(in: .newlines)
            lines.append((range,value)); location = NSMaxRange(range)
        }
        while lines.last?.value.isEmpty == true { lines.removeLast() }
        guard let closing = lines.indices.last, match(#"^```[ \t]*$"#,in: lines[closing].value) != nil,
              let opening = lines.indices[..<closing].last(where: { match(#"^```[A-Za-z0-9_+.-]*[ \t]*$"#,in: lines[$0].value) != nil }) else { return false }
        let start = lines[opening].range.location
        if let attributes = editor.textStorage?.attributes(at: start,effectiveRange: nil), isCodeBlock(attributes) { return false }
        let contentStart = NSMaxRange(lines[opening].range)
        let contentRange = NSRange(location: contentStart,length: max(0,lines[closing].range.location - contentStart))
        let content = source.substring(with: contentRange)
        let block = NSMutableAttributedString(string: content + (content.hasSuffix("\n") ? "" : "\n"),attributes: codeBlockAttributes)
        block.append(NSAttributedString(string: "\n",attributes: bodyAttributes))
        let closingRange = lines[closing].range
        editor.insertText(block,replacementRange: NSRange(location: start,length: NSMaxRange(closingRange) - start))
        editor.setSelectedRange(NSRange(location: start + block.length,length: 0)); editor.typingAttributes = bodyAttributes
        return true
    }
    @discardableResult static func recognize(in editor: NSTextView) -> Bool {
        guard editor.isRichText, !editor.hasMarkedText(), editor.selectedRange().length == 0 else { return false }
        let text = editor.string as NSString; let caret = editor.selectedRange().location
        guard caret <= text.length else { return false }
        if isCodeBlock(editor.typingAttributes) { return false }
        if convertPastedCodeBlock(in: editor,caret: caret) { return true }
        let line = text.lineRange(for: NSRange(location: caret,length: 0))
        let inputRange = NSRange(location: line.location,length: caret - line.location)
        let input = text.substring(with: inputRange)
        if let match = match(#"^(#{1,6}) $"#,in: input) {
            let count = (input as NSString).substring(with: match.range(at: 1)).count
            var attributes = bodyAttributes
            attributes[.font] = NSFont.boldSystemFont(ofSize: [24.0,20,18,17,16,15][count - 1])
            replace(in: editor,range: inputRange,with: "",attributes: attributes)
            return true
        }
        if ["- ","* ","+ "].contains(input) {
            replace(in: editor,range: inputRange,with: "• ",attributes: listAttributes()); return true
        }
        if match(#"^\d{1,9}[.)] $"#,in: input) != nil {
            let existing = editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle
            if (existing?.headIndent ?? 0) < 18 {
                replace(in: editor,range: inputRange,with: input,attributes: listAttributes()); return true
            }
        }
        if input == "> " {
            replace(in: editor,range: inputRange,with: "│ ",attributes: listAttributes()); return true
        }
        let formats: [(String,DocumentFormat)] = [
            (#"(?<![\\*])\*\*([^*\n]+)\*\*$"#,.bold),
            (#"(?<![\\_])__([^_\n]+)__$"#,.bold),
            (#"(?<![\\~])~~([^~\n]+)~~$"#,.strike),
            (#"(?<![\\`])`([^`\n]+)`$"#,.code),
            (#"(?<![\\*])\*([^*\n]+)\*$"#,.italic),
            (#"(?<![\\_\p{L}\p{N}])_([^_\n]+)_$"#,.italic)
        ]
        // Inline code is handled before emphasis, and its content stays literal.
        let ordered = [formats[3]] + formats.enumerated().filter { $0.offset != 3 }.map(\.element)
        if input.filter({ $0 == "`" }).count % 2 == 1 { return false }
        for (pattern,format) in ordered {
            guard let match = match(pattern,in: input) else { continue }
            let inner = (input as NSString).substring(with: match.range(at: 1))
            let range = NSRange(location: line.location + match.range.location,length: match.range.length)
            let original = editor.typingAttributes
            var attributes = original
            let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
            switch format {
            case .bold: attributes[.font] = NSFontManager.shared.convert(font,toHaveTrait: .boldFontMask)
            case .italic: attributes[.font] = NSFontManager.shared.convert(font,toHaveTrait: .italicFontMask)
            case .strike: attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .code: attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize,weight: .regular)
            default: break
            }
            replace(in: editor,range: range,with: inner,attributes: attributes)
            editor.typingAttributes = original
            return true
        }
        if let match = match(#"(?<!\\)\[([^\]\n]+)\]\((https?://[^\s)]+|mailto:[^\s)]+)\)$"#,in: input),
           let url = URL(string: (input as NSString).substring(with: match.range(at: 2))) {
            let original = editor.typingAttributes
            var attributes = original; attributes[.link] = url
            let range = NSRange(location: line.location + match.range.location,length: match.range.length)
            replace(in: editor,range: range,with: (input as NSString).substring(with: match.range(at: 1)),attributes: attributes)
            editor.typingAttributes = original
            return true
        }
        return false
    }
    @discardableResult static func insertNewline(in editor: NSTextView) -> Bool {
        let text = editor.string as NSString; let caret = editor.selectedRange().location
        guard editor.isRichText, !editor.hasMarkedText(), editor.selectedRange().length == 0,caret <= text.length else { return false }
        let line = text.lineRange(for: NSRange(location: caret,length: 0))
        let input = text.substring(with: NSRange(location: line.location,length: caret - line.location))
        let full = text.substring(with: line).trimmingCharacters(in: .newlines)
        if isCodeBlock(editor.typingAttributes) {
            if input.trimmingCharacters(in: .whitespaces) == "```", input == full {
                replace(in: editor,range: line,with: "\n",attributes: bodyAttributes)
                editor.setSelectedRange(NSRange(location: line.location,length: 0))
            } else {
                let indentation = String(input.prefix { $0 == " " || $0 == "\t" })
                replace(in: editor,range: editor.selectedRange(),with: "\n" + indentation,attributes: codeBlockAttributes)
            }
            return true
        }
        if input == full, match(#"^```[A-Za-z0-9_+.\-]*[ \t]*$"#,in: input) != nil {
            replace(in: editor,range: line,with: "\n",attributes: codeBlockAttributes)
            editor.setSelectedRange(NSRange(location: line.location,length: 0)); return true
        }
        let marker: String
        if input.hasPrefix("• ") { marker = "• " }
        else if input.hasPrefix("│ ") { marker = "│ " }
        else if let match = match(#"^(\d{1,9})([.)]) "#,in: input) {
            let number = Int((input as NSString).substring(with: match.range(at: 1))) ?? 1
            marker = "\(number + 1)" + (input as NSString).substring(with: match.range(at: 2)) + " "
        } else {
            if let font = editor.typingAttributes[.font] as? NSFont,
               font.pointSize > 14, NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
                editor.insertText("\n",replacementRange: editor.selectedRange()); editor.typingAttributes = bodyAttributes; return true
            }
            return false
        }
        let prefixLength = input.hasPrefix("• ") || input.hasPrefix("│ ") ? 2 : (match(#"^\d{1,9}[.)] "#,in: input)?.range.length ?? 0)
        // Empty list item exits the list; splitting a nonempty item keeps its text.
        if (full as NSString).length == prefixLength {
            replace(in: editor,range: NSRange(location: line.location,length: prefixLength),with: "",attributes: bodyAttributes)
        } else { replace(in: editor,range: editor.selectedRange(),with: "\n" + marker,attributes: listAttributes()) }
        return true
    }
    private static func match(_ pattern: String,in text: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text,range: NSRange(location: 0,length: (text as NSString).length))
    }
    private static func replace(in editor: NSTextView,range: NSRange,with text: String,attributes: [NSAttributedString.Key: Any]) {
        editor.insertText(NSAttributedString(string: text,attributes: attributes),replacementRange: range)
        editor.typingAttributes = attributes
    }
}
