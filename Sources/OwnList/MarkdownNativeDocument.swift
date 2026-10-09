import AppKit
import Foundation

extension NSAttributedString.Key {
    /// Semantic metadata travels with edited runs and is persisted alongside RTF.
    static let ziloBlock = NSAttributedString.Key("ZiloDocumentBlock")
}

enum DocumentStyle {
    static let text = NSColor(srgbRed: 0.14,green: 0.15,blue: 0.19,alpha: 1)
    static let muted = NSColor(srgbRed: 0.40,green: 0.42,blue: 0.47,alpha: 1)
    static let accent = NSColor(srgbRed: 0.32,green: 0.42,blue: 0.91,alpha: 1)
    static let background = NSColor(srgbRed: 0.96,green: 0.965,blue: 0.975,alpha: 1)
    static let border = NSColor(srgbRed: 0.89,green: 0.90,blue: 0.93,alpha: 1)
    static var body: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.lineSpacing = 5; p.paragraphSpacing = 12
        return [.font:NSFont.systemFont(ofSize:14),.foregroundColor:text,.paragraphStyle:p]
    }
    static func metadata(_ attrs: [NSAttributedString.Key: Any]) -> [String:String] { attrs[.ziloBlock] as? [String:String] ?? [:] }
    static func codeColor(_ name: String) -> NSColor? {
        let colors: [(String,String)] = [("comment","707785"),("quote","707785"),("keyword","A626A4"),("selector-tag","A626A4"),("literal","986801"),("string","267B42"),("regexp","267B42"),("number","986801"),("type","2557A7"),("built_in","2557A7"),("title","2557A7"),("attr","986801"),("variable","986801"),("meta","A626A4"),("attribute","267B42"),("addition","267B42"),("deletion","C54747"),("section","2557A7")]
        guard let hex = colors.first(where: { name.components(separatedBy:" ").contains("hljs-" + $0.0) })?.1, let v = UInt32(hex,radix:16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 255)/255,green:CGFloat((v >> 8) & 255)/255,blue:CGFloat(v & 255)/255,alpha:1)
    }
}

