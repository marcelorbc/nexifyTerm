import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    private var updaterController: SPUStandardUpdaterController?

    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheck: Date?
    @Published var updateAvailable = false

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private init() {
        guard !Self.isDebugBuild else {
            NexLog.general.info("Sparkle disabled in DEBUG builds")
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = controller

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheck)
    }

    func checkForUpdates() {
        updaterController?.updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        updaterController?.updater.checkForUpdatesInBackground()
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set {
            updaterController?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updaterController?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            updaterController?.updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var updaterService = UpdaterService.shared

    var body: some View {
        Button("Verificar Atualizações…") {
            updaterService.checkForUpdates()
        }
        .disabled(!updaterService.canCheckForUpdates)
    }
}
