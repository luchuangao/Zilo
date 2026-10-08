import SwiftUI
import AppKit
import JavaScriptCore
import WebKit

/// Bundled parsers run offline in JavaScriptCore. Document HTML is disabled;
/// only the renderer's escaped markup reaches the read-only preview.
@MainActor final class MarkdownRenderer {
    static let shared = MarkdownRenderer()
    struct Result { var html: String; var codes: [String] }
    private let context = JSContext()!
    private init() {
        context.evaluateScript("var console = {log:function(){},warn:function(){},error:function(){}};")
        for name in ["highlight-all.min","markdown-it.min"] {
            #if SWIFT_PACKAGE
            let url = Bundle.module.url(forResource: name,withExtension: "js",subdirectory: "PreviewResources")
            #else
            let url = Bundle.main.url(forResource: name,withExtension: "js",subdirectory: "PreviewResources")
            #endif
            if let url, let source = try? String(contentsOf: url,encoding: .utf8) { context.evaluateScript(source) }
        }
        context.evaluateScript(Self.bridge)
    }
    var languages: [String] { context.evaluateScript("hljs.listLanguages()")?.toArray() as? [String] ?? [] }
    func render(_ source: String) -> Result {
        guard let value = context.objectForKeyedSubscript("renderZilo")?.call(withArguments: [source]),
              let result = value.toDictionary(), let html = result["html"] as? String else {
            return Result(html: "<p>" + Self.escape(source) + "</p>",codes: [])
        }
        return Result(html: html,codes: result["codes"] as? [String] ?? [])
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&",with: "&amp;").replacingOccurrences(of: "<",with: "&lt;").replacingOccurrences(of: ">",with: "&gt;").replacingOccurrences(of: "\"",with: "&quot;")
    }
    /// Read only managed image files. Resolving symlinks prevents references
    /// from walking outside the document's attachment directory.
    static func imageURL(_ url: URL,root: URL?) -> URL? {
        guard url.scheme == "zilo-image",url.host == "local",let root,
              url.path.hasPrefix("/Attachments/") else { return nil }
        let base = root.appendingPathComponent("Attachments",isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(String(url.path.dropFirst())).standardizedFileURL
        let file = candidate.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(candidate.lastPathComponent).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        return file
    }
    private static let bridge = #"""
    function renderZilo(source) {
      var md = markdownit({html:false,breaks:false,linkify:false,typographer:false});
      var codes = [], escape = md.utils.escapeHtml;
      // Common technical identifiers are literal even when legacy notes omit backticks.
      md.inline.ruler.before('emphasis','zilo_identifier',function(state,silent) {
        var match = /^__(?:name|init|main|file|all|version|doc|dict|class|repr|str)__/.exec(state.src.slice(state.pos));
        if (!match) return false;
        if (!silent) state.pending += match[0];
        state.pos += match[0].length; return true;
      });
      md.renderer.rules.fence = function(tokens, index) {
        var token = tokens[index], requested = token.info.trim().split(/\s+/)[0].toLowerCase();
        var known = requested && hljs.getLanguage(requested);
        var highlighted = null;
        if (token.content.length <= 120000) {
          try {
            if (known) highlighted = hljs.highlight(token.content,{language:requested,ignoreIllegals:true});
            else if (!requested) highlighted = hljs.highlightAuto(token.content,['bash','swift','python','javascript','typescript','json','yaml','sql','xml','css','go','rust','cpp','java','nginx']);
          } catch (_) {}
        }
        var language = requested || (highlighted && highlighted.relevance > 1 && highlighted.language) || 'text';
        var label = ({bash:'Bash',shell:'Shell',swift:'Swift',python:'Python',javascript:'JavaScript',typescript:'TypeScript',json:'JSON',yaml:'YAML',sql:'SQL',xml:'HTML / XML',cpp:'C++',csharp:'C#',go:'Go',rust:'Rust',java:'Java',nginx:'Nginx',text:'纯文本',plaintext:'纯文本'})[language] || language;
        var id = codes.push(token.content) - 1;
        return '<section class="code-card"><header><span>'+escape(label)+'</span><a aria-label="复制代码" href="zilo-copy:'+id+'">复制</a></header><pre><code class="hljs">'+(highlighted ? highlighted.value : escape(token.content))+'</code></pre></section>';
      };
      var image = md.renderer.rules.image;
      md.renderer.rules.image = function(tokens,index,options,env,self) {
        var token=tokens[index], src=token.attrGet('src') || '';
        if (/^Attachments\//.test(src)) token.attrSet('src','zilo-image://local/'+src);
        else if (!/^data:image\/(png|jpeg|gif|webp);base64,/i.test(src)) return '<span class="missing-image">[图片：'+escape(token.content || '未载入')+']</span>';
        return image(tokens,index,options,env,self);
      };
      return {html:source ? md.render(source) : '<p class="empty">预览将在这里显示</p>',codes:codes};
    }
    """#
}

struct MarkdownPreviewView: NSViewRepresentable {
    var source: String
    var baseURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator,forURLScheme: "zilo-image")
        let view = WKWebView(frame: .zero,configuration: config)
        view.navigationDelegate = context.coordinator
        view.setAccessibilityLabel("Markdown 预览正文")
        context.coordinator.update(source,root: baseURL,dark: colorScheme == .dark,in: view)
        view.loadHTMLString(Self.page,baseURL: nil)
        return view
    }
    func updateNSView(_ view: WKWebView,context: Context) {
        context.coordinator.update(source,root: baseURL,dark: colorScheme == .dark,in: view)
    }
    final class Coordinator: NSObject,WKNavigationDelegate,WKURLSchemeHandler {
        var source: String?; var root: URL?; var dark = false; var ready = false
        var rendered = MarkdownRenderer.Result(html: "",codes: [])
        func update(_ value: String,root: URL?,dark: Bool,in view: WKWebView) {
            guard value != source || root != self.root || dark != self.dark else { return }
            self.source = value; self.root = root; self.dark = dark
            rendered = MarkdownRenderer.shared.render(value)
            if ready { display(in: view) }
        }
        func display(in view: WKWebView) {
            guard let data = try? JSONSerialization.data(withJSONObject: [rendered.html,dark]),let args = String(data: data,encoding: .utf8) else { return }
            view.evaluateJavaScript("updatePreview.apply(null," + args + ")",completionHandler: nil)
        }
        func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) { ready = true; display(in: webView) }
        func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated {
                if url.scheme == "zilo-copy",let index = Int(url.absoluteString.dropFirst("zilo-copy:".count)),rendered.codes.indices.contains(index) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rendered.codes[index],forType: .string)
                } else if ["http","https","mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                else if let fragment = url.fragment,url.scheme == "about" {
                    let encoded = try? JSONSerialization.data(withJSONObject: [fragment])
                    if let encoded,let argument = String(data: encoded,encoding: .utf8) { webView.evaluateJavaScript("document.getElementById(" + argument + "[0])?.scrollIntoView()",completionHandler: nil) }
                }
                decisionHandler(.cancel)
            } else { decisionHandler(url.absoluteString == "about:blank" ? .allow : .cancel) }
        }
        func webView(_ webView: WKWebView,start task: WKURLSchemeTask) {
            guard let url = task.request.url,let file = MarkdownRenderer.imageURL(url,root: root),let data = try? Data(contentsOf: file),NSImage(data: data) != nil else {
                task.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            let mime = ["png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg","gif":"image/gif","webp":"image/webp"][file.pathExtension.lowercased()] ?? "image/png"
            task.didReceive(URLResponse(url: url,mimeType: mime,expectedContentLength: data.count,textEncodingName: nil))
            task.didReceive(data); task.didFinish()
        }
        func webView(_ webView: WKWebView,stop task: WKURLSchemeTask) {}
    }
    static let page = #"""
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src zilo-image: data:; style-src 'unsafe-inline'; script-src 'nonce-zilo-preview';"><style>
    :root{color-scheme:light;--bg:#fff;--text:#242730;--muted:#656b78;--border:#e6e8ee;--code:#f5f6f8;--accent:#526ae8;--keyword:#a626a4;--string:#267b42;--number:#986801;--function:#2557a7;--comment:#707785}
    :root[data-dark=true]{color-scheme:dark;--bg:#202126;--text:#eceef4;--muted:#b1b5c0;--border:#383a44;--code:#282a32;--accent:#a4b2ff;--keyword:#db9bdf;--string:#9acd9b;--number:#e9bf83;--function:#99bded;--comment:#9a9fae}
    *{box-sizing:border-box}html{background:var(--bg);color:var(--text);font:14px/1.65 -apple-system,BlinkMacSystemFont,'Helvetica Neue',sans-serif;-webkit-text-size-adjust:100%}body{margin:0;padding:0 1px 32px;overflow-wrap:anywhere}article{max-width:780px;margin:auto}p{margin:0 0 16px}h1,h2,h3,h4,h5,h6{line-height:1.45;letter-spacing:-.015em;font-weight:650;margin:22px 0 12px}article>:first-child{margin-top:0}h1{font-size:25px}h2{font-size:21px}h3{font-size:18px}h4{font-size:16px}h5,h6{font-size:14px}h1,h2{padding-bottom:8px;border-bottom:1px solid var(--border)}ul,ol{padding-left:25px;margin:8px 0 20px}li{padding-left:3px;margin:6px 0}li>p{margin:4px 0 8px}li>ul,li>ol{margin:4px 0 8px}blockquote{margin:18px 0;padding:2px 0 2px 16px;border-left:3px solid var(--accent);color:var(--muted)}blockquote p:last-child{margin-bottom:0}a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}code{font:12.5px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:2px 5px;border-radius:4px}pre code{background:transparent;padding:0;border-radius:0;white-space:pre;overflow-wrap:normal}.code-card{margin:18px 0 22px;border:1px solid var(--border);border-radius:9px;background:var(--code);overflow:hidden}.code-card header{display:flex;align-items:center;justify-content:space-between;padding:9px 14px;border-bottom:1px solid var(--border);font-size:11px;line-height:1.4;color:var(--muted)}.code-card header a{font-size:11px;padding:2px 4px}pre{margin:0;padding:14px 16px;overflow-x:auto;line-height:1.65;tab-size:4}img{display:block;max-width:100%;max-height:480px;object-fit:contain;margin:14px 0;border-radius:6px}table{display:block;overflow-x:auto;border-collapse:collapse;margin:18px 0;font-size:13px}th,td{padding:8px 12px;border:1px solid var(--border);min-width:80px}th{background:var(--code);font-weight:600}hr{border:0;border-top:1px solid var(--border);margin:24px 0}.empty,.missing-image{color:var(--muted)}.hljs-keyword,.hljs-selector-tag,.hljs-meta{color:var(--keyword)}.hljs-string,.hljs-regexp,.hljs-addition,.hljs-attribute{color:var(--string)}.hljs-number,.hljs-literal,.hljs-symbol,.hljs-bullet{color:var(--number)}.hljs-title,.hljs-built_in,.hljs-type,.hljs-section{color:var(--function)}.hljs-comment,.hljs-quote{color:var(--comment);font-style:italic}.hljs-deletion{color:#c54747}.hljs-emphasis{font-style:italic}.hljs-strong{font-weight:bold}
    </style></head><body><article id="document" aria-label="Markdown 预览正文"></article><script nonce="zilo-preview">function updatePreview(html,dark){var x=window.scrollX,y=window.scrollY;document.documentElement.dataset.dark=String(dark);document.getElementById('document').innerHTML=html;window.scrollTo(x,y);}</script></body></html>
    """#
}

/// Keep the native window controls inside the 64-point navigation rail.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView,context: Context) { view.scheduleLayout() }
    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            guard let window else { return }
            for name in [NSWindow.didResizeNotification,NSWindow.didExitFullScreenNotification,NSWindow.didBecomeKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name,object: window,queue: .main) { [weak self] _ in self?.scheduleLayout() })
            }
            scheduleLayout()
        }
        override func layout() { super.layout(); scheduleLayout() }
        func scheduleLayout() { DispatchQueue.main.async { [weak self] in self?.alignButtons() } }
        private func alignButtons() {
            guard let window,!window.styleMask.contains(.fullScreen) else { return }
            for (index,type) in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton].enumerated() {
                guard let button = window.standardWindowButton(type) else { continue }
                let x = 6 + CGFloat(index) * 18
                if abs(button.frame.origin.x - x) > 0.5 { button.setFrameOrigin(NSPoint(x: x,y: button.frame.origin.y)) }
            }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
