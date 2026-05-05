import SwiftUI

// MARK: - Grouping

/// One group of history entries that all came from the same tab. Used to render
/// collapsible sections in the panel/modal so the user can see "Histórico desta aba"
/// and not just a flat firehose of every message ever sent.
struct HistoryGroup: Identifiable {
    let id: String
    let tabId: UUID?
    /// Primary heading shown for this group. Prefers the LLM-generated
    /// conversation title (ChatGPT-style); falls back to the tab name.
    let title: String
    /// Whether `title` came from the LLM titler. Drives the small "✨" badge.
    let titleFromLLM: Bool
    /// Tab name (current or last-known). Always populated; useful for the
    /// secondary line under the conversation title.
    let tabName: String
    let entries: [HistoryEntry]    // newest first

    var lastActivity: Date { entries.first?.timestamp ?? .distantPast }
    var firstActivity: Date { entries.last?.timestamp ?? .distantPast }
    var count: Int { entries.count }

    var subtitle: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(lastActivity) {
            formatter.dateFormat = "HH:mm"
            return "Hoje · \(formatter.string(from: lastActivity))"
        }
        if calendar.isDateInYesterday(lastActivity) {
            formatter.dateFormat = "HH:mm"
            return "Ontem · \(formatter.string(from: lastActivity))"
        }
        formatter.dateFormat = "dd/MM HH:mm"
        return formatter.string(from: lastActivity)
    }
}

enum HistoryGrouper {
    /// Groups entries by `tabId`, preserving most-recent-activity ordering and
    /// resolving the displayed tab title to whatever the active tab is named
    /// today (falls back to whatever was saved in the entry). Optionally
    /// resolves an LLM-generated conversation title via `conversationTitles`.
    static func group(
        entries: [HistoryEntry],
        currentTabTitles: [UUID: String],
        conversationTitles: [UUID: String] = [:]
    ) -> [HistoryGroup] {
        var buckets: [String: [HistoryEntry]] = [:]
        var order: [String] = []

        for entry in entries.reversed() {  // newest first
            let key = entry.tabId?.uuidString ?? "__legacy__"
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(entry)
        }

        return order.compactMap { key -> HistoryGroup? in
            guard let bucket = buckets[key], !bucket.isEmpty else { return nil }
            let tabId = bucket.first?.tabId
            let tabName: String = {
                if let tabId, let live = currentTabTitles[tabId] { return live }
                if let saved = bucket.first?.tabTitle, !saved.isEmpty { return saved }
                return "Aba removida"
            }()
            let llmTitle: String? = {
                guard let tabId, let t = conversationTitles[tabId], !t.isEmpty else { return nil }
                return t
            }()
            let title = llmTitle ?? tabName
            return HistoryGroup(
                id: key,
                tabId: tabId,
                title: title,
                titleFromLLM: llmTitle != nil,
                tabName: tabName,
                entries: bucket
            )
        }
    }
}

