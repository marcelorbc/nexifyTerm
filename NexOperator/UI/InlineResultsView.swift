import SwiftUI

struct InlineResultsView: View {
    @EnvironmentObject var appState: AppState

    private var results: [StepResult] { appState.agentResults }
    private var running: Bool { appState.isAgentRunning }
    private var status: String? { appState.agentStatus }

    var body: some View {
        VStack(spacing: 0) {
            let _ = appState.tabStateVersion
            if running || !results.isEmpty || status != nil {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if running, let plan = appState.runningPlan {
                                RunningPlanBanner(plan: plan, round: appState.runningPlanRound, completedCount: results.count)
                                    .id("running-plan")
                            }

                            ForEach(results) { result in
                                StepCardView(result: result)
                                    .id(result.id)
                            }

                            if running, let s = status {
                                ThinkingView(
                                    status: s,
                                    provider: appState.activeTab?.provider.displayName ?? "",
                                    model: appState.activeTab?.model ?? "",
                                    startTime: appState.agentStartTime,
                                    thinkingPhase: appState.thinkingPhase,
                                    thinkingDetails: appState.thinkingDetails,
                                    streamingText: appState.streamingText,
                                    onCancel: { appState.cancelAgent() }
                                )
                                .id("running-status")
                            }

                            if !running, let s = status {
                                CompletionCardView(
                                    summary: s,
                                    richOutput: appState.lastRichOutput,
                                    elapsedTime: appState.agentElapsedTime
                                ) {
                                    appState.agentStatus = nil
                                    appState.agentResults = []
                                }
                                .id("completion-card")
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("bottom-anchor")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .onChange(of: appState.tabStateVersion) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

struct StepCardView: View {
    let result: StepResult

    @State private var isExpanded = false

    private var cleanCommand: String {
        result.command.strippingANSICodes()
    }

    private var isWriteFile: Bool {
        result.command.contains("write_file") && result.filePath != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: result.wasBlocked ? "xmark.octagon.fill" : (result.output.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                    .font(.system(size: 10))
                    .foregroundColor(result.wasBlocked ? .red : (result.output.succeeded ? .green : .orange))

                Text(cleanCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                if result.output.timedOut {
                    HStack(spacing: 2) {
                        Image(systemName: "clock.badge.xmark")
                            .font(.system(size: 8))
                        Text("TIMEOUT")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(3)
                }

                HStack(spacing: 4) {
                    Image(systemName: result.risk.icon)
                        .font(.system(size: 8))
                    Text(result.risk.displayName)
                        .font(.system(size: 9))
                }
                .foregroundColor(result.risk.color)

                if !result.wasBlocked && !result.output.combinedOutput.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: NexTheme.iconSizeSmall))
                            .foregroundColor(NexTheme.textSecondary)
                            .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let path = result.filePath {
                FileActionBar(filePath: path, isWrite: isWriteFile)
            }

            if isExpanded {
                Text(result.output.truncatedOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(NexTheme.bg.opacity(0.6))
                    .cornerRadius(6)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 8)
    }
}

// MARK: - File Action Bar

struct FileActionBar: View {
    let filePath: String
    let isWrite: Bool

    private var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    private var folderPath: String {
        (filePath as NSString).deletingLastPathComponent
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isWrite ? "doc.badge.plus" : "doc.text")
                .font(.system(size: 9))
                .foregroundColor(isWrite ? .green : NexTheme.accent)

            Text(filePath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(NexTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if fileExists {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 8))
                        Text("Abrir")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(NexTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(NexTheme.accentDim)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Abrir arquivo: \(fileName)")
            }

            Button {
                NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: folderPath)
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "folder")
                        .font(.system(size: 8))
                    Text("Pasta")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(NexTheme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(NexTheme.surfaceHover)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Revelar no Finder: \(folderPath)")

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(filePath, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 8))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copiar caminho")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isWrite ? Color.green.opacity(0.05) : NexTheme.surface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isWrite ? Color.green.opacity(0.15) : NexTheme.border.opacity(0.3), lineWidth: 0.5)
        )
    }
}

struct ThinkingView: View {
    let status: String
    let provider: String
    let model: String
    let startTime: Date?
    let thinkingPhase: String?
    let thinkingDetails: [String]
    let streamingText: String?
    var onCancel: (() -> Void)?

    private let slowThreshold: TimeInterval = 30
    private let verySlowThreshold: TimeInterval = 90

    @State private var elapsed: TimeInterval = 0
    @State private var pulseOpacity: Double = 0.4
    @State private var visibleDetails: Int = 0
    @State private var isStreamExpanded = true
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isSlow: Bool { elapsed >= slowThreshold }
    private var isVerySlow: Bool { elapsed >= verySlowThreshold }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                thinkingIndicator

                VStack(alignment: .leading, spacing: 1) {
                    Text(thinkingPhase ?? status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isSlow ? .orange : .accentColor)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Label(provider, systemImage: "cpu")
                            .font(.system(size: 9))
                        Label(model, systemImage: "brain")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                }

                Spacer()

                if streamingText != nil {
                    streamingBadge
                }

                if isSlow, let onCancel {
                    killButton(onCancel)
                }

                Text(formattedElapsed)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(isVerySlow ? .red : (isSlow ? .orange : NexTheme.accent.opacity(0.8)))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if isSlow {
                slowWarningBanner
            }

            if !thinkingDetails.isEmpty && streamingText == nil {
                Divider().opacity(0.1)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(thinkingDetails.prefix(visibleDetails).enumerated()), id: \.offset) { idx, detail in
                        HStack(spacing: 5) {
                            Text(detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(NexTheme.textSecondary.opacity(0.8))
                                .lineLimit(1)
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .animation(.easeOut(duration: 0.25), value: visibleDetails)
            }

            if let text = streamingText, !text.isEmpty {
                Divider().opacity(0.1)
                streamingOutputView(text)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        )
        .onReceive(clockTimer) { _ in
            if let start = startTime {
                elapsed = Date().timeIntervalSince(start)
            }
        }
        .onAppear {
            if let start = startTime {
                elapsed = Date().timeIntervalSince(start)
            }
            animateDetails()
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseOpacity = 1.0
            }
        }
        .onChange(of: thinkingDetails.count) { _, _ in
            visibleDetails = 0
            animateDetails()
        }
    }

    private var streamingBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(NexTheme.accent)
                .frame(width: 5, height: 5)
                .opacity(pulseOpacity)
            Text("STREAMING")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(NexTheme.accent)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(NexTheme.accent.opacity(0.1))
        .cornerRadius(4)
    }

    private func streamingOutputView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "text.word.spacing")
                    .font(.system(size: 8))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.6))

                Text("Resposta da LLM")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.6))

                Text("(\(text.count) chars)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.4))

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isStreamExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isStreamExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: NexTheme.iconSizeSmall))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.5))
                        .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 3)

            if isStreamExpanded {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(streamPreview(text))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(NexTheme.accent.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("stream-end")
                    }
                    .frame(maxHeight: 120)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .onChange(of: text.count) { _, _ in
                        proxy.scrollTo("stream-end", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func streamPreview(_ text: String) -> String {
        let maxChars = 2000
        if text.count <= maxChars { return text }
        return "..." + String(text.suffix(maxChars))
    }

    private func killButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                Text(isVerySlow ? "Derrubar" : "Parar")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isVerySlow ? Color.red.opacity(0.25) : Color.orange.opacity(0.15))
            .foregroundColor(isVerySlow ? .red : .orange)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .help("Derrubar execução atual")
    }

    private var slowWarningBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: isVerySlow ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                .font(.system(size: 10))
                .foregroundColor(isVerySlow ? .red : .orange)

            Text(isVerySlow
                 ? "Execução muito lenta (\(formattedElapsed)). Considere derrubar."
                 : "Execução lenta (\(formattedElapsed))...")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isVerySlow ? .red : .orange)

            Spacer()

            if let onCancel {
                Button(action: onCancel) {
                    Text("Derrubar")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.2))
                        .foregroundColor(.red)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isVerySlow ? Color.red.opacity(0.06) : Color.orange.opacity(0.06))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var thinkingIndicator: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 28, height: 28)
    }

    private func animateDetails() {
        let total = thinkingDetails.count
        guard total > 0 else { return }
        for i in 1...total {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) {
                withAnimation { visibleDetails = i }
            }
        }
    }

    private var formattedElapsed: String {
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        return mins > 0 ? String(format: "%dm %02ds", mins, secs) : String(format: "%ds", secs)
    }
}

