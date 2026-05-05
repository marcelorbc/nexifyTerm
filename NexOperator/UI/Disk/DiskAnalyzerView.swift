import SwiftUI

enum DiskDetailTab: String, CaseIterable {
    case list = "Lista"
    case sunburst = "Sunburst"
    case topExtensions = "Extensões"
    case topFiles = "Top Arquivos"

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .sunburst: return "circle.circle"
        case .topExtensions: return "doc.on.doc"
        case .topFiles: return "arrow.up.doc"
        }
    }
}

struct DiskAnalyzerView: View {
    @EnvironmentObject var appState: AppState
    let directory: String

    @StateObject private var scanner = DiskScanService()
    @State private var focusedNode: DiskNode?
    @State private var rootNode: DiskNode?
    @State private var volumeInfo: VolumeInfo?
    @State private var selectedDetailTab: DiskDetailTab = .list
    @State private var skipDevDirs: Bool = ConfigStore.shared.diskAnalyzerSkipDevDirs
    @State private var showSkippedPathsPopover = false

    private var displayNode: DiskNode? {
        focusedNode ?? rootNode
    }

    var body: some View {
        VStack(spacing: 0) {
            VolumeSummaryView(volumeInfo: volumeInfo, scannedNode: rootNode)

            if let node = displayNode {
                DiskBreadcrumbView(breadcrumb: node.breadcrumb()) { target in
                    focusedNode = target.id == rootNode?.id ? nil : target
                }
            }

            Divider()

            switch scanner.state {
            case .idle:
                scanPlaceholder

            case .scanning(let progress):
                scanningView(progress)

            case .done:
                if let node = displayNode {
                    mainContent(node)
                }

            case .error(let message):
                errorView(message)
            }

            Divider()
            statusBar
        }
        .onAppear {
            let url = URL(fileURLWithPath: directory)
            volumeInfo = VolumeInfo.forURL(url)
            scanner.skipDevDirectories = skipDevDirs
            scanner.scan(url)
        }
        .onDisappear {
            scanner.cancel()
        }
        .onChange(of: scanner.state.rootNode?.id) { _, _ in
            if let root = scanner.state.rootNode {
                rootNode = root
                focusedNode = nil
            }
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private func mainContent(_ node: DiskNode) -> some View {
        HSplitView {
            DiskTreemapView(node: node) { child in
                focusedNode = child
            }
            .frame(minWidth: 300)

            VStack(spacing: 0) {
                detailTabBar
                Divider()
                detailContent(node)
            }
            .frame(minWidth: 250, idealWidth: 350)
        }
    }

    private var detailTabBar: some View {
        HStack(spacing: 0) {
            ForEach(DiskDetailTab.allCases, id: \.self) { tab in
                Button {
                    selectedDetailTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10))
                        Text(tab.rawValue)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(selectedDetailTab == tab ? .accentColor : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        selectedDetailTab == tab
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            Spacer()

            if focusedNode != nil {
                Button {
                    navigateUp()
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Pasta pai")
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    @ViewBuilder
    private func detailContent(_ node: DiskNode) -> some View {
        switch selectedDetailTab {
        case .list:
            DiskTableView(node: node) { child in
                focusedNode = child
            }
        case .sunburst:
            DiskSunburstView(node: node) { child in
                focusedNode = child
            }
        case .topExtensions:
            DiskTopExtensionsView(node: node)
        case .topFiles:
            DiskTopFilesView(node: node)
        }
    }

    // MARK: - Scanning State

    private var scanPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Preparando análise...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanningView(_ progress: DiskScanProgress) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text("Analisando disco...")
                .font(.system(size: 14, weight: .medium))

            VStack(spacing: 6) {
                Text("\(progress.scannedItems) itens escaneados")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(progress.formattedBytes)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.accentColor)
                Text(progress.currentPath)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 400)
            }

            Button("Cancelar") {
                scanner.cancel()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text("Erro ao analisar")
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Tentar novamente") {
                scanner.scan(URL(fileURLWithPath: directory))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if case .scanning(let progress) = scanner.state {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("\(progress.scannedItems) itens | \(progress.formattedBytes)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if let root = rootNode {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                Text("\(root.fileCount) arquivos, \(root.folderCount) pastas | \(root.formattedSize)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if !scanner.skippedPaths.isEmpty {
                Button {
                    showSkippedPathsPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                        Text("\(scanner.skippedPaths.count) ignoradas")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .help("Pastas que não foram escaneadas")
                .popover(isPresented: $showSkippedPathsPopover, arrowEdge: .top) {
                    skippedPathsPopover
                }
            }

            Spacer()

            Toggle(isOn: $skipDevDirs) {
                Text("Ignorar node_modules / .git / build")
                    .font(.system(size: 10))
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .onChange(of: skipDevDirs) { _, newValue in
                ConfigStore.shared.diskAnalyzerSkipDevDirs = newValue
                scanner.skipDevDirectories = newValue
                focusedNode = nil
                scanner.scan(URL(fileURLWithPath: directory))
            }

            if let node = displayNode, node.id != rootNode?.id {
                Text(node.url.path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Button {
                focusedNode = nil
                scanner.scan(URL(fileURLWithPath: directory))
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reescanear")
            .disabled(scanner.state.isScanning)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
    }

    private var skippedPathsPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pastas ignoradas")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(scanner.skippedPaths.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text("Aceleram drasticamente o scan. Desmarque o checkbox para incluí-las.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(scanner.skippedPaths.prefix(50), id: \.self) { path in
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if scanner.skippedPaths.count > 50 {
                        Text("… e mais \(scanner.skippedPaths.count - 50)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 380)
    }

    // MARK: - Navigation

    private func navigateUp() {
        guard let current = focusedNode, let parent = current.parent else {
            focusedNode = nil
            return
        }
        focusedNode = parent.id == rootNode?.id ? nil : parent
    }
}
