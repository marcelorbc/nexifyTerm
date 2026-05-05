import SwiftUI

/// Sheet for branch cleanup: lists branches already merged into the target
/// branch and branches that are stale (no commits for N days). Allows bulk
/// delete with a single confirmation.
struct GitBranchHygieneView: View {
    @ObservedObject var viewModel: GitViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var mergedTarget: String = "main"
    @State private var staleDaysThreshold: Int = 60
    @State private var merged: [String] = []
    @State private var ageList: [GitService.BranchAge] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var selectedMerged: Set<String> = []
    @State private var selectedStale: Set<String> = []
    @State private var isBulkDeleting = false
    @State private var bulkSummary: (ok: Int, fail: Int, lastError: String?)?
    @State private var section: Section = .merged

    enum Section: String, CaseIterable, Identifiable {
        case merged = "Mergeadas"
        case stale = "Stale"
        var id: String { rawValue }
        var icon: String {
            self == .merged ? "checkmark.seal" : "clock.badge.exclamationmark"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controlsBar
            Divider()
            if isLoading {
                ProgressView("Calculando…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorText {
                errorState(err)
            } else {
                content
            }
            if let summary = bulkSummary {
                Divider()
                bulkBanner(summary: summary)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .background(NexTheme.bg)
        .task { await reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors")
                .font(.system(size: 14))
                .foregroundColor(NexTheme.accent)
            Text("Higiene de Branches")
                .font(.system(size: 14, weight: .bold))
            Text(viewModel.repoPath.components(separatedBy: "/").suffix(2).joined(separator: "/"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(NexTheme.textSecondary)
            Spacer()
            Button("Fechar") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    // MARK: - Controls

    private var controlsBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in
                    Label(s.rawValue, systemImage: s.icon).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            if section == .merged {
                HStack(spacing: 4) {
                    Text("em").font(.system(size: 11)).foregroundColor(NexTheme.textSecondary)
                    TextField("main", text: $mergedTarget, onCommit: { Task { await reload() } })
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 11, design: .monospaced))
                }
            } else {
                HStack(spacing: 4) {
                    Text("sem commit há").font(.system(size: 11)).foregroundColor(NexTheme.textSecondary)
                    Stepper("\(staleDaysThreshold)d", value: $staleDaysThreshold, in: 7...365, step: 7)
                        .font(.system(size: 11))
                }
            }

            Spacer()

            Button {
                Task { await reload() }
            } label: {
                Label("Atualizar", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                Task { await deleteSelected() }
            } label: {
                Label("Apagar selecionadas", systemImage: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.red.opacity(0.15))
                    .foregroundColor(.red)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .disabled(currentSelection.isEmpty || isBulkDeleting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch section {
        case .merged: mergedList
        case .stale:  staleList
        }
    }

    private var mergedList: some View {
        Group {
            if merged.isEmpty {
                emptyState(
                    icon: "checkmark.seal.fill",
                    title: "Nenhuma branch mergeada em \(mergedTarget)",
                    subtitle: "Tudo limpo — nada a remover."
                )
            } else {
                List(merged, id: \.self, selection: $selectedMerged) { name in
                    BranchHygieneRow(
                        name: name,
                        subtitle: "Mergeada em \(mergedTarget)",
                        isSelected: selectedMerged.contains(name),
                        toggle: { toggle(\.selectedMerged, value: name) }
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    private var staleList: some View {
        Group {
            let stales = ageList.filter { $0.daysSinceLastCommit >= staleDaysThreshold && !$0.isCurrent }
            if stales.isEmpty {
                emptyState(
                    icon: "clock.badge.checkmark",
                    title: "Nenhuma branch parada há \(staleDaysThreshold) dias",
                    subtitle: "Aumente o threshold ou rode em outros repos."
                )
            } else {
                List(stales, id: \.name, selection: $selectedStale) { ba in
                    BranchHygieneRow(
                        name: ba.name,
                        subtitle: "\(ba.daysSinceLastCommit)d · \(ba.lastCommitSubject.prefix(60))",
                        isSelected: selectedStale.contains(ba.name),
                        toggle: { toggle(\.selectedStale, value: ba.name) }
                    )
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Empty / error / banner

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(NexTheme.textSecondary.opacity(0.5))
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 10)).foregroundColor(NexTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 28))
                .foregroundColor(.red)
            Text("Falha ao carregar")
                .font(.system(size: 12, weight: .semibold))
            Text(msg)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(NexTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Tentar de novo") { Task { await reload() } }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bulkBanner(summary: (ok: Int, fail: Int, lastError: String?)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: summary.fail == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(summary.fail == 0 ? .green : .orange)
            Text("\(summary.ok) apagadas · \(summary.fail) erro\(summary.fail == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .semibold))
            if let err = summary.lastError {
                Text("último: \(err)")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { bulkSummary = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(NexTheme.surface)
    }

    // MARK: - Actions

    private var currentSelection: Set<String> {
        section == .merged ? selectedMerged : selectedStale
    }

    private func toggle<S>(_ kp: ReferenceWritableKeyPath<GitBranchHygieneView, S>, value: String) where S == Set<String> {
        // No-op placeholder; SwiftUI handles list selection automatically.
        // Kept to preserve row API symmetry with manual toggle styles.
        _ = kp
        _ = value
    }

    private func reload() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            async let mergedTask = viewModel.mergedBranchesList(target: mergedTarget)
            async let ageTask = viewModel.branchAgeList()
            let (m, a) = try await (mergedTask, ageTask)
            merged = m
            ageList = a
            // Drop stale selections that no longer exist.
            selectedMerged = selectedMerged.intersection(Set(m))
            let staleNames = Set(a.filter { $0.daysSinceLastCommit >= staleDaysThreshold }.map(\.name))
            selectedStale = selectedStale.intersection(staleNames)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func deleteSelected() async {
        let targets = currentSelection
        guard !targets.isEmpty else { return }

        isBulkDeleting = true
        defer { isBulkDeleting = false }

        var ok = 0
        var fail = 0
        var lastErr: String?
        for name in targets {
            do {
                try await viewModel.deleteBranchDirect(name)
                ok += 1
            } catch {
                fail += 1
                lastErr = "\(name): \(error.localizedDescription)"
            }
        }
        bulkSummary = (ok, fail, lastErr)
        if section == .merged {
            selectedMerged.removeAll()
        } else {
            selectedStale.removeAll()
        }
        await reload()
    }
}

// MARK: - Row

private struct BranchHygieneRow: View {
    let name: String
    let subtitle: String
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