struct CompletionCardView: View {
    let summary: String
    let richOutput: RichOutput?
    let elapsedTime: TimeInterval?
    let onDismiss: () -> Void

    @State private var showHTML = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Text("Análise Completa")
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)

                if let time = elapsedTime {
                    Text("(\(formatTime(time)))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                }

                Spacer()

                if richOutput?.html != nil {
                    Button {
                        withAnimation { showHTML.toggle() }
                    } label: {
                        Image(systemName: showHTML ? "terminal" : "globe")
                            .font(.system(size: NexTheme.iconSizeSmall))
                            .foregroundColor(NexTheme.textSecondary)
                            .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(showHTML ? "Ver texto" : "Ver HTML")
                }

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(summary, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: NexTheme.iconSizeSmall))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Copiar resumo")

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: NexTheme.iconSizeSmall))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }

            if let rich = richOutput, hasRichContent(rich) {
                RichOutputView(output: rich)
            }

            MarkdownContentView(content: summary, fontSize: 11)

            if showHTML, let html = richOutput?.html {
                WebPreviewPanel(html: html) {
                    withAnimation { showHTML = false }
                }
                .frame(maxHeight: 250)
                .cornerRadius(8)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        )
    }

    private func hasRichContent(_ rich: RichOutput) -> Bool {
        (rich.metrics != nil && !(rich.metrics!.isEmpty)) ||
        rich.table != nil ||
        rich.chart != nil
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return mins > 0 ? String(format: "%dm %02ds", mins, secs) : String(format: "%ds", secs)
    }
}

