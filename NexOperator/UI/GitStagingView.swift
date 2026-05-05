import SwiftUI
import UniformTypeIdentifiers

private let gitFileUTType = UTType(exportedAs: "com.nexia.nexoperator.gitfile")

struct GitStagingView: View {
    @ObservedObject var viewModel: GitViewModel
    @EnvironmentObject var appState: AppState
    @State private var selectedUnstaged: Set<String> = []
    @State private var selectedStaged: Set<String> = []
    @State private var lastClickedUnstaged: String?
    @State private var lastClickedStaged: String?
    @State private var unstagedDropTargeted = false
    @State private var stagedDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            stagingHeader
            Divider()

            HStack(spacing: 0) {
                unstagedPanel
                Divider()
                stagedPanel
            }

            Divider()
            commitBar
        }
        .background(NexTheme.bg)
        .sheet(isPresented: $viewModel.isShowingDiff) {
            if let diff = viewModel.selectedFileDiff {
                GitDiffView(diff: diff) {
                    viewModel.closeDiff()
                }
            }
        }
    }

    // MARK: - Header

    private var stagingHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: NexTheme.iconSizeSmall))
                .foregroundColor(NexTheme.accent)
            Text("Staging Area")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NexTheme.textPrimary)

            Spacer()

            Text("Arraste arquivos entre painéis ou use Shift/⌘+Click para multi-select")
                .font(.system(size: 9))
                .foregroundColor(NexTheme.textSecondary.opacity(0.5))

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Unstaged Panel

    private var unstagedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Unstaged (\(viewModel.unstagedFiles.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)
                Spacer()
                if !selectedUnstaged.isEmpty {
                    Button("Stage \(selectedUnstaged.count) sel.") {
                        stageSelected()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                Button("Stage All") {
                    Task { await viewModel.stageAll() }
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundColor(NexTheme.accent)
                .disabled(viewModel.unstagedFiles.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            if viewModel.unstagedFiles.isEmpty && !unstagedDropTargeted {
                emptyState("Nenhum arquivo modificado")
            } else {
                fileList(
                    files: viewModel.unstagedFiles,
                    selectedIds: $selectedUnstaged,
                    lastClicked: $lastClickedUnstaged,
                    isStaged: false
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .stroke(unstagedDropTargeted ? Color.orange.opacity(0.6) : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.utf8PlainText], isTargeted: $unstagedDropTargeted) { providers in
            handleDrop(providers: providers, targetIsStaged: false)
            return true
        }
    }

    // MARK: - Staged Panel

    private var stagedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Staged (\(viewModel.stagedFiles.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)
                Spacer()
                if !selectedStaged.isEmpty {
                    Button("Unstage \(selectedStaged.count) sel.") {
                        unstageSelected()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Button("Unstage All") {
                    Task { await viewModel.unstageAll() }
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundColor(.orange)
                .disabled(viewModel.stagedFiles.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            if viewModel.stagedFiles.isEmpty && !stagedDropTargeted {
                dropZoneEmptyState("Arraste arquivos aqui para stage")
            } else {
                fileList(
                    files: viewModel.stagedFiles,
                    selectedIds: $selectedStaged,
                    lastClicked: $lastClickedStaged,
                    isStaged: true
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .stroke(stagedDropTargeted ? NexTheme.accent.opacity(0.6) : Color.clear, lineWidth: 2)
        )
        .onDrop(of: [.utf8PlainText], isTargeted: $stagedDropTargeted) { providers in
            handleDrop(providers: providers, targetIsStaged: true)
            return true
        }
    }

    // MARK: - File List with Multi-Select + Drag

    private func fileList(
        files: [GitFileStatus],
        selectedIds: Binding<Set<String>>,
        lastClicked: Binding<String?>,
        isStaged: Bool
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    DraggableFileRow(
                        file: file,
                        isSelected: selectedIds.wrappedValue.contains(file.id),
                        allFiles: files,
                        selectedIds: selectedIds,
                        dragPayload: buildDragPayload(
                            file: file,
                            allFiles: files,
                            selectedIds: selectedIds.wrappedValue,
                            isStaged: isStaged
                        ),
                        fileURL: URL(fileURLWithPath: viewModel.repoPath)
                            .appendingPathComponent(file.path),
                        onTap: { event in
                            handleClick(
                                file: file,
                                index: index,
                                allFiles: files,
                                event: event,
                                selectedIds: selectedIds,
                                lastClicked: lastClicked
                            )
                        },
                        onDoubleTap: {
                            if isStaged {
                                Task { await viewModel.unstageFiles([file]) }
                            } else {
                                Task { await viewModel.stageFiles([file]) }
                            }
                        },
                        onViewDiff: {
                            Task { await viewModel.loadDiff(for: file, staged: isStaged) }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Click Handling (Shift + Cmd support)

    private func handleClick(
        file: GitFileStatus,
        index: Int,
        allFiles: [GitFileStatus],
        event: ClickModifiers,
        selectedIds: Binding<Set<String>>,
        lastClicked: Binding<String?>
    ) {
        if event.shift, let lastId = lastClicked.wrappedValue,
           let lastIndex = allFiles.firstIndex(where: { $0.id == lastId }) {
            let range = min(lastIndex, index)...max(lastIndex, index)
            let rangeIds = Set(range.map { allFiles[$0].id })
            if event.command {
                selectedIds.wrappedValue.formUnion(rangeIds)
            } else {
                selectedIds.wrappedValue = rangeIds
            }
        } else if event.command {
            if selectedIds.wrappedValue.contains(file.id) {
                selectedIds.wrappedValue.remove(file.id)
            } else {
                selectedIds.wrappedValue.insert(file.id)
            }
        } else {
            selectedIds.wrappedValue = [file.id]
        }
        lastClicked.wrappedValue = file.id
    }

    // MARK: - Drag Payload

    private func buildDragPayload(
        file: GitFileStatus,
        allFiles: [GitFileStatus],
        selectedIds: Set<String>,
        isStaged: Bool
    ) -> String {
        let source = isStaged ? "staged" : "unstaged"
        if selectedIds.contains(file.id) && selectedIds.count > 1 {
            let paths = allFiles.filter { selectedIds.contains($0.id) }.map(\.path)
            return "\(source):\(paths.joined(separator: "\n"))"
        }
        return "\(source):\(file.path)"
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider], targetIsStaged: Bool) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier, options: nil) { data, _ in
                guard let data = data as? Data, let payload = String(data: data, encoding: .utf8) else { return }

                let parts = payload.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return }
                let source = String(parts[0])
                let paths = String(parts[1]).components(separatedBy: "\n")

                guard (source == "unstaged" && targetIsStaged) || (source == "staged" && !targetIsStaged) else { return }

                Task { @MainActor in
                    if targetIsStaged {
                        await viewModel.stagePaths(paths)
                        selectedUnstaged.removeAll()
                    } else {
                        await viewModel.unstagePaths(paths)
                        selectedStaged.removeAll()
                    }
                }
            }
        }
    }

    // MARK: - Batch Actions

    private func stageSelected() {
        let files = viewModel.unstagedFiles.filter { selectedUnstaged.contains($0.id) }
        Task {
            await viewModel.stageFiles(files)
            selectedUnstaged.removeAll()
        }
    }

    private func unstageSelected() {
        let files = viewModel.stagedFiles.filter { selectedStaged.contains($0.id) }
        Task {
            await viewModel.unstageFiles(files)
            selectedStaged.removeAll()
        }
    }

    // MARK: - Commit Bar

    private var commitBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Mensagem do commit...", text: $viewModel.commitMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(NexTheme.surface)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(NexTheme.border, lineWidth: 0.5)
                    )
                    .onSubmit {
                        Task { await viewModel.commitChanges() }
                    }

                aiGenerateButton
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            HStack(spacing: 6) {
                Button {
                    Task { await viewModel.commitChanges() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: NexTheme.iconSizeSmall))
                        Text("Commit")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(commitDisabled ? Color.gray.opacity(0.5) : NexTheme.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(commitDisabled)
                .cursorOnHover(.pointingHand)
                .help("Commit local (⌘↩)")

                Button {
                    Task { await viewModel.commitAndPush() }
                } label: {
                    HStack(spacing: 3) {
                        if viewModel.isCommitPushing {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: NexTheme.iconSizeSmall))
                        }
                        Text("Commit & Push")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(commitDisabled || viewModel.isCommitPushing
                                  ? Color.gray.opacity(0.5)
                                  : Color.green)
                    )
                }
                .buttonStyle(.plain)
                .disabled(commitDisabled || viewModel.isCommitPushing)
                .cursorOnHover(.pointingHand)
                .help("Commit + Push")

                Button {
                    Task { await viewModel.push() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(NexTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Push")
                .cursorOnHover(.pointingHand)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(NexTheme.surface)
    }

    private var commitDisabled: Bool {
        viewModel.stagedFiles.isEmpty || viewModel.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var aiGenerateButton: some View {
        Button {
            guard let tab = appState.activeTab else { return }
            Task {
                await viewModel.generateCommitMessage(
                    router: appState.modelRouter,
                    provider: tab.provider,
                    model: tab.model
                )
            }
        } label: {
            HStack(spacing: 3) {
                if viewModel.isGeneratingMessage {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: NexTheme.iconSizeSmall))
                }
                Text("IA")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(viewModel.isGeneratingMessage ? NexTheme.textSecondary : NexTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(NexTheme.accent.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(NexTheme.accent.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.stagedFiles.isEmpty || viewModel.isGeneratingMessage)
        .cursorOnHover(.pointingHand)
        .help("Gerar mensagem de commit com IA")
    }

    // MARK: - Empty States

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dropZoneEmptyState(_ text: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "arrow.right.doc.on.clipboard")
                .font(.system(size: 20))
                .foregroundColor(NexTheme.textSecondary.opacity(0.3))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Click Modifiers

struct ClickModifiers {
    let shift: Bool
    let command: Bool
}

// MARK: - Draggable File Row

struct DraggableFileRow: View {
    let file: GitFileStatus
    let isSelected: Bool
    let allFiles: [GitFileStatus]
    let selectedIds: Binding<Set<String>>
    let dragPayload: String
    /// Absolute URL of the file on disk, used so the drag is recognized by
    /// external apps (Finder, Mail, Slack, ...) — without this, dragging out
    /// of the app would fail because only the internal NSString payload was
    /// registered. We register both: file-url for external apps and the
    /// existing utf8PlainText payload for staged↔unstaged drops within the app.
    let fileURL: URL?
    let onTap: (ClickModifiers) -> Void
    let onDoubleTap: () -> Void
    let onViewDiff: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : file.status.icon)
                .font(.system(size: 10))
                .foregroundColor(isSelected ? NexTheme.accent : file.status.color)
                .frame(width: 14)

            Text(file.fileName)
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if isHovered {
                Button {
                    onViewDiff()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Ver diff")
            }

            Text(file.path)
                .font(.system(size: 9))
                .foregroundColor(NexTheme.textSecondary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 120, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected
                    ? NexTheme.accentDim
                    : isHovered ? NexTheme.surfaceHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onDrag {
            let provider = NSItemProvider()
            // Register file-url FIRST so external apps prefer it; the internal
            // drop handlers explicitly ask for utf8PlainText, so they are not
            // affected by this preference.
            if let url = fileURL,
               FileManager.default.fileExists(atPath: url.path) {
                provider.registerObject(url as NSURL, visibility: .all)
            }
            provider.registerObject(dragPayload as NSString, visibility: .all)
            return provider
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onDoubleTap() }
        )
        .simultaneousGesture(
            TapGesture(count: 1).modifiers(.shift).onEnded {
                onTap(ClickModifiers(shift: true, command: false))
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).modifiers(.command).onEnded {
                onTap(ClickModifiers(shift: false, command: true))
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                onTap(ClickModifiers(shift: false, command: false))
            }
        )
        .contextMenu {
            Button("Ver Diff") { onViewDiff() }
            Divider()
            Button("Stage/Unstage") { onDoubleTap() }
            if selectedIds.wrappedValue.count > 1 && isSelected {
                Button("Stage/Unstage \(selectedIds.wrappedValue.count) selecionados") {
                    onDoubleTap()
                }
            }
        }
    }
}
