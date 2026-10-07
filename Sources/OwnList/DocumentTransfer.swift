import AppKit
import UniformTypeIdentifiers

enum RichDocument {
    static func decode(_ data: Data) -> NSAttributedString? {
        // Autodetect preserves both old RTF documents and flattened RTFD images.
        try? NSAttributedString(data: data, options: [:], documentAttributes: nil)
    }
    static func encode(_ text: NSAttributedString) -> Data? {
        let type: NSAttributedString.DocumentType = hasImages(text) ? .rtfd : .rtf
        return try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
    }
    static func hasImages(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value is NSTextAttachment { found = true; stop.pointee = true }
        }
        return found
    }
    static func imageData(_ attachment: NSTextAttachment) -> Data? {
        let image = attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)) ?? (attachment.attachmentCell as? NSCell)?.image
        guard let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    static func image(_ data: Data, name: String = "图片.png") throws -> NSAttributedString {
        guard let original = NSImage(data: data), original.size.width > 0, original.size.height > 0,
              let tiff = original.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw TransferError.invalidImage(name) }
        let attachment = NSTextAttachment()
        attachment.fileWrapper = FileWrapper(regularFileWithContents: png)
        attachment.fileWrapper?.preferredFilename = (name as NSString).deletingPathExtension + ".png"
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: original)
        return NSAttributedString(attachment: attachment)
    }
    @discardableResult static func fitImages(_ text: NSAttributedString, width: CGFloat, maxHeight: CGFloat = 700) -> Bool {
        var changed = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment,
                  let data = attachment.fileWrapper?.regularFileContents, let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0 else { return }
            let scale = min(1, max(40, width) / image.size.width, maxHeight / image.size.height)
            let size = NSSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
            if attachment.attachmentCell?.cellSize() != size {
                image.size = size; attachment.attachmentCell = NSTextAttachmentCell(imageCell: image); changed = true
            }
        }
        return changed
    }
    enum TransferError: LocalizedError {
        case invalidImage(String), failedExport, unsupportedFile(String)
        var errorDescription: String? {
            switch self {
            case .invalidImage(let name): return "无法读取图片：\(name)"
            case .failedExport: return "文档导出失败，请选择可写入的位置后重试。"
            case .unsupportedFile(let name): return "无法读取 Markdown 文件：\(name)"
            }
        }
    }
}

