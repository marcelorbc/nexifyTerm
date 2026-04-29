import Foundation

enum NexToolRegistry {

    static let allTools: [NexToolDefinition] = [
        // ── Sistema ──
        getSystemInfo,
        getDiskUsage,
        getProcessList,
        getNetworkInfo,
        getBatteryStatus,

        // ── Arquivos ──
        readFile,
        writeFile,
        listDirectory,
        searchFiles,
        searchContent,

        // ── Terminal ──
        executeCommand,
        killProcess,

        // ── Pacotes ──
        managePackages,

        // ── macOS ──
        openApplication,
        openUrl,
        getClipboard,
        setClipboard,
        manageDefaults,

        // ── Automação ──
        sendEmail,
        readEmails,
        calendarEvents,
        sendMessage,
        readMessages,
        browserControl,
        runShortcut,
        sendNotification,
        controlMusic,
        searchContacts,
        manageReminders,

        // ── Desenvolvimento ──
        gitInfo,
        dockerInfo
    ]

    static func openAITools() -> [[String: Any]] {
        allTools.map { $0.toOpenAISchema() }
    }

    static func tools(for model: String) -> [NexToolDefinition] {
        let caps = ProviderType.capabilities(for: model)

        guard caps.canUseToolCalling else { return [] }

        var available = allTools

        if !caps.supportsFileAccess {
            let fileTools: Set<String> = ["read_file", "write_file", "search_files", "search_content"]
            available = available.filter { !fileTools.contains($0.name) }
        }

        if available.count > caps.maxToolCount && caps.maxToolCount > 0 {
            available = Array(available.prefix(caps.maxToolCount))
        }

        return available
    }

    static func openAITools(for model: String) -> [[String: Any]] {
        tools(for: model).map { $0.toOpenAISchema() }
    }

    static func toolDescriptionForPrompt() -> String {
        var desc = "=== FERRAMENTAS DISPONÍVEIS ===\n"
        desc += "Você pode chamar estas ferramentas para obter informações ou executar ações:\n\n"

        let grouped = Dictionary(grouping: allTools) { $0.category }
        let order: [NexToolDefinition.ToolCategory] = [.system, .files, .terminal, .packages, .macos, .automation, .development]

        for category in order {
            guard let tools = grouped[category] else { continue }
            desc += "[\(category.rawValue)]\n"
            for tool in tools {
                let params = tool.parameters.map { p in
                    let req = p.required ? "(obrigatório)" : "(opcional)"
                    return "  - \(p.name): \(p.description) \(req)"
                }.joined(separator: "\n")
                desc += "• \(tool.name): \(tool.description)\n"
                if !params.isEmpty { desc += "\(params)\n" }
            }
            desc += "\n"
        }
        return desc
    }

    // MARK: - Sistema

    static let getSystemInfo = NexToolDefinition(
        name: "get_system_info",
        description: "Obtém informações do sistema: versão do macOS, CPU, memória RAM, uptime e hostname",
        parameters: [
            NexToolParam("sections", type: "string",
                         description: "Seções a incluir separadas por vírgula: cpu, memory, os, uptime, hostname, all",
                         required: false)
        ],
        category: .system
    )

    static let getDiskUsage = NexToolDefinition(
        name: "get_disk_usage",
        description: "Obtém uso de disco de todos os volumes montados com espaço total, usado e disponível",
        parameters: [
            NexToolParam("path", description: "Caminho específico para verificar (default: todos os volumes)", required: false)
        ],
        category: .system
    )

    static let getProcessList = NexToolDefinition(
        name: "get_process_list",
        description: "Lista processos em execução com uso de CPU e memória, ordenados por consumo",
        parameters: [
            NexToolParam("sort_by", type: "string",
                         description: "Ordenar por: cpu ou memory",
                         required: false, enumValues: ["cpu", "memory"]),
            NexToolParam("limit", type: "string",
                         description: "Número máximo de processos a retornar (default: 15)",
                         required: false)
        ],
        category: .system
    )

    static let getNetworkInfo = NexToolDefinition(
        name: "get_network_info",
        description: "Obtém informações de rede: interfaces ativas, IPs, DNS, gateway e conectividade",
        parameters: [
            NexToolParam("check_connectivity", type: "string",
                         description: "Se 'true', testa conectividade com a internet",
                         required: false, enumValues: ["true", "false"])
        ],
        category: .system
    )

    static let getBatteryStatus = NexToolDefinition(
        name: "get_battery_status",
        description: "Obtém status da bateria: nível, carregando, ciclos, saúde e tempo restante",
        parameters: [],
        category: .system
    )

    // MARK: - Arquivos