struct HistoryPanelView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var titleStore = ConversationTitleStore.shared
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

    private var groups: [HistoryGroup] {
        let titles = Dictionary(uniqueKeysWithValues: appState.tabs.map { ($0.id, $0.title) })
        let convTitles = titleStore.titles.reduce(into: [UUID: String]()) { acc, kv in
            acc[kv.key] = kv.value.title
        }
        return HistoryGrouper.group(
            entries: appState.history,
            currentTabTitles: titles,
            conversationTitles: convTitles
        )
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
                LazyVStack(spacing: 4, pinnedViews: []) {
                    ForEach(groups) { group in
                        HistoryGroupSection(
                            group: group,
                            isActiveTab: group.tabId == appState.activeTabId,
                            onReplay: onReplay
                        )
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
    @ObservedObject private var titleStore = ConversationTitleStore.shared
    @Environment(\.dismiss) private var dismiss
    let onReplay: (HistoryEntry) -> Void

    @State private var searchText = ""

    private func matches(_ entry: HistoryEntry, query: String) -> Bool {
        if query.isEmpty { return true }
        let q = query.lowercased()
        if entry.userInput.lowercased().contains(q) { return true }
        if entry.commands.joined(separator: " ").lowercased().contains(q) { return true }
        if (entry.summary ?? "").lowercased().contains(q) { return true }
        if (entry.tabTitle ?? "").lowercased().contains(q) { return true }
        return false
    }

    private var groups: [HistoryGroup] {
        let titles = Dictionary(uniqueKeysWithValues: appState.tabs.map { ($0.id, $0.title) })
        let convTitles = titleStore.titles.reduce(into: [UUID: String]()) { acc, kv in
            acc[kv.key] = kv.value.title
        }
        let filtered = appState.history.filter { matches($0, query: searchText) }
        return HistoryGrouper.group(
            entries: filtered,
            currentTabTitles: titles,
            conversationTitles: convTitles
        )
    }

    private var totalEntries: Int {
        groups.reduce(0) { $0 + $1.count }
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

                Text("\(totalEntries) em \(groups.count) aba(s)")
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
                TextField("Buscar no histórico (mensagem, comando, aba)...", text: $searchText)
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
                LazyVStack(spacing: 8) {
                    ForEach(groups) { group in
                        HistoryGroupSection(
                            group: group,
                            isActiveTab: group.tabId == appState.activeTabId,
                            onReplay: { entry in
                                onReplay(entry)
                                dismiss()
                            }
                        )
                    }
                    if groups.isEmpty {
                        Text(searchText.isEmpty ? "Nenhuma entrada" : "Nada encontrado para \"\(searchText)\"")
                            .font(.system(size: 12))
                            .foregroundColor(NexTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
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

// MARK: - Collapsible group section

struct HistoryGroupSection: View {
    let group: HistoryGroup
    let isActiveTab: Bool
    let onReplay: (HistoryEntry) -> Void

    @State private var isExpanded: Bool
    @State private var copiedAll: Bool = false

    init(group: HistoryGroup, isActiveTab: Bool, onReplay: @escaping (HistoryEntry) -> Void) {
        self.group = group
        self.isActiveTab = isActiveTab
        self.onReplay = onReplay
        // Auto-expand the active tab; collapse everything else by default to
        // keep the panel readable even after dozens of sessions.
        _isExpanded = State(initialValue: isActiveTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(group.entries) { entry in
                        HistoryRowView(entry: entry, onReplay: { onReplay(entry) })
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 6)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 12)
                        .padding(.top, 2)

                    Image(systemName: isActiveTab ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle")
                        .font(.system(size: 10))
                        .foregroundColor(isActiveTab ? .accentColor : NexTheme.textSecondary)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if group.titleFromLLM {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 8))
                                    .foregroundColor(.accentColor.opacity(0.85))
                            }
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(NexTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if group.titleFromLLM, group.tabName != group.title {
                            Text(group.tabName)
                                .font(.system(size: 9))
                                .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                copyAll()
            } label: {
                Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(copiedAll ? .green : NexTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(NexTheme.surface.opacity(copiedAll ? 0.8 : 0.5))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copiedAll ? "Copiado!" : "Copiar toda a conversa (\(group.count) turnos) para a área de transferência")

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(group.count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(NexTheme.surface)
                    .cornerRadius(4)
                Text(group.subtitle)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActiveTab ? NexTheme.accentDim.opacity(0.4) : Color.clear)
        )
    }

    private func copyAll() {
        let text = HistoryGroupExporter.export(group: group)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedAll = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedAll = false
        }
    }
}

// MARK: - Group Exporter (consolidated context for analysis)

enum HistoryGroupExporter {
    /// Serializes a whole conversation group into a single, LLM-friendly
    /// markdown blob so the user can paste it into ChatGPT/Claude/etc. and
    /// analyse multiple turns at once.
    static func export(group: HistoryGroup) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"

        // We display newest-first in the UI; for analysis, oldest-first reads
        // far better, so we reverse here.
        let entries = group.entries.reversed()

        var out = ""
        out += "# \(group.title)\n"
        if group.titleFromLLM, group.tabName != group.title {
            out += "_Aba: \(group.tabName)_\n"
        }
        out += "_Turnos: \(group.count) · Início: \(formatter.string(from: group.firstActivity)) · Fim: \(formatter.string(from: group.lastActivity))_\n\n"
        out += "---\n\n"

        for (idx, entry) in entries.enumerated() {
            let n = idx + 1
            out += "## Turno \(n)/\(group.count) — \(formatter.string(from: entry.timestamp))\n\n"

            out += "### Pedido do usuário\n"
            out += entry.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            out += "\n\n"

            if let plan = entry.plan {
                let planTitle = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let planExp = plan.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                if !planTitle.isEmpty || !planExp.isEmpty {
                    out += "### Plano do agente\n"
                    if !planTitle.isEmpty { out += "**\(planTitle)**\n\n" }
                    if !planExp.isEmpty { out += planExp + "\n\n" }
                }
            }

            if !entry.commands.isEmpty {
                out += "### Comandos\n"
                out += "```bash\n"
                for cmd in entry.commands {
                    out += cmd + "\n"
                }
                out += "```\n\n"
            }

            if let outputs = entry.stepOutputs, !outputs.isEmpty {
                out += "### Execução\n"
                for (i, step) in outputs.enumerated() {
                    out += "**Passo \(i + 1)** · `$ \(step.command)` · exit \(step.exitCode)\n"
                    if !step.stdout.isEmpty {
                        out += "```\n\(step.stdout.trimmingCharacters(in: .whitespacesAndNewlines))\n```\n"
                    }
                    if !step.stderr.isEmpty {
                        out += "_stderr:_\n```\n\(step.stderr.trimmingCharacters(in: .whitespacesAndNewlines))\n```\n"
                    }
                    out += "\n"
                }
            }

            if let summary = entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                out += "### Resultado\n"
                out += summary + "\n\n"
            }

            out += "---\n\n"
        }

        return out
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