/// Consumes exactly the markdown-it tokens used by the preview. No second
/// Markdown grammar: soft breaks, nesting, tables, emphasis and languages agree.
enum MarkdownNativeDocument {
    private struct ListContext { var ordered: Bool; var next: Int; var first = false }
    static func parse(_ source: String,baseURL: URL?) -> MarkdownDocument.ImportResult {
        let rendered = MarkdownRenderer.shared.render(source)
        let output = NSMutableAttributedString(string: ""); var warnings: [String] = []
        var lists: [ListContext] = []; var quote = 0; var heading = 0
        var table: NSTextTable?; var row = -1; var column = 0; var tableID = ""; var header = false; var cell: [String:Any]?
        let tokens = rendered.tokens
        func attrs(_ token: [String:Any]) -> [String:String] {
            var result: [String:String] = [:]
            for pair in token["attrs"] as? [[String]] ?? [] where pair.count == 2 { result[pair[0]] = pair[1] }
            return result
        }
        for (index,token) in tokens.enumerated() {
            let type = token["type"] as? String ?? ""
            switch type {
            case "heading_open": heading = Int((token["tag"] as? String ?? "h1").dropFirst()) ?? 1
            case "heading_close": heading = 0
            case "blockquote_open": quote += 1
            case "blockquote_close": quote -= 1
            case "bullet_list_open", "ordered_list_open": lists.append(ListContext(ordered:type == "ordered_list_open",next:Int(attrs(token)["start"] ?? "1") ?? 1))
            case "bullet_list_close", "ordered_list_close": if !lists.isEmpty { lists.removeLast() }
            case "list_item_open": if !lists.isEmpty { lists[lists.count-1].first = true }
            case "list_item_close": if !lists.isEmpty { lists[lists.count-1].next += 1 }
            case "table_open":
                table = NSTextTable(); tableID = UUID().uuidString; row = -1
                var columns = 0
                for next in tokens.dropFirst(index+1) { if next["type"] as? String == "tr_close" { break }; if next["type"] as? String == "th_open" { columns += 1 } }
                table?.numberOfColumns = max(1,columns); table?.layoutAlgorithm = .fixedLayoutAlgorithm; table?.collapsesBorders = true
                table?.setValue(100,type:.percentageValueType,for:.width)
            case "table_close": table = nil; cell = nil
            case "thead_open": header = true
            case "tbody_open": header = false
            case "tr_open": row += 1; column = 0
            case "th_open", "td_open": cell = token
            case "th_close", "td_close": column += 1; cell = nil
            case "inline":
                var a = DocumentStyle.body
                let p = (a[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                var meta: [String:String] = ["kind":"paragraph"]; var prefix = ""
                if heading > 0 {
                    a[.font] = NSFont.boldSystemFont(ofSize:[24.0,20,18,16,15,14][min(5,heading-1)])
                    p.paragraphSpacingBefore = output.length == 0 ? 0 : 18; p.paragraphSpacing = 10
                    meta = ["kind":"heading","level":String(heading)]
                }
                if quote > 0 { meta["quote"] = String(quote); p.headIndent += CGFloat(quote * 16); p.firstLineHeadIndent = p.headIndent; a[.foregroundColor] = DocumentStyle.muted }
                let children = token["children"] as? [[String:Any]] ?? []
                let checkbox = children.first(where: { $0["type"] as? String == "html_inline" && ($0["meta"] as? [String:Any])?["checked"] != nil })
                if !lists.isEmpty {
                    let level = lists.count - 1; let first = lists[lists.count-1].first
                    let mark = checkbox.map { ($0["meta"] as? [String:Any])?["checked"] as? Bool == true ? "☑ " : "☐ " }
                    prefix += first ? mark ?? (lists.last!.ordered ? "\(lists.last!.next). " : "• ") : ""
                    meta["listDepth"] = String(level); meta["listPrefix"] = first ? (mark != nil ? (mark == "☑ " ? "- [x] " : "- [ ] ") : lists.last!.ordered ? "\(lists.last!.next). " : "- ") : ""
                    meta["displayPrefix"] = prefix
                    p.firstLineHeadIndent = CGFloat(level * 24 + (quote * 16)); p.headIndent = p.firstLineHeadIndent + 24
                    p.paragraphSpacing = 6; lists[lists.count-1].first = false
                }
                if let table, let cell {
                    meta = ["kind":"table","table":tableID,"row":String(row),"column":String(column),"header":header ? "1":"0","columns":String(table.numberOfColumns)]
                    let block = NSTextTableBlock(table:table,startingRow:row,rowSpan:1,startingColumn:column,columnSpan:1)
                    block.setValue(100/CGFloat(table.numberOfColumns),type:.percentageValueType,for:.width)
                    block.setWidth(8,type:.absoluteValueType,for:.padding); block.setWidth(0.5,type:.absoluteValueType,for:.border); block.setBorderColor(DocumentStyle.border)
                    if header { block.backgroundColor = DocumentStyle.background; a[.font] = NSFont.boldSystemFont(ofSize:13) } else { a[.font] = NSFont.systemFont(ofSize:13) }
                    p.textBlocks = [block]; p.paragraphSpacing = 0; p.lineSpacing = 4
                    if attrs(cell)["style"] == "text-align:center" { p.alignment = .center; meta["align"] = "center" }
                    if attrs(cell)["style"] == "text-align:right" { p.alignment = .right; meta["align"] = "right" }
                }
                a[.paragraphStyle] = p; if !meta.isEmpty { a[.ziloBlock] = meta }
                output.append(NSAttributedString(string:prefix,attributes:a))
                output.append(inline(children,attributes:a,baseURL:baseURL,warnings:&warnings))
                output.append(NSAttributedString(string:"\n",attributes:a))
            case "fence", "code_block":
                var meta = token["meta"] as? [String:Any] ?? [:]
                if meta["kind"] as? String == "mindmap" {
                    do { output.append(try MindMapDocument.attachment(token["content"] as? String ?? "")); output.append(NSAttributedString(string:"\n",attributes:DocumentStyle.body)); continue }
                    catch { warnings.append(error.localizedDescription); meta["language"] = "mermaid"; meta["label"] = "思维导图（待修正）" }
                }
                let language = meta["language"] as? String ?? "text"; let label = meta["label"] as? String ?? "纯文本"
                let blockID = UUID().uuidString
                var labelAttrs = DocumentStyle.body; labelAttrs[.font] = NSFont.systemFont(ofSize:11,weight:.medium); labelAttrs[.foregroundColor] = DocumentStyle.muted; labelAttrs[.backgroundColor] = DocumentStyle.background
                labelAttrs[.ziloBlock] = ["kind":"codeLabel","block":blockID,"language":language,"label":label]
                output.append(NSAttributedString(string:label+"\n",attributes:labelAttrs))
                var a = MarkdownTyping.codeBlockAttributes; a[.foregroundColor] = DocumentStyle.text; a[.backgroundColor] = DocumentStyle.background
                a[.ziloBlock] = ["kind":"code","block":blockID,"language":language]
                let code = token["content"] as? String ?? ""
                let highlighted = HighlightRuns.parse(meta["highlight"] as? String ?? MarkdownRenderer.escape(code),attributes:a)
                output.append(highlighted); if !code.hasSuffix("\n") { output.append(NSAttributedString(string:"\n",attributes:a)) }
                output.append(NSAttributedString(string:"\n",attributes:DocumentStyle.body))
            case "hr":
                var a = DocumentStyle.body; a[.foregroundColor] = DocumentStyle.border; a[.ziloBlock] = ["kind":"rule"]
                output.append(NSAttributedString(string:"────────────────────────\n",attributes:a))
            default: break
            }
        }
        // One terminator is an implementation detail; author-entered soft breaks remain.
        if source.hasSuffix("\n") == false, output.length > 0, output.string.hasSuffix("\n"), !output.string.hasSuffix("\n\n") { output.deleteCharacters(in:NSRange(location:output.length-1,length:1)) }
        return MarkdownDocument.ImportResult(content:output,warnings:warnings)
    }
    private static func inline(_ tokens: [[String:Any]],attributes: [NSAttributedString.Key:Any],baseURL: URL?,warnings: inout [String]) -> NSAttributedString {
        let result = NSMutableAttributedString(string:""); var stack = [attributes]
        for t in tokens {
            let type = t["type"] as? String ?? ""; let text = t["content"] as? String ?? ""; var a = stack.last!
            let font = a[.font] as? NSFont ?? .systemFont(ofSize:14)
            switch type {
            case "strong_open", "em_open", "s_open", "link_open":
                if type == "strong_open" { a[.font] = NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask) }
                if type == "em_open" { a[.font] = NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask) }
                if type == "s_open" { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if type == "link_open", let href = (t["attrs"] as? [[String]])?.first(where: { $0.first == "href" })?.last { a[.link] = href; a[.foregroundColor] = DocumentStyle.accent }
                stack.append(a)
            case "strong_close", "em_close", "s_close", "link_close": if stack.count > 1 { stack.removeLast() }
            case "softbreak", "hardbreak": result.append(NSAttributedString(string:"\u{2028}",attributes:a))
            case "code_inline": a[.font] = NSFont.monospacedSystemFont(ofSize:13,weight:.regular); a[.backgroundColor] = DocumentStyle.background; result.append(NSAttributedString(string:text,attributes:a))
            case "text": result.append(NSAttributedString(string:text,attributes:a))
            case "image":
                let address = (t["attrs"] as? [[String]])?.first(where: { $0.first == "src" })?.last ?? ""
                if let bytes = MarkdownDocument.imageBytes(address,baseURL:baseURL), let image = try? RichDocument.image(bytes,name:text.isEmpty ? "图片.png":text) {
                    let run = NSMutableAttributedString(attributedString:image); run.addAttributes(a,range:NSRange(location:0,length:run.length)); result.append(run)
                } else { warnings.append("图片未载入：\(address)。可通过“插入图片”补充。"); result.append(NSAttributedString(string:"[图片：\(text)]",attributes:a)) }
            default: break
            }
        }
        return result
    }
    /// XML parsing only reads escaped highlight.js spans; no HTML loader/network.
    private final class HighlightRuns: NSObject,XMLParserDelegate {
        var stack: [[NSAttributedString.Key:Any]]; let output = NSMutableAttributedString(string:"")
        init(_ attrs: [NSAttributedString.Key:Any]) { stack = [attrs] }
        static func parse(_ html: String,attributes: [NSAttributedString.Key:Any]) -> NSAttributedString {
            let delegate = HighlightRuns(attributes); let parser = XMLParser(data:Data(("<root>"+html+"</root>").utf8)); parser.delegate = delegate
            guard parser.parse() else { return NSAttributedString(string:html.replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression),attributes:attributes) }
            return delegate.output
        }
        func parser(_ parser: XMLParser,didStartElement name: String,namespaceURI: String?,qualifiedName: String?,attributes attrs: [String:String]) {
            var a = stack.last!; if (attrs["class"] ?? "").contains("hljs-comment") { a[.font] = NSFontManager.shared.convert(a[.font] as! NSFont,toHaveTrait:.italicFontMask) }; if let color = DocumentStyle.codeColor(attrs["class"] ?? "") { a[.foregroundColor] = color }; stack.append(a)
        }
        func parser(_ parser: XMLParser,didEndElement: String,namespaceURI: String?,qualifiedName: String?) { if stack.count > 1 { stack.removeLast() } }
        func parser(_ parser: XMLParser,foundCharacters text: String) { output.append(NSAttributedString(string:text,attributes:stack.last!)) }
    }

