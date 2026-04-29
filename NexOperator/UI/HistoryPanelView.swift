import SwiftUI

struct HistoryPanelView: View {
    @EnvironmentObject var appState: AppState
    let onReplay: (HistoryEntry) -> Void
    let onClose: () -> Void

    @State private var panelWidth: CGFloat = 280
    @State private var showModal = false

    private let minWidth: CGFloat = 200
    private let maxWidth: CGFloat = 500

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                historyHeader
                Divider()
                historyContent
            }
            .frame(width: panelWidth)
            .background(Color(nsColor: .windowBackgroundColor))

            resizeHandle
        }
        .sheet(isPresented: $showModal) {
            HistoryModalView(onReplay: onReplay)
                .environmentObject(appState)
        }
    }

    private var historyHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            Text("Histórico")
                .font(.system(size: 12, weight: .semibold))

            Spacer()

            if !appState.history.isEmpty {
                Button {
                    appState.history.removeAll()
                    HistoryStore.shared.clear()
                } label: {
                    Text("Limpar")
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.borderless)
            }

            Button { showModal = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Expandir")

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .onTapGesture(count: 2) {
            showModal = true
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if appState.history.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "clock")
                    .font(.title2)
                    .foregroundColor(NexTheme.textSecondary.opacity(0.3))
                Text("Nenhum comando ainda")
                    .font(.caption)
                    .foregroundColor(NexTheme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(appState.history.reversed()) { entry in
                        HistoryRowView(entry: entry, onReplay: {
                            onReplay(entry)
                        })
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 5)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 2, height: 28)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newWidth = panelWidth + value.translation.width
                        panelWidth = min(maxWidth, max(minWidth, newWidth))
                    }
            )
            .cursorOnHover(.resizeLeftRight)
    }
}

