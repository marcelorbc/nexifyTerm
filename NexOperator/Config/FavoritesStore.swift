import Foundation

struct FavoriteItem: Codable, Identifiable {
    let id: UUID
    var path: String
    var name: String
    var icon: String
    var order: Int
    var isDirectory: Bool

    init(path: String, name: String? = nil, icon: String? = nil, order: Int = 0) {
        self.id = UUID()
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
        self.icon = icon ?? (isDir.boolValue ? "folder.fill" : "doc.fill")
        self.order = order
    }
}

class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favorites: [FavoriteItem] = []

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NexOperator")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("favorites.json")
        load()
        addDefaultsIfEmpty()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data) else {
            return
        }
        favorites = decoded.sorted { $0.order < $1.order }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(favorites) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func addDefaultsIfEmpty() {
        guard favorites.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaults: [(String, String, String)] = [
            (home, "Home", "house.fill"),
            (home + "/Desktop", "Desktop", "menubar.dock.rectangle"),
            (home + "/Documents", "Documentos", "doc.fill"),
            (home + "/Downloads", "Downloads", "arrow.down.circle.fill"),
            (home + "/Developer", "Developer", "chevron.left.forwardslash.chevron.right"),
        ]
        for (i, (path, name, icon)) in defaults.enumerated() {
            if FileManager.default.fileExists(atPath: path) {
                favorites.append(FavoriteItem(path: path, name: name, icon: icon, order: i))
            }
        }
        save()
    }

    func add(path: String, name: String? = nil, icon: String? = nil) {
        guard !favorites.contains(where: { $0.path == path }) else { return }
        let item = FavoriteItem(path: path, name: name, icon: icon, order: favorites.count)
        favorites.append(item)
        save()
    }

    func remove(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        reorder()
        save()
    }

    func isFavorite(path: String) -> Bool {
        favorites.contains { $0.path == path }
    }

    func rename(_ id: UUID, to newName: String) {
        guard let idx = favorites.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        favorites[idx].name = trimmed
        save()
    }

    func toggleFavorite(path: String, name: String? = nil, icon: String? = nil) {
        if let existing = favorites.first(where: { $0.path == path }) {
            remove(existing.id)
        } else {
            add(path: path, name: name, icon: icon)
        }
    }

    private func reorder() {
        for i in favorites.indices {
            favorites[i].order = i
        }
    }
}
