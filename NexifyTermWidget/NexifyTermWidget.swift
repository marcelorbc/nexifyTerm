import WidgetKit
import SwiftUI

// MARK: - Shared Data Types (duplicated from main app for widget target)

private let suiteName = "group.com.nexia.nexifyterm"

struct WidgetDirectory: Codable {
    let path: String
    let name: String
}

struct WidgetTab: Codable {
    let title: String
    let directory: String
    let mode: String
    let isActive: Bool
}

private func loadRecentDirectories() -> [WidgetDirectory] {
    guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: "widget_recentDirectories"),
          let items = try? JSONDecoder().decode([WidgetDirectory].self, from: data) else {
        return []
    }
    return items
}

private func loadActiveTabs() -> [WidgetTab] {
    guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: "widget_activeTabs"),
          let items = try? JSONDecoder().decode([WidgetTab].self, from: data) else {
        return []
    }
    return items
}

// MARK: - Quick Actions Widget

struct QuickActionsEntry: TimelineEntry {
    let date: Date
}

struct QuickActionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry {
        QuickActionsEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
        completion(QuickActionsEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickActionsEntry>) -> Void) {
        let entry = QuickActionsEntry(date: .now)
        let timeline = Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3600)))
        completion(timeline)
    }
}

struct QuickActionsWidgetView: View {
    var entry: QuickActionsEntry

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.title3)
                Text("NexifyTerm")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            HStack(spacing: 12) {
                Link(destination: URL(string: "nexifyterm://newTab?type=terminal")!) {
                    VStack(spacing: 4) {
                        Image(systemName: "plus.rectangle")
                            .font(.title3)
                        Text("Novo")
                            .font(.caption2)
                    }
                }

                Link(destination: URL(string: "nexifyterm://open")!) {
                    VStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.title3)
                        Text("Abrir")
                            .font(.caption2)
                    }
                }

                Link(destination: URL(string: "nexifyterm://newTab?type=git")!) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.title3)
                        Text("Git")
                            .font(.caption2)
                    }
                }
            }
        }
        .padding()
    }
}

struct QuickActionsWidget: Widget {
    let kind = "QuickActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickActionsProvider()) { entry in
            QuickActionsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Actions")
        .description("Ações rápidas do NexifyTerm")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Recent Directories Widget

struct RecentDirsEntry: TimelineEntry {
    let date: Date
    let directories: [WidgetDirectory]
}

struct RecentDirsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentDirsEntry {
        RecentDirsEntry(date: .now, directories: [
            WidgetDirectory(path: "/Users/user/project", name: "project"),
            WidgetDirectory(path: "/Users/user/work", name: "work"),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentDirsEntry) -> Void) {
        let dirs = loadRecentDirectories()
        completion(RecentDirsEntry(date: .now, directories: dirs))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentDirsEntry>) -> Void) {
        let dirs = loadRecentDirectories()
        let entry = RecentDirsEntry(date: .now, directories: dirs)
        let timeline = Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300)))
        completion(timeline)
    }
}

struct RecentDirsWidgetView: View {
    var entry: RecentDirsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                Text("Recentes")
                    .font(.headline)
            }
            .padding(.bottom, 2)

            if entry.directories.isEmpty {
                Text("Nenhum diretório recente")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entry.directories.prefix(5).enumerated()), id: \.offset) { _, dir in
                    let encoded = dir.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dir.path
                    Link(destination: URL(string: "nexifyterm://open?path=\(encoded)")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(dir.name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
    }
}

struct RecentDirsWidget: Widget {
    let kind = "RecentDirsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecentDirsProvider()) { entry in
            RecentDirsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recent Directories")
        .description("Diretórios acessados recentemente")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Active Sessions Widget

struct ActiveSessionsEntry: TimelineEntry {
    let date: Date
    let tabs: [WidgetTab]
}

struct ActiveSessionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActiveSessionsEntry {
        ActiveSessionsEntry(date: .now, tabs: [
            WidgetTab(title: "Terminal 1", directory: "~/project", mode: "terminal", isActive: true),
            WidgetTab(title: "Git: work", directory: "~/work", mode: "git", isActive: false),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ActiveSessionsEntry) -> Void) {
        let tabs = loadActiveTabs()
        completion(ActiveSessionsEntry(date: .now, tabs: tabs))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActiveSessionsEntry>) -> Void) {
        let tabs = loadActiveTabs()
        let entry = ActiveSessionsEntry(date: .now, tabs: tabs)
        let timeline = Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(120)))
        completion(timeline)
    }
}

struct ActiveSessionsWidgetView: View {
    var entry: ActiveSessionsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                Text("Sessões Ativas")
                    .font(.headline)
                Spacer()
                Text("\(entry.tabs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            if entry.tabs.isEmpty {
                VStack {
                    Spacer()
                    Text("Nenhuma sessão ativa")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ForEach(Array(entry.tabs.prefix(6).enumerated()), id: \.offset) { _, tab in
                    HStack(spacing: 6) {
                        Image(systemName: iconForMode(tab.mode))
                            .font(.caption2)
                            .foregroundStyle(tab.isActive ? .blue : .secondary)
                        Text(tab.title)
                            .font(.caption)
                            .fontWeight(tab.isActive ? .semibold : .regular)
                            .lineLimit(1)
                        Spacer()
                        Text(URL(fileURLWithPath: tab.directory).lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
    }

    private func iconForMode(_ mode: String) -> String {
        switch mode {
        case "terminal": return "terminal.fill"
        case "explorer": return "folder.fill"
        case "git": return "arrow.triangle.branch"
        case "mosaic": return "rectangle.split.2x2.fill"
        default: return "terminal.fill"
        }
    }
}

struct ActiveSessionsWidget: Widget {
    let kind = "ActiveSessionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ActiveSessionsProvider()) { entry in
            ActiveSessionsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Active Sessions")
        .description("Sessões abertas no NexifyTerm")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Widget Bundle

@main
struct NexifyTermWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickActionsWidget()
        RecentDirsWidget()
        ActiveSessionsWidget()
    }
}
