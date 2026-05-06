import SwiftUI
import UniformTypeIdentifiers

struct InputBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var inputText = ""
    @State private var inputHistory: [String] = []
    @State private var historyIndex: Int = -1
    @State private var showQuickActions = false
    @State private var showSkillAutocomplete = false
    @State private var skillQuery = ""
    @State private var attachments: [FileAttachment] = []
    @State private var isDragOver = false
    @FocusState private var isFocused: Bool

    private var activeTabMode: TabMode {
        appState.activeTab?.tabMode ?? .terminal
    }

    private var detectedIntent: InputIntent {
        InputClassifier.classify(inputText, tabMode: activeTabMode)
    }

    private var isRunning: Bool { appState.isAgentRunning }
    private var isBrowserOpen: Bool { appState.browserURL != nil }

    @State private var inputAreaHeight: CGFloat = 34
    private let minInputHeight: CGFloat = 28
    private let maxInputHeight: CGFloat = 180

    private var placeholderText: String {
        if isBrowserOpen { return "Peça algo para o agente fazer no site..." }
        switch activeTabMode {
        case .git:
            return "Ex: \"gerar commit message\", \"o que mudou?\", \"push\"..."
        case .explorer:
            return "Ex: \"qual o maior arquivo?\", \"organize por tipo\"..."
        case .terminal:
            return "Pergunte algo à IA ou digite um comando..."
        case .mosaic:
            return "Pergunte algo à IA ou digite um comando..."
        case .diskAnalyzer:
            return "Pergunte sobre o uso de disco ou peça sugestões de limpeza..."
        case .whatsapp:
            return "Ex: \"resume esta conversa\", \"sugira uma resposta\"..."
        }
    }

    var body: some View {
        let _ = appState.tabStateVersion

        VStack(spacing: 0) {
            if showSkillAutocomplete && !isRunning {
                SkillAutocompleteView(query: skillQuery) { skill in
                    applySkill(skill)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showQuickActions && !isRunning {
                QuickActionsView(tabMode: activeTabMode) { prompt in
                    submitAI(prompt)
                    showQuickActions = false
                }
                .environmentObject(appState)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let error = appState.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(NexTheme.textSecondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(error, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: NexTheme.iconSizeSmall))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Copiar erro")

                    Button {
                        appState.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: NexTheme.iconSizeMedium))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.06))
            }

            VStack(spacing: 0) {
                if !attachments.isEmpty {
                    attachmentsPreview
                        .padding(.top, 4)
                        .padding(.horizontal, 10)
                }

                // Resize handle
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: 32, height: 3)
                    )
                    .contentShape(Rectangle().inset(by: -4))
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newH = inputAreaHeight - value.translation.height
                                inputAreaHeight = min(maxInputHeight, max(minInputHeight, newH))
                            }
                    )
                    .cursorOnHover(.resizeUpDown)

                HStack(alignment: .bottom, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if inputText.isEmpty && attachments.isEmpty {
                            Text(placeholderText)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary.opacity(0.45))
                                .padding(.top, 2)
                                .padding(.leading, 4)
                        }

                        GrowingTextEditor(
                            text: $inputText,
                            isFocused: $isFocused,
                            isDisabled: isRunning,
                            onSubmit: { submit() },
                            onUpArrow: { navigateHistory(direction: .up) },
                            onDownArrow: { navigateHistory(direction: .down) },
                            onEscape: {
                                if !attachments.isEmpty {
                                    withAnimation(.easeOut(duration: 0.12)) { attachments.removeAll() }
                                } else if showQuickActions {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        showQuickActions = false
                                    }
                                } else {
                                    inputText = ""
                                }
                            }
                        )
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .frame(height: inputAreaHeight)

                    inputActions
                        .padding(.trailing, 8)
                        .padding(.bottom, 6)
                }

                HStack(spacing: 4) {
                    inputToolbar
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .padding(.top, 2)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.1), radius: 4, y: -1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isFocused
                                    ? Color.accentColor.opacity(0.35)
                                    : NexTheme.border.opacity(0.5),
                                lineWidth: isFocused ? 1.5 : 0.5
                            )
                    )
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .padding(.top, 2)
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
                handleDrop(providers)
            }
            .overlay(
                isDragOver ? RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .padding(.top, 2)
                    : nil
            )
        }
        .animation(.easeInOut(duration: 0.15), value: showQuickActions)
        .animation(.easeInOut(duration: 0.12), value: showSkillAutocomplete)
        .onChange(of: inputText) { _, newValue in
            updateSkillAutocomplete(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusInputBar)) { _ in
            isFocused = true
        }
    }

    // MARK: - Bottom Toolbar (inside card, Cursor/Gemini style)

    @ViewBuilder
    private var inputToolbar: some View {
        if let tab = appState.activeTab {
            let availability = ProviderAvailabilityService.shared
            let providers = availability.availableProviders.isEmpty
                ? ProviderType.allCases
                : availability.availableProviders
            let models = availability.availableModels(for: tab.provider)

            HStack(spacing: 4) {
                Button { openFilePicker() } label: {
                    Image(systemName: !attachments.isEmpty ? "plus.circle.fill" : "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(!attachments.isEmpty ? .accentColor : .secondary.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Anexar arquivo")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showQuickActions.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("Ações")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(showQuickActions ? .accentColor : .secondary.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        showQuickActions
                            ? RoundedRectangle(cornerRadius: 6).fill(NexTheme.accentDim)
                            : nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Ações rápidas")

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 2)

                chipPicker(
                    icon: "cpu",
                    selection: Binding(
                        get: { tab.provider },
                        set: { newVal in
                            appState.activeTab?.provider = newVal
                            let newModels = ProviderAvailabilityService.shared.availableModels(for: newVal)
                            let currentModel = appState.configStore.modelForProvider(newVal)
                            appState.activeTab?.model = newModels.contains(currentModel)
                                ? currentModel
                                : (newModels.first ?? newVal.defaultModel)
                            appState.configStore.defaultProvider = newVal
                        }
                    ),
                    options: providers,
                    label: { $0.displayName }
                )

                if !models.isEmpty {
                    chipPicker(
                        icon: nil,
                        selection: Binding(
                            get: { tab.model },
                            set: { newVal in
                                appState.activeTab?.model = newVal
                                switch tab.provider {
                                case .ollama: appState.configStore.ollamaModel = newVal
                                case .openAI: appState.configStore.openAIModel = newVal
                                case .gemini: appState.configStore.geminiModel = newVal
                                }
                            }
                        ),
                        options: models,
                        label: { $0 }
                    )
                }

                chipPicker(
                    icon: "checkmark.shield",
                    selection: Binding(
                        get: { tab.approvalMode },
                        set: { newVal in
                            appState.activeTab?.approvalMode = newVal
                            appState.configStore.defaultApprovalMode = newVal
                        }
                    ),
                    options: ApprovalMode.allCases,
                    label: { $0.displayName }
                )

                ContextSizeIndicator(breakdown: contextBreakdown(for: tab))

                intentBadge
            }
        }
    }

    private func contextBreakdown(for tab: TerminalTab) -> ContextEstimator.Breakdown {
        let caps = ProviderType.capabilities(for: tab.model)
        let turns = appState.agentState(for: tab.id).recentTurnsForPrompt
        return ContextEstimator.breakdown(
            tabMode: tab.tabMode,
            contextWindow: caps.contextWindow,
            userInput: inputText,
            attachments: attachments,
            turns: turns,
            terminalContextChars: 0
        )
    }

    private func chipPicker<T: Hashable>(
        icon: String?,
        selection: Binding<T>,
        options: [T],
        label: @escaping (T) -> String
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    if selection.wrappedValue as AnyHashable == option as AnyHashable {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                }
                Text(label(selection.wrappedValue))
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var inputActions: some View {
        if isRunning {
            HStack(spacing: 8) {
                Text("Executando...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Button {
                    appState.cancelAgent()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9))
                        Text("Stop")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(NexTheme.border, lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        } else {
            let hasContent = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty

            Button { submit() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(hasContent ? .white : .secondary.opacity(0.4))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(hasContent ? Color.accentColor : Color.secondary.opacity(0.1))
                    )
                    .scaleEffect(hasContent ? 1.0 : 0.92)
                    .animation(.easeOut(duration: 0.15), value: hasContent)
            }
            .buttonStyle(.plain)
            .disabled(!hasContent)
        }
    }

    @ViewBuilder
    private var intentBadge: some View {
        let isSkill = inputText.hasPrefix("/") && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isURL = !isBrowserOpen && !isSkill && detectURL(inputText) != nil
        let isAI = isBrowserOpen || (!isURL && !isSkill && detectedIntent == .aiRequest && !inputText.isEmpty)

        if isSkill || isURL || isAI {
            let (icon, label) = contextBadgeInfo(isSkill: isSkill, isURL: isURL)

            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(contextBadgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(contextBadgeColor.opacity(0.12))
            )
        }
    }

    private func contextBadgeInfo(isSkill: Bool, isURL: Bool) -> (String, String) {
        if isSkill { return ("sparkle", "Skill") }
        if isURL { return ("globe", "URL") }
        if isBrowserOpen { return ("globe", "Web") }
        switch activeTabMode {
        case .git: return ("arrow.triangle.branch", "Git AI")
        case .explorer: return ("folder.fill", "Explorer AI")
        default: return ("sparkles", "AI")
        }
    }

    private var contextBadgeColor: Color {
        switch activeTabMode {
        case .git: return .orange
        case .explorer: return .cyan
        default: return .accentColor
        }
    }

    enum HistoryDirection { case up, down }

    private func navigateHistory(direction: HistoryDirection) {
        guard !inputHistory.isEmpty else { return }
        switch direction {
        case .up:
            if historyIndex < inputHistory.count - 1 {
                historyIndex += 1
                inputText = inputHistory[inputHistory.count - 1 - historyIndex]
            }
        case .down:
            if historyIndex > 0 {
                historyIndex -= 1
                inputText = inputHistory[inputHistory.count - 1 - historyIndex]
            } else {
                historyIndex = -1
                inputText = ""
            }
        }
    }

    private func updateSkillAutocomplete(_ text: String) {
        if text.hasPrefix("/") && !text.contains(" ") {
            let query = String(text.dropFirst())
            skillQuery = query
            let hasResults = !SkillStore.shared.search(query: query).isEmpty
            showSkillAutocomplete = hasResults || query.isEmpty
        } else {
            showSkillAutocomplete = false
            skillQuery = ""
        }
    }

    private func applySkill(_ skill: Skill) {
        inputText = "/\(skill.name) "
        showSkillAutocomplete = false
        skillQuery = ""
    }

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !isRunning else { return }

        if !text.isEmpty {
            inputHistory.append(text)
            historyIndex = -1
        }

        inputText = ""
        showQuickActions = false
        showSkillAutocomplete = false

        if !attachments.isEmpty {
            let defaultMsg = attachments.count == 1
                ? "Execute o que está descrito neste arquivo"
                : "Analise os \(attachments.count) arquivos anexados"
            submitAI(text.isEmpty ? defaultMsg : text)
            return
        }

        if text.hasPrefix("/"), let (skill, userPrompt) = parseSkillInput(text) {
            submitWithSkill(skill: skill, userPrompt: userPrompt)
            return
        }

        if isBrowserOpen {
            submitAI(text)
            return
        }

        if let url = detectURL(text) {
            appState.openBrowser(url)
            return
        }

        let intent = InputClassifier.classify(text, tabMode: activeTabMode)

        switch intent {
        case .terminalCommand:
            let cmd = (text.hasPrefix("!") || text.hasPrefix(">"))
                ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                : text
            appState.sendTerminalCommand(cmd)

        case .aiRequest:
            submitAI(text)
        }
    }

    private func parseSkillInput(_ text: String) -> (Skill, String)? {
        let withoutSlash = String(text.dropFirst())
        let parts = withoutSlash.split(separator: " ", maxSplits: 1)
        guard let skillName = parts.first else { return nil }
        guard let skill = SkillStore.shared.find(name: String(skillName)) else { return nil }
        let userPrompt = parts.count > 1 ? String(parts[1]) : ""
        return (skill, userPrompt)
    }

    private func submitWithSkill(skill: Skill, userPrompt: String) {
        let context = "[SKILL: \(skill.name)] \(skill.instruction)\n\nUser request: \(userPrompt)"
        appState.startAgentExecution(context)
    }

    private func detectURL(_ text: String) -> URL? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if lowered.hasPrefix("www.") {
            return URL(string: "https://\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return nil
    }

    private func submitAI(_ text: String) {
        let msg = (text.hasPrefix("?") || text.hasPrefix("ai ") || text.hasPrefix("ask "))
            ? String(text.drop(while: { $0 != " " }).dropFirst()).trimmingCharacters(in: .whitespaces)
            : text
        let finalMsg = msg.isEmpty ? text : msg
        appState.startAgentExecution(finalMsg, attachments: attachments)
        attachments = []
    }

    // MARK: - File Attachment

    @ViewBuilder
    private var attachmentsPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments, id: \.originalPath) { att in
                    attachmentChip(att)
                }

                if attachments.count > 1 {
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            attachments.removeAll()
                        }
                    } label: {
                        Text("Limpar")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func attachmentChip(_ att: FileAttachment) -> some View {
        let chipBg = Color.accentColor.opacity(0.08)
        let chipBorder = Color.accentColor.opacity(0.15)

        return HStack(spacing: 5) {
            Image(systemName: att.fileType.icon)
                .font(.system(size: 10))
                .foregroundColor(NexTheme.accent)

            Text(att.fileName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(1)

            Button {
                withAnimation(.easeOut(duration: 0.12)) {
                    removeAttachment(att)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(chipBg)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(chipBorder, lineWidth: 0.5)
        )
        .onDrag {
            NSItemProvider(object: URL(fileURLWithPath: att.originalPath) as NSURL)
        }
    }

    private func removeAttachment(_ att: FileAttachment) {
        attachments.removeAll { $0.originalPath == att.originalPath }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .pdf, .plainText, .json, .yaml,
            .sourceCode, .shellScript, .html, .xml
        ]
        panel.title = "Anexar arquivos"
        panel.prompt = "Anexar"

        if let tab = appState.activeTab {
            panel.directoryURL = URL(fileURLWithPath: tab.currentDirectory)
        }

        if panel.runModal() == .OK {
            let newFiles = panel.urls.compactMap { FileAttachmentExtractor.extract(from: $0) }
            let existing = Set(attachments.map(\.originalPath))
            let unique = newFiles.filter { !existing.contains($0.originalPath) }
            guard !unique.isEmpty else { return }

            withAnimation(.easeInOut(duration: 0.15)) {
                attachments.append(contentsOf: unique)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      let extracted = FileAttachmentExtractor.extract(from: url) else { return }

                DispatchQueue.main.async {
                    let alreadyAttached = attachments.contains(where: { $0.originalPath == extracted.originalPath })
                    guard !alreadyAttached else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        attachments.append(extracted)
                    }
                }
            }
        }
        return true
    }
}

struct GrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var isDisabled: Bool
    var onSubmit: () -> Void
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> InputScrollView {
        let scrollView = InputScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = InputTextView()
        textView.isEditable = !isDisabled
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor(NexTheme.textPrimary)
        textView.insertionPointColor = NSColor(NexTheme.accent)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.delegate = context.coordinator
        textView.inputDelegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateNSView(_ scrollView: InputScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        textView.isEditable = !isDisabled
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextEditor
        weak var textView: NSTextView?
        weak var scrollView: InputScrollView?

        init(_ parent: GrowingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if textView.string.isEmpty || !textView.string.contains("\n") {
                    parent.onUpArrow()
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if textView.string.isEmpty || !textView.string.contains("\n") {
                    parent.onDownArrow()
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}

class InputScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

class InputTextView: NSTextView {
    weak var inputDelegate: GrowingTextEditor.Coordinator?
}