    static func export(_ content: NSAttributedString,assets: String,inlineImages: Bool) -> MarkdownDocument.ExportResult {
        let source = content.string as NSString; var location = 0; var result = ""; var images: [(String,Data)] = []
        let ticks = max(3,(content.string.components(separatedBy:"\n").map { $0.prefix { $0 == "`" }.count }.max() ?? 0)+1)
        let fence = String(repeating:"`",count:ticks); var codeID: String?; var lastTable: String?; var tableRow: String?; var columns = 0
        func image(_ attachment: NSTextAttachment) -> String {
            guard let data = RichDocument.imageData(attachment) else { return "" }
            if inlineImages { return "![图片](data:image/png;base64,\(data.base64EncodedString()))" }
            let name = "image-\(images.count+1).png"; images.append((name,data)); return "![图片](<\(assets)/\(name)>)"
        }
        func inline(_ paragraph: NSAttributedString,skip: Int = 0,heading: Bool = false) -> String {
            var output = ""
            if paragraph.length <= skip { return output }
            paragraph.enumerateAttributes(in:NSRange(location:skip,length:paragraph.length-skip)) { a,range,_ in
                if let attachment = a[.attachment] as? NSTextAttachment { output += image(attachment); return }
                var text = (paragraph.string as NSString).substring(with:range).replacingOccurrences(of:"\n",with:"")
                let f = a[.font] as? NSFont ?? .systemFont(ofSize:14); let traits = NSFontManager.shared.traits(of:f)
                // Keep line breaks outside inline delimiters and table pipes escaped.
                let parts = text.components(separatedBy:"\u{2028}").map { part -> String in
                    guard !part.isEmpty else { return "" }; var value = part
                    if traits.contains(.fixedPitchFontMask) { let n = String(repeating:"`",count:max(1,part.components(separatedBy:"`").count)); value = n+" "+part+" "+n }
                    else {
                        value = value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"*",with:"\\*").replacingOccurrences(of:"_",with:"\\_").replacingOccurrences(of:"[",with:"\\[").replacingOccurrences(of:"|",with:"\\|")
                        if !heading && traits.contains(.boldFontMask) { value = "**"+value+"**" }
                        if traits.contains(.italicFontMask) { value = "*"+value+"*" }
                        if (a[.strikethroughStyle] as? Int ?? 0) != 0 { value = "~~"+value+"~~" }
                    }
                    if let link = a[.link] { value = "["+value+"]("+String(describing:link)+")" }; return value
                }
                text = parts.joined(separator:"\n"); output += text
            }
            return output
        }
        while location < source.length {
            let range = source.paragraphRange(for:NSRange(location:location,length:0)); let a = content.attributes(at:location,effectiveRange:nil); let meta = DocumentStyle.metadata(a)
            let paragraph = content.attributedSubstring(from:range); let code = meta["kind"] == "code" || MarkdownTyping.isCodeBlock(a)
            if meta["kind"] == "mindmap",let map = meta["source"] {
                if codeID != nil { result += fence+"\n"; codeID = nil }
                result += "\n```mermaid\n"+map+"\n```\n\n"; location = NSMaxRange(range); continue
            }
            if meta["kind"] == "codeLabel",paragraph.string.trimmingCharacters(in:.newlines) == meta["label"] { location = NSMaxRange(range); continue }
            if code {
                let id = meta["block"] ?? "legacy"
                if codeID != id { if codeID != nil { result += fence+"\n\n" }; result += fence+(meta["language"] ?? "")+"\n"; codeID = id }
                result += paragraph.string; if !paragraph.string.hasSuffix("\n") { result += "\n" }; location = NSMaxRange(range); continue
            }
            if codeID != nil { result += fence+"\n"; codeID = nil }
            if meta["kind"] == "table" {
                let id = meta["table"] ?? ""; let row = meta["row"] ?? "0"; let column = Int(meta["column"] ?? "0") ?? 0
                if id != lastTable { result += "\n"; lastTable = id; tableRow = nil; columns = Int(meta["columns"] ?? "1") ?? 1 }
                if tableRow != row {
                    if tableRow != nil { result += " |\n"; if tableRow == "0" { result += "|"+String(repeating:" --- |",count:columns)+"\n" } }
                    result += "|"; tableRow = row
                }
                result += " "+inline(paragraph,heading:meta["header"] == "1").replacingOccurrences(of:"\n",with:" ")+((column == columns-1) ? "":" |")
                location = NSMaxRange(range); continue
            }
            if lastTable != nil { result += " |\n"; if tableRow == "0" { result += "|"+String(repeating:" --- |",count:columns)+"\n" }; result += "\n"; lastTable = nil; tableRow = nil }
            let font = a[.font] as? NSFont ?? .systemFont(ofSize:14)
            let heading = meta["level"].flatMap(Int.init) ?? (NSFontManager.shared.traits(of:font).contains(.boldFontMask) && font.pointSize >= 15 ? (([CGFloat(24),20,18,16,15,14].firstIndex(where: { font.pointSize >= $0 }) ?? 5)+1):0)
            if meta["kind"] == "rule" { result += "\n---\n\n"; location = NSMaxRange(range); continue }
            var prefix = heading > 0 ? String(repeating:"#",count:heading)+" " : ""
            let quote = Int(meta["quote"] ?? "0") ?? 0; if quote > 0 { prefix = String(repeating:"> ",count:quote)+prefix }
            let display = meta["displayPrefix"] ?? ""
            if let depth = meta["listDepth"].flatMap(Int.init) {
                var listPrefix = meta["listPrefix"] ?? ""
                if paragraph.string.hasPrefix("☐ ") { listPrefix = "- [ ] " }; if paragraph.string.hasPrefix("☑ ") { listPrefix = "- [x] " }
                prefix += String(repeating:" ",count:depth*2)+listPrefix
            }
            var line = inline(paragraph,skip:paragraph.string.hasPrefix("☐ ") || paragraph.string.hasPrefix("☑ ") ? 2 : paragraph.string.hasPrefix(display) ? display.utf16.count:0,heading:heading > 0)
            if meta.isEmpty {
                if line.hasPrefix("• ") { line = "- "+line.dropFirst(2) }
                if line.hasPrefix("│ ") { line = "> "+line.dropFirst(2) }
                if line.hasPrefix("☐ ") { line = "- [ ] "+line.dropFirst(2) }; if line.hasPrefix("☑ ") { line = "- [x] "+line.dropFirst(2) }
            }
            // Continuation lines are indented to remain in the same list item.
            if let depth = meta["listDepth"].flatMap(Int.init) { line = line.replacingOccurrences(of:"\n",with:"\n"+String(repeating:" ",count:depth*2+2)) }
            result += prefix+line+"\n"
            if meta["listDepth"] == nil && !line.isEmpty { result += "\n" }
            location = NSMaxRange(range)
        }
        if codeID != nil { result += fence+"\n" }
        if lastTable != nil { result += " |\n"; if tableRow == "0" { result += "|"+String(repeating:" --- |",count:columns)+"\n" } }
        return MarkdownDocument.ExportResult(text:result,images:images)
    }
}
