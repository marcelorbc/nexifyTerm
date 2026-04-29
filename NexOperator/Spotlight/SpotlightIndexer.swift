import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    private let index = CSSearchableIndex.default()
    private let domainRecents = "com.nexia.nexifyterm.recents"

    func indexRecentDirectories(_ directories: [RecentDirectory]) {
        index.deleteSearchableItems(withDomainIdentifiers: [domainRecents]) { [weak self] error in
            if let error {
                NexLog.general.error("Spotlight delete error: \(error.localizedDescription)")
            }
            self?.addDirectoryItems(directories)
        }
    }

    func removeAll() {
        index.deleteSearchableItems(withDomainIdentifiers: [domainRecents]) { error in
            if let error {
                NexLog.general.error("Spotlight removeAll error: \(error.localizedDescription)")
            }
        }
    }

    private func addDirectoryItems(_ directories: [RecentDirectory]) {
        let items = directories.map { dir -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .folder)
            attributes.title = dir.name
            attributes.contentDescription = "Abrir \(dir.path) no NexifyTerm"
            attributes.path = dir.path
            attributes.keywords = ["terminal", "nexifyterm", dir.name]
            attributes.lastUsedDate = dir.visitedAt
            attributes.supportsNavigation = true

            return CSSearchableItem(
                uniqueIdentifier: "dir:\(dir.path)",
                domainIdentifier: domainRecents,
                attributeSet: attributes
            )
        }

        guard !items.isEmpty else { return }

        index.indexSearchableItems(items) { error in
            if let error {
                NexLog.general.error("Spotlight index error: \(error.localizedDescription)")
            }
        }
    }

    func handleSpotlightActivity(_ userActivity: NSUserActivity) -> String? {
        if userActivity.activityType == CSSearchableItemActionType,
           let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
            if identifier.hasPrefix("dir:") {
                return String(identifier.dropFirst(4))
            }
        }
        return nil
    }
}