enum MarkdownDocument {
    struct ImportResult { let content: NSAttributedString; let warnings: [String] }
    static func read(_ url: URL, authorizeImages: Bool = false) throws -> ImportResult {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var encoding = String.Encoding.utf8
        guard let source = try? String(contentsOf: url, usedEncoding: &encoding) else { throw RichDocument.TransferError.unsupportedFile(url.lastPathComponent) }
        let result = parse(source, baseURL: url.deletingLastPathComponent())
        if authorizeImages, result.warnings.contains(where: { $0.hasPrefix("图片未载入") }),
           let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\((?!https?://|data:)[^)]+\)"#),
           regex.firstMatch(in: source,range: NSRange(location: 0,length: source.utf16.count)) != nil {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.directoryURL = url.deletingLastPathComponent(); panel.prompt = "载入图片"
            panel.message = "此 Markdown 文档引用了本地图片。请选择文档所在的文件夹，以便读取其中的图片。"
            if panel.runModal() == .OK, let folder = panel.url {
                let scopedFolder = folder.startAccessingSecurityScopedResource(); defer { if scopedFolder { folder.stopAccessingSecurityScopedResource() } }
                return parse(source,baseURL: folder)
            }
        }
        return result
    }
    static func parse(_ source: String, baseURL: URL? = nil) -> ImportResult {
        let result = NSMutableAttributedString(string: ""); var warnings: [String] = []
        var fence: String?
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                if trimmed.hasPrefix(current), trimmed.dropFirst(current.count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil; continue }
                result.append(NSAttributedString(string: line + "\n", attributes: MarkdownTyping.codeBlockAttributes)); continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix { $0 == trimmed.first }); continue }
            var attributes = MarkdownTyping.bodyAttributes; var body = line
            if let match = match(#"^(#{1,6})[ \t]+(.*)$"#, line) {
                let level = (line as NSString).substring(with: match.range(at: 1)).count
                attributes[.font] = NSFont.boldSystemFont(ofSize: [24.0,20,18,17,16,15][level - 1])
                body = (line as NSString).substring(with: match.range(at: 2))
            } else if let match = match(#"^\s*[-*+][ \t]+(.*)$"#, line) {
                attributes = MarkdownTyping.listAttributes(); body = "• " + (line as NSString).substring(with: match.range(at: 1))
            } else if match(#"^\s*\d+[.)][ \t]+"#, line) != nil { attributes = MarkdownTyping.listAttributes() }
            else if let match = match(#"^>[ \t]?(.*)$"#, line) {
                attributes = MarkdownTyping.listAttributes(); body = "│ " + (line as NSString).substring(with: match.range(at: 1))
            }
            let paragraph = inline(body, attributes: attributes, baseURL: baseURL, warnings: &warnings)
            result.append(paragraph)
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
        }
        if fence != nil { warnings.append("代码围栏未闭合，已保留其中的代码。") }
        return ImportResult(content: result, warnings: warnings)
    }
    private static func inline(_ text: String, attributes: [NSAttributedString.Key: Any], baseURL: URL?, warnings: inout [String]) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let pattern = #"(?<!\\)(?:!\[([^\]]*)\]\((<[^>]+>|[^)]+)\)|\[([^\]]+)\]\(([^)]+)\)|(`+)(.+?)\5|\*\*(.+?)\*\*|__(.+?)__|~~(.+?)~~|\*([^*]+)\*|_([^_]+)_)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString; var offset = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output.append(NSAttributedString(string: unescape(source.substring(with: NSRange(location: offset, length: match.range.location - offset))), attributes: attributes))
            func value(_ group: Int) -> String? { let r = match.range(at: group); return r.location == NSNotFound ? nil : source.substring(with: r) }
            var run = attributes
            if let path = value(2) {
                let address = path.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                let decoded = address.removingPercentEncoding ?? address
                let url: URL? = decoded.hasPrefix("file:") ? URL(string: decoded) : decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : baseURL?.appendingPathComponent(decoded)
                if let url, !decoded.contains("://") || url.isFileURL, let data = try? Data(contentsOf: url), let image = try? RichDocument.image(data, name: url.lastPathComponent) { output.append(image) }
                else if decoded.hasPrefix("data:image/"), let comma = decoded.firstIndex(of: ","), let data = Data(base64Encoded: String(decoded[decoded.index(after: comma)...])), let image = try? RichDocument.image(data) { output.append(image) }
                else { output.append(NSAttributedString(string: "[图片：\(value(1) ?? address)]", attributes: attributes)); warnings.append("图片未载入：\(address)。可通过“插入图片”补充。") }
            } else if let title = value(3), let address = value(4), let url = URL(string: address) {
                run[.link] = url; output.append(inline(title, attributes: run, baseURL: baseURL, warnings: &warnings))
            } else if let code = value(6) {
                run[.font] = NSFont.monospacedSystemFont(ofSize: (run[.font] as? NSFont)?.pointSize ?? 14, weight: .regular)
                output.append(NSAttributedString(string: code, attributes: run))
            } else {
                let font = run[.font] as? NSFont ?? .systemFont(ofSize: 14)
                let content = value(7) ?? value(8) ?? value(9) ?? value(10) ?? value(11) ?? ""
                if value(7) != nil || value(8) != nil { run[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                else if value(9) != nil { run[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                else { run[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                output.append(inline(content, attributes: run, baseURL: baseURL, warnings: &warnings))
            }
            offset = NSMaxRange(match.range)
        }
        output.append(NSAttributedString(string: unescape(source.substring(from: offset)), attributes: attributes))
        return output
    }
    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: #"\\([\\`*_{}\[\]()#+.!>~-])"#, with: "$1", options: .regularExpression)
    }
    private static func match(_ pattern: String, _ text: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count))
    }
    struct ExportResult { let text: String; let images: [(String, Data)] }
    static func export(_ content: NSAttributedString, assets: String, inlineImages: Bool = false) -> ExportResult {
        let maxTicks = content.string.components(separatedBy: "\n").map { $0.prefix { $0 == "`" }.count }.max() ?? 0
        let codeFence = String(repeating: "`", count: max(3, maxTicks + 1))
        let source = content.string as NSString; var result = ""; var images: [(String, Data)] = []; var location = 0; var inCode = false
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let paragraph = content.attributedSubstring(from: range)
            let isCode = MarkdownTyping.isCodeBlock(content.attributes(at: location, effectiveRange: nil))
            if isCode != inCode { result += codeFence + "\n"; inCode = isCode }
            if isCode { result += paragraph.string; location = NSMaxRange(range); continue }
            let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let heading = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) && $0.pointSize >= 15 } ?? false
            if heading && !paragraph.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { let sizes: [CGFloat] = [24,20,18,17,16,15]; let level = sizes.firstIndex(where: { (font?.pointSize ?? 0) >= $0 }) ?? 5; result += String(repeating: "#", count: level + 1) + " " }
            var line = ""
            paragraph.enumerateAttributes(in: NSRange(location: 0, length: paragraph.length)) { attrs, run, _ in
                if let attachment = attrs[.attachment] as? NSTextAttachment, let data = RichDocument.imageData(attachment) {
                    if inlineImages { line += "![图片](data:image/png;base64,\(data.base64EncodedString()))" }
                    else { let name = "image-\(images.count + 1).png"; images.append((name, data)); line += "![图片](<\(assets)/\(name)>)" }
                    return
                }
                var text = (paragraph.string as NSString).substring(with: run)
                let newline = text.hasSuffix("\n"); if newline { text.removeLast() }
                if !text.isEmpty {
                    let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 14); let traits = NSFontManager.shared.traits(of: font)
                    if traits.contains(.fixedPitchFontMask) { let ticks = String(repeating: "`", count: max(1, (text.components(separatedBy: "`").count))); text = ticks + " " + text + " " + ticks }
                    else {
                        text = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "[", with: "\\[")
                        if !heading && traits.contains(.boldFontMask) { text = "**" + text + "**" }
                        if traits.contains(.italicFontMask) { text = "*" + text + "*" }
                        if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { text = "~~" + text + "~~" }
                        if (attrs[.underlineStyle] as? Int ?? 0) != 0 { text = "<u>" + text + "</u>" }
                    }
                    if let url = attrs[.link] { text = "[\(text)](\(url))" }
                }
                line += text + (newline ? "\n" : "")
            }
            if line.hasPrefix("• ") { line = "- " + line.dropFirst(2) }
            if line.hasPrefix("│ ") { line = "> " + line.dropFirst(2) }
            result += line; location = NSMaxRange(range)
        }
        if inCode { if !result.hasSuffix("\n") { result += "\n" }; result += codeFence + "\n" }
        return ExportResult(text: result, images: images)
    }
}