    static let readFile = NexToolDefinition(
        name: "read_file",
        description: "Lê o conteúdo de um arquivo. Retorna as primeiras linhas para arquivos grandes",
        parameters: [
            NexToolParam("path", description: "Caminho absoluto ou relativo do arquivo"),
            NexToolParam("max_lines", type: "string",
                         description: "Número máximo de linhas a retornar (default: 100)",
                         required: false)
        ],
        category: .files
    )

    static let writeFile = NexToolDefinition(
        name: "write_file",
        description: "Escreve conteúdo em um arquivo. Cria o arquivo se não existir",
        parameters: [
            NexToolParam("path", description: "Caminho absoluto ou relativo do arquivo"),
            NexToolParam("content", description: "Conteúdo a ser escrito no arquivo"),
            NexToolParam("append", type: "string",
                         description: "Se 'true', adiciona ao final do arquivo em vez de sobrescrever",
                         required: false, enumValues: ["true", "false"])
        ],
        category: .files
    )

    static let listDirectory = NexToolDefinition(
        name: "list_directory",
        description: "Lista arquivos e diretórios com detalhes: tamanho, data de modificação, permissões",
        parameters: [
            NexToolParam("path", description: "Caminho do diretório (default: diretório atual)", required: false),
            NexToolParam("show_hidden", type: "string",
                         description: "Se 'true', mostra arquivos ocultos",
                         required: false, enumValues: ["true", "false"]),
            NexToolParam("sort_by", type: "string",
                         description: "Ordenar por: name, size, date",
                         required: false, enumValues: ["name", "size", "date"])
        ],
        category: .files
    )

    static let searchFiles = NexToolDefinition(
        name: "search_files",
        description: "Busca arquivos por nome ou padrão glob em um diretório e subdiretórios",
        parameters: [
            NexToolParam("pattern", description: "Padrão de busca (ex: '*.swift', 'README*', '*.log')"),
            NexToolParam("path", description: "Diretório onde buscar (default: diretório atual)", required: false),
            NexToolParam("max_depth", type: "string",
                         description: "Profundidade máxima de subdiretórios (default: 5)",
                         required: false)
        ],
        category: .files
    )

    static let searchContent = NexToolDefinition(
        name: "search_content",
        description: "Busca texto dentro de arquivos (como grep). Retorna linhas que contêm o padrão",
        parameters: [
            NexToolParam("pattern", description: "Texto ou regex a buscar dentro dos arquivos"),
            NexToolParam("path", description: "Diretório ou arquivo onde buscar (default: diretório atual)", required: false),
            NexToolParam("file_pattern", description: "Filtrar por tipo de arquivo (ex: '*.swift', '*.json')", required: false),
            NexToolParam("case_sensitive", type: "string",
                         description: "Se 'false', busca ignora maiúsculas/minúsculas",
                         required: false, enumValues: ["true", "false"])
        ],
        category: .files
    )

    // MARK: - Terminal

    static let executeCommand = NexToolDefinition(
        name: "execute_command",
        description: "Executa um comando shell no terminal e retorna o resultado. Use para qualquer operação não coberta pelas outras ferramentas",
        parameters: [
            NexToolParam("command", description: "O comando shell a ser executado"),
            NexToolParam("working_directory", description: "Diretório de trabalho para o comando", required: false),
            NexToolParam("timeout", type: "string",
                         description: "Timeout em segundos (default: 60)",
                         required: false)
        ],
        category: .terminal
    )

    static let killProcess = NexToolDefinition(
        name: "kill_process",
        description: "Encerra um processo por PID ou nome",
        parameters: [
            NexToolParam("target", description: "PID numérico ou nome do processo"),
            NexToolParam("signal", type: "string",
                         description: "Sinal a enviar: TERM, KILL, HUP",
                         required: false, enumValues: ["TERM", "KILL", "HUP"])
        ],
        category: .terminal
    )

    // MARK: - Pacotes

    static let managePackages = NexToolDefinition(
        name: "manage_packages",
        description: "Gerencia pacotes via Homebrew: instalar, desinstalar, buscar, listar ou atualizar",
        parameters: [
            NexToolParam("action", type: "string",
                         description: "Ação a executar",
                         enumValues: ["install", "uninstall", "search", "list", "update", "info", "outdated"]),
            NexToolParam("package_name", description: "Nome do pacote (não necessário para list/update/outdated)", required: false)
        ],
        category: .packages
    )

    // MARK: - macOS

    static let openApplication = NexToolDefinition(
        name: "open_application",
        description: "Abre um aplicativo macOS pelo nome",
        parameters: [
            NexToolParam("name", description: "Nome do aplicativo (ex: 'Safari', 'Terminal', 'Finder')")
        ],
        category: .macos
    )

    static let openUrl = NexToolDefinition(
        name: "open_url",
        description: "Abre uma URL no navegador embutido do NexOperator",
        parameters: [
            NexToolParam("url", description: "URL completa (ex: 'https://www.google.com')")
        ],
        category: .macos
    )