struct HistoryModalView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let onReplay: (HistoryEntry) -> Void

    @State private var searchText = ""

    private var filtered: [HistoryEntry] {
        let reversed = appState.history.reversed()
        if searchText.isEmpty { return Array(reversed) }
        let q = searchText.lowercased()
        return reversed.filter {
            $0.userInput.lowercased().contains(q) ||
            $0.commands.joined(separator: " ").lowercased().contains(q) ||
            ($0.summary ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.accentColor)
                Text("Histórico Completo")
                    .font(.headline)
                    .foregroundColor(NexTheme.textPrimary)

                Spacer()

                Text("\(appState.history.count) entradas")
                    .font(.caption)
                    .foregroundColor(NexTheme.textSecondary)

                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(NexTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(NexTheme.textSecondary)
                TextField("Buscar no histórico...", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(NexTheme.textPrimary)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(NexTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(NexTheme.surface)
            .cornerRadius(8)
            .padding(.horizontal)

            Divider().padding(.top, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { entry in
                        HistoryRowView(entry: entry, onReplay: {
                            onReplay(entry)
                            dismiss()
                        })
                    }
                }
                .padding(8)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .frame(idealWidth: 750, idealHeight: 550)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct HistoryRowView: View {
    let entry: HistoryEntry
    let onReplay: () -> Void

    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var copied = false
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: entry.isAgent ? "sparkles" : "terminal")
                    .font(.system(size: 9))
                    .foregroundColor(entry.isAgent ? .accentColor : .secondary)
                    .frame(width: 14)

                Text(entry.userInput)
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(isExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(entry.timeFormatted)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.5))
            }

            if isExpanded {
                expandedContent
            }

            if let summary = entry.summary, !isExpanded {
                Text(summary)
                    .font(.system(size: 9))
                    .foregroundColor(entry.summary?.hasPrefix("Erro") == true ? .red.opacity(0.7) : NexTheme.accent.opacity(0.7))
                    .lineLimit(1)
                    .padding(.leading, 20)
            }

            HStack(spacing: 6) {
                Button { onReplay() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                        Text("Reenviar")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundColor(.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                Button { copyFullText() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(copied ? "Copiado!" : "Copiar")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundColor(copied ? .green : NexTheme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                if entry.hasOutputs {
                    Button { showDetail = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                                .font(.system(size: 9))
                            Text("Ver resultado")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundColor(NexTheme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()
            }
            .padding(.leading, 20)
            .padding(.top, 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHovered ? NexTheme.surfaceHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            showDetail = true
        }
        .onTapGesture(count: 1) {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        }
        .onHover { isHovered = $0 }
        .sheet(isPresented: $showDetail) {
            HistoryDetailView(entry: entry, onReplay: onReplay)
        }
    }

    private func copyFullText() {
        var text = entry.userInput
        if !entry.commands.isEmpty {
            text += "\n\nComandos:\n" + entry.commands.joined(separator: "\n")
        }
        if let summary = entry.summary {
            text += "\n\nResultado:\n" + summary
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !entry.commands.isEmpty {
                ForEach(entry.commands, id: \.self) { cmd in
                    HStack(spacing: 4) {
                        Text("$")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(NexTheme.accent.opacity(0.5))
                        Text(cmd)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(NexTheme.textSecondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, 16)
                }
            }

            if let summary = entry.summary {
                Text(summary)
                    .font(.system(size: 10))
                    .foregroundColor(entry.summary?.hasPrefix("Erro") == true ? .red.opacity(0.7) : NexTheme.accent.opacity(0.7))
                    .lineLimit(6)
                    .padding(.leading, 20)
                    .padding(.top, 2)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - History Detail Modal

struct HistoryDetailView: View {
    let entry: HistoryEntry
    let onReplay: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copiedAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    requestSection
                    if let outputs = entry.stepOutputs, !outputs.isEmpty {
                        stepsSection(outputs)
                    }
                    if let summary = entry.summary {
                        summarySection(summary)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 650, minHeight: 450)
        .frame(idealWidth: 800, idealHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isAgent ? "sparkles" : "terminal")
                .font(.title3)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Resultado da Execução")
                    .font(.headline)
                    .foregroundColor(NexTheme.textPrimary)
                Text(entry.dateFormatted)
                    .font(.caption)
                    .foregroundColor(NexTheme.textSecondary)
            }

            Spacer()

            Button { onReplay(); dismiss() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                    Text("Reenviar")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor)
                .foregroundColor(.black)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Button { copyAll() } label: {
                HStack(spacing: 4) {
                    Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                    Text(copiedAll ? "Copiado!" : "Copiar tudo")
                        .font(.system(size: 11))
                }
                .foregroundColor(copiedAll ? .green : NexTheme.textSecondary)
            }
            .buttonStyle(.plain)

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Solicitação", systemImage: "text.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)

            Text(entry.userInput)
                .font(.system(size: 13))
                .foregroundColor(NexTheme.textPrimary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NexTheme.surface)
                .cornerRadius(8)
        }
    }

    private func stepsSection(_ outputs: [HistoryStepOutput]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Passos Executados (\(outputs.count))", systemImage: "list.number")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)

            ForEach(Array(outputs.enumerated()), id: \.offset) { index, step in
                StepDetailCard(index: index, step: step)
            }
        }
    }

    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Resultado Final", systemImage: "checkmark.seal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)

            Text(summary)
                .font(.system(size: 12))
                .foregroundColor(summary.hasPrefix("Erro") ? .red.opacity(0.8) : NexTheme.accent)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NexTheme.surface)
                .cornerRadius(8)
        }
    }

    private func copyAll() {
        var text = "Solicitação: \(entry.userInput)\n"
        text += "Data: \(entry.dateFormatted)\n\n"

        if let outputs = entry.stepOutputs {
            for (i, step) in outputs.enumerated() {
                text += "--- Passo \(i + 1) ---\n"
                text += "$ \(step.command)\n"
                text += "Exit code: \(step.exitCode)\n"
                if !step.stdout.isEmpty { text += "stdout:\n\(step.stdout)\n" }
                if !step.stderr.isEmpty { text += "stderr:\n\(step.stderr)\n" }
                text += "\n"
            }
        }

        if let summary = entry.summary {
            text += "--- Resultado ---\n\(summary)\n"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedAll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedAll = false }
    }
}

struct StepDetailCard: View {
    let index: Int
    let step: HistoryStepOutput
    @State private var isExpanded = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(step.succeeded ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text("Passo \(index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)

                Text(step.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("exit \(step.exitCode)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(step.succeeded ? .green.opacity(0.7) : .red.opacity(0.7))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(step.truncatedOutput, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: NexTheme.iconSizeSmall))
                        .foregroundColor(copied ? .green : NexTheme.textSecondary)
                        .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: NexTheme.iconSizeSmall))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if isExpanded {
                Divider().opacity(0.2)

                VStack(alignment: .leading, spacing: 4) {
                    if !step.stdout.isEmpty {
                        Text(step.stdout)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(NexTheme.textPrimary.opacity(0.85))
                            .textSelection(.enabled)
                    }
                    if !step.stderr.isEmpty {
                        Text(step.stderr)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.red.opacity(0.75))
                            .textSelection(.enabled)
                    }
                    if step.stdout.isEmpty && step.stderr.isEmpty {
                        Text("(sem output)")
                            .font(.system(size: 10))
                            .foregroundColor(NexTheme.textSecondary.opacity(0.5))
                            .italic()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(NexTheme.surface)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(step.succeeded ? Color.green.opacity(0.15) : Color.red.opacity(0.15), lineWidth: 0.5)
        )
    }
}
