import SwiftUI
import AppKit

struct DirectoryPickerView: View {
    let defaultPath: String
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedPath: String = ""
    @State private var recentPaths: [String] = []

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Escolha a pasta do terminal")
                        .font(.headline)
                        .foregroundColor(NexTheme.textPrimary)
                    Text("Selecione onde o novo terminal deve iniciar")
                        .font(.caption)
                        .foregroundColor(NexTheme.textSecondary)
                }
                Spacer()
            }

            HStack {
                Image(systemName: "folder")
                    .foregroundColor(NexTheme.textSecondary)
                Text(selectedPath.isEmpty ? defaultPath : selectedPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Escolher...") {
                    openFolderPicker()
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(NexTheme.surface)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(NexTheme.border, lineWidth: 0.5)
            )

            if !recentPaths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recentes")
                        .font(.caption.bold())
                        .foregroundColor(NexTheme.textSecondary)

                    ForEach(recentPaths, id: \.self) { path in
                        Button {
                            selectedPath = path
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9))
                                    .foregroundColor(NexTheme.textSecondary)
                                Text(abbreviatePath(path))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(selectedPath == path ? NexTheme.accent : NexTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(selectedPath == path ? NexTheme.accentDim : Color.clear)
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            quickPaths

            HStack(spacing: 12) {
                Button("Cancelar") { onCancel() }
                    .keyboardShortcut(.escape)

                Spacer()

                Button("Usar padrão") {
                    onSelect(defaultPath)
                }
                .foregroundColor(NexTheme.textSecondary)

                Button {
                    let path = selectedPath.isEmpty ? defaultPath : selectedPath
                    saveRecent(path)
                    onSelect(path)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(.caption)
                        Text("Abrir Terminal")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.black)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(NexTheme.bg)
        .onAppear {
            selectedPath = defaultPath
            loadRecent()
        }
    }

    private var quickPaths: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Atalhos")
                .font(.caption.bold())
                .foregroundColor(NexTheme.textSecondary)

            HStack(spacing: 6) {
                quickButton("Home", path: FileManager.default.homeDirectoryForCurrentUser.path, icon: "house")
                quickButton("Desktop", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path, icon: "desktopcomputer")
                quickButton("Documents", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path, icon: "doc")
                quickButton("Downloads", path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path, icon: "arrow.down.circle")
                quickButton("/", path: "/", icon: "internaldrive")
            }
        }
    }

    private func quickButton(_ label: String, path: String, icon: String) -> some View {
        Button {
            selectedPath = path
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(selectedPath == path ? NexTheme.accentDim : NexTheme.surfaceHover)
            .foregroundColor(selectedPath == path ? NexTheme.accent : NexTheme.textSecondary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: selectedPath.isEmpty ? defaultPath : selectedPath)
        panel.prompt = "Selecionar"
        panel.message = "Escolha a pasta inicial do terminal"

        if panel.runModal() == .OK, let url = panel.url {
            selectedPath = url.path
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private let recentKey = "recentDirectories"

    private func loadRecent() {
        if let raw = NexPersistence.shared.getConfig(recentKey) {
            recentPaths = raw.components(separatedBy: "|").filter { !$0.isEmpty }.prefix(5).map { String($0) }
        }
    }

    private func saveRecent(_ path: String) {
        var paths = recentPaths.filter { $0 != path }
        paths.insert(path, at: 0)
        paths = Array(paths.prefix(5))
        NexPersistence.shared.setConfig(recentKey, value: paths.joined(separator: "|"))
    }
}
