import Foundation

struct VolumeInfo {
    let name: String
    let totalCapacity: Int64
    let availableCapacity: Int64
    let mountPath: String

    var usedCapacity: Int64 { totalCapacity - availableCapacity }

    var usedPercentage: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(usedCapacity) / Double(totalCapacity) * 100.0
    }

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalCapacity, countStyle: .file)
    }

    var formattedAvailable: String {
        ByteCountFormatter.string(fromByteCount: availableCapacity, countStyle: .file)
    }

    var formattedUsed: String {
        ByteCountFormatter.string(fromByteCount: usedCapacity, countStyle: .file)
    }

    static func forURL(_ url: URL) -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        let name = values.volumeName ?? "Macintosh HD"
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)

        var mountURL = url
        while mountURL.path != "/" {
            let parent = mountURL.deletingLastPathComponent()
            if parent.path == mountURL.path { break }
            let parentValues = try? parent.resourceValues(forKeys: [.volumeNameKey])
            if parentValues?.volumeName != name { break }
            mountURL = parent
        }

        return VolumeInfo(
            name: name,
            totalCapacity: total,
            availableCapacity: available,
            mountPath: mountURL.path
        )
    }
}
