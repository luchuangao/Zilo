import AppKit
import UniformTypeIdentifiers

enum RichDocument {
    private static let signature = Data("ZILORICH1\n".utf8)
    private struct SemanticRun: Codable { var location: Int; var length: Int; var block: [String:String] }
    private struct Envelope: Codable { var rtf: Data; var runs: [SemanticRun] }
    static func decode(_ data: Data) -> NSAttributedString? {
        // Legacy RTF/RTFD remain readable. The envelope keeps language/table/list
        // metadata that RTF itself cannot represent, without changing attachments.
        guard data.starts(with: signature) else { return try? NSAttributedString(data:data,options:[:],documentAttributes:nil) }
        guard let envelope = try? JSONDecoder().decode(Envelope.self,from:data.dropFirst(signature.count)),
              let text = try? NSMutableAttributedString(data:envelope.rtf,options:[:],documentAttributes:nil) else { return nil }
        for run in envelope.runs where run.location >= 0 && run.length > 0 && run.location <= text.length && run.length <= text.length-run.location {
            text.addAttribute(.ziloBlock,value:run.block,range:NSRange(location:run.location,length:run.length))
        }
        return text
    }
    static func encode(_ text: NSAttributedString) -> Data? {
        let type: NSAttributedString.DocumentType = hasImages(text) ? .rtfd : .rtf
        guard let rtf = try? text.data(from:NSRange(location:0,length:text.length),documentAttributes:[.documentType:type]) else { return nil }
        var runs: [SemanticRun] = []
        text.enumerateAttribute(.ziloBlock,in:NSRange(location:0,length:text.length)) { value,range,_ in
            if let block = value as? [String:String] { runs.append(SemanticRun(location:range.location,length:range.length,block:block)) }
        }
        guard !runs.isEmpty else { return rtf }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(Envelope(rtf:rtf,runs:runs)) else { return nil }
        return signature + json
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
        MarkdownNativeDocument.parse(source,baseURL: baseURL)
    }
    /// Replace actual image destinations only, preserving source syntax and code examples.
    static func rewriteImages(_ source: String,_ transform: (String) throws -> String) rethrows -> String {
        let regex = try! NSRegularExpression(pattern: #"(?<!\\)(?:(`+).*?\1|!\[[^\]]*\]\((<[^>]+>|[^)]+)\))"#)
        var fence: String?; var result = ""
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let current = fence {
                if trimmed.hasPrefix(current), trimmed.dropFirst(current.count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                result += line + "\n"; continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix { $0 == trimmed.first }); result += line + "\n"; continue }
            let ns = line as NSString; var rewritten = line
            for match in regex.matches(in: line,range: NSRange(location: 0,length: ns.length)).reversed() {
                let range = match.range(at: 2); guard range.location != NSNotFound else { continue }
                let original = ns.substring(with: range)
                let address = original.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                let changed = try transform(address)
                if changed != address {
                    rewritten = (rewritten as NSString).replacingCharacters(in: range,with: changed.contains(" ") ? "<" + changed + ">" : changed)
                }
            }
            result += rewritten + "\n"
        }
        result.removeLast(); return result
    }
    static func imageBytes(_ address: String,baseURL: URL?) -> Data? {
        let decoded = address.removingPercentEncoding ?? address
        if decoded.hasPrefix("data:image/"), let comma = decoded.firstIndex(of: ",") {
            return Data(base64Encoded: String(decoded[decoded.index(after: comma)...]))
        }
        guard !decoded.contains("://") || decoded.hasPrefix("file:") else { return nil }
        let url = decoded.hasPrefix("file:") ? URL(string: decoded) : decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : baseURL?.appendingPathComponent(decoded)
        return url.flatMap { try? Data(contentsOf: $0) }
    }
    struct ExportResult { let text: String; let images: [(String, Data)] }
    static func export(_ content: NSAttributedString, assets: String, inlineImages: Bool = false) -> ExportResult {
        MarkdownNativeDocument.export(content,assets: assets,inlineImages: inlineImages)
    }
}

