import SwiftUI

struct TerminalContainerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let tabId = appState.activeTabId,
           let tab = appState.tabs.first(where: { $0.id == tabId }) {
            switch tab.tabMode {
            case .terminal:
                let session = appState.sessionManager.session(for: tabId, initialDirectory: tab.currentDirectory)
                SwiftTermViewRepresentable(session: session)
                    .id(tabId)
            case .explorer:
                FileExplorerView(directory: tab.currentDirectory)
                    .id(tabId)
                    .environmentObject(appState)
            case .mosaic:
                if let layout = tab.mosaicLayout {
                    MosaicView(
                        node: layout,
                        tabId: tabId,
                        directory: tab.currentDirectory,
                        onLayoutChange: { newLayout in
                            appState.updateMosaicLayout(tabId: tabId, layout: newLayout)
                        }
                    )
                    .environmentObject(appState)
                    .id(tabId)
                }
            case .git:
                GitTabView(viewModel: appState.gitViewModel(for: tabId))
                    .environmentObject(appState)
                    .id(tabId)
            case .diskAnalyzer:
                DiskAnalyzerView(directory: tab.currentDirectory)
                    .environmentObject(appState)
                    .id(tabId)
            case .whatsapp:
                WhatsAppTabView()
                    .environmentObject(appState)
                    .environmentObject(WhatsAppStore.shared)
                    .id(tabId)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No terminal open")
                    .foregroundColor(.secondary)
                Button("New Tab") {
                    appState.addTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
