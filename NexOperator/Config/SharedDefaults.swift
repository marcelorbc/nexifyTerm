import Foundation

enum SharedDefaults {
    static let suiteName = "group.com.nexia.nexifyterm"

    static var suite: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    enum Key {
        static let recentDirectories = "widget_recentDirectories"
        static let activeTabs = "widget_activeTabs"
    }

    struct WidgetTab: Codable {
        let title: String
        let directory: String
        let mode: String
        let isActive: Bool
    }

    struct WidgetDirectory: Codable {
        let path: String
        let name: String
    }

    static func updateRecentDirectories(_ dirs: [RecentDirectory]) {
        let items = dirs.prefix(10).map { WidgetDirectory(path: $0.path, name: $0.name) }
        if let data = try? JSONEncoder().encode(items) {
            suite?.set(data, forKey: Key.recentDirectories)
        }
    }

    static func updateActiveTabs(_ tabs: [TerminalTab], activeId: UUID?) {
        let items = tabs.map { tab in
            WidgetTab(
                title: tab.title,
                directory: tab.currentDirectory,
                mode: tab.tabMode.rawValue,
                isActive: tab.id == activeId
            )
        }
        if let data = try? JSONEncoder().encode(items) {
            suite?.set(data, forKey: Key.activeTabs)
        }
    }

    static func loadRecentDirectories() -> [WidgetDirectory] {
        guard let data = suite?.data(forKey: Key.recentDirectories),
              let items = try? JSONDecoder().decode([WidgetDirectory].self, from: data) else {
            return []
        }
        return items
    }

    static func loadActiveTabs() -> [WidgetTab] {
        guard let data = suite?.data(forKey: Key.activeTabs),
              let items = try? JSONDecoder().decode([WidgetTab].self, from: data) else {
            return []
        }
        return items
    }
}
