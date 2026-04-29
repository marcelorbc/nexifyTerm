import SwiftUI

struct QuickAction: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let prompt: String
}

struct QuickActionsView: View {
    @EnvironmentObject var appState: AppState
    let tabMode: TabMode
    let onSelect: (String) -> Void

    private var actions: [QuickAction] {
        switch tabMode {
        case .git: return Self.gitActions
        case .explorer: return Self.explorerActions
        default: return Self.terminalActions
        }
    }

    private var accentColor: Color {
        switch tabMode {
        case .git: return .orange
        case .explorer: return .cyan
        default: return .accentColor
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(actions) { action in
                    Button {
                        onSelect(action.prompt)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: action.icon)
                                .font(.system(size: NexTheme.iconSizeSmall))
                                .foregroundColor(accentColor)
                            Text(action.label)
                                .font(.system(size: 12))
                                .foregroundColor(NexTheme.textPrimary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassCard(cornerRadius: 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Terminal Actions

    static let terminalActions: [QuickAction] = [
        QuickAction(icon: "cpu", label: "CPU usage", prompt: "show me which processes are using the most CPU right now"),
        QuickAction(icon: "memorychip", label: "Memory", prompt: "check memory usage and show what's consuming the most RAM"),
        QuickAction(icon: "internaldrive", label: "Disk space", prompt: "show disk space usage and find the largest folders in my home directory"),
        QuickAction(icon: "network", label: "Network", prompt: "check my network connection, show my IP and test internet speed"),
        QuickAction(icon: "wifi", label: "WiFi info", prompt: "show WiFi network info, signal strength, and connected network name"),
        QuickAction(icon: "globe", label: "DNS check", prompt: "show my current DNS configuration and test DNS resolution"),
        QuickAction(icon: "bolt.circle", label: "Ports", prompt: "show all listening ports and which processes are using them"),
        QuickAction(icon: "trash.circle", label: "Clean caches", prompt: "find and show safe caches I can clean to free up space, but don't delete yet"),
        QuickAction(icon: "arrow.up.circle", label: "Startup apps", prompt: "list all apps that start on login and show how to remove unwanted ones"),
        QuickAction(icon: "battery.75percent", label: "Battery", prompt: "show battery health, cycle count, and current power consumption"),
        QuickAction(icon: "speedometer", label: "Slow Mac?", prompt: "my Mac feels slow, diagnose the issue: check CPU, memory, disk I/O, and startup items"),
        QuickAction(icon: "shippingbox", label: "Updates", prompt: "check if there are system updates or brew updates available"),
    ]

    // MARK: - Git Actions

    static let gitActions: [QuickAction] = [
        QuickAction(icon: "text.badge.checkmark", label: "Gerar commit", prompt: "analise os arquivos staged e gere uma mensagem de commit seguindo conventional commits"),
        QuickAction(icon: "pencil.and.outline", label: "O que mudou?", prompt: "mostre um resumo de todas as mudanças no repositório (staged e unstaged) com detalhes por arquivo"),
        QuickAction(icon: "arrow.up.circle", label: "Push", prompt: "faça push das mudanças para o remote"),
        QuickAction(icon: "arrow.down.circle", label: "Pull & sync", prompt: "faça pull do remote e mostre se há conflitos ou mudanças novas"),
        QuickAction(icon: "arrow.triangle.branch", label: "Criar branch", prompt: "crie uma nova branch baseada no que estou trabalhando"),
        QuickAction(icon: "tray.and.arrow.down", label: "Stash", prompt: "salve minhas mudanças atuais em um stash"),
        QuickAction(icon: "text.badge.checkmark", label: "Commit & push", prompt: "faça stage all, gere uma mensagem de commit, commite e push"),
        QuickAction(icon: "clock.arrow.circlepath", label: "Histórico", prompt: "mostre o histórico recente de commits com detalhes"),
        QuickAction(icon: "exclamationmark.triangle", label: "Conflitos", prompt: "verifique se há conflitos de merge e ajude a resolver"),
        QuickAction(icon: "arrow.uturn.backward", label: "Desfazer último", prompt: "desfaça o último commit mantendo as mudanças (soft reset)"),
        QuickAction(icon: "tag", label: "Criar tag", prompt: "crie uma tag de release para o commit atual"),
    ]

    // MARK: - Explorer Actions

    static let explorerActions: [QuickAction] = [
        QuickAction(icon: "doc.text.magnifyingglass", label: "Resumo da pasta", prompt: "analise o conteúdo desta pasta e me dê um resumo do que é este projeto/diretório"),
        QuickAction(icon: "arrow.up.arrow.down", label: "Maiores arquivos", prompt: "encontre os maiores arquivos neste diretório e subdiretórios"),
        QuickAction(icon: "doc.on.doc", label: "Duplicados", prompt: "encontre arquivos duplicados neste diretório"),
        QuickAction(icon: "trash.circle", label: "Limpar temporários", prompt: "encontre e liste arquivos temporários (.DS_Store, .tmp, __pycache__, node_modules, etc.) que podem ser removidos"),
        QuickAction(icon: "terminal.fill", label: "Terminal aqui", prompt: "abra um terminal neste diretório"),
        QuickAction(icon: "magnifyingglass", label: "Buscar no código", prompt: "busque TODOs e FIXMEs nos arquivos de código deste diretório"),
        QuickAction(icon: "folder.badge.gearshape", label: "Organizar", prompt: "sugira uma organização para os arquivos desta pasta, agrupando por tipo"),
        QuickAction(icon: "doc.zipper", label: "Comprimir", prompt: "comprima os arquivos selecionados em um arquivo zip"),
        QuickAction(icon: "photo.stack", label: "Listar imagens", prompt: "encontre todas as imagens neste diretório e mostre um resumo com tamanhos"),
        QuickAction(icon: "chart.pie", label: "Uso de espaço", prompt: "analise o uso de espaço em disco deste diretório e mostre os maiores consumidores"),
    ]
}
