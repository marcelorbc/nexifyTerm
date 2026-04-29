import Foundation

// MARK: - Layout Template (Codable description of a mosaic structure)

enum PaneTemplate: String, Codable {
    case terminal
    case explorer
}

indirect enum LayoutTemplate: Codable {
    case pane(PaneTemplate)
    case split(axis: MosaicAxis, ratio: CGFloat, first: LayoutTemplate, second: LayoutTemplate)

    enum CodingKeys: String, CodingKey {
        case type, paneType, axis, ratio, first, second
    }

    enum NodeType: String, Codable {
        case pane, split
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let paneType):
            try container.encode(NodeType.pane, forKey: .type)
            try container.encode(paneType, forKey: .paneType)
        case .split(let axis, let ratio, let first, let second):
            try container.encode(NodeType.split, forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)
        switch type {
        case .pane:
            let paneType = try container.decode(PaneTemplate.self, forKey: .paneType)
            self = .pane(paneType)
        case .split:
            let axis = try container.decode(MosaicAxis.self, forKey: .axis)
            let ratio = try container.decode(CGFloat.self, forKey: .ratio)
            let first = try container.decode(LayoutTemplate.self, forKey: .first)
            let second = try container.decode(LayoutTemplate.self, forKey: .second)
            self = .split(axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    func instantiate(directory: String) -> MosaicNode {
        switch self {
        case .pane(let paneType):
            switch paneType {
            case .terminal:
                return .pane(id: UUID(), content: .terminal(UUID()))
            case .explorer:
                return .pane(id: UUID(), content: .explorer(directory))
            }
        case .split(let axis, let ratio, let first, let second):
            return .split(
                id: UUID(), axis: axis, ratio: ratio,
                first: first.instantiate(directory: directory),
                second: second.instantiate(directory: directory)
            )
        }
    }

    static func from(node: MosaicNode) -> LayoutTemplate {
        switch node {
        case .pane(_, let content):
            switch content {
            case .terminal: return .pane(.terminal)
            case .explorer: return .pane(.explorer)
            }
        case .split(_, let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio, first: from(node: first), second: from(node: second))
        }
    }

    var description: String {
        let parts = collectPanes()
        let terminals = parts.filter { $0 == .terminal }.count
        let explorers = parts.filter { $0 == .explorer }.count
        var items: [String] = []
        if terminals > 0 { items.append("\(terminals) Terminal\(terminals > 1 ? "s" : "")") }
        if explorers > 0 { items.append("\(explorers) Explorer\(explorers > 1 ? "s" : "")") }
        return items.joined(separator: " + ")
    }

    private func collectPanes() -> [PaneTemplate] {
        switch self {
        case .pane(let t): return [t]
        case .split(_, _, let first, let second):
            return first.collectPanes() + second.collectPanes()
        }
    }
}

// MARK: - Preset Model

struct MosaicPreset: Identifiable, Codable {
    var id: UUID
    var name: String
    var icon: String
    var layout: LayoutTemplate
    var createdAt: Date

    init(name: String, icon: String = "rectangle.split.2x2", layout: LayoutTemplate) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.layout = layout
        self.createdAt = Date()
    }
}

// MARK: - Store

final class MosaicPresetStore: ObservableObject {
    static let shared = MosaicPresetStore()

    @Published var presets: [MosaicPreset] = []

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("NexOperator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("mosaic_presets.json")
        load()
    }

    func save(_ preset: MosaicPreset) {
        presets.append(preset)
        persist()
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func rename(_ id: UUID, to newName: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = newName
        persist()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            presets = try JSONDecoder().decode([MosaicPreset].self, from: data)
        } catch {
            NexLog.config.error("Failed to load mosaic presets: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(presets)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NexLog.config.error("Failed to save mosaic presets: \(error.localizedDescription)")
        }
    }
}
