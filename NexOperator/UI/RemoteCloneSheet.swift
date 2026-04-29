import SwiftUI

struct RemoteCloneSheet: View {
    @ObservedObject var viewModel: RemoteExplorerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var newFolderName = ""
    @State private var isCreatingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            VStack(spacing: 16) {
                folderSelector
                repoList

                if viewModel.isCloningInProgress {
                    cloneProgress
                }
            }
            .padding(16)

            Divider()
            sheetFooter
        }
        .frame(minWidth: 550, minHeight: 400)
        .background(NexTheme.bg)
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14))
                .foregroundColor(NexTheme.accent)
            Text("Clonar Repositórios")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(NexTheme.textPrimary)

            Spacer()

            Text("\(viewModel.cloneRequests.count) repositórios")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NexTheme.surface)
    }

    // MARK: - Folder Selector

    private var folderSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PASTA DESTINO")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)

            HStack(spacing: 8) {
                TextField("Caminho da pasta", text: $viewModel.cloneBasePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Button {
                    selectFolder()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                }
                .help("Escolher pasta")

                Button {
                    isCreatingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                }
                .help("Criar nova pasta")
            }

            if isCreatingFolder {
                HStack(spacing: 6) {
                    TextField("Nome da nova pasta", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { createFolder() }

                    Button("Criar") { createFolder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(newFolderName.isEmpty)

                    Button("Cancelar") {
                        isCreatingFolder = false
                        newFolderName = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                }
            }

            if !viewModel.cloneBasePath.isEmpty {
                let exists = FileManager.default.fileExists(atPath: viewModel.cloneBasePath)
                HStack(spacing: 4) {
                    Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(exists ? .green : .red)
                    Text(exists ? "Pasta existe" : "Pasta não encontrada")
                        .font(.system(size: 9))
                        .foregroundColor(exists ? .green : .red)
                }
            }
        }
    }

    // MARK: - Repo List

    private var repoList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REPOSITÓRIOS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(viewModel.cloneRequests) { request in
                        CloneRepoRow(request: request)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(NexTheme.surface)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(NexTheme.border, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Progress

    private var cloneProgress: some View {
        VStack(spacing: 6) {
            let total = viewModel.cloneRequests.count
            let done = viewModel.cloneRequests.filter { req in
                if req.status == .completed { return true }
                if case .failed = req.status { return true }
                return false
            }.count

            ProgressView(value: Double(done), total: Double(total))
                .progressViewStyle(.linear)

            Text("Clonando \(done)/\(total)...")
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary)
        }
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack {
            Button("Cancelar") {
                dismiss()
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                Task { await viewModel.startClone() }
            } label: {
                HStack(spacing: 4) {
                    if viewModel.isCloningInProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                    }
                    Text(viewModel.isCloningInProgress ? "Clonando..." : "Iniciar Clone")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.cloneBasePath.isEmpty || viewModel.isCloningInProgress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Selecionar"
        panel.message = "Escolha a pasta destino para os repositórios"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.cloneBasePath = url.path
        }
    }

    private func createFolder() {
        guard !newFolderName.isEmpty else { return }
        let path = "\(viewModel.cloneBasePath)/\(newFolderName)"
        if viewModel.createDirectory(at: path) {
            viewModel.cloneBasePath = path
            isCreatingFolder = false
            newFolderName = ""
        }
    }
}

// MARK: - Clone Repo Row

struct CloneRepoRow: View {
    let request: CloneRequest

    var body: some View {
        HStack(spacing: 8) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(request.repository.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)

                if !request.destinationPath.isEmpty {
                    Text(request.destinationPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if case .failed(let msg) = request.status {
                Text(msg)
                    .font(.system(size: 9))
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .frame(maxWidth: 150)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch request.status {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary)
        case .cloning:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
        }
    }
}
