import SwiftUI
#if os(macOS)
import AppKit
#endif
import JavaScriptCore
import WebKit

/// Bundled parsers run offline in JavaScriptCore. Document HTML is disabled;
/// only the renderer's escaped markup reaches the read-only preview.
final class MarkdownRenderer {
    static let shared = MarkdownRenderer()
    struct Result { var html: String; var codes: [String]; var tokens: [[String: Any]] = [] }
    private let lock = NSRecursiveLock()
    private let context = JSContext()!
    // Small bounded LRU: switching between recent tasks reuses parsed/highlighted
    // markup; large documents and export rendering do not occupy this cache.
    private var previewCache: [(source: String,result: Result)] = []
    private var cacheBytes = 0
    private let cacheBudget = 2_000_000
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
        let mindmap: @convention(block) (String) -> String = { source in
            do { return MindMapDocument.svg(try MindMapDocument.parse(source)) }
            catch { return "<p class=\"missing-image\">"+Self.escape(error.localizedDescription)+"</p>" }
        }
        context.setObject(mindmap,forKeyedSubscript:"ziloMindmap" as NSString)
        let labels = ["plain": ZiloLanguage.text("纯文本"), "copy": ZiloLanguage.text("复制"), "preview": ZiloLanguage.text("预览将在这里显示"), "language": ZiloLanguage.text("代码语言")]
        if let data = try? JSONSerialization.data(withJSONObject: labels,options: [.sortedKeys]),let json = String(data: data,encoding: .utf8) { context.evaluateScript("var ziloUI = " + json + ";") }
        context.evaluateScript(Self.bridge)
    }
    var languages: [String] { lock.lock(); defer { lock.unlock() }; return context.evaluateScript("hljs.listLanguages()")?.toArray() as? [String] ?? [] }
    func render(_ source: String, forExport: Bool = false) -> Result {
        lock.lock(); defer { lock.unlock() }
        if !forExport,let index = previewCache.firstIndex(where: { $0.source == source }) {
            let hit = previewCache.remove(at: index); previewCache.append(hit); return hit.result
        }
        guard let value = context.objectForKeyedSubscript("renderZilo")?.call(withArguments: [source,forExport]),
              let result = value.toDictionary(), let html = result["html"] as? String else {
            return Result(html: "<p>" + Self.escape(source) + "</p>",codes: [])
        }
        let rendered = Result(html: html,codes: result["codes"] as? [String] ?? [],tokens: result["tokens"] as? [[String: Any]] ?? [])
        let bytes = source.utf8.count + html.utf8.count
        if !forExport,bytes <= cacheBudget / 2 {
            while !previewCache.isEmpty && (previewCache.count >= 8 || cacheBytes + bytes > cacheBudget) {
                let removed = previewCache.removeFirst(); cacheBytes -= removed.source.utf8.count + removed.result.html.utf8.count
            }
            previewCache.append((source,rendered)); cacheBytes += bytes
        }
        return rendered
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
    function renderZilo(source, forExport) {
      // Notes preserve the author's Enter presses, including list descriptions.
      // A trailing Tab is whitespace, not a reason to collapse the following line.
      var md = markdownit({html:false,breaks:true,linkify:false,typographer:false});
      var codes = [], escape = md.utils.escapeHtml;
      // Common technical identifiers are literal even when legacy notes omit backticks.
      md.inline.ruler.before('emphasis','zilo_identifier',function(state,silent) {
        var match = /^__(?:name|init|main|file|all|version|doc|dict|class|repr|str)__/.exec(state.src.slice(state.pos));
        if (!match) return false;
        if (!silent) state.pending += match[0];
        state.pos += match[0].length; return true;
      });
      // GFM task markers are read-only in preview; edit their source to toggle.
      md.core.ruler.after('inline','zilo_task_lists',function(state) {
        var depth=0;
        state.tokens.forEach(function(token,index) {
          if (token.type==='list_item_open') depth++;
          else if (token.type==='list_item_close') depth--;
          else if (depth && token.type==='inline' && index>1 && state.tokens[index-2].type==='list_item_open' && /^\[[ xX]\][ \t]+/.test(token.content) && token.children && token.children[0] && token.children[0].type==='text') {
            var first=token.children[0], marker=/^\[([ xX])\][ \t]+/.exec(first.content);
            if (!marker) return;
            first.content=first.content.slice(marker[0].length);
            var checkbox=new state.Token('html_inline','',0);
            checkbox.content='<input class="task-checkbox" type="checkbox" disabled aria-label="'+(marker[1]===' ' ? '未完成' : '已完成')+'"'+(marker[1]===' ' ? '' : ' checked')+'>';
            checkbox.meta={checked:marker[1]!==' '};
            token.children.unshift(checkbox);
          }
        });
      });
      md.renderer.rules.fence = function(tokens, index) {
        var token = tokens[index], requested = token.info.trim().split(/\s+/)[0].toLowerCase();
        if (requested==='mermaid' && /^\s*mindmap(?:\s|$)/.test(token.content)) {
          token.meta={kind:'mindmap',source:token.content};
          return '<section class="mindmap">'+ziloMindmap(token.content)+'</section>';
        }
        var known = requested && hljs.getLanguage(requested);
        var highlighted = null;
        if (token.content.length <= 120000) {
          try {
            if (known) highlighted = hljs.highlight(token.content,{language:requested,ignoreIllegals:true});
            else if (!requested) highlighted = hljs.highlightAuto(token.content,['bash','swift','python','javascript','typescript','json','yaml','sql','xml','css','go','rust','cpp','java','nginx']);
          } catch (_) {}
        }
        var language = requested || (highlighted && highlighted.relevance > 1 && highlighted.language) || 'text';
        var label = ({bash:'Bash',shell:'Shell',swift:'Swift',python:'Python',javascript:'JavaScript',typescript:'TypeScript',json:'JSON',yaml:'YAML',sql:'SQL',xml:'HTML / XML',html:'HTML',objectivec:'Objective-C',c:'C',kotlin:'Kotlin',ruby:'Ruby',php:'PHP',css:'CSS',cpp:'C++',csharp:'C#',go:'Go',rust:'Rust',java:'Java',nginx:'Nginx',text:ziloUI.plain,plaintext:ziloUI.plain})[language] || language;
        token.meta={language:language,label:label,highlight:highlighted ? highlighted.value : escape(token.content)};
        var id = codes.push(token.content) - 1;
        if (forExport) return '<section class="code-card"><header><span>'+escape(label)+'</span></header><pre><code class="hljs">'+(highlighted ? highlighted.value : escape(token.content))+'</code></pre></section>';
        return '<section class="code-card"><header><a class="code-language" aria-label="选择代码语言" href="zilo-language:'+id+'">'+escape(label)+' <svg class="language-chevron" viewBox="0 0 10 14" aria-hidden="true"><path d="M2 5 5 2 8 5M2 9 5 12 8 9"/></svg></a><a aria-label="复制代码" href="zilo-copy:'+id+'">'+escape(ziloUI.copy)+'</a></header><pre><code class="hljs">'+(highlighted ? highlighted.value : escape(token.content))+'</code></pre></section>';
      };
      var image = md.renderer.rules.image;
      md.renderer.rules.image = function(tokens,index,options,env,self) {
        var token=tokens[index], src=token.attrGet('src') || '';
        if (/^Attachments\//.test(src)) token.attrSet('src','zilo-image://local/'+src);
        else if (!/^data:image\/(png|jpeg|gif|webp);base64,/i.test(src)) return '<span class="missing-image">[图片：'+escape(token.content || '未载入')+']</span>';
        var html=image(tokens,index,options,env,self); token.attrSet('src',src); return html;
      };
      var tokens=md.parse(source,{});
      var html=source ? md.renderer.render(tokens,md.options,{}) : '<p class="empty">'+escape(ziloUI.preview)+'</p>';
      function plain(t) { return {type:t.type,tag:t.tag,content:t.content,map:t.map,attrs:t.attrs || [],meta:t.meta || {},hidden:t.hidden,children:t.children ? t.children.map(plain) : []}; }
      return {html:html,codes:codes,tokens:tokens.map(plain)};
    }
    """#
}

#if os(macOS)
struct MarkdownPreviewView: NSViewRepresentable {
    var source: String
    var baseURL: URL?
    var onChangeLanguage: ((String) -> Void)? = nil
    var onBeginEditing: (() -> Void)? = nil
    var paperBackground: UInt32? = nil
    var compact = false
    var transparentBackground = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("accent") private var themeID = "blue"
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator,forURLScheme: "zilo-image")
        if onBeginEditing != nil {
            config.userContentController.add(context.coordinator,name: "ziloBeginEditing")
            config.userContentController.addUserScript(WKUserScript(source: Self.editGestureScript,injectionTime: .atDocumentEnd,forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero,configuration: config)
        view.navigationDelegate = context.coordinator
        view.setAccessibilityLabel("Markdown 预览正文")
        context.coordinator.onBeginEditing = onBeginEditing
        context.coordinator.onChangeLanguage = onChangeLanguage
        context.coordinator.paperBackground = paperBackground
        context.coordinator.compact = compact
        context.coordinator.transparentBackground = transparentBackground
        context.coordinator.update(source,root: baseURL,dark: colorScheme == .dark,theme: themeID,in: view)
        view.setValue(false,forKey: "drawsBackground")
        // Avoid an opaque first frame before the initial JS render finishes.
        let page = transparentBackground ? Self.page.replacingOccurrences(of: "html{background:var(--bg)",with: "html{background:transparent") : Self.page
        view.loadHTMLString(page,baseURL: nil)
        return view
    }
    func updateNSView(_ view: WKWebView,context: Context) {
        context.coordinator.onBeginEditing = onBeginEditing
        context.coordinator.onChangeLanguage = onChangeLanguage
        context.coordinator.paperBackground = paperBackground
        context.coordinator.compact = compact
        context.coordinator.transparentBackground = transparentBackground
        context.coordinator.update(source,root: baseURL,dark: colorScheme == .dark,theme: themeID,in: view)
    }
    static func dismantleNSView(_ view: WKWebView,coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "ziloBeginEditing")
        coordinator.previewInteraction.cancel()
        coordinator.onBeginEditing = nil; view.navigationDelegate = nil
    }
    static let editGestureScript = #"""
    function ziloExternalLink(anchor) { return anchor && /^(https?:|mailto:)/i.test(anchor.href); }
    document.addEventListener('click', function(event) {
      if (!event.isTrusted || event.button !== 0 || event.detail === 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      var anchor = event.target.closest('a[href]');
      if (!ziloExternalLink(anchor)) return;
      event.preventDefault();
      if (event.detail === 1) window.webkit.messageHandlers.ziloBeginEditing.postMessage({action:'open-link',url:anchor.href});
    });
    document.addEventListener('dblclick', function(event) {
      if (!event.isTrusted || event.target.closest('button,input,select,textarea')) return;
      var anchor = event.target.closest('a[href]');
      if (anchor && !ziloExternalLink(anchor)) return;
      event.preventDefault();
      window.webkit.messageHandlers.ziloBeginEditing.postMessage({action:'begin-editing'});
    });
    """#
    final class Coordinator: NSObject,WKNavigationDelegate,WKURLSchemeHandler,WKScriptMessageHandler {
        var source: String?; var root: URL?; var dark = false; var theme = ""; var ready = false
        var onChangeLanguage: ((String) -> Void)?
        let previewInteraction = PreviewEditInteraction()
        var onBeginEditing: (() -> Void)? {
            get { previewInteraction.onBeginEditing }
            set { previewInteraction.onBeginEditing = newValue }
        }
        func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
            guard message.name == "ziloBeginEditing",message.frameInfo.isMainFrame,onBeginEditing != nil,
                  let body = message.body as? [String:String] else { return }
            if body["action"] == "begin-editing" { previewInteraction.beginEditing() }
            else if body["action"] == "open-link",let value = body["url"],let url = URL(string: value) { previewInteraction.followLink(url) }
        }
        var paperBackground: UInt32?
        var compact = false
        var transparentBackground = false
        var displayedTransparent = false
        var displayedPaper: UInt32?
        var displayedCompact = false
        var rendered = MarkdownRenderer.Result(html: "",codes: [])
        func update(_ value: String,root: URL?,dark: Bool,theme: String = "blue",in view: WKWebView) {
            guard value != source || root != self.root || dark != self.dark || theme != self.theme || paperBackground != displayedPaper || compact != displayedCompact || transparentBackground != displayedTransparent else { return }
            let contentChanged = value != source
            self.source = value; self.root = root; self.dark = dark; self.theme = theme
            displayedPaper = paperBackground; displayedCompact = compact; displayedTransparent = transparentBackground
            if contentChanged { rendered = MarkdownRenderer.shared.render(value) }
            if ready { display(in: view) }
        }
        func display(in view: WKWebView) {
            guard let data = try? JSONSerialization.data(withJSONObject: [rendered.html,dark,String(format: "#%06X",AppTheme.resolve(theme).value("accent",dark: dark))]),let args = String(data: data,encoding: .utf8) else { return }
            let paper = transparentBackground ? "transparent" : paperBackground.map { String(format: "#%06X",$0) } ?? ""
            let styling = "document.documentElement.style.background='var(--bg)';document.documentElement.style.setProperty('--bg','" + paper + "');document.body.style.paddingBottom='" + (compact ? "8px" : "32px") + "';document.documentElement.style.fontSize='" + (compact ? "13px" : "14px") + "';"
            view.setValue(false,forKey: "drawsBackground")
            view.evaluateJavaScript("updatePreview.apply(null," + args + ");" + styling,completionHandler: nil)
        }
        func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) { ready = true; display(in: webView) }
        func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated {
                if url.scheme == "zilo-copy",let index = Int(url.absoluteString.dropFirst("zilo-copy:".count)),rendered.codes.indices.contains(index) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rendered.codes[index],forType: .string)
                } else if url.scheme == "zilo-language",let index = Int(url.absoluteString.dropFirst("zilo-language:".count)),rendered.codes.indices.contains(index),onChangeLanguage != nil {
                    let current = CodeLanguage.fences(rendered)[index]["meta"] as? [String:Any]
                    decisionHandler(.cancel)
                    DispatchQueue.main.async { [weak self,weak webView] in
                        guard let self,let webView else { return }
                        CodeLanguageMenu.show(current: current?["language"] as? String ?? "",at: webView.convert(webView.window?.mouseLocationOutsideOfEventStream ?? .zero,from: nil),in: webView) { language in
                            if let source = self.source,let changed = CodeLanguage.replacing(source,index: index,language: language) { self.onChangeLanguage?(changed) }
                        }
                    }
                    return
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
    *{box-sizing:border-box}html{background:var(--bg);color:var(--text);font:14px/1.65 -apple-system,BlinkMacSystemFont,'Helvetica Neue',sans-serif;-webkit-text-size-adjust:100%}body{margin:0;padding:0 1px 32px;overflow-wrap:anywhere}article{max-width:780px;margin:auto}p{margin:0 0 16px}h1,h2,h3,h4,h5,h6{line-height:1.45;letter-spacing:-.015em;font-weight:650;margin:22px 0 12px}article>:first-child{margin-top:0}h1{font-size:24px}h2{font-size:20px}h3{font-size:18px}h4{font-size:16px}h5,h6{font-size:14px}h1,h2{padding-bottom:8px;border-bottom:1px solid var(--border)}ul,ol{padding-left:25px;margin:8px 0 20px}li{padding-left:3px;margin:6px 0}li>p{margin:4px 0 8px}li>ul,li>ol{margin:4px 0 8px}blockquote{margin:18px 0;padding:2px 0 2px 16px;border-left:3px solid var(--accent);color:var(--muted)}blockquote p:last-child{margin-bottom:0}a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}code{font:12.5px/1.65 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:2px 5px;border-radius:4px}pre code{background:transparent;padding:0;border-radius:0;white-space:pre;overflow-wrap:normal}.code-card{margin:18px 0 22px;border:1px solid var(--border);border-radius:9px;background:var(--code);overflow:hidden}.code-card header{display:flex;align-items:center;justify-content:space-between;padding:9px 14px;border-bottom:1px solid var(--border);font-size:11px;line-height:1.4;color:var(--muted)}.code-card header a{font-size:12px;padding:3px 5px;color:var(--muted);border-radius:5px}.code-card header a:hover{background:var(--border);text-decoration:none}.code-language{display:inline-flex;align-items:center;gap:6px}.language-chevron{width:8px;height:11px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}.code-card header{border-bottom:0;padding:10px 12px 2px}.code-card pre{padding-top:10px}pre{margin:0;padding:14px 16px;overflow-x:auto;line-height:1.65;tab-size:4}img{display:block;max-width:100%;max-height:480px;object-fit:contain;margin:14px 0;border-radius:6px}table{display:block;overflow-x:auto;border-collapse:collapse;margin:18px 0;font-size:13px}th,td{padding:8px 12px;border:1px solid var(--border);min-width:80px}th{background:var(--code);font-weight:600}hr{border:0;border-top:1px solid var(--border);margin:24px 0}.task-checkbox{width:14px;height:14px;margin:0 7px 0 0;vertical-align:-2px;accent-color:var(--accent)}.mindmap{margin:18px 0;overflow:auto;border:1px solid var(--border);border-radius:9px;background:white}.mindmap svg{display:block;width:100%;height:auto}.empty,.missing-image{color:var(--muted)}.hljs-keyword,.hljs-selector-tag,.hljs-meta{color:var(--keyword)}.hljs-string,.hljs-regexp,.hljs-addition,.hljs-attribute{color:var(--string)}.hljs-number,.hljs-literal,.hljs-symbol,.hljs-bullet{color:var(--number)}.hljs-title,.hljs-built_in,.hljs-type,.hljs-section{color:var(--function)}.hljs-comment,.hljs-quote{color:var(--comment);font-style:italic}.hljs-deletion{color:#c54747}.hljs-emphasis{font-style:italic}.hljs-strong{font-weight:bold}
    </style></head><body><article id="document" aria-label="Markdown 预览正文"></article><script nonce="zilo-preview">function updatePreview(html,dark,accent){var x=window.scrollX,y=window.scrollY;document.documentElement.dataset.dark=String(dark);document.documentElement.style.setProperty("--accent",accent);document.getElementById('document').innerHTML=html;window.scrollTo(x,y);}</script></body></html>
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


/// Language selection changes only the opening fence; code bytes stay literal.
enum CodeLanguage {
    static let common: [(String,String)] = [("swift","Swift"),("objectivec","Objective-C"),("c","C"),("cpp","C++"),("csharp","C#"),("java","Java"),("javascript","JavaScript"),("typescript","TypeScript"),("python","Python"),("go","Go"),("rust","Rust"),("kotlin","Kotlin"),("ruby","Ruby"),("php","PHP"),("xml","HTML / XML"),("css","CSS"),("bash","Bash"),("sql","SQL"),("json","JSON"),("yaml","YAML"),("nginx","Nginx")]
    static func fences(_ rendered: MarkdownRenderer.Result) -> [[String:Any]] {
        rendered.tokens.filter { $0["type"] as? String == "fence" && ($0["meta"] as? [String:Any])?["kind"] as? String != "mindmap" }
    }
    static func replacing(_ source: String,index: Int,language: String) -> String? {
        let tokens = fences(MarkdownRenderer.shared.render(source))
        guard tokens.indices.contains(index), let lines = tokens[index]["map"] as? [Int],let line = lines.first,
              language.isEmpty || language == "plaintext" || MarkdownRenderer.shared.languages.contains(language) else { return nil }
        let text = source as NSString; var location = 0
        for _ in 0..<line { guard location < text.length else { return nil }; location = NSMaxRange(text.lineRange(for: NSRange(location: location,length: 0))) }
        let range = text.lineRange(for: NSRange(location: location,length: 0)),opening = text.substring(with: range) as NSString
        guard let marker = try? NSRegularExpression(pattern: "`{3,}|~{3,}"),let match = marker.firstMatch(in: opening as String,range: NSRange(location: 0,length: opening.length)) else { return nil }
        let body = (opening as String).trimmingCharacters(in: .newlines) as NSString
        let replacement = NSRange(location: range.location + NSMaxRange(match.range),length: body.length - NSMaxRange(match.range))
        return text.replacingCharacters(in: replacement,with: language)
    }
    static func richBlock(code: String,language: String) -> NSAttributedString {
        let runs = (try? NSRegularExpression(pattern: "`+").matches(in: code,range: NSRange(location: 0,length: (code as NSString).length))) ?? []
        let fence = String(repeating: "`",count: max(3,(runs.map { $0.range.length }.max() ?? 0) + 1))
        return MarkdownDocument.parse(fence + language + "\n" + code + (code.hasSuffix("\n") ? "" : "\n") + fence).content
    }
    static func decorateLegacyBlocks(_ content: NSAttributedString) -> NSAttributedString {
        var ranges: [NSRange] = []
        content.enumerateAttributes(in: NSRange(location: 0,length: content.length)) { attrs,range,_ in
            guard MarkdownTyping.isCodeBlock(attrs),DocumentStyle.metadata(attrs)["kind"] != "code" else { return }
            if let last = ranges.last,NSMaxRange(last) == range.location { ranges[ranges.count - 1] = NSUnionRange(last,range) }
            else { ranges.append(range) }
        }
        let result = NSMutableAttributedString(attributedString: content)
        for range in ranges.reversed() {
            let parsed = richBlock(code: content.attributedSubstring(from: range).string,language: "")
            var length = 0
            parsed.enumerateAttribute(.ziloBlock,in: NSRange(location: 0,length: parsed.length)) { value,piece,_ in if value != nil { length = NSMaxRange(piece) } }
            if length > 0 { result.replaceCharacters(in: range,with: parsed.attributedSubstring(from: NSRange(location: 0,length: length))) }
        }
        return result
    }
    @discardableResult static func changeRichBlock(_ block: String,language: String,in editor: NSTextView) -> Bool {
        guard let storage = editor.textStorage else { return false }
        var range = NSRange(location: NSNotFound,length: 0); var code = ""
        storage.enumerateAttribute(.ziloBlock,in: NSRange(location: 0,length: storage.length)) { value,piece,_ in
            guard let meta = value as? [String:String],meta["block"] == block else { return }
            range = range.location == NSNotFound ? piece : NSUnionRange(range,piece)
            if meta["kind"] == "code" { code += storage.attributedSubstring(from: piece).string }
        }
        guard range.location != NSNotFound else { return false }
        let parsed = richBlock(code: code,language: language)
        var length = 0
        parsed.enumerateAttribute(.ziloBlock,in: NSRange(location: 0,length: parsed.length)) { value,piece,_ in if value != nil { length = NSMaxRange(piece) } }
        guard length > 0 else { return false }
        let replacement = parsed.attributedSubstring(from: NSRange(location: 0,length: length))
        guard editor.performValidatedReplacement(in: range,with: replacement) else { return false }
        editor.setSelectedRange(NSRange(location: range.location + replacement.length,length: 0))
        return true
    }
}

final class CodeLanguageMenu: NSObject {
    let action: (String) -> Void
    init(action: @escaping (String) -> Void) { self.action = action }
    @objc func choose(_ item: NSMenuItem) { if let language = item.representedObject as? String { action(language) } }
    static func show(current: String,at point: NSPoint,in view: NSView,action: @escaping (String) -> Void) {
        let handler = CodeLanguageMenu(action: action),menu = NSMenu()
        let heading = NSMenuItem(title: ZiloLanguage.text("代码"),action: nil,keyEquivalent: ""); heading.isEnabled = false; menu.addItem(heading)
        func append(_ id: String,_ title: String,to target: NSMenu) {
            let localizedTitle = ZiloLanguage.text(title)
            let item = NSMenuItem(title: localizedTitle,action: #selector(choose(_:)),keyEquivalent: "")
            item.target = handler; item.representedObject = id
            item.state = current == id || (id == "plaintext" && current == "text") ? .on : .off
            if item.state == .on { item.attributedTitle = NSAttributedString(string: localizedTitle,attributes: [.foregroundColor: NSColor.controlAccentColor]) }
            target.addItem(item)
        }
        for (id,title) in CodeLanguage.common { append(id,title,to: menu) }
        menu.addItem(.separator()); append("","自动检测",to: menu); append("plaintext","纯文本",to: menu)
        let more = NSMenu(),common = Set(CodeLanguage.common.map { $0.0 } + ["plaintext"])
        for id in MarkdownRenderer.shared.languages.sorted() where !common.contains(id) { append(id,id,to: more) }
        let moreItem = NSMenuItem(title: ZiloLanguage.text("更多语言"),action: nil,keyEquivalent: ""); moreItem.submenu = more; menu.addItem(moreItem)
        withExtendedLifetime(handler) { menu.popUp(positioning: nil,at: point,in: view) }
    }
}

#endif
