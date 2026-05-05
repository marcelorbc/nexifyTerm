import Foundation

@MainActor
final class DiskScanService: ObservableObject {
    @Published var state: DiskScanState = .idle
    /// Diretórios que foram pulados nesta varredura (para mostrar ao usuário).
    @Published private(set) var skippedPaths: [String] = []

    private var scanTask: Task<Void, Never>?

    private static let progressUpdateInterval = 500

    /// Pastas de sistema do macOS — sempre puladas.
    private static let systemSkips: Set<String> = [
        ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100",
        ".Trashes", ".vol", ".TemporaryItems"
    ]

    /// Pastas de dependência/build/cache de stacks comuns. Reduz o scan de
    /// uma workspace de dev em até 95% (um único `node_modules` pode ter
    /// 100k+ arquivos sem valor analítico).
    static let devSkips: Set<String> = [
        "node_modules", ".git", ".svn", ".hg",
        "Pods", "Carthage", ".bundle", "vendor",
        "target", "build", "dist", "out", ".next", ".nuxt", ".turbo",
        "DerivedData", ".swiftpm", ".build",
        "__pycache__", ".venv", "venv", ".tox", ".pytest_cache", ".mypy_cache",
        ".gradle", ".idea", ".vscode",
        ".cache", ".parcel-cache", ".yarn"
    ]

    private static let resourceKeys: Set<URLResourceKey> = [
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .isDirectoryKey,
        .isSymbolicLinkKey
    ]

    /// Quando `true`, pula `node_modules`, `.git`, `Pods`, build dirs etc.
    /// Default `true` — drasticamente acelera análise de pastas de dev.
    var skipDevDirectories: Bool = true {
        didSet { rebuildSkipSet() }
    }

    private var activeSkipSet: Set<String> = DiskScanService.systemSkips

    init() {
        rebuildSkipSet()
    }

    private func rebuildSkipSet() {
        var skips = Self.systemSkips
        if skipDevDirectories {
            skips.formUnion(Self.devSkips)
        }
        activeSkipSet = skips
    }

    func scan(_ url: URL) {
        cancel()
        skippedPaths = []
        state = .scanning(progress: DiskScanProgress(scannedItems: 0, currentPath: url.path, bytesSeen: 0))

        let skipped = activeSkipSet
        let keys = Self.resourceKeys
        let interval = Self.progressUpdateInterval

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                var itemCount = 0
                var totalBytes: Int64 = 0

                let root = try DiskScanService.buildTree(
                    url: url,
                    skipped: skipped,
                    resourceKeys: keys,
                    progressInterval: interval,
                    itemCount: &itemCount,
                    totalBytes: &totalBytes,
                    reporter: self
                )
                root.propagateCounts()

                try Task.checkCancellation()

                await MainActor.run { [weak self] in
                    self?.state = .done(root)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.state = .idle
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.state = .error(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
    }

    private nonisolated static func buildTree(
        url: URL,
        skipped: Set<String>,
        resourceKeys: Set<URLResourceKey>,
        progressInterval: Int,
        itemCount: inout Int,
        totalBytes: inout Int64,
        reporter: DiskScanService?
    ) throws -> DiskNode {
        try Task.checkCancellation()

        let values = try? url.resourceValues(forKeys: resourceKeys)
        let isSymlink = values?.isSymbolicLink ?? false
        if isSymlink {
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            return DiskNode(url: url, isDirectory: false, size: size)
        }

        let isDir = values?.isDirectory ?? false

        if !isDir {
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            itemCount += 1
            totalBytes += size

            if itemCount % progressInterval == 0 {
                let count = itemCount
                let bytes = totalBytes
                let path = url.lastPathComponent
                Task { @MainActor [weak reporter] in
                    reporter?.state = .scanning(progress: DiskScanProgress(
                        scannedItems: count, currentPath: path, bytesSeen: bytes
                    ))
                }
            }
            return DiskNode(url: url, isDirectory: false, size: size)
        }

        if skipped.contains(url.lastPathComponent) {
            // Reporta o path pulado para a UI mostrar transparência ao usuário.
            let skippedPath = url.path
            Task { @MainActor [weak reporter] in
                guard let r = reporter else { return }
                if r.skippedPaths.count < 200 {
                    r.skippedPaths.append(skippedPath)
                }
            }
            return DiskNode(url: url, isDirectory: true, size: 0)
        }

        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsPackageDescendants]
            )
        } catch {
            return DiskNode(url: url, isDirectory: true, size: 0)
        }

        var children: [DiskNode] = []
        children.reserveCapacity(contents.count)
        var dirSize: Int64 = 0

        for childURL in contents {
            try Task.checkCancellation()
            let child = try buildTree(
                url: childURL,
                skipped: skipped,
                resourceKeys: resourceKeys,
                progressInterval: progressInterval,
                itemCount: &itemCount,
                totalBytes: &totalBytes,
                reporter: reporter
            )
            child.parent = nil
            dirSize += child.size
            children.append(child)
        }

        let node = DiskNode(url: url, isDirectory: true, size: dirSize, children: children)
        return node
    }
}
