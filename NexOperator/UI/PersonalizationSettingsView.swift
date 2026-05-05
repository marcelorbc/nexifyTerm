import SwiftUI

/// Settings tab to manage all personalization layers, mirroring ChatGPT's model:
///   1. Personality / style baseline
///   2. Custom instructions (always-on)
///   3. Saved memories (persistent facts about the user)
///   4. Toggles for memory & chat-history reference + auto-capture
struct PersonalizationSettingsView: View {
    @ObservedObject var memoryStore = MemoryStore.shared
    @ObservedObject var systemProfileService = SystemProfileService.shared
    @ObservedObject var historyAnalyzer = HistoryAnalyzer.shared
    @EnvironmentObject var appState: AppState

    @State private var customInstructions: String = ""
    @State private var personalityStyle: PersonalityStyle = .direct
    @State private var memoryEnabled: Bool = true
    @State private var memoryAutoCapture: Bool = true
    @State private var referenceChatHistory: Bool = true
    @State private var systemProfileEnabled: Bool = true

    @State private var newMemoryContent: String = ""
    @State private var newMemoryCategory: MemoryCategory = .preference

    @State private var editingMemory: UserMemory?
    @State private var memoryToDelete: UserMemory?
    @State private var showClearAllConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                styleSection
                customInstructionsSection
                memoryTogglesSection
                addMemorySection
                memoriesListSection
                systemProfileSection
                historyInsightsSection
                dangerSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NexTheme.bg)
        .onAppear {
            load()
            // First-time analysis if cache is empty.
            if historyAnalyzer.report.isEmpty {
                historyAnalyzer.scheduleAnalysis(entries: appState.history, delay: 0.2)
            }
        }
        .sheet(item: $editingMemory) { mem in
            MemoryEditorView(memory: mem) { updated in
                memoryStore.update(updated)
                editingMemory = nil
            } onCancel: {
                editingMemory = nil
            }
        }
        .alert("Limpar todas as memórias?", isPresented: $showClearAllConfirm) {
            Button("Cancelar", role: .cancel) {}
            Button("Limpar tudo", role: .destructive) {
                memoryStore.clearAll()
            }
        } message: {
            Text("Esta ação não pode ser desfeita. As instruções personalizadas e o estilo permanecem.")
        }
        .alert("Excluir memória?", isPresented: Binding(
            get: { memoryToDelete != nil },
            set: { if !$0 { memoryToDelete = nil } }
        )) {
            Button("Cancelar", role: .cancel) { memoryToDelete = nil }
            Button("Excluir", role: .destructive) {
                if let mem = memoryToDelete { memoryStore.remove(id: mem.id) }
                memoryToDelete = nil
            }
        } message: {
            if let mem = memoryToDelete {
                Text("\"\(mem.content.prefix(120))\"")
            }
        }
    }

    // MARK: - Sections

    private var styleSection: some View {
        section(title: "Personalidade / Estilo", icon: "wand.and.sparkles", caption: "Define o tom base usado em todas as respostas. Combina com memórias e instruções.") {
            Picker("Estilo", selection: $personalityStyle) {
                ForEach(PersonalityStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: personalityStyle) { _, newValue in
                appState.configStore.personalityStyle = newValue
            }

            Text(personalityStyle.description)
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
                .padding(.top, 2)
        }
    }

    private var customInstructionsSection: some View {
        section(
            title: "Instruções Personalizadas",
            icon: "text.alignleft",
            caption: "Regras fixas que o agente sempre considera. Ex: \"Responda em pt-BR, prefira código completo, raciocine como CTO.\""
        ) {
            TextEditor(text: $customInstructions)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 180)
                .padding(6)
                .background(NexTheme.surface)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NexTheme.border, lineWidth: 0.5)
                )
                .onChange(of: customInstructions) { _, newValue in
                    appState.configStore.customInstructions = newValue
                }

            HStack {
                Text("\(customInstructions.count) caracteres")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                Spacer()
                if !customInstructions.isEmpty {
                    Button("Limpar") {
                        customInstructions = ""
                        appState.configStore.customInstructions = ""
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var memoryTogglesSection: some View {
        section(title: "Memória e Histórico", icon: "brain", caption: "Controle de quando e como o agente lembra de você entre conversas.") {
            Toggle("Memória ativada", isOn: $memoryEnabled)
                .toggleStyle(.switch)
                .onChange(of: memoryEnabled) { _, newValue in
                    appState.configStore.memoryEnabled = newValue
                }

            Toggle("Permitir captura automática (LLM identifica e salva)", isOn: $memoryAutoCapture)
                .toggleStyle(.switch)
                .disabled(!memoryEnabled)
                .onChange(of: memoryAutoCapture) { _, newValue in
                    appState.configStore.memoryAutoCapture = newValue
                }

            Toggle("Usar histórico desta aba como contexto", isOn: $referenceChatHistory)
                .toggleStyle(.switch)
                .onChange(of: referenceChatHistory) { _, newValue in
                    appState.configStore.referenceChatHistory = newValue
                }
        }
    }

    private var addMemorySection: some View {
        section(title: "Adicionar Memória", icon: "plus.circle", caption: "Adicione manualmente algo que o agente deve lembrar de você.") {
            HStack(spacing: 8) {
                Picker("", selection: $newMemoryCategory) {
                    ForEach(MemoryCategory.allCases) { cat in
                        Label(cat.label, systemImage: cat.icon).tag(cat)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)

                TextField("Ex: Prefiro respostas diretas em Markdown", text: $newMemoryContent)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Button {
                    addMemory()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return)
            }
        }
    }

    private var memoriesListSection: some View {
        section(
            title: "Memórias Salvas (\(memoryStore.memories.count))",
            icon: "tray.full",
            caption: "Memórias fixadas (📌) sobrevivem ao limite. Cliques: editar / fixar / excluir."
        ) {
            if memoryStore.memories.isEmpty {
                emptyMemoriesState
            } else {
                VStack(spacing: 4) {
                    ForEach(memoryStore.all()) { memory in
                        memoryRow(memory)
                    }
                }
            }
        }
    }

    private var emptyMemoriesState: some View {
        VStack(spacing: 6) {
            Image(systemName: "brain")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
            Text("Nenhuma memória salva")
                .font(.system(size: 12))
                .foregroundColor(NexTheme.textSecondary)
            Text("Adicione manualmente acima ou peça ao agente: \"lembre que prefiro X\"")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func memoryRow(_ memory: UserMemory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: memory.category.icon)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 24, height: 24)
                .background(NexTheme.accentDim)
                .cornerRadius(5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(memory.category.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NexTheme.textSecondary)
                    Text(memory.source.label)
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(NexTheme.surface)
                        .cornerRadius(3)
                    if memory.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    Text(formattedDate(memory.updatedAt))
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.6))
                }

                Text(memory.content)
                    .font(.system(size: 12))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 2) {
                Button {
                    memoryStore.togglePinned(id: memory.id)
                } label: {
                    Image(systemName: memory.pinned ? "pin.slash" : "pin")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(memory.pinned ? "Desafixar" : "Fixar")

                Button {
                    editingMemory = memory
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Editar")

                Button {
                    memoryToDelete = memory
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.7))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Excluir")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(NexTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(NexTheme.border, lineWidth: 0.5)
        )
    }

    private var systemProfileSection: some View {
        section(
            title: "Perfil do Sistema",
            icon: "macwindow.on.rectangle",
            caption: "Hardware, macOS e softwares detectados são injetados no prompt para o agente planejar com contexto real (sem precisar checar \"se está instalado\" toda hora)."
        ) {
            Toggle("Enviar perfil do sistema ao agente", isOn: $systemProfileEnabled)
                .toggleStyle(.switch)
                .onChange(of: systemProfileEnabled) { _, newValue in
                    appState.configStore.systemProfileEnabled = newValue
                }

            systemProfileSummary
        }
    }

    @ViewBuilder
    private var systemProfileSummary: some View {
        let profile = systemProfileService.profile

        if profile.isEmpty {
            HStack(spacing: 8) {
                if systemProfileService.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("Coletando informações do sistema…")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text("Perfil ainda não coletado.")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                }
                Spacer()
                Button {
                    systemProfileService.refresh(force: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                        Text("Coletar agora")
                            .font(.system(size: 11))
                    }
                }
                .controlSize(.small)
                .disabled(systemProfileService.isRefreshing)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                profileHeader(profile)
                profileToolsGrid(profile)
                profilePackageManagers(profile)
                profileFooter(profile)
            }
        }
    }

    private func profileHeader(_ profile: SystemProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11))
                Text(profileHeaderHardware(profile))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NexTheme.textPrimary)
            }
            HStack(spacing: 6) {
                Image(systemName: "applelogo")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11))
                Text(profileHeaderOS(profile))
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11))
                Text(profileHeaderShell(profile))
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NexTheme.surface)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(NexTheme.border, lineWidth: 0.5)
        )
    }

    private func profileHeaderHardware(_ profile: SystemProfile) -> String {
        let hw = profile.hardware
        var parts: [String] = []
        let chip = hw.chip.isEmpty ? hw.model : hw.chip
        if !chip.isEmpty { parts.append(chip) }
        if !hw.architecture.isEmpty { parts.append(hw.architecture) }
        if hw.physicalCores > 0 { parts.append("\(hw.physicalCores)P/\(hw.logicalCores)L cores") }
        if hw.memoryGB > 0 { parts.append("\(hw.memoryGB) GB RAM") }
        return parts.joined(separator: " · ")
    }

    private func profileHeaderOS(_ profile: SystemProfile) -> String {
        let os = profile.os
        var line = "\(os.name) \(os.version)"
        if !os.build.isEmpty { line += " (\(os.build))" }
        line += " · \(os.timezone)"
        return line
    }

    private func profileHeaderShell(_ profile: SystemProfile) -> String {
        let env = profile.shellEnv
        var line = env.defaultShell
        if env.pathHasHomebrew { line += " · Homebrew ✓" }
        if let editor = env.defaultEditor { line += " · EDITOR=\(editor)" }
        return line
    }

    @ViewBuilder
    private func profileToolsGrid(_ profile: SystemProfile) -> some View {
        let installed = profile.installedTools
        if installed.isEmpty {
            EmptyView()
        } else {
            let grouped = Dictionary(grouping: installed, by: { $0.category })
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SystemProfile.DetectedTool.Category.allCases, id: \.self) { cat in
                    if let items = grouped[cat], !items.isEmpty {
                        toolCategoryRow(cat: cat, tools: items)
                    }
                }
            }
        }
    }

    private func toolCategoryRow(cat: SystemProfile.DetectedTool.Category, tools: [SystemProfile.DetectedTool]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: cat.icon)
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
                Text(cat.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)
            }
            FlowLayout(spacing: 4) {
                ForEach(tools) { tool in
                    toolBadge(tool)
                }
            }
        }
    }

    private func toolBadge(_ tool: SystemProfile.DetectedTool) -> some View {
        HStack(spacing: 4) {
            Text(tool.name)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
            if let v = tool.version, let short = shortenVersion(v) {
                Text(short)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(NexTheme.accentDim.opacity(0.5))
        .foregroundColor(NexTheme.accent)
        .cornerRadius(4)
    }

    private func shortenVersion(_ raw: String) -> String? {
        if let match = raw.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
            return String(raw[match])
        }
        return raw.count <= 18 ? raw : nil
    }

    @ViewBuilder
    private func profilePackageManagers(_ profile: SystemProfile) -> some View {
        if profile.packageManagers.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(profile.packageManagers) { pm in
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                        Text(pm.name)
                            .font(.system(size: 11, weight: .semibold))
                        if let v = pm.version {
                            Text("v\(v)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(NexTheme.textSecondary)
                        }
                        Text("\(pm.packagesCount) pacote(s)")
                            .font(.system(size: 10))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                }
            }
        }
    }

    private func profileFooter(_ profile: SystemProfile) -> some View {
        HStack {
            Text("Coletado em \(formattedDate(profile.collectedAt))")
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary)
            Spacer()
            if systemProfileService.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                systemProfileService.refresh(force: true)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("Atualizar")
                        .font(.system(size: 10))
                }
            }
            .controlSize(.small)
            .disabled(systemProfileService.isRefreshing)
        }
    }

    private var historyInsightsSection: some View {
        section(
            title: "Insights do Histórico",
            icon: "chart.bar.doc.horizontal",
            caption: "O agente analisa o próprio histórico para identificar padrões problemáticos (promessa sem execução, perda de contexto, comandos que falham repetidamente)."
        ) {
            historyHealthRow
            historyInsightsList
            historyAnalyzeRow
        }
    }

    private var historyHealthRow: some View {
        let s = historyAnalyzer.report.summary
        let total = historyAnalyzer.report.analyzedEntries
        return HStack(spacing: 14) {
            healthMetric(
                label: "Saúde",
                value: total == 0 ? "—" : "\(Int(s.successRate * 100))%",
                color: total == 0 ? .secondary : (s.successRate >= 0.8 ? .green : (s.successRate >= 0.5 ? .orange : .red))
            )
            healthMetric(
                label: "Cmds/turno",
                value: total == 0 ? "—" : String(format: "%.1f", s.avgCommandsPerTurn),
                color: .accentColor
            )
            healthMetric(
                label: "Promessas",
                value: total == 0 ? "—" : "\(Int(s.promiseRate * 100))%",
                color: s.promiseRate > 0.1 ? .red : .green
            )
            healthMetric(
                label: "Truncadas",
                value: total == 0 ? "—" : "\(Int(s.truncationRate * 100))%",
                color: s.truncationRate > 0.1 ? .orange : .green
            )
            Spacer()
        }
    }

    private func healthMetric(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(NexTheme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(NexTheme.surface)
        .cornerRadius(5)
    }

    @ViewBuilder
    private var historyInsightsList: some View {
        let insights = historyAnalyzer.report.insights
        if insights.isEmpty {
            HStack(spacing: 8) {
                if historyAnalyzer.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Text("Analisando histórico…")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                } else if appState.history.isEmpty {
                    Image(systemName: "tray")
                        .foregroundColor(NexTheme.textSecondary)
                        .font(.system(size: 11))
                    Text("Sem histórico para analisar ainda.")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                    Text("Nenhum padrão problemático detectado nas últimas \(historyAnalyzer.report.analyzedEntries) interações.")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                }
                Spacer()
            }
        } else {
            VStack(spacing: 6) {
                ForEach(insights) { insight in
                    insightRow(insight)
                }
            }
        }
    }

    private func insightRow(_ insight: HistoryInsight) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: insight.kind.icon)
                .font(.system(size: 12))
                .foregroundColor(insightColor(insight.severity))
                .frame(width: 24, height: 24)
                .background(insightColor(insight.severity).opacity(0.15))
                .cornerRadius(5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(insight.kind.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(NexTheme.textSecondary)
                    Text(insight.severity.label)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(insightColor(insight.severity).opacity(0.18))
                        .foregroundColor(insightColor(insight.severity))
                        .cornerRadius(3)
                    Text("×\(insight.occurrences)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                    Spacer()
                }
                Text(insight.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NexTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(insight.detail)
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(NexTheme.surface)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(insightColor(insight.severity).opacity(0.3), lineWidth: 0.5)
        )
    }

    private func insightColor(_ severity: HistoryInsight.Severity) -> Color {
        switch severity {
        case .info:     return .blue
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    private var historyAnalyzeRow: some View {
        HStack(spacing: 8) {
            if historyAnalyzer.report.generatedAt > .distantPast {
                Text("Última análise: \(formattedDate(historyAnalyzer.report.generatedAt))  ·  \(historyAnalyzer.report.analyzedEntries) interações")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
            }
            Spacer()
            if historyAnalyzer.isAnalyzing {
                ProgressView().controlSize(.small)
            }
            Button {
                historyAnalyzer.analyze(entries: appState.history)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("Re-analisar")
                        .font(.system(size: 11))
                }
            }
            .controlSize(.small)
            .disabled(historyAnalyzer.isAnalyzing)
        }
    }

    private var dangerSection: some View {
        section(title: "Zona de Risco", icon: "exclamationmark.triangle", caption: "Limpa todas as memórias. As instruções personalizadas e o estilo são preservados.") {
            HStack {
                Spacer()
                Button("Limpar todas as memórias", role: .destructive) {
                    showClearAllConfirm = true
                }
                .controlSize(.small)
                .disabled(memoryStore.memories.isEmpty)
            }
        }
    }

    // MARK: - Helpers

    private func load() {
        let config = appState.configStore
        customInstructions = config.customInstructions
        personalityStyle = config.personalityStyle
        memoryEnabled = config.memoryEnabled
        memoryAutoCapture = config.memoryAutoCapture
        referenceChatHistory = config.referenceChatHistory
        systemProfileEnabled = config.systemProfileEnabled
    }

    private func addMemory() {
        let trimmed = newMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        memoryStore.add(content: trimmed, category: newMemoryCategory, source: .manual)
        newMemoryContent = ""
    }

    private func formattedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM"
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        icon: String,
        caption: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(NexTheme.border, lineWidth: 0.5)
                    )
            )

            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Memory Editor Sheet