struct RunningPlanBanner: View {
    let plan: AgentPlan
    let round: Int
    let completedCount: Int

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)

                Text(plan.title)
                    .font(.caption.bold())
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)

                if round > 0 {
                    Text("Round \(round + 1)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(NexTheme.accentDim)
                        .foregroundColor(.accentColor)
                        .cornerRadius(3)
                }

                Spacer()

                Text("\(completedCount)/\(plan.commands.count + completedCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: NexTheme.iconSizeSmall))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }

            if isExpanded {
                if hasSlowCommands {
                    HStack(spacing: 4) {
                        Image(systemName: "tortoise.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("Este plano contém comandos que podem demorar. Você pode derrubar a qualquer momento.")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(4)
                }

                Text(plan.explanation)
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(2)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(plan.commands.enumerated()), id: \.offset) { idx, cmd in
                        let isDone = idx < (plan.commands.count - remainingCount)
                        let slowEstimate = SlowCommandClassifier.classify(cmd.command)
                        HStack(spacing: 4) {
                            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 8))
                                .foregroundColor(isDone ? .green : NexTheme.textSecondary.opacity(0.5))

                            Text(cmd.command.strippingANSICodes())
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(isDone ? NexTheme.textSecondary : NexTheme.textPrimary)
                                .lineLimit(1)
                                .strikethrough(isDone)

                            Spacer()

                            if !isDone, let label = slowEstimate.shortLabel {
                                Text(label)
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.12))
                                    .cornerRadius(3)
                            }

                            Text(cmd.expectedRisk)
                                .font(.system(size: 8))
                                .foregroundColor(riskColor(cmd.expectedRisk))
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(NexTheme.surface.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NexTheme.accent.opacity(0.2), lineWidth: 0.5)
                )
        )
    }

    private var remainingCount: Int {
        max(0, plan.commands.count - max(0, completedCount))
    }

    private var hasSlowCommands: Bool {
        plan.commands.contains { SlowCommandClassifier.classify($0.command).isSlow }
    }

    private func riskColor(_ risk: String) -> Color {
        switch risk.lowercased() {
        case "readonly": return .green
        case "low": return .blue
        case "medium": return .orange
        case "high": return .red
        case "blocked": return .red
        default: return NexTheme.textSecondary
        }
    }
}