    static let getClipboard = NexToolDefinition(
        name: "get_clipboard",
        description: "Lê o conteúdo atual da área de transferência (clipboard) do macOS",
        parameters: [],
        category: .macos
    )

    static let setClipboard = NexToolDefinition(
        name: "set_clipboard",
        description: "Define o conteúdo da área de transferência (clipboard) do macOS",
        parameters: [
            NexToolParam("content", description: "Texto a ser copiado para a área de transferência")
        ],
        category: .macos
    )

    static let manageDefaults = NexToolDefinition(
        name: "manage_defaults",
        description: "Lê ou escreve preferências do macOS via 'defaults' (NSUserDefaults)",
        parameters: [
            NexToolParam("action", type: "string",
                         description: "Ação: read ou write",
                         enumValues: ["read", "write"]),
            NexToolParam("domain", description: "Domínio (ex: 'com.apple.finder', 'NSGlobalDomain')"),
            NexToolParam("key", description: "Chave da preferência", required: false),
            NexToolParam("value", description: "Valor a definir (apenas para write)", required: false),
            NexToolParam("value_type", type: "string",
                         description: "Tipo do valor: string, int, float, bool",
                         required: false, enumValues: ["string", "int", "float", "bool"])
        ],
        category: .macos
    )

    // MARK: - Desenvolvimento

    static let gitInfo = NexToolDefinition(
        name: "git_info",
        description: "Obtém informações de um repositório Git: status, log, branch, diff, remotes",
        parameters: [
            NexToolParam("action", type: "string",
                         description: "Operação Git a executar",
                         enumValues: ["status", "log", "branch", "diff", "remote", "stash_list"]),
            NexToolParam("path", description: "Caminho do repositório (default: diretório atual)", required: false),
            NexToolParam("limit", type: "string",
                         description: "Limite de resultados para log (default: 10)",
                         required: false)
        ],
        category: .development
    )

    static let dockerInfo = NexToolDefinition(
        name: "docker_info",
        description: "Obtém informações do Docker: containers, imagens, volumes e status do daemon",
        parameters: [
            NexToolParam("action", type: "string",
                         description: "Operação Docker a executar",
                         enumValues: ["containers", "images", "volumes", "info", "compose_status"]),
            NexToolParam("all", type: "string",
                         description: "Se 'true', inclui itens parados/inativos",
                         required: false, enumValues: ["true", "false"])
        ],
        category: .development
    )

    // MARK: - Automação macOS

    static let sendEmail = NexToolDefinition(
        name: "send_email",
        description: "Envia um email via Mail.app ou Microsoft Outlook. Suporta destinatário, assunto, corpo e CC/BCC",
        parameters: [
            NexToolParam("to", description: "Endereço de email do destinatário"),
            NexToolParam("subject", description: "Assunto do email"),
            NexToolParam("body", description: "Corpo do email em texto"),
            NexToolParam("cc", description: "Endereço CC (opcional)", required: false),
            NexToolParam("bcc", description: "Endereço BCC (opcional)", required: false),
            NexToolParam("app", type: "string",
                         description: "App de email a usar (default: mail)",
                         required: false, enumValues: ["mail", "outlook"])
        ],
        category: .automation
    )

    static let readEmails = NexToolDefinition(
        name: "read_emails",
        description: "Lê emails recentes do Mail.app ou Outlook. Retorna remetente, assunto, data e preview do corpo",
        parameters: [
            NexToolParam("count", type: "string",
                         description: "Número de emails a retornar (default: 5)",
                         required: false),
            NexToolParam("mailbox", description: "Nome da caixa: INBOX, Sent, etc. (default: INBOX)", required: false),
            NexToolParam("app", type: "string",
                         description: "App de email (default: mail)",
                         required: false, enumValues: ["mail", "outlook"])
        ],
        category: .automation
    )

    static let calendarEvents = NexToolDefinition(
        name: "calendar_events",
        description: "Lê ou cria eventos no Calendário do macOS. Lista eventos de hoje/semana ou cria novos",
        parameters: [
            NexToolParam("action", type: "string",
                         description: "Ação a executar",
                         enumValues: ["list_today", "list_week", "create", "list_calendars"]),
            NexToolParam("title", description: "Título do evento (para create)", required: false),
            NexToolParam("start_date", description: "Data/hora início no formato 'YYYY-MM-DD HH:mm' (para create)", required: false),
            NexToolParam("end_date", description: "Data/hora fim no formato 'YYYY-MM-DD HH:mm' (para create)", required: false),
            NexToolParam("calendar_name", description: "Nome do calendário (para create, default: primeiro calendário)", required: false),
            NexToolParam("location", description: "Local do evento (para create)", required: false),
            NexToolParam("notes", description: "Notas do evento (para create)", required: false)
        ],
        category: .automation
    )

