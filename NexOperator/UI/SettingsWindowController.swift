import AppKit
import SwiftUI

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    func show(appState: AppState) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func close() {}
}
