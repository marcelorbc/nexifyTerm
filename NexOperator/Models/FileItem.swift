import Foundation
import AppKit

enum FileItemType: String, Comparable {
    case folder
    case file
    case symlink
    case app

    static func < (lhs: FileItemType, rhs: FileItemType) -> Bool {
        let order: [FileItemType] = [.folder, .app, .file, .symlink]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

struct FileItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let size: Int64
    let createdDate: Date?
    let modifiedDate: Date?
    let fileType: FileItemType
    let isHidden: Bool
    let tags: [String]
    let fileExtension: String
    let isDirectory: Bool

    init(url: URL) {
        self.url = url
        self.id = url.path
        self.name = url.lastPathComponent

        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue

        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey,
            .isHiddenKey, .tagNamesKey, .isSymbolicLinkKey, .isApplicationKey,
            .typeIdentifierKey
        ]
        let values = try? url.resourceValues(forKeys: resourceKeys)

        self.size = Int64(values?.fileSize ?? 0)
        self.createdDate = values?.creationDate
        self.modifiedDate = values?.contentModificationDate
        self.isHidden = values?.isHidden ?? name.hasPrefix(".")
        self.tags = values?.tagNames ?? []
        self.fileExtension = url.pathExtension.lowercased()

        if values?.isSymbolicLink == true {
            self.fileType = .symlink
        } else if values?.isApplication == true {
            self.fileType = .app
        } else if isDir.boolValue {
            self.fileType = .folder
        } else {
            self.fileType = .file
        }
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    var isGitRepo: Bool {
        guard isDirectory else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    var sfSymbol: String {
        switch fileType {
        case .folder:
            if isGitRepo { return "arrow.triangle.branch" }
            return "folder.fill"
        case .app: return "app.fill"
        case .symlink: return "arrow.triangle.turn.up.right.diamond.fill"
        case .file:
            switch fileExtension {
            case "swift", "py", "js", "ts", "rb", "go", "rs", "java", "c", "cpp", "h", "m", "cs":
                return "chevron.left.forwardslash.chevron.right"
            case "json", "yaml", "yml", "xml", "plist", "toml":
                return "doc.text.fill"
            case "md", "txt", "rtf", "log":
                return "doc.plaintext.fill"
            case "html", "css", "scss":
                return "globe"
            case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "heic":
                return "photo.fill"
            case "mp4", "mov", "avi", "mkv":
                return "film.fill"
            case "mp3", "wav", "aac", "flac", "m4a":
                return "waveform"
            case "pdf":
                return "doc.richtext.fill"
            case "zip", "tar", "gz", "rar", "7z":
                return "doc.zipper"
            case "sh", "bash", "zsh", "fish":
                return "terminal.fill"
            case "env", "gitignore", "dockerignore":
                return "gearshape.fill"
            default:
                return "doc.fill"
            }
        }
    }

    var formattedSize: String {
        guard fileType != .folder else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var typeDescription: String {
        switch fileType {
        case .folder: return "Pasta"
        case .app: return "Aplicativo"
        case .symlink: return "Atalho"
        case .file:
            if fileExtension.isEmpty { return "Arquivo" }
            return fileExtension.uppercased()
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum FileSortField: String, CaseIterable {
    case name, size, modified, created, type
}

enum FileSortOrder {
    case ascending, descending
    var toggled: FileSortOrder {
        self == .ascending ? .descending : .ascending
    }
}

@MainActor
class FileItemProvider: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var currentURL: URL
    @Published var isLoading = false
    @Published var error: String?
    @Published var sortField: FileSortField = .name
    @Published var sortOrder: FileSortOrder = .ascending
    @Published var showHidden = false

    private var watcher: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1
    private var pollTimer: Timer?
    /// Wave 4 · M4: debounce work item for filesystem events. A noisy directory
    /// (npm install, git checkout, etc.) used to fire several `load()` calls
    /// within a few milliseconds, each rebuilding the entire `[FileItem]` array
    /// on the main thread. We coalesce bursts into a single load.
    private var reloadDebounce: DispatchWorkItem?
    private static let reloadDebounceInterval: DispatchTimeInterval = .milliseconds(220)

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = url
    }

    func load() {
        isLoading = true
        error = nil

        let fm = FileManager.default
        do {
            let urls = try fm.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [
                    .fileSizeKey, .creationDateKey, .contentModificationDateKey,
                    .isHiddenKey, .tagNamesKey, .isSymbolicLinkKey, .isApplicationKey
                ],
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
            items = urls.map { FileItem(url: $0) }
            sortItems()
            startWatching()
        } catch {
            self.error = error.localizedDescription
            items = []
        }
        isLoading = false
    }

    func navigate(to url: URL) {
        stopWatching()
        currentURL = url
        load()
    }

    func sortItems() {
        items.sort { a, b in
            if a.fileType == .folder && b.fileType != .folder { return true }
            if a.fileType != .folder && b.fileType == .folder { return false }

            let result: Bool
            switch sortField {
            case .name:
                result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .size:
                result = a.size < b.size
            case .modified:
                result = (a.modifiedDate ?? .distantPast) < (b.modifiedDate ?? .distantPast)
            case .created:
                result = (a.createdDate ?? .distantPast) < (b.createdDate ?? .distantPast)
            case .type:
                result = a.fileExtension < b.fileExtension
            }
            return sortOrder == .ascending ? result : !result
        }
    }

    // MARK: - File Operations

    func rename(item: FileItem, to newName: String) throws {
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: item.url, to: dest)
        load()
    }

    func moveItems(_ items: [FileItem], to destination: URL) throws {
        for item in items {
            let dest = destination.appendingPathComponent(item.name)
            try FileManager.default.moveItem(at: item.url, to: dest)
        }
        load()
    }

    func deleteItems(_ items: [FileItem]) throws {
        for item in items {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
        load()
    }

    func permanentDeleteItems(_ items: [FileItem]) throws {
        for item in items {
            try FileManager.default.removeItem(at: item.url)
        }
        load()
    }

    func duplicateItem(_ item: FileItem) throws {
        let ext = item.url.pathExtension
        let base = item.url.deletingPathExtension().lastPathComponent
        let parent = item.url.deletingLastPathComponent()
        let copyName = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
        let dest = parent.appendingPathComponent(copyName)
        try FileManager.default.copyItem(at: item.url, to: dest)
        load()
    }

    func createFolder(named name: String) throws {
        let dest = currentURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        load()
    }

    func setTags(for item: FileItem, tags: [String]) throws {
        try (item.url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        load()
    }

    func getTags(for url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    // MARK: - Clipboard (Copy/Cut/Paste like Finder)

    enum ClipboardOperation {
        case copy, cut
    }

    private(set) static var clipboardURLs: [URL] = []
    private(set) static var clipboardOperation: ClipboardOperation = .copy

    static func copyFilesToClipboard(_ urls: [URL], operation: ClipboardOperation = .copy) {
        clipboardURLs = urls
        clipboardOperation = operation
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    static var hasClipboardFiles: Bool {
        !clipboardURLs.isEmpty
    }

    func pasteFiles(to destination: URL) throws {
        let fm = FileManager.default
        for source in Self.clipboardURLs {
            let destURL = destination.appendingPathComponent(source.lastPathComponent)
            let finalURL = Self.uniqueDestination(destURL)
            switch Self.clipboardOperation {
            case .copy:
                try fm.copyItem(at: source, to: finalURL)
            case .cut:
                try fm.moveItem(at: source, to: finalURL)
            }
        }
        if Self.clipboardOperation == .cut {
            Self.clipboardURLs = []
        }
        load()
    }

    private static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        for i in 2...100 {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    // MARK: - Clipboard Content Paste (Image / Text)

    enum ClipboardContentType {
        case image, text, none
    }

    static func detectClipboardContent() -> ClipboardContentType {
        let pb = NSPasteboard.general

        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return .none
        }

        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil {
            return .image
        }

        if let str = pb.string(forType: .string), !str.isEmpty {
            return .text
        }

        return .none
    }

    func saveImageFromClipboard(named name: String, to destination: URL) throws {
        let pb = NSPasteboard.general
        guard let imageData = pb.data(forType: .png) ?? pb.data(forType: .tiff) else {
            throw NSError(domain: "FileItemProvider", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Sem dados de imagem no clipboard"])
        }

        guard let image = NSImage(data: imageData),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FileItemProvider", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Falha ao processar imagem"])
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImageExt = ["png", "jpg", "jpeg", "webp", "gif"].contains(where: { cleanName.lowercased().hasSuffix(".\($0)") })
        let fileName = hasImageExt ? cleanName : "\(cleanName).png"
        let fileURL = destination.appendingPathComponent(fileName)
        let finalURL = Self.uniqueDestination(fileURL)
        try pngData.write(to: finalURL)
        load()
    }

    func saveTextFromClipboard(named name: String, to destination: URL) throws {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else {
            throw NSError(domain: "FileItemProvider", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Sem texto no clipboard"])
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = cleanName.contains(".") ? cleanName : "\(cleanName).txt"
        let fileURL = destination.appendingPathComponent(fileName)
        let finalURL = Self.uniqueDestination(fileURL)
        try text.write(to: finalURL, atomically: true, encoding: .utf8)
        load()
    }

    static func openInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    // MARK: - File System Watching

    private func startWatching() {
        stopWatching()
        watcherFD = open(currentURL.path, O_EVTONLY)
        guard watcherFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watcherFD,
            eventMask: [.write, .rename, .delete, .link, .attrib, .extend, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Coalesce bursts into a single load() — see Wave 4 · M4.
            self?.scheduleDebouncedReload()
        }
        source.setCancelHandler { [weak self] in
            guard let fd = self?.watcherFD, fd >= 0 else { return }
            close(fd)
            self?.watcherFD = -1
        }
        source.resume()
        watcher = source

        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshIfChanged()
        }
    }

    private var lastItemCount: Int = 0

    private func refreshIfChanged() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: currentURL,
            includingPropertiesForKeys: nil,
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else { return }
        if contents.count != items.count {
            load()
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        pollTimer?.invalidate()
        pollTimer = nil
        reloadDebounce?.cancel()
        reloadDebounce = nil
    }

    /// Wave 4 · M4: schedules a single coalesced `load()` for upcoming bursts of
    /// filesystem events. Existing pending work is cancelled so only the latest
    /// debounced call survives.
    private func scheduleDebouncedReload() {
        reloadDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.load()
        }
        reloadDebounce = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.reloadDebounceInterval,
            execute: item
        )
    }

    deinit {
        watcher?.cancel()
        watcher = nil
        pollTimer?.invalidate()
        pollTimer = nil
        reloadDebounce?.cancel()
        reloadDebounce = nil
        if watcherFD >= 0 {
            close(watcherFD)
            watcherFD = -1
        }
    }
}
