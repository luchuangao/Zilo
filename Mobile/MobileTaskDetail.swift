import SwiftUI
import UIKit
import WebKit
import UniformTypeIdentifiers
import QuickLook

struct MobileTaskDetail: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore; @Environment(\.dismiss) var dismiss
    let id: UUID
    @State private var addChild = false; @State private var attach = false; @State private var preview = false; @State private var file: URL?
    @State private var move = false
    @State private var reminderCheck: UUID?
    @State private var previewHeight: CGFloat = 180
    @FocusState private var notesFocused: Bool
    var task: TaskItem? { store.tasks.first { $0.id == id } }
    func field<T>(_ path: WritableKeyPath<TaskItem,T>,_ fallback: T) -> Binding<T> { Binding(get: { task?[keyPath: path] ?? fallback },set: { value in store.mutate(id) { $0[keyPath: path] = value } }) }
    var body: some View {
        Group { if let task {
            ScrollView { VStack(alignment: .leading,spacing: 20) {
                TextField("任务名称",text: field(\.title,""),axis: .vertical).font(.system(size: 25,weight: .semibold)).lineLimit(1...5).accessibilityLabel("任务名称")
                HStack(spacing: 16) {
                    Button { store.complete(id) } label: { Image(systemName: task.completed ? "checkmark.square.fill" : "square").font(.system(size: 23)) }.accessibilityLabel(task.completed ? "恢复任务" : "完成任务")
                    Divider().frame(height: 22)
                    NavigationLink { MobileTaskOptions(id: id) } label: { Label(task.due.map { $0.formatted(date: .abbreviated,time: task.allDay ? .omitted : .shortened) } ?? "设置日期",systemImage: "calendar").font(.subheadline) }
                    Spacer(); Button { store.mutate(id) { $0.starred.toggle() } } label: { Image(systemName: task.starred ? "star.fill" : "star").foregroundStyle(task.starred ? Color.yellow : Color.secondary) }.accessibilityLabel("收藏任务")
                }
                Divider()
                HStack {
                    Text("内容").font(.subheadline.weight(.medium)).foregroundStyle(.secondary); Spacer()
                    if task.editingMode == .markdown { Picker("正文编辑方式",selection: $preview) { Text("编辑").tag(false); Text("预览").tag(true) }.labelsHidden().pickerStyle(.segmented).frame(width: 132) }
                    Menu { Button("Markdown") { store.mutate(id) { $0.documentMode = .markdown } }; Button("富文本") { store.mutate(id) { $0.documentMode = .richText } } } label: { Image(systemName: "textformat") }.accessibilityLabel("正文编辑方式")
                }
                if task.editingMode == .markdown {
                    if preview {
                        MobileMarkdownPreview(source: field(\.notes,""),root: store.persistence.root,onContentHeight: { previewHeight = max(180,$0) }).frame(height: previewHeight).accessibilityLabel("Markdown 预览")
                    } else {
                        TextEditor(text: field(\.notes,"")).font(.system(size: 16)).frame(minHeight: 180).scrollContentBackground(.hidden).focused($notesFocused).accessibilityLabel("Markdown 正文")
                    }
                } else {
                    MobileRichTextEditor(data: field(\.richText,nil),plain: field(\.notes,"")).frame(minHeight: 230).accessibilityLabel("富文本正文")
                }
                if !task.checks.isEmpty {
                    Divider()
                    ForEach(task.checks) { check in HStack {
                        Button { store.mutate(id) { item in if let index = item.checks.firstIndex(where: { $0.id == check.id }) { item.checks[index].done.toggle() } } } label: { Image(systemName: check.done ? "checkmark.square.fill" : "square") }
                        TextField("检查项",text: Binding(get: { store.tasks.first { $0.id == id }?.checks.first { $0.id == check.id }?.title ?? "" },set: { text in store.mutate(id) { item in if let index = item.checks.firstIndex(where: { $0.id == check.id }) { item.checks[index].title = text } } })).strikethrough(check.done)
                        Button { reminderCheck = check.id } label: { Image(systemName: check.due == nil ? "bell" : "bell.fill").font(.subheadline) }.accessibilityLabel("检查项提醒")
                    } }
                }
                Divider()
                ForEach(store.tasks.filter { !$0.deleted && $0.parentID == id }.sorted { $0.order < $1.order }) { child in
                    HStack(spacing: 12) {
                        Button { store.complete(child.id) } label: { Image(systemName: child.completed ? "checkmark.square.fill" : "square").font(.system(size: 22)) }
                        TextField("子任务名称",text: Binding(get: { store.tasks.first { $0.id == child.id }?.title ?? "" },set: { value in store.mutate(child.id) { $0.title = value } })).strikethrough(child.completed)
                        NavigationLink { MobileTaskDetail(id: child.id) } label: { Image(systemName: "chevron.right").font(.caption) }
                    }.padding(.vertical,5)
                }
                Button { addChild = true } label: { Label("添加子任务",systemImage: "plus") }.padding(.vertical,6)
                if !task.attachments.isEmpty {
                    Divider(); Text("附件").font(.subheadline).foregroundStyle(.secondary)
                    ForEach(task.attachments) { item in
                        Button { let target = store.persistence.root.appendingPathComponent(item.relativePath); if FileManager.default.fileExists(atPath: target.path) { file = target } else { store.error = "附件正在从 iCloud 下载，请稍后再试。" } } label: { Label(item.name,systemImage: "paperclip").font(.subheadline) }
                    }
                }
                HStack { Image(systemName: "line.3.horizontal"); Text(task.listID.flatMap { listID in store.lists.first { $0.id == listID }?.name } ?? ZiloLanguage.text("收集箱")); Spacer(); Text(task.created,format: .dateTime.month().day()).font(.caption) }.font(.footnote).foregroundStyle(.secondary).padding(.top,24)
            }.padding(20) }
            .navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Menu {
                    Button("添加附件",systemImage: "paperclip") { attach = true }
                    NavigationLink("日期与任务属性") { MobileTaskOptions(id: id) }
                    NavigationLink("修改历史") { MobileTaskHistory(id: id) }
                    Button("移动位置",systemImage: "arrow.up.arrow.down") { move = true }
                    if task.deleted { Button("恢复任务") { store.restore(id); dismiss() } }
                    else { Button("移到回收站",systemImage: "trash",role: .destructive) { store.trash(id); dismiss() } }
                } label: { Image(systemName: "ellipsis") } }
            }.sheet(isPresented: $addChild) { MobileAddTask(listID: task.listID,parentID: id) }
                .sheet(isPresented: $move) { NavigationStack { MobileMoveTask(id: id) } }
                .fileImporter(isPresented: $attach,allowedContentTypes: [.item],allowsMultipleSelection: true) { result in switch result { case .success(let urls): store.attach(urls,taskID: id); case .failure(let error): store.error = error.localizedDescription } }
                .sheet(isPresented: Binding(get: { reminderCheck != nil },set: { if !$0 { reminderCheck = nil } })) {
                    if let checkID = reminderCheck { NavigationStack { MobileCheckReminder(taskID: id,checkID: checkID) } }
                }
                .quickLookPreview($file)
                .onChange(of: preview) { _,value in if value { notesFocused = false; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),to: nil,from: nil,for: nil) } }
                .onChange(of: task.editingMode) { _,_ in preview = false }
                .onChange(of: id) { _,_ in preview = false; previewHeight = 180 }
        } else { MobileEmpty(title: "任务暂不可用",detail: "同步完成后再试。",icon: "doc") } }
    }
}
struct MobileTaskOptions: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore
    let id: UUID
    var task: TaskItem? { store.tasks.first { $0.id == id } }
    func field<T>(_ path: WritableKeyPath<TaskItem,T>,_ fallback: T) -> Binding<T> { Binding(get: { task?[keyPath: path] ?? fallback },set: { value in store.mutate(id) { $0[keyPath: path] = value } }) }
    var body: some View { Form { if let task {
        Section("日期与提醒") {
            Toggle("设置日期",isOn: Binding(get: { task.due != nil },set: { value in store.mutate(id) { $0.setDue(value ? Date() : nil); if value { $0.reminders = [0] } } }))
            if task.due != nil {
                Toggle("全天",isOn: field(\.allDay,true))
                DatePicker("日期",selection: Binding(get: { self.task?.due ?? Date() },set: { date in store.mutate(id) { $0.setDue(date) } }),displayedComponents: task.allDay ? [.date] : [.date,.hourAndMinute])
                Toggle("设置开始时间",isOn: Binding(get: { task.start != nil },set: { value in store.mutate(id) { $0.setStart(value ? (task.due ?? Date()).addingTimeInterval(-max(60,task.duration)) : nil) } }))
                if task.start != nil {
                    DatePicker("开始",selection: Binding(get: { self.task?.start ?? Date() },set: { date in store.mutate(id) { $0.setStart(date) } }),displayedComponents: task.allDay ? [.date] : [.date,.hourAndMinute])
                }
                MobileReminderOffsets(offsets: field(\.reminders,[]))
                Picker("重复",selection: Binding(get: { self.task?.repeatRule.frequency ?? "none" },set: { value in store.mutate(id) { $0.repeatRule.frequency = value; $0.repeatRule.anchor = $0.due } })) {
                    Text("不重复").tag("none"); Text("每天").tag("daily"); Text("工作日").tag("workdays"); Text("每周").tag("weekly"); Text("每月").tag("monthly"); Text("每年").tag("yearly")
                }
            }
        }
        Section("任务属性") {
            Picker("优先级",selection: field(\.priority,0)) { Text("无").tag(0); Text("低").tag(1); Text("中").tag(2); Text("高").tag(3) }
            Picker("清单",selection: field(\.listID,nil)) { Text("收集箱").tag(nil as UUID?); ForEach(store.lists.filter { !$0.deleted }) { list in Text(list.name).tag(Optional(list.id)) } }
            TextField("标签，以逗号分隔",text: Binding(get: { self.task?.tags.joined(separator: ", ") ?? "" },set: { text in store.mutate(id) { $0.tags = text.split(whereSeparator: { $0 == "," || $0 == "，" }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }))
            Toggle("收藏",isOn: field(\.starred,false))
        }
    } }.navigationTitle("任务属性").navigationBarTitleDisplayMode(.inline) }
}
struct MobileMoveTask: View {
    @Environment(\.mobileAccent) private var appAccent
    @EnvironmentObject var store: MobileStore; @Environment(\.dismiss) var dismiss
    let id: UUID
    @State private var position = 1
    var body: some View { List {
        Section { Picker("放置方式",selection: $position) { Text("放在之前").tag(0); Text("设为子任务").tag(1); Text("放在之后").tag(2) }.pickerStyle(.segmented) }
        Section("选择目标任务") { ForEach(store.active.filter { $0.id != id }) { task in
            if TaskPlacement.changes(store.tasks,source: id,target: task.id,position: position == 0 ? .before : position == 1 ? .child : .after) != nil {
                Button(task.title) { store.place(id,task.id,position == 0 ? .before : position == 1 ? .child : .after); dismiss() }.foregroundStyle(.primary)
            }
        } }
        if store.tasks.first(where: { $0.id == id })?.parentID != nil {
            Section { Button("移为顶层任务") { if store.promoteTask(id) { dismiss() } } }
        }
    }.navigationTitle("移动任务").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } } }
}
struct MobileRichTextEditor: UIViewRepresentable {
    @Binding var data: Data?; @Binding var plain: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.delegate = context.coordinator; view.font = .systemFont(ofSize: 16); view.isScrollEnabled = true; view.overrideUserInterfaceStyle = .light; view.backgroundColor = .white
        context.coordinator.editor = view
        let toolbar = UIToolbar(); toolbar.sizeToFit(); toolbar.items = [UIBarButtonItem(title: ZiloLanguage.text("加粗"),style: .plain,target: context.coordinator,action: #selector(Coordinator.bold)),UIBarButtonItem(title: ZiloLanguage.text("斜体"),style: .plain,target: context.coordinator,action: #selector(Coordinator.italic)),UIBarButtonItem(title: ZiloLanguage.text("下划线"),style: .plain,target: context.coordinator,action: #selector(Coordinator.underline)),UIBarButtonItem(image: UIImage(systemName: "link"),style: .plain,target: context.coordinator,action: #selector(Coordinator.link)),UIBarButtonItem(systemItem: .flexibleSpace),UIBarButtonItem(title: ZiloLanguage.text("完成"),style: .done,target: context.coordinator,action: #selector(Coordinator.done))]; view.inputAccessoryView = toolbar
        view.textContainerInset = UIEdgeInsets(top: 0,left: 0,bottom: 12,right: 0); view.textContainer.lineFragmentPadding = 0; view.allowsEditingTextAttributes = true
        if let data,let attr = try? NSAttributedString(data: data,options: [.documentType:NSAttributedString.DocumentType.rtfd],documentAttributes: nil) { view.attributedText = attr } else { view.text = plain }
        return view
    }
    func updateUIView(_ view: UITextView,context: Context) {
        context.coordinator.parent = self
        guard !view.isFirstResponder else { return }
        if view.text != plain { if let data,let attr = try? NSAttributedString(data: data,options: [.documentType:NSAttributedString.DocumentType.rtfd],documentAttributes: nil) { view.attributedText = attr } else { view.text = plain } }
    }
    final class Coordinator: NSObject,UITextViewDelegate {
        weak var editor: UITextView?
        weak var linkAction: UIAlertAction?
        var parent: MobileRichTextEditor; init(_ parent: MobileRichTextEditor) { self.parent = parent }
        @objc func link() {
            guard let editor,let root = editor.window?.rootViewController else { return }
            var top = root; while let presented = top.presentedViewController { top = presented }
            let range = editor.selectedRange
            let alert = UIAlertController(title: ZiloLanguage.text("插入链接"),message: nil,preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "https://example.com"; $0.keyboardType = .URL; $0.autocapitalizationType = .none; $0.addTarget(self,action: #selector(self.validateLink(_:)),for: .editingChanged) }
            alert.addTextField { $0.placeholder = "链接文字"; if range.length > 0 { $0.text = (editor.text as NSString).substring(with: range) } }
            alert.addAction(UIAlertAction(title: ZiloLanguage.text("取消"),style: .cancel))
            let insert = UIAlertAction(title: ZiloLanguage.text("插入"),style: .default) { _ in
                let raw = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let url = URL(string: raw),["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
                let title = alert.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var attributes = editor.typingAttributes; attributes[.link] = url
                editor.textStorage.replaceCharacters(in: range,with: NSAttributedString(string: title.isEmpty ? raw : title,attributes: attributes))
                self.textViewDidChange(editor)
            }; insert.isEnabled = false; linkAction = insert; alert.addAction(insert); top.present(alert,animated: true)
        }
        @objc func validateLink(_ field: UITextField) {
            let raw = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = URL(string: raw)
            linkAction?.isEnabled = url.map { ["http","https","mailto"].contains($0.scheme?.lowercased() ?? "") && ($0.scheme == "mailto" || $0.host?.isEmpty == false) } ?? false
        }
        @objc func done() { editor?.resignFirstResponder() }
        @objc func bold() { change(.traitBold) }
        @objc func italic() { change(.traitItalic) }
        @objc func underline() {
            guard let editor else { return }; let range = editor.selectedRange
            let current = (editor.typingAttributes[.underlineStyle] as? Int) ?? 0
            if range.length == 0 { editor.typingAttributes[.underlineStyle] = current == 0 ? 1 : 0 }
            else { let value = editor.textStorage.attribute(.underlineStyle,at: range.location,effectiveRange: nil) as? Int ?? 0; editor.textStorage.addAttribute(.underlineStyle,value: value == 0 ? 1 : 0,range: range); textViewDidChange(editor) }
        }
        func change(_ trait: UIFontDescriptor.SymbolicTraits) {
            guard let editor else { return }; let range = editor.selectedRange
            func toggle(_ font: UIFont) -> UIFont {
                var traits = font.fontDescriptor.symbolicTraits
                if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                return font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0,size: font.pointSize) } ?? font
            }
            if range.length == 0 { editor.typingAttributes[.font] = toggle(editor.typingAttributes[.font] as? UIFont ?? .systemFont(ofSize: 16)) }
            else {
                let storage = editor.textStorage; var replacements: [(NSRange,UIFont)] = []
                storage.enumerateAttribute(.font,in: range) { value,subrange,_ in replacements.append((subrange,toggle(value as? UIFont ?? .systemFont(ofSize: 16)))) }
                for (subrange,font) in replacements { storage.addAttribute(.font,value: font,range: subrange) }
                textViewDidChange(editor)
            }
        }
        func textViewDidChange(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            if let data = try? textView.attributedText.data(from: NSRange(location: 0,length: textView.attributedText.length),documentAttributes: [.documentType:NSAttributedString.DocumentType.rtfd]) { parent.data = data; parent.plain = textView.text }
        }
    }
}
struct MobileMarkdownPreview: UIViewRepresentable {
    @Binding var source: String
    var root: URL
    var onContentHeight: ((CGFloat) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.setURLSchemeHandler(context.coordinator,forURLScheme: "zilo-image")
        if onContentHeight != nil {
            config.userContentController.add(context.coordinator,name: "documentHeight")
            config.userContentController.addUserScript(WKUserScript(source: "const article=document.getElementById('document'); const report=()=>window.webkit.messageHandlers.documentHeight.postMessage(Math.ceil(article.getBoundingClientRect().height)); new ResizeObserver(report).observe(article); report();",injectionTime: .atDocumentEnd,forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero,configuration: config); view.navigationDelegate = context.coordinator; view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = onContentHeight == nil; return view
    }
    func updateUIView(_ view: WKWebView,context: Context) {
        context.coordinator.parent = self
        let key = source + "|" + String(scheme == .dark); guard key != context.coordinator.key else { return }; context.coordinator.key = key
        let result = MarkdownRenderer.shared.render(source); context.coordinator.codes = result.codes
        let dark = scheme == .dark
        let css = "body{margin:0;font:16px -apple-system;color:\(dark ? "#eee" : "#242730");background:transparent;line-height:1.65;overflow-wrap:anywhere}article{display:flow-root;padding:0 0 8px}h1,h2{line-height:1.35}a{color:#4c6fff}img,svg{max-width:100%}blockquote{margin:15px 0;padding-left:15px;border-left:3px solid #ddd;color:#888}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:6px}.code-card{background:\(dark ? "#292b32" : "#f4f5f7");border-radius:10px;margin:18px 0;overflow:hidden}header{display:flex;justify-content:space-between;padding:12px 14px;font-size:12px}header a{text-decoration:none}.language-chevron{width:8px;height:12px;stroke:currentColor;fill:none;stroke-width:1.5}pre{margin:0;padding:0 14px 14px;overflow:auto;font:14px monospace;white-space:pre}.hljs-keyword{color:#c968cd}.hljs-string{color:#20a765}.hljs-number{color:#e78635}.hljs-comment{color:#888}.mindmap{overflow:auto}.task-checkbox{width:16px;height:16px;margin-right:5px}"
        view.loadHTMLString("<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none';img-src data: zilo-image:;style-src 'unsafe-inline'\"><style>" + css + "</style>" + "<article id=\"document\">" + result.html + "</article>",baseURL: nil)
    }
    static func dismantleUIView(_ view: WKWebView,coordinator: Coordinator) { view.configuration.userContentController.removeScriptMessageHandler(forName: "documentHeight"); view.navigationDelegate = nil }
    final class Coordinator: NSObject,WKNavigationDelegate,WKURLSchemeHandler,WKScriptMessageHandler {
        var parent: MobileMarkdownPreview; var key = ""; var codes: [String] = []
        init(_ parent: MobileMarkdownPreview) { self.parent = parent }
        func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
            guard message.name == "documentHeight",let number = message.body as? NSNumber else { return }
            let height = CGFloat(truncating: number); guard height.isFinite && height > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.onContentHeight?(height) }
        }
        func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == "zilo-copy",let index = Int(url.absoluteString.replacingOccurrences(of: "zilo-copy:",with: "")),codes.indices.contains(index) { UIPasteboard.general.string = codes[index]; decisionHandler(.cancel) }
            else if url.scheme == "zilo-language",let index = Int(url.absoluteString.replacingOccurrences(of: "zilo-language:",with: "")) {
                let sheet = UIAlertController(title: ZiloLanguage.text("代码语言"),message: nil,preferredStyle: .actionSheet)
                for (language,title) in [("swift","Swift"),("objectivec","Objective-C"),("c","C"),("cpp","C++"),("csharp","C#"),("java","Java"),("javascript","JavaScript"),("typescript","TypeScript"),("python","Python"),("go","Go"),("rust","Rust"),("kotlin","Kotlin"),("ruby","Ruby"),("php","PHP"),("html","HTML"),("css","CSS"),("bash","Bash"),("sql","SQL"),("json","JSON"),("plaintext","纯文本")] {
                    sheet.addAction(UIAlertAction(title: title,style: .default) { _ in
                        var lines = self.parent.source.components(separatedBy: "\n"); var fence = -1; var inside = false
                        for i in lines.indices where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                            if !inside { fence += 1; if fence == index { let indent = lines[i].prefix { $0 == " " }; lines[i] = indent + "```" + language; self.parent.source = lines.joined(separator: "\n"); break } }; inside.toggle()
                        }
                    })
                }
                sheet.addAction(UIAlertAction(title: ZiloLanguage.text("取消"),style: .cancel))
                if let controller = webView.window?.rootViewController { var top = controller; while let presented = top.presentedViewController { top = presented }; sheet.popoverPresentationController?.sourceView = webView; top.present(sheet,animated: true) }
                decisionHandler(.cancel)
            } else if action.navigationType == .linkActivated {
                if ["https","http","mailto"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }; decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView,start task: WKURLSchemeTask) {
            guard let url = task.request.url,let file = MarkdownRenderer.imageURL(url,root: parent.root),let data = try? Data(contentsOf: file) else { task.didFailWithError(CocoaError(.fileReadNoSuchFile)); return }
            let ext = file.pathExtension.lowercased(); let mime = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : ext == "webp" ? "image/webp" : "image/jpeg"
            task.didReceive(URLResponse(url: url,mimeType: mime,expectedContentLength: data.count,textEncodingName: nil)); task.didReceive(data); task.didFinish()
        }
        func webView(_ webView: WKWebView,stop task: WKURLSchemeTask) { }
    }
}

struct MobileReminderOffsets: View {
    @Binding var offsets: [Double]
    @State private var minutes = "15"
    var body: some View { Group {
        ForEach([0.0,300,900,1800,3600,86400],id: \.self) { offset in
            Toggle(offset == 0 ? ZiloLanguage.text("到时提醒") : ZiloLanguage.format("提前 %lld 分钟",Int(offset / 60)),isOn: Binding(get: { offsets.contains(offset) },set: { value in offsets.removeAll { $0 == offset }; if value { offsets.append(offset) } }))
        }
        ForEach(offsets.filter { ![0.0,300,900,1800,3600,86400].contains($0) },id: \.self) { offset in HStack { Text(ZiloLanguage.format("提前 %lld 分钟",Int(offset / 60))); Spacer(); Button("移除") { offsets.removeAll { $0 == offset } } } }
        HStack { TextField("提前分钟数",text: $minutes).keyboardType(.numberPad); Button("添加提醒") { if let value = Double(minutes),value.isFinite,value > 0,!offsets.contains(value * 60) { offsets.append(value * 60) } }.disabled(Double(minutes).map { !$0.isFinite || $0 <= 0 } ?? true) }
    } }
}
struct MobileCheckReminder: View {
    @EnvironmentObject var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    var taskID: UUID; var checkID: UUID
    var check: CheckItem? { store.tasks.first { $0.id == taskID }?.checks.first { $0.id == checkID } }
    func change(_ body: (inout CheckItem) -> Void) { store.mutate(taskID) { task in if let index = task.checks.firstIndex(where: { $0.id == checkID }) { body(&task.checks[index]) } } }
    var body: some View { Form { if let check {
        Section { Text(check.title); Toggle("检查项提醒",isOn: Binding(get: { check.due != nil },set: { enabled in change { $0.due = enabled ? Date().addingTimeInterval(3600) : nil; $0.reminders = enabled ? [0] : nil } })) }
        if check.due != nil { Section("日期与提醒") {
            DatePicker("日期与时间",selection: Binding(get: { self.check?.due ?? Date() },set: { date in change { $0.due = date } }))
            MobileReminderOffsets(offsets: Binding(get: { self.check?.reminders ?? [0] },set: { offsets in change { $0.reminders = offsets } }))
        } }
    } }.navigationTitle("检查项提醒").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } }
}
struct MobileTaskHistory: View {
    @EnvironmentObject var store: MobileStore
    var id: UUID
    @State private var versions: [FieldVersion] = []
    var body: some View { List(versions.reversed()) { version in
        VStack(alignment: .leading,spacing: 8) {
            HStack { Text(ZiloLanguage.text(["title":"任务名称","notes":"内容","due":"日期","checks":"检查项","reminders":"提醒","start":"开始","tags":"标签","priority":"优先级"][version.field] ?? version.field)).font(.subheadline.weight(.medium)); Spacer(); Text(version.timestamp,format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
            Text(version.json).font(.footnote).lineLimit(6).textSelection(.enabled)
            Button("恢复这个字段") { do { try store.persistence.restoreField(version); store.reload(); versions = try store.persistence.versions(owner: id) } catch { store.error = error.localizedDescription } }
        }.padding(.vertical,6)
    }.navigationTitle("修改历史").navigationBarTitleDisplayMode(.inline).task { do { versions = try store.persistence.versions(owner: id) } catch { store.error = error.localizedDescription } } }
}
