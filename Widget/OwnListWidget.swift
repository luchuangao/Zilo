import SwiftUI
import WidgetKit

struct Entry: TimelineEntry { let date: Date; let tasks: [TaskItem] }
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { var task = TaskItem(); task.title = "今天的安排"; return Entry(date: Date(),tasks: [task]) }
    func getSnapshot(in context: Context,completion: @escaping (Entry) -> Void) { completion(load()) }
    func getTimeline(in context: Context,completion: @escaping (Timeline<Entry>) -> Void) { completion(Timeline(entries: [load()],policy: .after(Date().addingTimeInterval(300)))) }
    func load() -> Entry { guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Bundle.main.object(forInfoDictionaryKey: "OwnListAppGroup") as? String ?? "VFDQL6Z55P.com.gaoluchuan.ownlist"), let data = try? Data(contentsOf: root.appendingPathComponent("today.json")), let tasks = try? JSONDecoder().decode([TaskItem].self,from: data) else { return Entry(date: Date(),tasks: []) }; return Entry(date: Date(),tasks: tasks) }
}
struct WidgetView: View { var entry: Entry; var body: some View { VStack(alignment: .leading,spacing: 10) { HStack { Label("今天",systemImage: "checkmark.circle.fill").foregroundStyle(.blue); Spacer(); Text("\(entry.tasks.count)").foregroundStyle(.secondary) }; ForEach(entry.tasks.prefix(5)) { t in Link(destination: URL(string: "ownlist://task?id=\(t.id)")!) { HStack { Image(systemName: "circle"); Text(t.title).lineLimit(1) }.font(.caption) } }; if entry.tasks.isEmpty { Text("今天的清单很清爽").font(.caption).foregroundStyle(.secondary) }; Spacer(); Link("添加任务",destination: URL(string: "ownlist://quick")!).font(.caption) }.containerBackground(.background,for: .widget) } }
@main struct OwnListWidget: Widget { var body: some WidgetConfiguration { StaticConfiguration(kind: "OwnListToday",provider: Provider()) { WidgetView(entry: $0) }.configurationDisplayName("知行清单 · 今天").description("查看今日任务并快速打开详情").supportedFamilies([.systemSmall,.systemMedium]) } }
