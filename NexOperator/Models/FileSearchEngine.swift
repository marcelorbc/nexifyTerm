import Foundation
import AppKit

@MainActor
class FileSearchEngine: ObservableObject {
    @Published var results: [FileSearchResult] = []
    @Published var isSearching = false
    @Published var searchText = ""

    private var spotlightQuery: NSMetadataQuery?
    private var fallbackTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    /// Wave 2 · A6: tokens returned by `addObserver(forName:...usingBlock:)` so we
    /// can actually remove them later. `removeObserver(self, name:object:)` does
    /// **not** work for block-based observers — without storing the tokens, the
    /// observers were leaking and accumulating across queries.
    private var spotlightObservers: [NSObjectProtocol] = []

    struct FileSearchResult: Identifiable, Hashable {
        let id: String
        let url: URL
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        let modifiedDate: Date?
        let matchType: MatchType
        let icon: NSImage

        enum MatchType: Hashable {
            case nameExact
            case namePrefix
            case nameContains
            case pathContains
        }

        var displayPath: String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if path.hasPrefix(home) {
                return "~" + path.dropFirst(home.count)
            }
            return path
        }

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: FileSearchResult, rhs: FileSearchResult) -> Bool { lhs.id == rhs.id }
    }

    // MARK: - Local Search (Explorer - recursive in directory)

    func searchLocal(query: String, in directory: URL, showHidden: Bool = false) {
        debounceTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            return
        }

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await performLocalSearch(query: query, in: directory, showHidden: showHidden)
        }
    }

    private func performLocalSearch(query: String, in directory: URL, showHidden: Bool) async {
        isSearching = true
        let lowerQuery = query.lowercased()
        var found: [FileSearchResult] = []
        let maxResults = 200

        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                .isHiddenKey
            ],
            options: showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        guard let enumerator else {
            isSearching = false
            return
        }

        var count = 0
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }
            count += 1

            if count % 500 == 0 {
                await Task.yield()
            }

            let fileName = fileURL.lastPathComponent.lowercased()

            let matchType: FileSearchResult.MatchType?
            if fileName == lowerQuery {
                matchType = .nameExact
            } else if fileName.hasPrefix(lowerQuery) {
                matchType = .namePrefix
            } else if fileName.contains(lowerQuery) {
                matchType = .nameContains
            } else if fileURL.path.lowercased().contains(lowerQuery) {
                matchType = .pathContains
            } else {
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = values?.isDirectory ?? false
            let size = Int64(values?.fileSize ?? 0)

            found.append(FileSearchResult(
                id: fileURL.path,
                url: fileURL,
                name: fileURL.lastPathComponent,
                path: fileURL.deletingLastPathComponent().path,
                isDirectory: isDir,
                size: size,
                modifiedDate: values?.contentModificationDate,
                matchType: matchType!,
                icon: NSWorkspace.shared.icon(forFile: fileURL.path)
            ))

            if found.count >= maxResults { break }
        }

        guard !Task.isCancelled else { return }

        found.sort { a, b in
            if a.matchType != b.matchType {
                return a.matchType.sortOrder < b.matchType.sortOrder
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        results = found
        isSearching = false
    }

    // MARK: - Global Search (Spotlight via NSMetadataQuery)

    func searchGlobal(query: String) {
        debounceTask?.cancel()
        cancelSpotlight()

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            return
        }

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            performSpotlightSearch(query: query)
        }
    }

    private func performSpotlightSearch(query: String) {
        cancelSpotlight()
        isSearching = true
        results = []

        let mdQuery = NSMetadataQuery()
        mdQuery.searchScopes = [
            NSMetadataQueryLocalComputerScope,
            NSMetadataQueryUserHomeScope
        ]

        let escaped = query.replacingOccurrences(of: "'", with: "\\'")
        mdQuery.predicate = NSPredicate(
            format: "kMDItemFSName LIKE[cd] %@ || kMDItemDisplayName LIKE[cd] %@",
            "*\(escaped)*",
            "*\(escaped)*"
        )
        mdQuery.sortDescriptors = [
            NSSortDescriptor(key: "kMDItemFSName", ascending: true)
        ]

        let finishToken = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: mdQuery,
            queue: .main
        ) { [weak self] notification in
            self?.handleSpotlightResults(notification)
        }

        let progressToken = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryGatheringProgress,
            object: mdQuery,
            queue: .main
        ) { [weak self] notification in
            self?.handleSpotlightResults(notification)
        }

        spotlightObservers = [finishToken, progressToken]
        spotlightQuery = mdQuery
        mdQuery.start()

        fallbackTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            mdQuery.stop()
        }
    }

    private func handleSpotlightResults(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }

        query.disableUpdates()
        defer { query.enableUpdates() }

        var found: [FileSearchResult] = []
        let maxResults = 150
        let count = min(query.resultCount, maxResults)

        for i in 0..<count {
            guard let item = query.result(at: i) as? NSMetadataItem else { continue }

            guard let path = item.value(forAttribute: kMDItemPath as String) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            let name = item.value(forAttribute: kMDItemFSName as String) as? String ?? url.lastPathComponent
            let size = item.value(forAttribute: kMDItemFSSize as String) as? Int64 ?? 0
            let modified = item.value(forAttribute: kMDItemContentModificationDate as String) as? Date
            let isDir = item.value(forAttribute: kMDItemContentTypeTree as String) as? [String]

            let isDirFlag = isDir?.contains("public.folder") ?? false

            let lowerQuery = searchText.lowercased()
            let lowerName = name.lowercased()
            let matchType: FileSearchResult.MatchType
            if lowerName == lowerQuery {
                matchType = .nameExact
            } else if lowerName.hasPrefix(lowerQuery) {
                matchType = .namePrefix
            } else if lowerName.contains(lowerQuery) {
                matchType = .nameContains
            } else {
                matchType = .pathContains
            }

            found.append(FileSearchResult(
                id: path,
                url: url,
                name: name,
                path: url.deletingLastPathComponent().path,
                isDirectory: isDirFlag,
                size: size,
                modifiedDate: modified,
                matchType: matchType,
                icon: NSWorkspace.shared.icon(forFile: path)
            ))
        }

        found.sort { a, b in
            if a.matchType != b.matchType {
                return a.matchType.sortOrder < b.matchType.sortOrder
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        results = found
        if notification.name == .NSMetadataQueryDidFinishGathering {
            isSearching = false
        }
    }

    // MARK: - Cleanup

    func cancelSpotlight() {
        spotlightQuery?.stop()
        spotlightQuery = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        for token in spotlightObservers {
            NotificationCenter.default.removeObserver(token)
        }
        spotlightObservers.removeAll()
    }

    func cancel() {
        debounceTask?.cancel()
        fallbackTask?.cancel()
        cancelSpotlight()
        isSearching = false
    }

    func clear() {
        cancel()
        results = []
        searchText = ""
    }

    deinit {
        // Wave 2 · A6: safety net — if the engine is deallocated while observers
        // are still registered, they would otherwise outlive the instance and
        // potentially crash on next callback. removeObserver(token) is safe to
        // call from deinit (no @MainActor hop needed).
        for token in spotlightObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

// MARK: - Sort Order for Match Types

extension FileSearchEngine.FileSearchResult.MatchType {
    var sortOrder: Int {
        switch self {
        case .nameExact: return 0
        case .namePrefix: return 1
        case .nameContains: return 2
        case .pathContains: return 3
        }
    }
}
