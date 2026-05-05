import Foundation

final class DiskNode: Identifiable, ObservableObject {
    let id: UUID
    let url: URL
    let name: String
    let isDirectory: Bool
    let extensionKey: String
    var size: Int64
    var fileCount: Int
    var folderCount: Int
    var children: [DiskNode]
    weak var parent: DiskNode?

    init(
        url: URL,
        isDirectory: Bool,
        size: Int64 = 0,
        children: [DiskNode] = []
    ) {
        self.id = UUID()
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.extensionKey = isDirectory ? "" : url.pathExtension.lowercased()
        self.size = size
        self.fileCount = isDirectory ? 0 : 1
        self.folderCount = isDirectory ? 1 : 0
        self.children = children
        for child in children {
            child.parent = self
        }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var percentageOfParent: Double {
        guard let p = parent, p.size > 0 else { return 100.0 }
        return Double(size) / Double(p.size) * 100.0
    }

    func percentageOf(_ total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(size) / Double(total) * 100.0
    }

    func sortedChildren(limit: Int? = nil) -> [DiskNode] {
        let sorted = children.sorted { $0.size > $1.size }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    func aggregateByExtension() -> [ExtensionAggregate] {
        var map: [String: (size: Int64, count: Int)] = [:]
        collectExtensions(into: &map)
        return map.map { ExtensionAggregate(ext: $0.key, totalSize: $0.value.size, count: $0.value.count) }
            .sorted { $0.totalSize > $1.totalSize }
    }

    private func collectExtensions(into map: inout [String: (size: Int64, count: Int)]) {
        if !isDirectory && !extensionKey.isEmpty {
            let existing = map[extensionKey, default: (0, 0)]
            map[extensionKey] = (existing.size + size, existing.count + 1)
        }
        for child in children {
            child.collectExtensions(into: &map)
        }
    }

    func collectLargestFiles(limit: Int = 50) -> [DiskNode] {
        var files: [DiskNode] = []
        collectFiles(into: &files)
        files.sort { $0.size > $1.size }
        return Array(files.prefix(limit))
    }

    private func collectFiles(into list: inout [DiskNode]) {
        if !isDirectory {
            list.append(self)
        }
        for child in children {
            child.collectFiles(into: &list)
        }
    }

    func breadcrumb() -> [DiskNode] {
        var path: [DiskNode] = [self]
        var current = self
        while let p = current.parent {
            path.insert(p, at: 0)
            current = p
        }
        return path
    }

    func propagateCounts() {
        if isDirectory {
            var fc = 0
            var dc = 0
            for child in children {
                child.propagateCounts()
                fc += child.fileCount
                dc += child.folderCount
            }
            fileCount = fc
            folderCount = dc
        }
    }
}

struct ExtensionAggregate: Identifiable {
    var id: String { ext }
    let ext: String
    let totalSize: Int64
    let count: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

enum DiskScanState {
    case idle
    case scanning(progress: DiskScanProgress)
    case done(DiskNode)
    case error(String)

    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }

    var rootNode: DiskNode? {
        if case .done(let node) = self { return node }
        return nil
    }
}

struct DiskScanProgress {
    let scannedItems: Int
    let currentPath: String
    let bytesSeen: Int64

    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: bytesSeen, countStyle: .file)
    }
}