/// Switching modes converts the document once; ordinary Markdown edits keep
/// the exact source, including whitespace, fences and incomplete syntax.
enum TaskDocument {
    static func summary(_ task: TaskItem) -> String {
        let text = task.notes.replacingOccurrences(of: "\u{fffc}",with: "")
            .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]+\)"#,with: "[图片]",options: .regularExpression)
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func switchMode(_ task: inout TaskItem, to mode: DocumentEditingMode,baseURL: URL? = nil) {
        guard task.editingMode != mode else { return }
        if mode == .markdown {
            if let content = task.richText.flatMap(RichDocument.decode) {
                task.notes = MarkdownDocument.export(content,assets: "",inlineImages: true).text
            }
            task.richText = nil
        } else {
            let content = MarkdownDocument.parse(task.notes,baseURL: baseURL).content
            task.notes = content.string
            task.richText = RichDocument.encode(content)
        }
        task.documentMode = mode
    }
}

enum DocumentExport {
    enum Format: String { case word = "docx", pdf = "pdf", markdown = "md" }
    static func content(task: TaskItem, children: [TaskItem],baseURL: URL? = nil) -> NSAttributedString {
        var title = DocumentStyle.body; title[.font] = NSFont.boldSystemFont(ofSize:24)
        title[.ziloBlock] = ["kind":"heading","level":"1","title":"1"]
        let output = NSMutableAttributedString(string:task.title+"\n",attributes:title)
        if let rich = task.richText.flatMap(RichDocument.decode) { output.append(rich) }
        else if task.editingMode == .markdown { output.append(MarkdownDocument.parse(task.notes,baseURL:baseURL).content) }
        else { output.append(NSAttributedString(string:task.notes,attributes:DocumentStyle.body)) }
        for item in task.checks { output.append(NSAttributedString(string: "\n\(item.done ? "☑" : "☐") \(item.title)", attributes: MarkdownTyping.bodyAttributes)) }
        if !children.isEmpty { output.append(NSAttributedString(string: "\n\n子任务\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])) }
        for child in children { output.append(NSAttributedString(string: "\(child.completed ? "☑" : "☐") \(child.title)\n", attributes: MarkdownTyping.bodyAttributes)) }
        return output
    }
    static func write(task: TaskItem, children: [TaskItem], format: Format, to url: URL,baseURL: URL? = nil) throws {
        let content = content(task: task, children: children,baseURL: baseURL)
        switch format {
        case .word: try WordDocument.data(content).write(to: url, options: .atomic)
        case .markdown:
            if task.editingMode == .markdown {
                var source = "# " + task.title + "\n\n" + task.notes
                for item in task.checks { source += "\n- [\(item.done ? "x" : " ")] \(item.title)" }
                if !children.isEmpty { source += "\n\n## 子任务\n" }
                for child in children { source += "- [\(child.completed ? "x" : " ")] \(child.title)\n" }
                let assets = url.deletingPathExtension().lastPathComponent + ".assets-" + UUID().uuidString.prefix(8)
                var images: [(String,Data)] = []
                source = MarkdownDocument.rewriteImages(source) { address in
                    guard let bytes = MarkdownDocument.imageBytes(address,baseURL: baseURL) else { return address }
                    let name = "image-\(images.count + 1).png"
                    guard let image = try? RichDocument.image(bytes), let attachment = image.attribute(.attachment,at: 0,effectiveRange: nil) as? NSTextAttachment, let png = RichDocument.imageData(attachment) else { return address }
                    images.append((name,png)); return String(assets) + "/" + name
                }
                if !images.isEmpty {
                    let folder = url.deletingLastPathComponent().appendingPathComponent(String(assets))
                    try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                    for (name,bytes) in images { try bytes.write(to: folder.appendingPathComponent(name),options: .atomic) }
                }
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
            let view = TaskPrintDocument.makeView(task: task, children: children,baseURL: baseURL)
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
        func color(_ value: Any?,fallback: String = "242730") -> String {
            guard let c = (value as? NSColor)?.usingColorSpace(.sRGB) else { return fallback }
            return String(format:"%02X%02X%02X",Int((c.redComponent*255).rounded()),Int((c.greenComponent*255).rounded()),Int((c.blueComponent*255).rounded()))
        }
        func paragraph(_ range: NSRange,inTable: Bool = false) -> String {
            let attrs = content.attributes(at:range.location,effectiveRange:nil); let meta = DocumentStyle.metadata(attrs)
            let code = MarkdownTyping.isCodeBlock(attrs) || meta["kind"] == "code"
            let font = attrs[.font] as? NSFont ?? .systemFont(ofSize:14)
            let heading = !inTable && (meta["kind"] == "heading" || NSFontManager.shared.traits(of:font).contains(.boldFontMask) && font.pointSize >= 15)
            let style = range.location == 0 ? "Title" : heading ? "Heading\(meta["level"] ?? "2")" : "Normal"
            let p = attrs[.paragraphStyle] as? NSParagraphStyle ?? .default
            let hasImage = RichDocument.hasImages(content.attributedSubstring(from:range))
            let line = hasImage ? "w:line=\"320\" w:lineRule=\"auto\"" : "w:line=\"\(Int(ceil(NSLayoutManager().defaultLineHeight(for:font)+p.lineSpacing)*20))\" w:lineRule=\"exact\""
            var value = "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/><w:spacing w:before=\"\(Int(p.paragraphSpacingBefore*20))\" w:after=\"\(Int(p.paragraphSpacing*20))\" \(line)/>"
            if heading || meta["kind"] == "codeLabel" { value += "<w:keepNext/>" }
            let first = Int(p.firstLineHeadIndent*20), left = Int(p.headIndent*20)
            if !inTable && (left != 0 || first != 0) { value += "<w:ind w:left=\"\(left)\"" + (first < left ? " w:hanging=\"\(left-first)\"" : " w:firstLine=\"\(first-left)\"") + "/>" }
            if p.alignment == .center { value += "<w:jc w:val=\"center\"/>" }; if p.alignment == .right { value += "<w:jc w:val=\"right\"/>" }
            if code || meta["kind"] == "codeLabel" { value += "<w:shd w:val=\"clear\" w:fill=\"F5F6F8\"/>" }
            if meta["quote"] != nil { value += "<w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:color=\"526AE8\" w:space=\"10\"/></w:pBdr>" }
            if heading && range.location > 0 { value += "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"E6E8EE\" w:space=\"6\"/></w:pBdr>" }
            value += "</w:pPr>"
            content.enumerateAttributes(in:range) { attrs,run,_ in
                if let attachment = attrs[.attachment] as? NSTextAttachment, let data = RichDocument.imageData(attachment), let image = NSImage(data:data) {
                    imageID += 1; let name = "image\(imageID).png"; let id = "image\(imageID)"
                    entries.append(("word/media/"+name,data))
                    relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"
                    let scale = min(1,523/max(1,image.size.width),700/max(1,image.size.height)); let cx = Int(image.size.width*scale*12700), cy = Int(image.size.height*scale*12700)
                    value += "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"\(imageID)\" name=\"图片\(imageID)\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(imageID)\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"; return
                }
                let f = attrs[.font] as? NSFont ?? .systemFont(ofSize:14); let traits = NSFontManager.shared.traits(of:f)
                let family = traits.contains(.fixedPitchFontMask) ? "Menlo" : "Arial"
                var properties = "<w:sz w:val=\"\(Int(f.pointSize*2))\"/><w:color w:val=\"\(color(attrs[.foregroundColor]))\"/>"
                if traits.contains(.boldFontMask) { properties += "<w:b/>" }; if traits.contains(.italicFontMask) { properties += "<w:i/>" }
                if (attrs[.underlineStyle] as? Int ?? 0) != 0 { properties += "<w:u w:val=\"single\"/>" }; if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { properties += "<w:strike/>" }
                if !code, let fill = attrs[.backgroundColor] as? NSColor { properties += "<w:shd w:val=\"clear\" w:fill=\"\(color(fill,fallback:"F5F6F8"))\"/>" }
                var text = source.substring(with:run)
                // Only remove the paragraph terminator, keeping all soft breaks.
                if NSMaxRange(run) == NSMaxRange(range), text.hasSuffix("\n") { text.removeLast() }
                var chunks: [(String,Bool)] = []
                for character in text { let emoji = character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }; if chunks.last?.1 == emoji { chunks[chunks.count-1].0.append(character) } else { chunks.append((String(character),emoji)) } }
                var runXML = ""
                for (chunk,emoji) in chunks {
                    let face = emoji ? "Apple Color Emoji" : family
                    var nodes = ""
                    for (i,line) in chunk.components(separatedBy:"\u{2028}").enumerated() {
                        if i > 0 { nodes += "<w:br/>" }
                        nodes += line.components(separatedBy:"\t").map { "<w:t xml:space=\"preserve\">\(xml($0))</w:t>" }.joined(separator:"<w:tab/>")
                    }
                    runXML += "<w:r><w:rPr><w:rFonts w:ascii=\"\(face)\" w:hAnsi=\"\(face)\" w:eastAsia=\"\(emoji ? face : "PingFang SC")\"/>\(properties)</w:rPr>\(nodes)</w:r>"
                }
                if let url = attrs[.link] {
                    linkID += 1; let id = "link\(linkID)"; relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xml(String(describing:url)))\" TargetMode=\"External\"/>"; value += "<w:hyperlink r:id=\"\(id)\">\(runXML)</w:hyperlink>"
                } else { value += runXML }
            }
            return value+"</w:p>"
        }
        while location < source.length {
            let range = source.paragraphRange(for:NSRange(location:location,length:0)); let meta = DocumentStyle.metadata(content.attributes(at:location,effectiveRange:nil))
            if meta["kind"] != "table" { body += paragraph(range); location = NSMaxRange(range); continue }
            let id = meta["table"] ?? ""; let columns = max(1,Int(meta["columns"] ?? "1") ?? 1); let width = 10466/columns
            body += "<w:tbl><w:tblPr><w:tblW w:w=\"10466\" w:type=\"dxa\"/><w:tblLayout w:type=\"fixed\"/><w:tblBorders>" + ["top","left","bottom","right","insideH","insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"E6E8EE\"/>" }.joined() + "</w:tblBorders><w:tblCellMar>" + ["top","left","bottom","right"].map { "<w:\($0) w:w=\"160\" w:type=\"dxa\"/>" }.joined() + "</w:tblCellMar></w:tblPr><w:tblGrid>" + String(repeating:"<w:gridCol w:w=\"\(width)\"/>",count:columns) + "</w:tblGrid>"
            var row: String?
            while location < source.length {
                let r = source.paragraphRange(for:NSRange(location:location,length:0)); let m = DocumentStyle.metadata(content.attributes(at:location,effectiveRange:nil))
                guard m["kind"] == "table",m["table"] == id else { break }
                if m["row"] != row { if row != nil { body += "</w:tr>" }; body += "<w:tr>"; if m["header"] == "1" { body += "<w:trPr><w:tblHeader/></w:trPr>" }; row = m["row"] }
                body += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>" + (m["header"] == "1" ? "<w:shd w:fill=\"F5F6F8\"/>":"") + "</w:tcPr>" + paragraph(r,inTable:true) + "</w:tc>"
                location = NSMaxRange(r)
            }
            if row != nil { body += "</w:tr>" }; body += "</w:tbl><w:p/>"
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
