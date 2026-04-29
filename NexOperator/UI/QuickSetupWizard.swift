import SwiftUI

// MARK: - URL Parser

struct ParsedRepoURL {
    let provider: RemoteProviderType
    let owner: String
    let repoName: String
    let organization: String?
    let cloneURL: String
    let project: String?

    var displayName: String {
        if let org = organization, provider == .azureDevOps {
            return "\(org)/\(repoName)"
        }
        return "\(owner)/\(repoName)"
    }

    static func parse(_ input: String) -> ParsedRepoURL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let gh = parseGitHub(trimmed) { return gh }
        if let az = parseAzureDevOps(trimmed) { return az }
        return nil
    }

    private static func parseGitHub(_ url: String) -> ParsedRepoURL? {
        // git@github.com:user/repo.git
        if url.hasPrefix("git@github.com:") {
            let path = url
                .replacingOccurrences(of: "git@github.com:", with: "")
                .replacingOccurrences(of: ".git", with: "")
            let parts = path.split(separator: "/")
            guard parts.count >= 2 else { return nil }
            let owner = String(parts[0])
            let repo = String(parts[1])
            return ParsedRepoURL(
                provider: .github,
                owner: owner,
                repoName: repo,
                organization: nil,
                cloneURL: "https://github.com/\(owner)/\(repo).git",
                project: nil
            )
        }

        // https://github.com/user/repo[.git]
        guard url.contains("github.com") else { return nil }

        let cleaned = url
            .replacingOccurrences(of: "https://github.com/", with: "")
            .replacingOccurrences(of: "http://github.com/", with: "")
            .replacingOccurrences(of: ".git", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let parts = cleaned.split(separator: "/")
        guard parts.count >= 2 else { return nil }

        let owner = String(parts[0])
        let repo = String(parts[1])

        return ParsedRepoURL(
            provider: .github,
            owner: owner,
            repoName: repo,
            organization: nil,
            cloneURL: "https://github.com/\(owner)/\(repo).git",
            project: nil
        )
    }

    private static func parseAzureDevOps(_ url: String) -> ParsedRepoURL? {
        // https://[user@]dev.azure.com/org/project/_git/repo
        if url.contains("dev.azure.com") {
            let stripped = url
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            let parts = stripped.split(separator: "/").map(String.init)

            guard let devIdx = parts.firstIndex(where: { $0.contains("dev.azure.com") }),
                  parts.count > devIdx + 3 else { return nil }

            let org = parts[devIdx + 1]
            let project = parts[devIdx + 2]
            let gitIdx = parts.firstIndex(of: "_git")
            let repo: String
            if let gi = gitIdx, parts.count > gi + 1 {
                repo = parts[gi + 1].replacingOccurrences(of: ".git", with: "")
            } else {
                repo = project
            }

            let cloneURL = "https://dev.azure.com/\(org)/\(project)/_git/\(repo)"

            return ParsedRepoURL(
                provider: .azureDevOps,
                owner: org,
                repoName: repo,
                organization: org,
                cloneURL: cloneURL,
                project: project
            )
        }

        // org@vs-ssh.visualstudio.com
        if url.contains("visualstudio.com") || url.contains("ssh.dev.azure.com") {
            let parts = url.split(separator: "/").map(String.init)
            let org = parts.first(where: { $0.contains("@") })?.split(separator: "@").first.map(String.init) ?? ""
            let repo = parts.last?.replacingOccurrences(of: ".git", with: "") ?? ""
            guard !org.isEmpty, !repo.isEmpty else { return nil }

            return ParsedRepoURL(
                provider: .azureDevOps,
                owner: org,
                repoName: repo,
                organization: org,
                cloneURL: url,
                project: nil
            )
        }

        return nil
    }
}

// MARK: - Wizard Step

enum QuickSetupStep: Int, CaseIterable {
    case pasteURL = 0
    case authenticate = 1
    case clone = 2
    case done = 3

