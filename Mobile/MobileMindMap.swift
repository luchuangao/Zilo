import UIKit
import SwiftUI
import CoreText

/// A local, deterministic renderer for the indentation-based Mermaid mindmap
/// subset. No remote renderer or document text leaves the Mac.
enum MindMapDocument {
    struct Node { var title: String; var parent: Int?; var depth: Int; var rect = CGRect.zero; var color = 0; var lines: [String] = [] }
    struct Diagram { var nodes: [Node]; var size: CGSize; var source: String }
    enum ParseError: LocalizedError {
        case empty, roots, tooLarge, unsupported
        var errorDescription: String? { switch self {
        case .empty: return "请输入中心主题。"
        case .roots: return "思维导图只能有一个中心主题，请缩进其余主题。"
        case .tooLarge: return "单张思维导图最多支持 100 个主题、12 层，请拆分后插入。"
        case .unsupported: return "暂不支持 Mermaid 的图标、样式指令和其他图表类型，请使用主题与缩进。"
        } }
    }
    static let example = "项目计划\n  目标\n    核心成果\n    验收标准\n  执行\n    时间安排\n    任务分工\n  复盘\n    经验总结"
    static let palette = ["526AE8","248C75","D48A26","A15FC0","D56979","397DAF"]
    static func parse(_ source: String) throws -> Diagram {
        var nodes: [Node] = []; var stack: [(Int,Int)] = []; var original: [String] = []; var first = true
        for raw in source.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n") {
            let expanded = raw.replacingOccurrences(of:"\t",with:"    "); let text = expanded.trimmingCharacters(in:.whitespaces)
            if text.isEmpty || text.hasPrefix("%%") { continue }
            if first && text == "mindmap" { first = false; continue }; first = false
            if text.hasPrefix(":::") || text.hasPrefix("::icon") || text.hasPrefix("---") { throw ParseError.unsupported }
            let indent = expanded.prefix { $0 == " " }.count
            while let last = stack.last,indent <= last.0 { stack.removeLast() }
            if !nodes.isEmpty && stack.isEmpty { throw ParseError.roots }
            var title = text
            // Accept the standard root((label)), id[label], id(label), id{label}
            // forms while keeping labels escaped in the generated SVG.
            let pattern = #"^(?:[\p{L}\p{N}_-]+)?(?:\(\((.*)\)\)|\[(.*)\]|\((.*)\)|\{(.*)\})$"#
            if let re = try? NSRegularExpression(pattern:pattern),let m = re.firstMatch(in:text,range:NSRange(location:0,length:text.utf16.count)) {
                for n in 1...4 where m.range(at:n).location != NSNotFound { title = (text as NSString).substring(with:m.range(at:n)) }
            }
            title = title.replacingOccurrences(of:"<br/>",with:"\n").replacingOccurrences(of:"<br>",with:"\n")
            guard !title.isEmpty else { throw ParseError.empty }
            if nodes.count >= 100 || stack.count >= 12 || title.count > 1000 { throw ParseError.tooLarge }
            let parent = stack.last?.1; let branch = parent == 0 ? nodes.count % palette.count : parent.map { nodes[$0].color } ?? 0
            nodes.append(Node(title:title,parent:parent,depth:stack.count,color:branch)); stack.append((indent,nodes.count-1)); original.append(String(repeating:"  ",count:stack.count-1)+text)
        }
        guard !nodes.isEmpty else { throw ParseError.empty }
        for index in nodes.indices { nodes[index].lines = wrappedLines(nodes[index].title,root: index == 0) }
        func height(_ i: Int) -> CGFloat { max(42,CGFloat(nodes[i].lines.count) * 20 + 24) }
        var sizes = [CGFloat](repeating:0,count:nodes.count)
        func measure(_ i: Int) -> CGFloat {
            let children = nodes.indices.filter { nodes[$0].parent == i }
            sizes[i] = max(height(i),children.map(measure).reduce(0,+)+CGFloat(max(0,children.count-1))*18); return sizes[i]
        }
        let h = measure(0)
        func place(_ i: Int,_ top: CGFloat) {
            nodes[i].rect = CGRect(x:24+CGFloat(nodes[i].depth)*238,y:top+(sizes[i]-height(i))/2+24,width:202,height:height(i))
            let children = nodes.indices.filter { nodes[$0].parent == i }; var y = top
            for child in children { place(child,y); y += sizes[child]+18 }
        }
        place(0,0)
        return Diagram(nodes:nodes,size:CGSize(width:(nodes.map { $0.rect.maxX }.max() ?? 226)+24,height:h+48),source:"mindmap\n"+original.map { "  "+$0 }.joined(separator:"\n"))
    }
    static func wrappedLines(_ title: String,root: Bool = false) -> [String] {
        let font = UIFont.systemFont(ofSize: 14,weight: root ? .semibold : .regular)
        var lines: [String] = []
        for paragraph in title.components(separatedBy: "\n") {
            guard !paragraph.isEmpty else { lines.append(""); continue }
            let text = paragraph as NSString
            let attributed = NSAttributedString(string: paragraph,attributes: [.font:font])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var offset = 0
            while offset < text.length {
                var count = CTTypesetterSuggestLineBreak(typesetter,offset,166)
                if count == 0 { count = CTTypesetterSuggestClusterBreak(typesetter,offset,166) }
                count = max(1,min(count,text.length-offset))
                lines.append(text.substring(with: NSRange(location: offset,length: count)))
                offset += count
            }
        }
        return lines
    }
    static func svg(_ diagram: Diagram) -> String {
        func n(_ x: CGFloat) -> String { String(format:"%.1f",Double(x)) }
        var html = "<svg xmlns=\"http://www.w3.org/2000/svg\" role=\"img\" aria-label=\"思维导图\" viewBox=\"0 0 \(n(diagram.size.width)) \(n(diagram.size.height))\"><rect width=\"100%\" height=\"100%\" fill=\"#FFFFFF\"/>"
        for node in diagram.nodes { if let parent = node.parent { let p = diagram.nodes[parent].rect; let r = node.rect; let mid = (p.maxX+r.minX)/2
            html += "<path d=\"M \(n(p.maxX)) \(n(p.midY)) C \(n(mid)) \(n(p.midY)), \(n(mid)) \(n(r.midY)), \(n(r.minX)) \(n(r.midY))\" fill=\"none\" stroke=\"#\(palette[node.color])\" stroke-width=\"2\"/>"
        } }
        for (i,node) in diagram.nodes.enumerated() {
            let r = node.rect; let color = palette[node.color]
            html += "<rect x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" rx=\"10\" fill=\"\(i == 0 ? "#526AE8":"#F5F6FA")\" stroke=\"#\(color)\"/>"
            html += "<g aria-label=\"\(MarkdownRenderer.escape(node.title))\"><title>\(MarkdownRenderer.escape(node.title))</title>"
            for (lineIndex,line) in node.lines.enumerated() {
                html += "<text x=\"\(n(r.minX+16))\" y=\"\(n(r.minY+12+CGFloat(lineIndex)*20+14))\" xml:space=\"preserve\" style=\"font: \(i == 0 ? "600":"400") 14px -apple-system,sans-serif;fill:\(i == 0 ? "white":"#242730")\">\(MarkdownRenderer.escape(line))</text>"
            }
            html += "</g>"
        }
        return html+"</svg>"
    }
}
