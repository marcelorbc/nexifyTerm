import Foundation

enum MosaicAxis: String, Codable {
    case horizontal
    case vertical
}

enum PaneContent: Equatable, Codable {
    case terminal(UUID)
    case explorer(String)

    // Wave 5 · A8: hand-rolled Codable conformance so we can persist mosaic
    // layouts in `session_tabs.json` without changing existing JSON written by
    // older builds (those files simply won't have a layout field).
    private enum CodingKeys: String, CodingKey { case type, sessionId, directory }
    private enum Kind: String, Codable { case terminal, explorer }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .terminal:
            let id = try c.decode(UUID.self, forKey: .sessionId)
            self = .terminal(id)
        case .explorer:
            let dir = try c.decode(String.self, forKey: .directory)
            self = .explorer(dir)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let id):
            try c.encode(Kind.terminal, forKey: .type)
            try c.encode(id, forKey: .sessionId)
        case .explorer(let dir):
            try c.encode(Kind.explorer, forKey: .type)
            try c.encode(dir, forKey: .directory)
        }
    }

    var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }

    var isExplorer: Bool {
        if case .explorer = self { return true }
        return false
    }

    var sessionId: UUID? {
        if case .terminal(let id) = self { return id }
        return nil
    }

    var directory: String? {
        if case .explorer(let dir) = self { return dir }
        return nil
    }

    var icon: String {
        switch self {
        case .terminal: return "terminal.fill"
        case .explorer: return "folder.fill"
        }
    }

    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .explorer(let dir): return URL(fileURLWithPath: dir).lastPathComponent
        }
    }
}

indirect enum MosaicNode: Identifiable, Equatable, Codable {
    case pane(id: UUID, content: PaneContent)
    case split(id: UUID, axis: MosaicAxis, ratio: CGFloat, first: MosaicNode, second: MosaicNode)

    // Wave 5 · A8: Codable for layout persistence. Discriminator-based to keep
    // the serialized form forward-compatible if new node types are added.
    private enum CodingKeys: String, CodingKey {
        case type, id, content, axis, ratio, first, second
    }
    private enum Kind: String, Codable { case pane, split }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        let id = try c.decode(UUID.self, forKey: .id)
        switch kind {
        case .pane:
            let content = try c.decode(PaneContent.self, forKey: .content)
            self = .pane(id: id, content: content)
        case .split:
            let axis = try c.decode(MosaicAxis.self, forKey: .axis)
            let ratio = try c.decode(Double.self, forKey: .ratio)
            let first = try c.decode(MosaicNode.self, forKey: .first)
            let second = try c.decode(MosaicNode.self, forKey: .second)
            self = .split(id: id, axis: axis, ratio: CGFloat(ratio), first: first, second: second)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let id, let content):
            try c.encode(Kind.pane, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(content, forKey: .content)
        case .split(let id, let axis, let ratio, let first, let second):
            try c.encode(Kind.split, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(axis, forKey: .axis)
            try c.encode(Double(ratio), forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }

    var id: UUID {
        switch self {
        case .pane(let id, _): return id
        case .split(let id, _, _, _, _): return id
        }
    }

    var allPaneIds: [UUID] {
        switch self {
        case .pane(let id, _): return [id]
        case .split(_, _, _, let first, let second):
            return first.allPaneIds + second.allPaneIds
        }
    }

    var allTerminalSessionIds: [UUID] {
        switch self {
        case .pane(_, let content):
            if case .terminal(let sessionId) = content { return [sessionId] }
            return []
        case .split(_, _, _, let first, let second):
            return first.allTerminalSessionIds + second.allTerminalSessionIds
        }
    }

    var paneCount: Int {
        switch self {
        case .pane: return 1
        case .split(_, _, _, let first, let second):
            return first.paneCount + second.paneCount
        }
    }

    func replacingPane(_ paneId: UUID, with newNode: MosaicNode) -> MosaicNode {
        switch self {
        case .pane(let id, _):
            return id == paneId ? newNode : self
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(
                id: id, axis: axis, ratio: ratio,
                first: first.replacingPane(paneId, with: newNode),
                second: second.replacingPane(paneId, with: newNode)
            )
        }
    }

    func removingPane(_ paneId: UUID) -> MosaicNode? {
        switch self {
        case .pane(let id, _):
            return id == paneId ? nil : self
        case .split(_, _, _, let first, let second):
            let newFirst = first.removingPane(paneId)
            let newSecond = second.removingPane(paneId)
            if let f = newFirst, let s = newSecond {
                return .split(id: self.id, axis: splitAxis!, ratio: splitRatio!, first: f, second: s)
            }
            return newFirst ?? newSecond
        }
    }

    func updatingRatio(splitId: UUID, newRatio: CGFloat) -> MosaicNode {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let ratio, let first, let second):
            let r = id == splitId ? newRatio : ratio
            return .split(
                id: id, axis: axis, ratio: r,
                first: first.updatingRatio(splitId: splitId, newRatio: newRatio),
                second: second.updatingRatio(splitId: splitId, newRatio: newRatio)
            )
        }
    }

    private var splitAxis: MosaicAxis? {
        if case .split(_, let axis, _, _, _) = self { return axis }
        return nil
    }

    private var splitRatio: CGFloat? {
        if case .split(_, _, let ratio, _, _) = self { return ratio }
        return nil
    }

    static func == (lhs: MosaicNode, rhs: MosaicNode) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Predefined Layouts

extension MosaicNode {
    static func singleTerminal(directory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> MosaicNode {
        .pane(id: UUID(), content: .terminal(UUID()))
    }

    static func twoColumns(directory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> MosaicNode {
        .split(
            id: UUID(), axis: .horizontal, ratio: 0.5,
            first: .pane(id: UUID(), content: .terminal(UUID())),
            second: .pane(id: UUID(), content: .terminal(UUID()))
        )
    }

    static func terminalAndExplorer(directory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> MosaicNode {
        .split(
            id: UUID(), axis: .horizontal, ratio: 0.6,
            first: .pane(id: UUID(), content: .terminal(UUID())),
            second: .pane(id: UUID(), content: .explorer(directory))
        )
    }

    static func threePane(directory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> MosaicNode {
        .split(
            id: UUID(), axis: .horizontal, ratio: 0.5,
            first: .pane(id: UUID(), content: .terminal(UUID())),
            second: .split(
                id: UUID(), axis: .vertical, ratio: 0.5,
                first: .pane(id: UUID(), content: .terminal(UUID())),
                second: .pane(id: UUID(), content: .explorer(directory))
            )
        )
    }

    static func grid2x2(directory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> MosaicNode {
        .split(
            id: UUID(), axis: .horizontal, ratio: 0.5,
            first: .split(
                id: UUID(), axis: .vertical, ratio: 0.5,
                first: .pane(id: UUID(), content: .terminal(UUID())),
                second: .pane(id: UUID(), content: .terminal(UUID()))
            ),
            second: .split(
                id: UUID(), axis: .vertical, ratio: 0.5,
                first: .pane(id: UUID(), content: .terminal(UUID())),
                second: .pane(id: UUID(), content: .explorer(directory))
            )
        )
    }
}