/// Switching modes converts the document once; ordinary Markdown edits keep
/// the exact source, including whitespace, fences and incomplete syntax.
enum TaskDocument {
    static func switchMode(_ task: inout TaskItem, to mode: DocumentEditingMode) {
        guard task.editingMode != mode else { return }
        if mode == .markdown {
            if let content = task.richText.flatMap(RichDocument.decode) {
                task.notes = MarkdownDocument.export(content,assets: "",inlineImages: true).text
            }
            task.richText = nil
        } else {
            let content = MarkdownDocument.parse(task.notes).content
            task.notes = content.string
            task.richText = RichDocument.encode(content)
        }
        task.documentMode = mode
    }
}

enum DocumentExport {
    enum Format: String { case word = "docx", pdf = "pdf", markdown = "md" }
    static func content(task: TaskItem, children: [TaskItem]) -> NSAttributedString {
        let output = NSMutableAttributedString(string: task.title + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.black])
        output.append(task.richText.flatMap(RichDocument.decode) ?? MarkdownDocument.parse(task.notes).content)
        for item in task.checks { output.append(NSAttributedString(string: "\n\(item.done ? "☑" : "☐") \(item.title)", attributes: MarkdownTyping.bodyAttributes)) }
        if !children.isEmpty { output.append(NSAttributedString(string: "\n\n子任务\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])) }
        for child in children { output.append(NSAttributedString(string: "\(child.completed ? "☑" : "☐") \(child.title)\n", attributes: MarkdownTyping.bodyAttributes)) }
        return output
    }
    static func write(task: TaskItem, children: [TaskItem], format: Format, to url: URL) throws {
        let content = content(task: task, children: children)
        switch format {
        case .word: try WordDocument.data(content).write(to: url, options: .atomic)
        case .markdown:
            if task.editingMode == .markdown {
                var source = "# " + task.title + "\n\n" + task.notes
                for item in task.checks { source += "\n- [\(item.done ? "x" : " ")] \(item.title)" }
                if !children.isEmpty { source += "\n\n## 子任务\n" }
                for child in children { source += "- [\(child.completed ? "x" : " ")] \(child.title)\n" }
                try source.write(to: url,atomically: true,encoding: .utf8)
                return
            }
            // Unique asset directory avoids overwriting images from a previous export.
            let assets = url.deletingPathExtension().lastPathComponent + ".assets-" + UUID().uuidString.prefix(8)
            let exported = MarkdownDocument.export(content, assets: assets)
            if !exported.images.isEmpty {
                let directory = url.deletingLastPathComponent().appendingPathComponent(assets, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (name, data) in exported.images { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
            }
            try exported.text.write(to: url, atomically: true, encoding: .utf8)
        case .pdf:
            let view = TaskPrintDocument.makeView(task: task, children: children)
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.paperSize = NSSize(width: 595.28, height: 841.89)
            info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
            info.horizontalPagination = .fit; info.verticalPagination = .automatic; info.isHorizontallyCentered = false; info.isVerticallyCentered = false
            info.jobDisposition = .save; info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let operation = NSPrintOperation(view: view, printInfo: info); operation.showsPrintPanel = false; operation.showsProgressPanel = false
            guard operation.run(), FileManager.default.fileExists(atPath: url.path) else { throw RichDocument.TransferError.failedExport }
        }
    }
}

/// A self-contained OOXML exporter; AppKit's DOCX writer drops image attachments.
enum WordDocument {
    static func data(_ content: NSAttributedString) -> Data {
        var entries: [(String, Data)] = []; var relationships = ""; var body = ""; var imageID = 0; var linkID = 0
        let source = content.string as NSString; var location = 0
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let attrs = content.attributes(at: location, effectiveRange: nil)
            let code = MarkdownTyping.isCodeBlock(attrs)
            let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 14)
            let heading = NSFontManager.shared.traits(of: font).contains(.boldFontMask) && font.pointSize >= 15
            let style = location == 0 ? "Title" : heading ? "Heading\(([CGFloat(24),20,18,17,16,15].firstIndex(where: { font.pointSize >= $0 }) ?? 5) + 1)" : "Normal"
            body += "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/><w:spacing w:after=\"120\"/>"
            if code { body += "<w:shd w:val=\"clear\" w:fill=\"F3F4F6\"/><w:ind w:left=\"180\"/>" }
            body += "</w:pPr>"
            content.enumerateAttributes(in: range) { attrs, run, _ in
                if let attachment = attrs[.attachment] as? NSTextAttachment, let data = RichDocument.imageData(attachment), let image = NSImage(data: data) {
                    imageID += 1; let name = "image\(imageID).png"; let id = "image\(imageID)"
                    entries.append(("word/media/" + name, data))
                    relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"
                    let scale = min(1, 523 / max(1, image.size.width), 700 / max(1, image.size.height))
                    let cx = Int(image.size.width * scale * 12700), cy = Int(image.size.height * scale * 12700)
                    body += "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"\(imageID)\" name=\"图片\(imageID)\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(imageID)\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"; return
                }
                let f = attrs[.font] as? NSFont ?? .systemFont(ofSize: 14); let traits = NSFontManager.shared.traits(of: f)
                let family = traits.contains(.fixedPitchFontMask) ? "Menlo" : "Arial"
                var properties = "<w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\" w:eastAsia=\"PingFang SC\"/><w:sz w:val=\"\(Int(f.pointSize * 2))\"/><w:color w:val=\"222222\"/>"
                if traits.contains(.boldFontMask) { properties += "<w:b/>" }; if traits.contains(.italicFontMask) { properties += "<w:i/>" }
                if (attrs[.underlineStyle] as? Int ?? 0) != 0 { properties += "<w:u w:val=\"single\"/>" }
                if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { properties += "<w:strike/>" }
                let text = source.substring(with: run).trimmingCharacters(in: .newlines)
                let runXML = "<w:r><w:rPr>\(properties)</w:rPr>" + text.components(separatedBy: "\t").map { "<w:t xml:space=\"preserve\">\(xml($0))</w:t>" }.joined(separator: "<w:tab/>") + "</w:r>"
                if let url = attrs[.link] {
                    linkID += 1; let id = "link\(linkID)"; relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xml(String(describing: url)))\" TargetMode=\"External\"/>"
                    body += "<w:hyperlink r:id=\"\(id)\">\(runXML)</w:hyperlink>"
                } else { body += runXML }
            }
            body += "</w:p>"; location = NSMaxRange(range)
        }
        body += "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"720\" w:right=\"720\" w:bottom=\"720\" w:left=\"720\"/></w:sectPr>"
        func add(_ path: String, _ xml: String) { entries.append((path, Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + xml).utf8))) }
        add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>")
        add("_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"document\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>")
        add("word/_rels/document.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)<Relationship Id=\"styles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>")
        add("word/document.xml", "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>\(body)</w:body></w:document>")
        let styles = (["Normal", "Title"] + (1...6).map { "Heading\($0)" }).map { "<w:style w:type=\"paragraph\" w:styleId=\"\($0)\"><w:name w:val=\"\($0)\"/>" + ($0 == "Normal" ? "" : "<w:basedOn w:val=\"Normal\"/>") + "</w:style>" }.joined()
        add("word/styles.xml", "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(styles)</w:styles>")
        return StoredZIP.data(entries)
    }
    private static func xml(_ string: String) -> String {
        String(string.unicodeScalars.filter { $0.value >= 32 || [9,10,13].contains($0.value) }).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private enum StoredZIP {
    static func data(_ entries: [(String, Data)]) -> Data {
        var output = Data(); var central = Data()
        func number<T: FixedWidthInteger>(_ value: T, into data: inout Data) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        for (name, bytes) in entries {
            let filename = Data(name.utf8), offset = UInt32(output.count), size = UInt32(bytes.count), checksum = crc(bytes)
            number(UInt32(0x04034b50), into: &output); for n in [UInt16(20),0x800,0,0,0] { number(n, into: &output) }
            for n in [checksum,size,size] { number(n, into: &output) }; number(UInt16(filename.count), into: &output); number(UInt16(0), into: &output); output.append(filename); output.append(bytes)
            number(UInt32(0x02014b50), into: &central); for n in [UInt16(20),20,0x800,0,0,0] { number(n, into: &central) }
            for n in [checksum,size,size] { number(n, into: &central) }; for n in [UInt16(filename.count),0,0,0,0] { number(n, into: &central) }; number(UInt32(0), into: &central); number(offset, into: &central); central.append(filename)
        }
        let offset = UInt32(output.count); output.append(central); number(UInt32(0x06054b50), into: &output)
        for n in [UInt16(0),0,UInt16(entries.count),UInt16(entries.count)] { number(n, into: &output) }; number(UInt32(central.count), into: &output); number(offset, into: &output); number(UInt16(0), into: &output)
        return output
    }
    private static func crc(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xedb88320) } }
        return crc ^ 0xffffffff
    }
}