    static let sendMessage = NexToolDefinition(
        name: "send_message",
        description: "Envia uma mensagem via iMessage/Messages do macOS. Funciona com números de telefone ou emails do iMessage",
        parameters: [
            NexToolParam("to", description: "Número de telefone ou email do destinatário (ex: +5511999999999)"),
            NexToolParam("message", description: "Texto da mensagem a enviar")
        ],
        category: .automation
    )

    static let readMessages = NexToolDefinition(
        name: "read_messages",
        description: "Lê mensagens recentes do Messages/iMessage do macOS",
        parameters: [
            NexToolParam("count", type: "string",
                         description: "Número de mensagens a retornar (default: 10)",
                         required: false),
            NexToolParam("from", description: "Filtrar por remetente (número ou email)", required: false)
        ],
        category: .automation
    )

    static let browserControl = NexToolDefinition(
        name: "browser_control",
        description: "Controla Chrome ou Safari: abrir URL, listar abas, buscar texto, fechar aba, obter URL atual",
        parameters: [
            NexToolParam("action", type: "string",
                         description: "Ação no navegador",
                         enumValues: ["open_url", "list_tabs", "current_url", "current_title", "close_tab", "search", "new_tab", "reload"]),
            NexToolParam("url", description: "URL para abrir (para open_url/new_tab)", required: false),
            NexToolParam("query", description: "Texto para buscar no Google (para search)", required: false),
            NexToolParam("tab_index", type: "string",
                         description: "Índice da aba (para close_tab, base 1)",
                         required: false),
            NexToolParam("browser", type: "string",
                         description: "Navegador (default: chrome)",
                         required: false, enumValues: ["chrome", "safari"])
        ],
        category: .automation
    )

    static let runShortcut = NexToolDefinition(
        name: "run_shortcut",
        description: "Executa um Atalho do macOS (Shortcuts.app). Lista atalhos disponíveis ou executa um pelo nome",
        parameters: [
            NexToolParam("action", type: "string",
                         description: "Ação: list para listar, run para executar",
                         enumValues: ["list", "run"]),
            NexToolParam("name", description: "Nome do atalho a executar (para run)", required: false),
            NexToolParam("input", description: "Texto de entrada para o atalho (para run)", required: false)
        ],
        category: .automation
    )

    static let sendNotification = NexToolDefinition(
        name: "send_notification",
        description: "Envia uma notificação no macOS com título, mensagem e som opcional",
        parameters: [
            NexToolParam("title", description: "Título da notificação"),
            NexToolParam("message", description: "Corpo da notificação"),
            NexToolParam("subtitle", description: "Subtítulo (opcional)", required: false),
            NexToolParam("sound", type: "string",
                         description: "Se 'true', toca som (default: true)",
                         required: false, enumValues: ["true", "false"])
        ],
        category: .automation
    )

    static let controlMusic = NexToolDefinition(
        name: "control_music",
        description: "Controla Spotify ou Apple Music: play, pause, next, previous, status, buscar e tocar",
        parameters: [
            NexToolParam("action", type: "string",
                         description: "Ação de música",
                         enumValues: ["play", "pause", "next", "previous", "status", "play_track", "volume_up", "volume_down"]),
            NexToolParam("query", description: "Nome da música/artista para play_track", required: false),
            NexToolParam("app", type: "string",
                         description: "App de música (default: spotify)",
                         required: false, enumValues: ["spotify", "music"])
        ],
        category: .automation
    )

    static let searchContacts = NexToolDefinition(
        name: "search_contacts",
        description: "Busca contatos no app Contatos do macOS por nome, email ou telefone",
        parameters: [
            NexToolParam("query", description: "Termo de busca (nome, email ou telefone)"),
            NexToolParam("limit", type: "string",
                         description: "Máximo de resultados (default: 10)",
                         required: false)
        ],
        category: .automation
    )

    static let manageReminders = NexToolDefinition(
        name: "manage_reminders",
        description: "Gerencia o app Lembretes do macOS: listar, criar ou completar lembretes",
        parameters: [
            NexToolParam("action", type: "string",
                         description: "Ação nos lembretes",
                         enumValues: ["list", "create", "complete", "list_lists"]),
            NexToolParam("title", description: "Título do lembrete (para create)", required: false),
            NexToolParam("due_date", description: "Data de vencimento 'YYYY-MM-DD HH:mm' (para create)", required: false),
            NexToolParam("list_name", description: "Nome da lista de lembretes (default: Reminders)", required: false),
            NexToolParam("reminder_index", type: "string",
                         description: "Índice do lembrete para completar (base 1)",
                         required: false),
            NexToolParam("notes", description: "Notas do lembrete (para create)", required: false)
        ],
        category: .automation
    )
}