private struct MemoryEditorView: View {
    @State var memory: UserMemory
    let onSave: (UserMemory) -> Void
    let onCancel: () -> Void

    @State private var content: String = ""
    @State private var category: MemoryCategory = .fact
    @State private var pinned: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Editar Memória")
                    .font(.title3.bold())
                Spacer()
                Button("Cancelar") { onCancel() }
                    .keyboardShortcut(.escape)
                Button("Salvar") {
                    var updated = memory
                    updated.content = content
                    updated.category = category
                    updated.pinned = pinned
                    onSave(updated)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(content.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            LabeledContent("Categoria") {
                Picker("", selection: $category) {
                    ForEach(MemoryCategory.allCases) { cat in
                        Label(cat.label, systemImage: cat.icon).tag(cat)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 200)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Conteúdo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)
                TextEditor(text: $content)
                    .font(.system(size: 12))
                    .frame(minHeight: 100, maxHeight: 180)
                    .padding(6)
                    .background(NexTheme.surface)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(NexTheme.border, lineWidth: 0.5)
                    )
            }

            Toggle("Fixar (não será removida automaticamente)", isOn: $pinned)
                .toggleStyle(.switch)
        }
        .padding(20)
        .frame(width: 460, height: 360)
        .onAppear {
            content = memory.content
            category = memory.category
            pinned = memory.pinned
        }
    }
}

private extension MemorySource {
    var label: String {
        switch self {
        case .manual:   return "manual"
        case .explicit: return "pedido"
        case .auto:     return "auto"
        }
    }
}

// MARK: - FlowLayout

/// Simple wrap-flow container so tool badges break to a new line when they
/// don't fit horizontally. Available natively in SwiftUI 16+ but we re-implement
/// for macOS 14 compatibility.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let result = layout(in: maxWidth, subviews: subviews)
        return CGSize(width: maxWidth.isFinite ? maxWidth : result.maxX, height: result.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(width: result.sizes[index].width, height: result.sizes[index].height)
            )
        }
    }

    private struct LayoutResult {
        var positions: [CGPoint]
        var sizes: [CGSize]
        var totalHeight: CGFloat
        var maxX: CGFloat
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> LayoutResult {
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x)
        }

        let total = y + rowHeight
        return LayoutResult(positions: positions, sizes: sizes, totalHeight: total, maxX: maxX)
    }
}