    var title: String {
        switch self {
        case .pasteURL: return "Colar URL"
        case .authenticate: return "Autenticar"
        case .clone: return "Clonar"
        case .done: return "Pronto"
        }
    }

    var icon: String {
        switch self {
        case .pasteURL: return "link"
        case .authenticate: return "person.badge.key"
        case .clone: return "arrow.down.circle"
        case .done: return "checkmark.circle"
        }
    }
}

// MARK: - Wizard View

struct QuickSetupWizard: View {
    @ObservedObject var viewModel: RemoteExplorerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var step: QuickSetupStep = .pasteURL
    @State private var rawURL = ""
    @State private var parsed: ParsedRepoURL?
    @State private var parseError = false

    @State private var authMethod: AuthMethod = .deviceOAuth
    @State private var patInput = ""
    @State private var azureOrgInput = ""

    @State private var oauthUserCode: String?
    @State private var isWaitingOAuth = false
    @State private var isAuthenticating = false
    @State private var authError: String?
    @State private var existingAccount: RemoteAccount?

    @State private var clonePath = NSHomeDirectory() + "/Developer"
    @State private var isCloning = false
    @State private var cloneProgress = ""
    @State private var cloneError: String?
    @State private var cloneSucceeded = false

    enum AuthMethod: String, CaseIterable {
        case deviceOAuth = "Login pelo Navegador"
        case pat = "Personal Access Token"
    }

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader
            Divider()
            stepIndicator
            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    switch step {
                    case .pasteURL: urlStep
                    case .authenticate: authStep
                    case .clone: cloneStep
                    case .done: doneStep
                    }
                }
                .padding(24)
            }
            .frame(maxHeight: .infinity)

            Divider()
            wizardFooter
        }
        .frame(width: 520, height: 480)
        .background(NexTheme.bg)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string),
               (clip.contains("github.com") || clip.contains("dev.azure.com")) {
                rawURL = clip
                tryParse()
            }
        }
    }

    // MARK: - Header

    private var wizardHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16))
                .foregroundColor(NexTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Setup Rápido")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
                Text("Cole uma URL de repositório e configure tudo automaticamente")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NexTheme.surface)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(QuickSetupStep.allCases, id: \.rawValue) { s in
                HStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(stepColor(for: s))
                            .frame(width: 22, height: 22)
                        if s.rawValue < step.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                        } else {
                            Image(systemName: s.icon)
                                .font(.system(size: 9))
                                .foregroundColor(s == step ? .white : NexTheme.textSecondary)
                        }
                    }
                    Text(s.title)
                        .font(.system(size: 10, weight: s == step ? .semibold : .regular))
                        .foregroundColor(s == step ? NexTheme.textPrimary : NexTheme.textSecondary)
                }
                if s != QuickSetupStep.allCases.last {
                    Spacer()
                    Rectangle()
                        .fill(s.rawValue < step.rawValue ? NexTheme.accent : NexTheme.border)
                        .frame(height: 1)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(NexTheme.surface.opacity(0.5))
    }

    private func stepColor(for s: QuickSetupStep) -> Color {
        if s.rawValue < step.rawValue { return .green }
        if s == step { return NexTheme.accent }
        return NexTheme.border
    }

    // MARK: - Step 1: Paste URL

    private var urlStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cole a URL do repositório")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
                Text("HTTP, HTTPS ou SSH — detectamos o provedor automaticamente")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundColor(NexTheme.textSecondary)
                TextField("https://github.com/user/repo.git", text: $rawURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { tryParse() }

                Button {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        rawURL = clip
                        tryParse()
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Colar do clipboard")
            }
            .padding(10)
            .background(NexTheme.surface)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(parseError ? Color.red.opacity(0.6) : NexTheme.border.opacity(0.5), lineWidth: 1)
            )

            if parseError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("URL não reconhecida. Use URLs do GitHub ou Azure DevOps.")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }

            if let p = parsed {
                parsedPreview(p)
            }

            urlExamples
        }
    }

    private func parsedPreview(_ p: ParsedRepoURL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: p.provider.icon)
                .font(.system(size: 18))
                .foregroundColor(p.provider.color)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(p.provider.color.opacity(0.1))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(p.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
                HStack(spacing: 6) {
                    Text(p.provider.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(p.provider.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(p.provider.color.opacity(0.1))
                        .cornerRadius(3)
                    if let proj = p.project {
                        Text("Projeto: \(proj)")
                            .font(.system(size: 9))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.green)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green.opacity(0.2), lineWidth: 0.5)
                )
        )
    }

    private var urlExamples: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Exemplos de URLs suportadas:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(NexTheme.textSecondary)

            Group {
                exampleRow("https://github.com/user/repo.git")
                exampleRow("git@github.com:org/repo.git")
                exampleRow("https://dev.azure.com/org/project/_git/repo")
            }
        }
        .padding(10)
        .background(NexTheme.surface.opacity(0.5))
        .cornerRadius(6)
    }

    private func exampleRow(_ url: String) -> some View {
        Button {
            rawURL = url
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 8))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.5))
                Text(url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: Authenticate

    private var authStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let account = existingAccount {
                existingAccountBanner(account)
            } else if let p = parsed {
                newAccountAuth(p)
            }
        }
    }

    private func existingAccountBanner(_ account: RemoteAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conta já configurada!")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(NexTheme.textPrimary)
                    Text("Usando: \(account.displayName)")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.green.opacity(0.2), lineWidth: 0.5)
                    )
            )

            Text("Você já tem uma conta configurada para este provedor. Podemos pular direto para o clone.")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
        }
    }

    @ViewBuilder
    private func newAccountAuth(_ p: ParsedRepoURL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Autenticação necessária")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(NexTheme.textPrimary)
            Text("Para acessar \(p.displayName), escolha como autenticar:")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
        }

        if p.provider == .github {
            githubAuthSection
        } else {
            azureAuthSection(p)
        }

        if let err = authError {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text(err)
                    .font(.system(size: 10))
            }
            .foregroundColor(.red)
        }
    }

    private var githubAuthSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Método", selection: $authMethod) {
                Text("Login pelo Navegador").tag(AuthMethod.deviceOAuth)
                Text("Personal Access Token").tag(AuthMethod.pat)
            }
            .pickerStyle(.segmented)

            if authMethod == .deviceOAuth {
                deviceOAuthCard
            } else {
                patCard(provider: .github)
            }
        }
    }

    private var deviceOAuthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "safari")
                    .font(.system(size: 16))
                    .foregroundColor(NexTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Login via GitHub")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(NexTheme.textPrimary)
                    Text("Abre o navegador para autorizar o NexifyTerm")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                }
            }

            if isWaitingOAuth {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Aguardando autorização no navegador...")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)

                    if let code = oauthUserCode {
                        VStack(spacing: 4) {
                            Text("Código de verificação:")
                                .font(.system(size: 10))
                                .foregroundColor(NexTheme.textSecondary)
                            Text(code)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(NexTheme.accent)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(NexTheme.accent.opacity(0.1))
                                )
                            Text("Código copiado para o clipboard")
                                .font(.system(size: 9))
                                .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            } else {
                Button {
                    startDeviceOAuth()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                        Text("Abrir GitHub no Navegador")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(NexTheme.accent)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 8))
                Text("Permissões: repo, read:org, read:user")
                    .font(.system(size: 9))
            }
            .foregroundColor(NexTheme.textSecondary.opacity(0.6))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(NexTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(NexTheme.border.opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    private func patCard(provider: RemoteProviderType) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Personal Access Token", text: $patInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            if provider == .azureDevOps {
                TextField("Organização", text: $azureOrgInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            if provider == .github {
                tokenCreateLink(
                    label: "Criar token no GitHub",
                    url: "https://github.com/settings/tokens/new?scopes=repo,read:org,read:user&description=NexifyTerm"
                )
            } else {
                tokenCreateLink(
                    label: "Criar token no Azure DevOps",
                    url: "https://dev.azure.com/\(azureOrgInput.isEmpty ? "_" : azureOrgInput)/_usersSettings/tokens"
                )
            }

            if isAuthenticating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Validando token...")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(NexTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(NexTheme.border.opacity(0.3), lineWidth: 0.5)
                )
        )
    }

    private func tokenCreateLink(label: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 9))
                Text(label)
                    .font(.system(size: 10))
            }
            .foregroundColor(NexTheme.accent)
        }
        .buttonStyle(.plain)
    }

    private func azureAuthSection(_ p: ParsedRepoURL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            patCard(provider: .azureDevOps)
                .onAppear {
                    azureOrgInput = p.organization ?? ""
                    authMethod = .pat
                }
        }
    }

    // MARK: - Step 3: Clone

    private var cloneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let p = parsed {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(NexTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clonar \(p.repoName)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(NexTheme.textPrimary)
                        Text(p.cloneURL)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(NexTheme.textSecondary)
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Pasta de destino:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NexTheme.textSecondary)

                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundColor(NexTheme.textSecondary)
                        TextField("~/Developer", text: $clonePath)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))

                        Button {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            panel.prompt = "Selecionar"
                            if panel.runModal() == .OK, let url = panel.url {
                                clonePath = url.path
                            }
                        } label: {
                            Text("Alterar...")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(NexTheme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(NexTheme.surface)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(NexTheme.border.opacity(0.5), lineWidth: 0.5)
                    )

                    Text("Será clonado em: \(clonePath)/\(p.repoName)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                }

                if isCloning {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        if !cloneProgress.isEmpty {
                            Text(cloneProgress)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(NexTheme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                }

                if let err = cloneError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(err)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Step 4: Done

    private var doneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Tudo pronto!")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(NexTheme.textPrimary)

            if let p = parsed {
                Text("\(p.displayName) foi clonado com sucesso.")
                    .font(.system(size: 12))
                    .foregroundColor(NexTheme.textSecondary)

                Text(clonePath + "/\(p.repoName)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(NexTheme.accent)
                    .padding(8)
                    .background(NexTheme.surface)
                    .cornerRadius(6)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var wizardFooter: some View {
        HStack {
            if step != .pasteURL && step != .done {
                Button {
                    withAnimation { goBack() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10))
                        Text("Voltar")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if step == .done {
                Button {
                    dismiss()
                } label: {
                    Text("Fechar")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button {
                    withAnimation { goNext() }
                } label: {
                    HStack(spacing: 4) {
                        if isAuthenticating || isCloning {
                            ProgressView().controlSize(.mini)
                        }
                        Text(nextButtonLabel)
                            .font(.system(size: 12, weight: .medium))
                        if !isAuthenticating && !isCloning {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canAdvance)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NexTheme.surface)
    }

    private var nextButtonLabel: String {
        switch step {
        case .pasteURL: return "Continuar"
        case .authenticate:
            if existingAccount != nil { return "Pular para Clone" }
            if isAuthenticating || isWaitingOAuth { return "Autenticando..." }
            return "Autenticar"
        case .clone:
            return isCloning ? "Clonando..." : "Clonar Repositório"
        case .done: return "Fechar"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .pasteURL: return parsed != nil
        case .authenticate:
            if existingAccount != nil { return true }
            if isWaitingOAuth || isAuthenticating { return false }
            if authMethod == .pat { return !patInput.isEmpty }
            return false
        case .clone: return !isCloning
        case .done: return true
        }
    }

    // MARK: - Navigation Logic

    private func tryParse() {
        parsed = ParsedRepoURL.parse(rawURL)
        parseError = parsed == nil && !rawURL.isEmpty
    }

    private func goNext() {
        switch step {
        case .pasteURL:
            tryParse()
            guard let p = parsed else { return }
            checkExistingAccount(for: p)
            step = .authenticate

        case .authenticate:
            if existingAccount != nil {
                step = .clone
            } else {
                Task { await authenticateWithPAT() }
            }

        case .clone:
            Task { await performClone() }

        case .done:
            dismiss()
        }
    }

    private func goBack() {
        switch step {
        case .authenticate: step = .pasteURL
        case .clone: step = .authenticate
        default: break
        }
    }

    private func checkExistingAccount(for p: ParsedRepoURL) {
        let oauthService = OAuthService.shared
        existingAccount = oauthService.accounts.first { account in
            if account.provider != p.provider { return false }
            if p.provider == .azureDevOps {
                return account.organization?.lowercased() == p.organization?.lowercased()
            }
            return true
        }
        if let existing = existingAccount {
            viewModel.selectAccount(existing)
        }
    }

    // MARK: - OAuth Device Flow

    private func startDeviceOAuth() {
        isWaitingOAuth = true
        authError = nil

        Task {
            do {
                let result = try await OAuthService.shared.authenticateGitHub(
                    clientId: AppConfig.GitHub.oauthClientId
                )

                OAuthService.shared.addAccount(
                    provider: .github,
                    displayName: "GitHub - \(result.username)",
                    username: result.username,
                    organization: nil,
                    token: result.token
                )

                viewModel.accounts = OAuthService.shared.accounts
                existingAccount = viewModel.accounts.last
                viewModel.selectedAccount = existingAccount
                isWaitingOAuth = false

                withAnimation { step = .clone }
            } catch {
                isWaitingOAuth = false
                authError = "Falha no login: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - PAT Auth

    private func authenticateWithPAT() async {
        guard let p = parsed else { return }
        isAuthenticating = true
        authError = nil

        do {
            let username: String
            let org: String?

            switch p.provider {
            case .github:
                let (data, _) = try await RemoteHTTP.request(
                    url: "https://api.github.com/user",
                    token: patInput,
                    provider: .github
                )
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                username = json["login"] as? String ?? p.owner
                org = nil

            case .azureDevOps:
                let resolvedOrg = azureOrgInput.isEmpty ? (p.organization ?? "") : azureOrgInput
                guard !resolvedOrg.isEmpty else {
                    authError = "Organização é obrigatória para Azure DevOps"
                    isAuthenticating = false
                    return
                }
                username = try await OAuthService.shared.validateAzureToken(
                    organization: resolvedOrg,
                    token: patInput
                )
                org = resolvedOrg
            }

            OAuthService.shared.addAccount(
                provider: p.provider,
                displayName: "\(p.provider.displayName) - \(username)",
                username: username,
                organization: org,
                token: patInput
            )

            viewModel.accounts = OAuthService.shared.accounts
            existingAccount = viewModel.accounts.last
            viewModel.selectedAccount = existingAccount
            isAuthenticating = false

            withAnimation { step = .clone }
        } catch {
            isAuthenticating = false
            authError = "Token inválido: \(error.localizedDescription)"
        }
    }

    // MARK: - Clone

    private func performClone() async {
        guard let p = parsed, let account = existingAccount else { return }
        let token = OAuthService.shared.token(for: account)
        let dest = "\(clonePath)/\(p.repoName)"

        isCloning = true
        cloneError = nil

        do {
            try FileManager.default.createDirectory(
                atPath: clonePath,
                withIntermediateDirectories: true
            )

            try await OAuthService.shared.cloneRepository(
                url: p.cloneURL,
                destination: dest,
                token: token,
                provider: p.provider
            ) { progress in
                Task { @MainActor in
                    cloneProgress = progress
                }
            }

            isCloning = false
            cloneSucceeded = true
            withAnimation { step = .done }
        } catch {
            isCloning = false
            cloneError = "Falha ao clonar: \(error.localizedDescription)"
        }
    }
}
