import AppKit
import SwiftUI

/// A local, deterministic renderer for the indentation-based Mermaid mindmap
/// subset. No remote renderer or document text leaves the Mac.
enum MindMapDocument {
    struct Node { var title: String; var parent: Int?; var depth: Int; var rect = NSRect.zero; var color = 0 }
    struct Diagram { var nodes: [Node]; var size: NSSize; var source: String }
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
        func height(_ i: Int) -> CGFloat {
            let bounds = (nodes[i].title as NSString).boundingRect(with:NSSize(width:170,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:14,weight:i == 0 ? .semibold:.regular)])
            return max(42,ceil(bounds.height)+24)
        }
        var sizes = [CGFloat](repeating:0,count:nodes.count)
        func measure(_ i: Int) -> CGFloat {
            let children = nodes.indices.filter { nodes[$0].parent == i }
            sizes[i] = max(height(i),children.map(measure).reduce(0,+)+CGFloat(max(0,children.count-1))*18); return sizes[i]
        }
        let h = measure(0)
        func place(_ i: Int,_ top: CGFloat) {
            nodes[i].rect = NSRect(x:24+CGFloat(nodes[i].depth)*238,y:top+(sizes[i]-height(i))/2+24,width:202,height:height(i))
            let children = nodes.indices.filter { nodes[$0].parent == i }; var y = top
            for child in children { place(child,y); y += sizes[child]+18 }
        }
        place(0,0)
        return Diagram(nodes:nodes,size:NSSize(width:(nodes.map { $0.rect.maxX }.max() ?? 226)+24,height:h+48),source:"mindmap\n"+original.map { "  "+$0 }.joined(separator:"\n"))
    }
    private static func hexColor(_ hex: String) -> NSColor {
        let v = UInt32(hex,radix:16) ?? 0; return NSColor(srgbRed:CGFloat((v>>16)&255)/255,green:CGFloat((v>>8)&255)/255,blue:CGFloat(v&255)/255,alpha:1)
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
            html += "<foreignObject x=\"\(n(r.minX+16))\" y=\"\(n(r.minY+10))\" width=\"170\" height=\"\(n(r.height-20))\"><div xmlns=\"http://www.w3.org/1999/xhtml\" style=\"font: \(i == 0 ? "600":"400") 14px -apple-system,sans-serif;line-height:1.4;color:\(i == 0 ? "white":"#242730");overflow-wrap:anywhere;white-space:pre-wrap\">\(MarkdownRenderer.escape(node.title))</div></foreignObject>"
        }
        return html+"</svg>"
    }
    static func png(_ diagram: Diagram) -> Data? {
        let scale = min(2,3600/max(diagram.size.width,diagram.size.height)); let w = Int(ceil(diagram.size.width*scale)),h = Int(ceil(diagram.size.height*scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context = NSGraphicsContext(bitmapImageRep:rep) else { return nil }
        rep.size = diagram.size; NSGraphicsContext.saveGraphicsState()
        context.cgContext.translateBy(x:0,y:CGFloat(h)); context.cgContext.scaleBy(x:scale,y:-scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context.cgContext,flipped:true)
        NSColor.white.setFill(); NSRect(origin:.zero,size:diagram.size).fill()
        for node in diagram.nodes { if let parent = node.parent {
            let p = diagram.nodes[parent].rect,r = node.rect,mid = (p.maxX+r.minX)/2
            let path = NSBezierPath(); path.move(to:NSPoint(x:p.maxX,y:p.midY)); path.curve(to:NSPoint(x:r.minX,y:r.midY),controlPoint1:NSPoint(x:mid,y:p.midY),controlPoint2:NSPoint(x:mid,y:r.midY)); path.lineWidth = 2; hexColor(palette[node.color]).setStroke(); path.stroke()
        } }
        for (i,node) in diagram.nodes.enumerated() {
            let path = NSBezierPath(roundedRect:node.rect,xRadius:10,yRadius:10); (i == 0 ? DocumentStyle.accent:DocumentStyle.background).setFill(); path.fill(); hexColor(palette[node.color]).setStroke(); path.lineWidth = 1; path.stroke()
            // AppKit text draws upright in a flipped graphics context.
            let p = NSMutableParagraphStyle(); p.lineSpacing = 2
            (node.title as NSString).draw(with:NSRect(x:node.rect.minX+16,y:node.rect.minY+10,width:170,height:node.rect.height-20),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:14,weight:i == 0 ? .semibold:.regular),.foregroundColor:i == 0 ? NSColor.white:DocumentStyle.text,.paragraphStyle:p])
        }
        NSGraphicsContext.restoreGraphicsState(); return rep.representation(using:.png,properties:[:])
    }
    static func attachment(_ source: String) throws -> NSAttributedString {
        let diagram = try parse(source); guard let bytes = png(diagram) else { throw RichDocument.TransferError.failedExport }
        let output = NSMutableAttributedString(attributedString:try RichDocument.image(bytes,name:"思维导图.png"))
        output.addAttributes([.ziloBlock:["kind":"mindmap","source":diagram.source],.paragraphStyle:DocumentStyle.body[.paragraphStyle]!],range:NSRange(location:0,length:output.length))
        return output
    }
}

struct MindMapEditor: View {
    @Binding var outline: String
    var replacing: Bool
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private var error: String? { do { _ = try MindMapDocument.parse(outline); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(replacing ? "编辑思维导图":"插入思维导图").font(.title2.bold())
            Text("每行一个主题，缩进表示子主题。Tab 增加层级，Shift + Tab 减少层级。").foregroundStyle(.secondary)
            HSplitView {
                MindMapOutlineEditor(text:$outline).frame(minWidth:230)
                MarkdownPreviewView(source:"```mermaid\n"+(outline.trimmingCharacters(in:.whitespacesAndNewlines).components(separatedBy:"\n").first == "mindmap" ? outline:"mindmap\n"+outline)+"\n```",baseURL:nil).frame(minWidth:350)
            }.frame(height:420)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack { Text("离线生成 · 支持多级主题 · 随文档导出").font(.caption).foregroundStyle(.secondary); Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button(replacing ? "保存":"插入") { onSave(outline); dismiss() }.keyboardShortcut(.defaultAction).disabled(error != nil) }
        }.padding(24).frame(width:800)
    }
}
private struct MindMapOutlineEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let editor = DocumentTextView(); editor.isRichText = false; editor.font = .monospacedSystemFont(ofSize:14,weight:.regular); editor.allowsUndo = true; editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true; editor.textContainerInset = NSSize(width:12,height:12); editor.string = text; editor.delegate = context.coordinator; scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView,context: Context) {
        context.coordinator.parent = self
        if let editor = view.documentView as? NSTextView,!editor.hasMarkedText(),editor.string != text { editor.string = text }
    }
    final class Coordinator: NSObject,NSTextViewDelegate {
        var parent: MindMapOutlineEditor; init(_ parent: MindMapOutlineEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView,!editor.hasMarkedText() { parent.text = editor.string } }
        func textView(_ textView: NSTextView,doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let selection = textView.selectedRange(); let source = textView.string as NSString
                let line = source.lineRange(for:NSRange(location:min(selection.location,source.length),length:0))
                let prefix = source.substring(with:NSRange(location:line.location,length:max(0,selection.location-line.location))).prefix { $0 == " " || $0 == "\t" }
                textView.insertText("\n"+prefix,replacementRange:selection); return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) { MarkdownSourceEditing.indent(in:textView,outdent:false); return true }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) { MarkdownSourceEditing.indent(in:textView,outdent:true); return true }
            return false
        }
    }
}
