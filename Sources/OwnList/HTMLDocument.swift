import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A portable, script-free document. Managed images are embedded so sharing
/// one HTML file never depends on Zilo's sandbox or an accompanying folder.
enum HTMLDocument {
    static func filename(_ title: String) -> String {
        let value = title.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return (value.isEmpty ? ZiloLanguage.text("文档") : String(value.prefix(80))) + ".html"
    }
    static func data(task: TaskItem,children: [TaskItem] = [],baseURL: URL? = nil) throws -> Data {
        var body: String
        if task.editingMode == .markdown {
            body = MarkdownRenderer.shared.render(task.notes,forExport: true).html
        } else {
            #if os(macOS)
            if let rich = task.richText.flatMap(RichDocument.decode) {
                body = MarkdownRenderer.shared.render(MarkdownDocument.export(rich,assets: "",inlineImages: true).text,forExport: true).html
            } else { body = "<p>" + escape(task.notes).replacingOccurrences(of: "\n",with: "<br>") + "</p>" }
            #else
            body = task.richText.flatMap(decodeRich).map(richHTML) ?? "<p>" + escape(task.notes).replacingOccurrences(of: "\n",with: "<br>") + "</p>"
            #endif
        }
        body = try embedImages(body,root: baseURL)
        if !task.checks.isEmpty {
            body += "<section><h2>" + escape(ZiloLanguage.text("检查项")) + "</h2><ul class=\"checks\">"
            for item in task.checks { body += check(item.title,done: item.done) }
            body += "</ul></section>"
        }
        if !children.isEmpty {
            body += "<section><h2>" + escape(ZiloLanguage.text("子任务")) + "</h2><ul class=\"checks\">"
            for child in children where !child.deleted { body += check(child.title,done: child.completed) }
            body += "</ul></section>"
        }
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ZiloLanguage.text("文档") : task.title
        let html = """
        <!doctype html>
        <html lang="\(escape(ZiloLanguage.locale.identifier))"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>\(escape(title))</title><style>\(css)</style></head>
        <body><main><h1 class="document-title">\(escape(title))</h1><article>\(body)</article></main></body></html>
        """
        return Data(html.utf8)
    }
    static func temporaryFile(task: TaskItem,children: [TaskItem] = [],baseURL: URL?) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Zilo-HTML-" + UUID().uuidString,isDirectory: true)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(filename(task.title))
        try data(task: task,children: children,baseURL: baseURL).write(to: url,options: .atomic)
        return url
    }
    private static func check(_ title: String,done: Bool) -> String {
        "<li><input type=\"checkbox\" disabled" + (done ? " checked" : "") + "><span>" + escape(title) + "</span></li>"
    }
    static func escape(_ value: String) -> String { MarkdownRenderer.escape(value) }
    private static func embedImages(_ html: String,root: URL?) throws -> String {
        let pattern = try NSRegularExpression(pattern: #"src="(zilo-image:[^"]+)""#)
        var result = html
        for match in pattern.matches(in: html,range: NSRange(html.startIndex...,in: html)).reversed() {
            let address = (html as NSString).substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;",with: "&")
            guard let url = URL(string: address),let file = MarkdownRenderer.imageURL(url,root: root),let data = try? Data(contentsOf: file),let uri = imageURI(data) else {
                throw CocoaError(.fileReadNoSuchFile,userInfo: [NSLocalizedDescriptionKey: ZiloLanguage.text("正文图片尚未下载，无法导出完整 HTML。请同步后重试。")])
            }
            result = (result as NSString).replacingCharacters(in: match.range(at: 1),with: uri)
        }
        return result
    }
    private static func imageURI(_ bytes: Data) -> String? {
        let mime: String
        if bytes.starts(with: [137,80,78,71,13,10,26,10]) { mime = "image/png" }
        else if bytes.starts(with: [255,216,255]) { mime = "image/jpeg" }
        else if bytes.starts(with: Data("GIF8".utf8)) { mime = "image/gif" }
        else if bytes.starts(with: Data("RIFF".utf8)) && bytes.count >= 12 && bytes[8..<12] == Data("WEBP".utf8) { mime = "image/webp" }
        else { return nil }
        return "data:" + mime + ";base64," + bytes.base64EncodedString()
    }
    #if os(iOS)
    private struct RichEnvelope: Decodable {
        struct Run: Decodable { var location: Int; var length: Int; var block: [String:String] }
        var rtf: Data; var runs: [Run]
    }
    static func decodeRich(_ data: Data) -> NSAttributedString? {
        let signature = Data("ZILORICH1\n".utf8)
        var bytes = data; var runs: [RichEnvelope.Run] = []
        if data.starts(with: signature) {
            guard let envelope = try? JSONDecoder().decode(RichEnvelope.self,from: data.dropFirst(signature.count)) else { return nil }
            bytes = envelope.rtf; runs = envelope.runs
        }
        guard let content = try? NSMutableAttributedString(data: bytes,options: [:],documentAttributes: nil) else { return nil }
        for run in runs where run.location >= 0 && run.length > 0 && run.location <= content.length && run.length <= content.length - run.location {
            content.addAttribute(NSAttributedString.Key("ZiloDocumentBlock"),value: run.block,range: NSRange(location: run.location,length: run.length))
        }
        return content
    }
    private static func richHTML(_ content: NSAttributedString) -> String {
        let source = content.string as NSString
        var result = ""; var location = 0; var table: String?; var row: String?
        func closeTable() { if table != nil { result += "</tr></tbody></table>"; table = nil; row = nil } }
        while location < content.length {
            let range = source.paragraphRange(for: NSRange(location: location,length: 0))
            let meta = content.attribute(NSAttributedString.Key("ZiloDocumentBlock"),at: location,effectiveRange: nil) as? [String:String] ?? [:]
            let isTable = meta["kind"] == "table"
            if !isTable || table != meta["table"] { closeTable() }
            var line = ""
            content.enumerateAttributes(in: range) { attrs,run,_ in
                if let attachment = attrs[.attachment] as? NSTextAttachment {
                    if let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(UIImage.init(data:)),let png = image.pngData(),let uri = imageURI(png) { line += "<img alt=\"" + escape(ZiloLanguage.text("图片")) + "\" src=\"" + uri + "\">" }
                    return
                }
                var text = source.substring(with: run)
                if NSMaxRange(run) == NSMaxRange(range),text.hasSuffix("\n") { text.removeLast() }
                var html = escape(text).replacingOccurrences(of: "\u{2028}",with: "<br>")
                if let font = attrs[.font] as? UIFont {
                    if font.fontDescriptor.symbolicTraits.contains(.traitBold) { html = "<strong>" + html + "</strong>" }
                    if font.fontDescriptor.symbolicTraits.contains(.traitItalic) { html = "<em>" + html + "</em>" }
                }
                if (attrs[.underlineStyle] as? Int ?? 0) != 0 { html = "<u>" + html + "</u>" }
                if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { html = "<s>" + html + "</s>" }
                if let link = attrs[.link],let url = URL(string: String(describing: link)),["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") { html = "<a href=\"" + escape(url.absoluteString) + "\">" + html + "</a>" }
                line += html
            }
            if isTable {
                if table == nil { table = meta["table"] ?? ""; result += "<table><tbody>" }
                if row != meta["row"] { if row != nil { result += "</tr>" }; result += "<tr>"; row = meta["row"] }
                let tag = meta["header"] == "1" ? "th" : "td"; result += "<" + tag + ">" + line + "</" + tag + ">"
            } else if meta["kind"] == "code" { result += "<pre><code>" + line + "</code></pre>" }
            else if let level = Int(meta["level"] ?? ""),(1...6).contains(level) { result += "<h\(level)>" + line + "</h\(level)>" }
            else { result += "<p class=\"rich-line\">" + (line.isEmpty ? "<br>" : line) + "</p>" }
            location = NSMaxRange(range)
        }
        closeTable(); return result
    }
    #endif
    private static let css = """
    :root{color-scheme:light}*{box-sizing:border-box}body{margin:0;background:#fff;color:#242730;font:16px/1.7 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;overflow-wrap:anywhere}main{max-width:960px;margin:auto;padding:48px 32px 72px}.document-title{font-size:30px;line-height:1.3;margin:0 0 32px;padding-bottom:20px;border-bottom:1px solid #e6e8ee}h1,h2,h3,h4,h5,h6{line-height:1.4;margin:1.4em 0 .6em}h2{font-size:23px}h3{font-size:19px}p{margin:.65em 0}a{color:#3e60d4}img,svg{max-width:100%;height:auto}blockquote{margin:20px 0;padding:2px 20px;border-left:3px solid #c8d0e4;color:#606878}table{width:100%;border-collapse:collapse;margin:20px 0}td,th{padding:10px 14px;border:1px solid #dde1e8;text-align:left}th{background:#f5f6f8}pre{overflow:auto;white-space:pre;font:14px/1.65 ui-monospace,Menlo,monospace;padding:16px;margin:0}code{font-family:ui-monospace,Menlo,monospace}p code,li code{background:#f1f3f6;border-radius:4px;padding:2px 5px}.code-card{margin:22px 0;background:#f5f6f8;border:1px solid #e6e8ee;border-radius:10px;overflow:hidden}.code-card header{padding:9px 16px;border-bottom:1px solid #e6e8ee;font-size:12px;color:#687081}.hljs-keyword,.hljs-selector-tag,.hljs-literal{color:#a626a4}.hljs-string,.hljs-regexp{color:#267b42}.hljs-number,.hljs-attr{color:#a15d17}.hljs-comment{color:#818791}.hljs-title,.hljs-function{color:#315bc4}.checks{list-style:none;padding:0}.checks li{display:flex;align-items:baseline;gap:10px;margin:8px 0}li:has(>.task-checkbox){list-style:none}.task-checkbox{width:15px;height:15px;margin:0 8px 0 0;vertical-align:-2px}.task-checkbox,input[type=checkbox]{accent-color:#526ae8}.missing-image{color:#687081}.mindmap{overflow:auto;margin:22px 0}.rich-line{white-space:pre-wrap}@media(max-width:600px){main{padding:28px 20px}.document-title{font-size:26px}}@media print{main{max-width:none;padding:0}.code-card,table,img{break-inside:avoid}a{color:inherit}}
    """
}
