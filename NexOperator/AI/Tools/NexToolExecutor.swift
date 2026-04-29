import Foundation

actor NexToolExecutor {

    private let workingDirectory: String
    private let maxOutputChars = 4000

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    func execute(call: NexToolCall) async -> NexToolResult {
        NexLog.ai.info("Executing tool: \(call.name) with args: \(call.arguments)")

        let content: String
        let isError: Bool

        do {
            content = try await dispatch(call)
            isError = false
        } catch {
            content = "Erro: \(error.localizedDescription)"
            isError = true
        }

        let truncated = content.count > maxOutputChars
            ? String(content.prefix(maxOutputChars / 2)) + "\n...[truncado \(content.count) chars]...\n" + String(content.suffix(maxOutputChars / 2))
            : content

        return NexToolResult(callId: call.id, toolName: call.name, content: truncated, isError: isError)
    }

    private func dispatch(_ call: NexToolCall) async throws -> String {
        let args = call.arguments

        switch call.name {
        case "get_system_info":     return await getSystemInfo(sections: args["sections"])
        case "get_disk_usage":      return await getDiskUsage(path: args["path"])
        case "get_process_list":    return await getProcessList(sortBy: args["sort_by"], limit: args["limit"])
        case "get_network_info":    return await getNetworkInfo(checkConnectivity: args["check_connectivity"] == "true")
        case "get_battery_status":  return await getBatteryStatus()
        case "read_file":           return try readFile(path: args["path"] ?? "", maxLines: Int(args["max_lines"] ?? "100") ?? 100)
        case "write_file":          return try writeFile(path: args["path"] ?? "", content: args["content"] ?? "", append: args["append"] == "true")
        case "list_directory":      return await listDirectory(path: args["path"], showHidden: args["show_hidden"] == "true", sortBy: args["sort_by"])
        case "search_files":        return await searchFiles(pattern: args["pattern"] ?? "*", path: args["path"], maxDepth: args["max_depth"])
        case "search_content":      return await searchContent(pattern: args["pattern"] ?? "", path: args["path"], filePattern: args["file_pattern"], caseSensitive: args["case_sensitive"] != "false")
        case "execute_command":     return await executeCommand(command: args["command"] ?? "", dir: args["working_directory"], timeout: args["timeout"])
        case "kill_process":        return await killProcess(target: args["target"] ?? "", signal: args["signal"])
        case "manage_packages":     return await managePackages(action: args["action"] ?? "list", packageName: args["package_name"])
        case "open_application":    return await openApplication(name: args["name"] ?? "")
        case "open_url":            return openUrl(url: args["url"] ?? "")
        case "get_clipboard":       return await getClipboard()
        case "set_clipboard":       return await setClipboard(content: args["content"] ?? "")
        case "manage_defaults":     return await manageDefaults(action: args["action"] ?? "read", domain: args["domain"] ?? "", key: args["key"], value: args["value"], valueType: args["value_type"])
        case "git_info":            return await gitInfo(action: args["action"] ?? "status", path: args["path"], limit: args["limit"])
        case "docker_info":         return await dockerInfo(action: args["action"] ?? "containers", all: args["all"] == "true")

        case "send_email":          return await sendEmail(to: args["to"] ?? "", subject: args["subject"] ?? "", body: args["body"] ?? "", cc: args["cc"], bcc: args["bcc"], app: args["app"] ?? "mail")
        case "read_emails":         return await readEmails(count: Int(args["count"] ?? "5") ?? 5, mailbox: args["mailbox"] ?? "INBOX", app: args["app"] ?? "mail")
        case "calendar_events":     return await calendarEvents(action: args["action"] ?? "list_today", title: args["title"], startDate: args["start_date"], endDate: args["end_date"], calendarName: args["calendar_name"], location: args["location"], notes: args["notes"])
        case "send_message":        return await sendMessage(to: args["to"] ?? "", message: args["message"] ?? "")
        case "read_messages":       return await readMessages(count: Int(args["count"] ?? "10") ?? 10, from: args["from"])
        case "browser_control":     return await browserControl(action: args["action"] ?? "list_tabs", url: args["url"], query: args["query"], tabIndex: args["tab_index"], browser: args["browser"] ?? "chrome")
        case "run_shortcut":        return await runShortcut(action: args["action"] ?? "list", name: args["name"], input: args["input"])
        case "send_notification":   return await sendNotification(title: args["title"] ?? "NexOperator", message: args["message"] ?? "", subtitle: args["subtitle"], sound: args["sound"] != "false")
        case "control_music":       return await controlMusic(action: args["action"] ?? "status", query: args["query"], app: args["app"] ?? "spotify")
        case "search_contacts":     return await searchContacts(query: args["query"] ?? "", limit: Int(args["limit"] ?? "10") ?? 10)
        case "manage_reminders":    return await manageReminders(action: args["action"] ?? "list", title: args["title"], dueDate: args["due_date"], listName: args["list_name"], reminderIndex: args["reminder_index"], notes: args["notes"])

        default:
            return "Ferramenta '\(call.name)' não reconhecida"
        }
    }

    // MARK: - Sistema

    private func getSystemInfo(sections: String?) async -> String {
        let requested = (sections ?? "all").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let all = requested.contains("all")

        var info: [String] = []

        if all || requested.contains("os") {
            let output = await shell("/usr/bin/sw_vers")
            info.append("=== macOS ===\n\(output)")
        }

        if all || requested.contains("hostname") {
            let output = await shell("hostname")
            info.append("Hostname: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        if all || requested.contains("cpu") {
            let brand = await shell("/usr/sbin/sysctl -n machdep.cpu.brand_string")
            let cores = await shell("/usr/sbin/sysctl -n hw.ncpu")
            info.append("CPU: \(brand.trimmingCharacters(in: .whitespacesAndNewlines)) (\(cores.trimmingCharacters(in: .whitespacesAndNewlines)) cores)")
        }

        if all || requested.contains("memory") {
            let mem = await shell("/usr/sbin/sysctl -n hw.memsize")
            if let bytes = UInt64(mem.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let gb = Double(bytes) / 1_073_741_824
                info.append("Memória RAM: \(String(format: "%.1f", gb)) GB")
            }
            let vmStat = await shell("vm_stat | head -10")
            info.append("vm_stat:\n\(vmStat)")
        }

        if all || requested.contains("uptime") {
            let output = await shell("uptime")
            info.append("Uptime: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return info.joined(separator: "\n\n")
    }

    private func getDiskUsage(path: String?) async -> String {
        if let path = path, !path.isEmpty {
            return await shell("df -h '\(path.replacingOccurrences(of: "'", with: "'\\''"))' && echo '---' && du -sh '\(path.replacingOccurrences(of: "'", with: "'\\''"))' 2>/dev/null | head -20")
        }
        return await shell("df -h")
    }

    private func getProcessList(sortBy: String?, limit: String?) async -> String {
        let maxProcs = Int(limit ?? "15") ?? 15
        let sortFlag = (sortBy ?? "cpu") == "memory" ? "-%mem" : "-%cpu"
        return await shell("ps aux --sort=\(sortFlag) | head -\(maxProcs + 1)")
    }

    private func getNetworkInfo(checkConnectivity: Bool) async -> String {
        var info = await shell("ifconfig | grep -E '^[a-z]|inet ' | head -30")
        let dns = await shell("/usr/sbin/scutil --dns | head -20")
        info += "\n\n=== DNS ===\n" + dns
        let gateway = await shell("netstat -nr | grep default | head -5")
        info += "\n\n=== Gateway ===\n" + gateway

        if checkConnectivity {
            let ping = await shell("ping -c 1 -t 3 8.8.8.8 2>&1 | tail -2")
            info += "\n\n=== Conectividade ===\n\(ping)"
        }

        return info
    }

    private func getBatteryStatus() async -> String {
        let pmset = await shell("/usr/bin/pmset -g batt")
        let spPower = await shell("/usr/sbin/system_profiler SPPowerDataType 2>/dev/null | head -30")
        return "=== Battery ===\n\(pmset)\n\n=== Power Details ===\n\(spPower)"
    }

    // MARK: - Arquivos

    private func readFile(path: String, maxLines: Int) throws -> String {
        let resolved = resolvePath(path)
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw ToolError.fileNotFound(resolved)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: resolved)[.size] as? UInt64) ?? 0
        if fileSize > 1_000_000 {
            guard let handle = FileHandle(forReadingAtPath: resolved) else {
                throw ToolError.readFailed(resolved)
            }
            defer { handle.closeFile() }
            let data = handle.readData(ofLength: 50_000)
            let text = String(data: data, encoding: .utf8) ?? "[Conteúdo binário não pode ser exibido]"
            let lines = text.components(separatedBy: "\n")
            return "[\(resolved) - \(formatBytes(fileSize)) - mostrando primeiras \(min(maxLines, lines.count)) linhas]\n\n" +
                   lines.prefix(maxLines).joined(separator: "\n")
        }

        guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return "[Arquivo binário ou encoding não suportado: \(resolved)]"
        }

        let lines = content.components(separatedBy: "\n")
        if lines.count > maxLines {
            return "[\(resolved) - \(lines.count) linhas - mostrando primeiras \(maxLines)]\n\n" +
                   lines.prefix(maxLines).joined(separator: "\n")
        }
        return "[\(resolved) - \(lines.count) linhas]\n\n\(content)"
    }

    private func writeFile(path: String, content: String, append: Bool) throws -> String {
        let resolved = resolvePath(path)

        let dir = (resolved as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        if append {
            if let handle = FileHandle(forWritingAtPath: resolved) {
                handle.seekToEndOfFile()
                if let data = content.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } else {
                try content.write(toFile: resolved, atomically: true, encoding: .utf8)
            }
        } else {
            try content.write(toFile: resolved, atomically: true, encoding: .utf8)
        }

        return "Arquivo escrito com sucesso: \(resolved) (\(content.count) caracteres)"
    }

    private func listDirectory(path: String?, showHidden: Bool, sortBy: String?) async -> String {
        let resolved = resolvePath(path ?? ".")
        var flags = "-lh"
        if showHidden { flags += "a" }

        let sortCmd: String
        switch sortBy {
        case "size":  sortCmd = " | sort -k5 -h -r"
        case "date":  sortCmd = " | sort -k6,7"
        default:      sortCmd = ""
        }

        return await shell("ls \(flags) '\(resolved.replacingOccurrences(of: "'", with: "'\\''"))'\(sortCmd)")
    }

    private func searchFiles(pattern: String, path: String?, maxDepth: String?) async -> String {
        let resolved = resolvePath(path ?? ".")
        let depth = Int(maxDepth ?? "5") ?? 5
        return await shell("find '\(resolved.replacingOccurrences(of: "'", with: "'\\''"))' -maxdepth \(depth) -name '\(pattern.replacingOccurrences(of: "'", with: "'\\''"))' -not -path '*/\\.git/*' 2>/dev/null | head -50")
    }

    private func searchContent(pattern: String, path: String?, filePattern: String?, caseSensitive: Bool) async -> String {
        let resolved = resolvePath(path ?? ".")
        var cmd = "grep -rn"
        if !caseSensitive { cmd += " -i" }
        cmd += " '\(pattern.replacingOccurrences(of: "'", with: "'\\''"))'"
        cmd += " '\(resolved.replacingOccurrences(of: "'", with: "'\\''"))'"
        if let fp = filePattern, !fp.isEmpty {
            cmd += " --include='\(fp.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        cmd += " 2>/dev/null | head -40"
        return await shell(cmd)
    }

    // MARK: - Terminal

    private func executeCommand(command: String, dir: String?, timeout: String?) async -> String {
        let effectiveDir = dir ?? workingDirectory
        let effectiveTimeout = TimeInterval(timeout ?? "") ?? 60

        let output = await CommandExecutor.run(
            command,
            workingDirectory: effectiveDir,
            timeout: effectiveTimeout
        )

        var result = ""
        if !output.stdout.isEmpty { result += output.stdout }
        if !output.stderr.isEmpty {
            if !result.isEmpty { result += "\n" }
            result += "[stderr] \(output.stderr)"
        }
        if output.timedOut { result += "\n[TIMEOUT após \(Int(effectiveTimeout))s]" }
        result += "\n[exit_code: \(output.exitCode)]"

        return result.isEmpty ? "[Comando executado sem saída - exit code: \(output.exitCode)]" : result
    }

    private func killProcess(target: String, signal: String?) async -> String {
        let sig = signal ?? "TERM"

        if let pid = Int(target) {
            return await shell("kill -\(sig) \(pid) 2>&1 && echo 'Processo \(pid) encerrado com sinal \(sig)' || echo 'Falha ao encerrar processo \(pid)'")
        }

        let escaped = target.replacingOccurrences(of: "'", with: "'\\''")
        return await shell("killall -\(sig) '\(escaped)' 2>&1 && echo 'Processos \(target) encerrados com sinal \(sig)' || echo 'Falha ao encerrar processos \(target)'")
    }

    // MARK: - Pacotes

    private func managePackages(action: String, packageName: String?) async -> String {
        let pkg = (packageName ?? "").replacingOccurrences(of: "'", with: "'\\''")

        switch action {
        case "install":
            guard !pkg.isEmpty else { return "Erro: nome do pacote é obrigatório para install" }
            return await shell("HOMEBREW_NO_AUTO_UPDATE=1 brew install '\(pkg)' 2>&1")
        case "uninstall":
            guard !pkg.isEmpty else { return "Erro: nome do pacote é obrigatório para uninstall" }
            return await shell("brew uninstall '\(pkg)' 2>&1")
        case "search":
            guard !pkg.isEmpty else { return "Erro: termo de busca é obrigatório para search" }
            return await shell("brew search '\(pkg)' 2>&1")
        case "list":
            return await shell("brew list --versions 2>&1 | head -40")
        case "update":
            return await shell("brew update 2>&1 && brew upgrade 2>&1")
        case "info":
            guard !pkg.isEmpty else { return "Erro: nome do pacote é obrigatório para info" }
            return await shell("brew info '\(pkg)' 2>&1")
        case "outdated":
            return await shell("brew outdated 2>&1")
        default:
            return "Ação brew não reconhecida: \(action)"
        }
    }

    // MARK: - macOS

    private func openApplication(name: String) async -> String {
        let escaped = name.replacingOccurrences(of: "'", with: "'\\''")
        return await shell("open -a '\(escaped)' 2>&1 && echo 'Aplicativo \(name) aberto com sucesso' || echo 'Falha ao abrir \(name)'")
    }

    private func openUrl(url: String) -> String {
        return "__OPEN_URL__:\(url)"
    }

    private func getClipboard() async -> String {
        let content = await shell("pbpaste 2>/dev/null")
        return content.isEmpty ? "[Clipboard vazio]" : content
    }

    private func setClipboard(content: String) async -> String {
        let escaped = content.replacingOccurrences(of: "'", with: "'\\''")
        _ = await shell("echo -n '\(escaped)' | pbcopy")
        return "Conteúdo copiado para a área de transferência (\(content.count) caracteres)"
    }

    private func manageDefaults(action: String, domain: String, key: String?, value: String?, valueType: String?) async -> String {
        let escapedDomain = domain.replacingOccurrences(of: "'", with: "'\\''")

        if action == "read" {
            if let key = key, !key.isEmpty {
                let escapedKey = key.replacingOccurrences(of: "'", with: "'\\''")
                return await shell("/usr/bin/defaults read '\(escapedDomain)' '\(escapedKey)' 2>&1")
            }
            return await shell("/usr/bin/defaults read '\(escapedDomain)' 2>&1 | head -50")
        }

        if action == "write" {
            guard let key = key, !key.isEmpty else { return "Erro: key é obrigatória para write" }
            guard let value = value else { return "Erro: value é obrigatório para write" }

            let escapedKey = key.replacingOccurrences(of: "'", with: "'\\''")
            let escapedValue = value.replacingOccurrences(of: "'", with: "'\\''")

            let typeFlag: String
            switch valueType {
            case "int":   typeFlag = "-int"
            case "float": typeFlag = "-float"
            case "bool":  typeFlag = "-bool"
            default:      typeFlag = "-string"
            }

            return await shell("/usr/bin/defaults write '\(escapedDomain)' '\(escapedKey)' \(typeFlag) '\(escapedValue)' 2>&1 && echo 'Preferência definida com sucesso'")
        }

        return "Ação defaults não reconhecida: \(action)"
    }

    // MARK: - Desenvolvimento

    private func gitInfo(action: String, path: String?, limit: String?) async -> String {
        let resolved = resolvePath(path ?? ".")
        let maxLog = Int(limit ?? "10") ?? 10
        let cdPrefix = "cd '\(resolved.replacingOccurrences(of: "'", with: "'\\''"))' && "

        switch action {
        case "status":
            return await shell("\(cdPrefix)git status 2>&1")
        case "log":
            return await shell("\(cdPrefix)git log --oneline --graph -\(maxLog) 2>&1")
        case "branch":
            return await shell("\(cdPrefix)git branch -a 2>&1")
        case "diff":
            return await shell("\(cdPrefix)git diff --stat 2>&1 && echo '---' && git diff 2>&1 | head -80")
        case "remote":
            return await shell("\(cdPrefix)git remote -v 2>&1")
        case "stash_list":
            return await shell("\(cdPrefix)git stash list 2>&1")
        default:
            return "Ação git não reconhecida: \(action)"
        }
    }

    private func dockerInfo(action: String, all: Bool) async -> String {
        let allFlag = all ? " -a" : ""

        switch action {
        case "containers":
            return await shell("docker ps\(allFlag) --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}' 2>&1")
        case "images":
            return await shell("docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' 2>&1")
        case "volumes":
            return await shell("docker volume ls 2>&1")
        case "info":
            return await shell("docker info 2>&1 | head -30")
        case "compose_status":
            return await shell("docker compose ps 2>&1 || docker-compose ps 2>&1")
        default:
            return "Ação docker não reconhecida: \(action)"
        }
    }

    // MARK: - Automação macOS

    private func sendEmail(to: String, subject: String, body: String, cc: String?, bcc: String?, app: String) async -> String {
        let escapedTo = to.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedSubject = subject.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")

        if app == "outlook" {
            var script = """
            tell application "Microsoft Outlook"
                set newMsg to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)"}
                make new to recipient at newMsg with properties {email address:{address:"\(escapedTo)"}}
            """
            if let cc = cc, !cc.isEmpty {
                let escapedCC = cc.replacingOccurrences(of: "\"", with: "\\\"")
                script += "\n    make new cc recipient at newMsg with properties {email address:{address:\"\(escapedCC)\"}}"
            }
            script += "\n    send newMsg\nend tell"
            return await runAppleScript(script)
        }

        var script = """
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:true}
            tell newMsg
                make new to recipient at end of to recipients with properties {address:"\(escapedTo)"}
        """
        if let cc = cc, !cc.isEmpty {
            let escapedCC = cc.replacingOccurrences(of: "\"", with: "\\\"")
            script += "\n        make new cc recipient at end of cc recipients with properties {address:\"\(escapedCC)\"}"
        }
        if let bcc = bcc, !bcc.isEmpty {
            let escapedBCC = bcc.replacingOccurrences(of: "\"", with: "\\\"")
            script += "\n        make new bcc recipient at end of bcc recipients with properties {address:\"\(escapedBCC)\"}"
        }
        script += """

            end tell
            send newMsg
        end tell
        """
        return await runAppleScript(script)
    }

    private func readEmails(count: Int, mailbox: String, app: String) async -> String {
        if app == "outlook" {
            let script = """
            tell application "Microsoft Outlook"
                set msgs to messages 1 through \(count) of inbox
                set output to ""
                repeat with msg in msgs
                    set output to output & "---" & linefeed
                    set output to output & "De: " & (sender of msg) & linefeed
                    set output to output & "Assunto: " & (subject of msg) & linefeed
                    set output to output & "Data: " & (time received of msg as text) & linefeed
                    set output to output & "Preview: " & (text of (plain text content of msg))'s text 1 thru 200 & linefeed
                end repeat
                return output
            end tell
            """
            return await runAppleScript(script)
        }

        let script = """
        tell application "Mail"
            set mailAccount to first account
            set targetMailbox to mailbox "\(mailbox)" of mailAccount
            set msgs to messages 1 through \(count) of targetMailbox
            set output to ""
            repeat with msg in msgs
                set output to output & "---" & linefeed
                set output to output & "De: " & (sender of msg) & linefeed
                set output to output & "Assunto: " & (subject of msg) & linefeed
                set output to output & "Data: " & (date received of msg as text) & linefeed
                set msgContent to content of msg
                if length of msgContent > 200 then
                    set msgContent to text 1 thru 200 of msgContent
                end if
                set output to output & "Preview: " & msgContent & linefeed
            end repeat
            return output
        end tell
        """
        return await runAppleScript(script)
    }

    private func calendarEvents(action: String, title: String?, startDate: String?, endDate: String?, calendarName: String?, location: String?, notes: String?) async -> String {
        switch action {
        case "list_calendars":
            let script = """
            tell application "Calendar"
                set calNames to ""
                repeat with cal in calendars
                    set calNames to calNames & name of cal & linefeed
                end repeat
                return calNames
            end tell
            """
            return await runAppleScript(script)

        case "list_today":
            let script = """
            set todayStart to current date
            set time of todayStart to 0
            set todayEnd to todayStart + 86400
            tell application "Calendar"
                set output to ""
                repeat with cal in calendars
                    set evts to (every event of cal whose start date >= todayStart and start date < todayEnd)
                    repeat with evt in evts
                        set output to output & "📅 " & summary of evt & linefeed
                        set output to output & "   Início: " & (start date of evt as text) & linefeed
                        set output to output & "   Fim: " & (end date of evt as text) & linefeed
                        if location of evt is not missing value and location of evt is not "" then
                            set output to output & "   Local: " & location of evt & linefeed
                        end if
                        set output to output & "   Cal: " & name of (calendar of evt) & linefeed
                        set output to output & "---" & linefeed
                    end repeat
                end repeat
                if output is "" then return "Nenhum evento hoje."
                return output
            end tell
            """
            return await runAppleScript(script)

        case "list_week":
            let script = """
            set todayStart to current date
            set time of todayStart to 0
            set weekEnd to todayStart + (7 * 86400)
            tell application "Calendar"
                set output to ""
                repeat with cal in calendars
                    set evts to (every event of cal whose start date >= todayStart and start date < weekEnd)
                    repeat with evt in evts
                        set output to output & "📅 " & summary of evt & linefeed
                        set output to output & "   Início: " & (start date of evt as text) & linefeed
                        set output to output & "   Fim: " & (end date of evt as text) & linefeed
                        if location of evt is not missing value and location of evt is not "" then
                            set output to output & "   Local: " & location of evt & linefeed
                        end if
                        set output to output & "   Cal: " & name of (calendar of evt) & linefeed
                        set output to output & "---" & linefeed
                    end repeat
                end repeat
                if output is "" then return "Nenhum evento esta semana."
                return output
            end tell
            """
            return await runAppleScript(script)

        case "create":
            guard let title = title, !title.isEmpty else { return "Erro: título é obrigatório" }
            guard let startDate = startDate, !startDate.isEmpty else { return "Erro: start_date é obrigatório" }

            let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            let end = endDate ?? startDate
            let calTarget = calendarName.map { "calendar \"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? "first calendar"
            let locProp = location.map { ", location:\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? ""
            let notesProp = notes.map { ", description:\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? ""

            let script = """
            set startD to date "\(startDate)"
            set endD to date "\(end)"
            tell application "Calendar"
                tell \(calTarget)
                    make new event with properties {summary:"\(escapedTitle)", start date:startD, end date:endD\(locProp)\(notesProp)}
                end tell
            end tell
            return "Evento '\(escapedTitle)' criado com sucesso!"
            """
            return await runAppleScript(script)

        default:
            return "Ação calendar não reconhecida: \(action)"
        }
    }

    private func sendMessage(to: String, message: String) async -> String {
        let escapedTo = to.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedMsg = message.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            set targetBuddy to buddy "\(escapedTo)" of (service 1 whose service type is iMessage)
            send "\(escapedMsg)" to targetBuddy
        end tell
        return "Mensagem enviada para \(escapedTo)"
        """
        return await runAppleScript(script)
    }

    private func readMessages(count: Int, from: String?) async -> String {
        var whereClause = ""
        if let from = from, !from.isEmpty {
            let escapedFrom = from.replacingOccurrences(of: "'", with: "'\\''")
            whereClause = "WHERE handle.id LIKE '%\(escapedFrom)%'"
        }

        let query = """
        SELECT
            datetime(message.date/1000000000 + 978307200, 'unixepoch', 'localtime') as date,
            CASE WHEN message.is_from_me = 1 THEN 'Eu' ELSE COALESCE(handle.id, 'Desconhecido') END as sender,
            message.text
        FROM message
        LEFT JOIN handle ON message.handle_id = handle.ROWID
        \(whereClause)
        WHERE message.text IS NOT NULL
        ORDER BY message.date DESC
        LIMIT \(count)
        """

        let escapedQuery = query.replacingOccurrences(of: "'", with: "'\\''").replacingOccurrences(of: "\n", with: " ")
        return await shell("sqlite3 -header -column ~/Library/Messages/chat.db '\(escapedQuery)' 2>&1 || echo 'Erro: permissão negada ao banco de mensagens. Verifique Full Disk Access nas Preferências do Sistema.'")
    }

    private func browserControl(action: String, url: String?, query: String?, tabIndex: String?, browser: String) async -> String {
        let appName = browser == "safari" ? "Safari" : "Google Chrome"
        let tabProp = browser == "safari" ? "current tab of front window" : "active tab of front window"
        let urlProp = browser == "safari" ? "URL" : "URL"
        let titleProp = browser == "safari" ? "name" : "title"

        switch action {
        case "open_url":
            guard let url = url, !url.isEmpty else { return "Erro: url é obrigatório" }
            let escapedURL = url.replacingOccurrences(of: "\"", with: "\\\"")
            if browser == "safari" {
                let script = """
                tell application "Safari"
                    activate
                    if (count of windows) = 0 then make new document
                    set URL of current tab of front window to "\(escapedURL)"
                end tell
                return "URL aberta no Safari: \(escapedURL)"
                """
                return await runAppleScript(script)
            }
            let script = """
            tell application "Google Chrome"
                activate
                if (count of windows) = 0 then make new window
                set URL of active tab of front window to "\(escapedURL)"
            end tell
            return "URL aberta no Chrome: \(escapedURL)"
            """
            return await runAppleScript(script)

        case "new_tab":
            let targetURL = url ?? "about:blank"
            let escapedURL = targetURL.replacingOccurrences(of: "\"", with: "\\\"")
            if browser == "safari" {
                let script = """
                tell application "Safari"
                    activate
                    if (count of windows) = 0 then make new document
                    tell front window
                        set newTab to make new tab with properties {URL:"\(escapedURL)"}
                        set current tab to newTab
                    end tell
                end tell
                return "Nova aba aberta no Safari"
                """
                return await runAppleScript(script)
            }
            let script = """
            tell application "Google Chrome"
                activate
                if (count of windows) = 0 then make new window
                tell front window
                    make new tab with properties {URL:"\(escapedURL)"}
                end tell
            end tell
            return "Nova aba aberta no Chrome"
            """
            return await runAppleScript(script)

        case "list_tabs":
            if browser == "safari" {
                let script = """
                tell application "Safari"
                    set output to ""
                    set tabIdx to 1
                    repeat with w in windows
                        repeat with t in tabs of w
                            set output to output & tabIdx & ". " & name of t & linefeed & "   " & URL of t & linefeed
                            set tabIdx to tabIdx + 1
                        end repeat
                    end repeat
                    if output is "" then return "Nenhuma aba aberta."
                    return output
                end tell
                """
                return await runAppleScript(script)
            }
            let script = """
            tell application "Google Chrome"
                set output to ""
                set tabIdx to 1
                repeat with w in windows
                    repeat with t in tabs of w
                        set output to output & tabIdx & ". " & title of t & linefeed & "   " & URL of t & linefeed
                        set tabIdx to tabIdx + 1
                    end repeat
                end repeat
                if output is "" then return "Nenhuma aba aberta."
                return output
            end tell
            """
            return await runAppleScript(script)

        case "current_url":
            let script = """
            tell application "\(appName)"
                return \(urlProp) of \(tabProp)
            end tell
            """
            return await runAppleScript(script)

        case "current_title":
            let script = """
            tell application "\(appName)"
                return \(titleProp) of \(tabProp)
            end tell
            """
            return await runAppleScript(script)

        case "close_tab":
            let idx = Int(tabIndex ?? "1") ?? 1
            if browser == "safari" {
                let script = """
                tell application "Safari"
                    close tab \(idx) of front window
                end tell
                return "Aba \(idx) fechada no Safari"
                """
                return await runAppleScript(script)
            }
            let script = """
            tell application "Google Chrome"
                delete tab \(idx) of front window
            end tell
            return "Aba \(idx) fechada no Chrome"
            """
            return await runAppleScript(script)

        case "search":
            guard let query = query, !query.isEmpty else { return "Erro: query é obrigatório" }
            let searchURL = "https://www.google.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            let escapedURL = searchURL.replacingOccurrences(of: "\"", with: "\\\"")
            if browser == "safari" {
                let script = """
                tell application "Safari"
                    activate
                    if (count of windows) = 0 then make new document
                    set URL of current tab of front window to "\(escapedURL)"
                end tell
                return "Buscando: \(query)"
                """
                return await runAppleScript(script)
            }
            let script = """
            tell application "Google Chrome"
                activate
                if (count of windows) = 0 then make new window
                set URL of active tab of front window to "\(escapedURL)"
            end tell
            return "Buscando: \(query)"
            """
            return await runAppleScript(script)

        case "reload":
            if browser == "safari" {
                let script = """
                tell application "Safari"
                    do JavaScript "location.reload()" in current tab of front window
                end tell
                return "Página recarregada no Safari"
                """
                return await runAppleScript(script)
            }
            let script = """
            tell application "Google Chrome"
                reload active tab of front window
            end tell
            return "Página recarregada no Chrome"
            """
            return await runAppleScript(script)

        default:
            return "Ação browser não reconhecida: \(action)"
        }
    }

    private func runShortcut(action: String, name: String?, input: String?) async -> String {
        switch action {
        case "list":
            return await shell("shortcuts list 2>&1")

        case "run":
            guard let name = name, !name.isEmpty else { return "Erro: nome do atalho é obrigatório" }
            let escaped = name.replacingOccurrences(of: "'", with: "'\\''")
            if let input = input, !input.isEmpty {
                let escapedInput = input.replacingOccurrences(of: "'", with: "'\\''")
                return await shell("echo '\(escapedInput)' | shortcuts run '\(escaped)' 2>&1")
            }
            return await shell("shortcuts run '\(escaped)' 2>&1")

        default:
            return "Ação shortcut não reconhecida: \(action)"
        }
    }

    private func sendNotification(title: String, message: String, subtitle: String?, sound: Bool) async -> String {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedMsg = message.replacingOccurrences(of: "\"", with: "\\\"")
        let subtitleProp = subtitle.map { " subtitle \"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? ""
        let soundProp = sound ? " sound name \"default\"" : ""

        let script = """
        display notification "\(escapedMsg)" with title "\(escapedTitle)"\(subtitleProp)\(soundProp)
        return "Notificação enviada: \(escapedTitle)"
        """
        return await runAppleScript(script)
    }

    private func controlMusic(action: String, query: String?, app: String) async -> String {
        let appName = app == "music" ? "Music" : "Spotify"

        switch action {
        case "play":
            let script = "tell application \"\(appName)\" to play"
            return await runAppleScript(script + "\nreturn \"▶️ Reproduzindo\"")

        case "pause":
            let script = "tell application \"\(appName)\" to pause"
            return await runAppleScript(script + "\nreturn \"⏸️ Pausado\"")

        case "next":
            let script = "tell application \"\(appName)\" to next track"
            return await runAppleScript(script + "\nreturn \"⏭️ Próxima faixa\"")

        case "previous":
            let script = "tell application \"\(appName)\" to previous track"
            return await runAppleScript(script + "\nreturn \"⏮️ Faixa anterior\"")

        case "status":
            if app == "music" {
                let script = """
                tell application "Music"
                    if player state is playing then
                        set trackName to name of current track
                        set artistName to artist of current track
                        set albumName to album of current track
                        set trackDuration to duration of current track
                        set trackPos to player position
                        return "▶️ " & trackName & " - " & artistName & linefeed & "Álbum: " & albumName & linefeed & "Posição: " & (round trackPos) & "s / " & (round trackDuration) & "s"
                    else
                        return "⏹️ Nenhuma música tocando"
                    end if
                end tell
                """
                return await runAppleScript(script)
            }
            let script = """
            tell application "Spotify"
                if player state is playing then
                    set trackName to name of current track
                    set artistName to artist of current track
                    set albumName to album of current track
                    set trackDuration to duration of current track
                    set trackPos to player position
                    return "▶️ " & trackName & " - " & artistName & linefeed & "Álbum: " & albumName & linefeed & "Posição: " & (round trackPos) & "s / " & (round (trackDuration / 1000)) & "s"
                else
                    return "⏹️ Nenhuma música tocando no Spotify"
                end if
            end tell
            """
            return await runAppleScript(script)

        case "play_track":
            guard let query = query, !query.isEmpty else { return "Erro: query é obrigatório" }
            if app == "music" {
                let escapedQuery = query.replacingOccurrences(of: "\"", with: "\\\"")
                let script = """
                tell application "Music"
                    set searchResults to search playlist "Library" for "\(escapedQuery)"
                    if (count of searchResults) > 0 then
                        play item 1 of searchResults
                        return "▶️ Tocando: " & name of (item 1 of searchResults) & " - " & artist of (item 1 of searchResults)
                    else
                        return "Nenhuma música encontrada para: \(escapedQuery)"
                    end if
                end tell
                """
                return await runAppleScript(script)
            }
            return await shell("open 'spotify:search:\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)' 2>&1 && echo 'Buscando no Spotify: \(query)'")

        case "volume_up":
            let script = """
            tell application "\(appName)"
                set sound volume to (sound volume + 10)
                return "🔊 Volume: " & sound volume
            end tell
            """
            return await runAppleScript(script)

        case "volume_down":
            let script = """
            tell application "\(appName)"
                set sound volume to (sound volume - 10)
                return "🔉 Volume: " & sound volume
            end tell
            """
            return await runAppleScript(script)

        default:
            return "Ação music não reconhecida: \(action)"
        }
    }

    private func searchContacts(query: String, limit: Int) async -> String {
        let escapedQuery = query.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Contacts"
            set matchingPeople to every person whose name contains "\(escapedQuery)"
            if (count of matchingPeople) = 0 then
                set matchingPeople to every person whose value of emails contains "\(escapedQuery)"
            end if
            if (count of matchingPeople) = 0 then
                set matchingPeople to every person whose value of phones contains "\(escapedQuery)"
            end if
            set output to ""
            set maxResults to \(limit)
            set resultCount to 0
            repeat with p in matchingPeople
                if resultCount >= maxResults then exit repeat
                set output to output & "👤 " & name of p & linefeed
                repeat with e in emails of p
                    set output to output & "   📧 " & value of e & linefeed
                end repeat
                repeat with ph in phones of p
                    set output to output & "   📱 " & value of ph & linefeed
                end repeat
                set output to output & "---" & linefeed
                set resultCount to resultCount + 1
            end repeat
            if output is "" then return "Nenhum contato encontrado para: \(escapedQuery)"
            return output
        end tell
        """
        return await runAppleScript(script)
    }

    private func manageReminders(action: String, title: String?, dueDate: String?, listName: String?, reminderIndex: String?, notes: String?) async -> String {
        let targetList = listName ?? "Reminders"
        let escapedList = targetList.replacingOccurrences(of: "\"", with: "\\\"")

        switch action {
        case "list_lists":
            let script = """
            tell application "Reminders"
                set output to ""
                repeat with l in lists
                    set incompleteCount to count of (reminders of l whose completed is false)
                    set output to output & "📋 " & name of l & " (" & incompleteCount & " pendentes)" & linefeed
                end repeat
                return output
            end tell
            """
            return await runAppleScript(script)

        case "list":
            let script = """
            tell application "Reminders"
                set targetList to list "\(escapedList)"
                set rems to reminders of targetList whose completed is false
                set output to ""
                set idx to 1
                repeat with r in rems
                    set output to output & idx & ". "
                    if due date of r is not missing value then
                        set output to output & "⏰ " & (due date of r as text) & " - "
                    end if
                    set output to output & name of r & linefeed
                    if body of r is not missing value and body of r is not "" then
                        set output to output & "   " & body of r & linefeed
                    end if
                    set idx to idx + 1
                end repeat
                if output is "" then return "Nenhum lembrete pendente em '\(escapedList)'."
                return output
            end tell
            """
            return await runAppleScript(script)

        case "create":
            guard let title = title, !title.isEmpty else { return "Erro: título é obrigatório" }
            let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            var props = "name:\"\(escapedTitle)\""
            if let notes = notes, !notes.isEmpty {
                props += ", body:\"\(notes.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            var duePart = ""
            if let dueDate = dueDate, !dueDate.isEmpty {
                duePart = "\nset due date of newRem to date \"\(dueDate)\""
            }
            let script = """
            tell application "Reminders"
                tell list "\(escapedList)"
                    set newRem to make new reminder with properties {\(props)}\(duePart)
                end tell
            end tell
            return "Lembrete '\(escapedTitle)' criado em '\(escapedList)'!"
            """
            return await runAppleScript(script)

        case "complete":
            guard let idx = reminderIndex, let index = Int(idx) else { return "Erro: reminder_index é obrigatório" }
            let script = """
            tell application "Reminders"
                set targetList to list "\(escapedList)"
                set rems to reminders of targetList whose completed is false
                if \(index) > (count of rems) then
                    return "Índice \(index) fora do range. Total pendentes: " & (count of rems)
                end if
                set completed of item \(index) of rems to true
                return "✅ Lembrete #\(index) marcado como completo!"
            end tell
            """
            return await runAppleScript(script)

        default:
            return "Ação reminders não reconhecida: \(action)"
        }
    }

    private func runAppleScript(_ script: String) async -> String {
        let escapedScript = script.replacingOccurrences(of: "'", with: "'\\''")
        let output = await shell("osascript -e '\(escapedScript)' 2>&1")
        return output.isEmpty ? "Comando AppleScript executado (sem saída)" : output
    }

    // MARK: - Helpers

    private func shell(_ command: String) async -> String {
        let output = await CommandExecutor.run(command, workingDirectory: workingDirectory, timeout: 30)
        return output.combinedOutput
    }

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return (workingDirectory as NSString).appendingPathComponent(path)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Errors

enum ToolError: LocalizedError {
    case fileNotFound(String)
    case readFailed(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "Arquivo não encontrado: \(path)"
        case .readFailed(let path): return "Falha ao ler arquivo: \(path)"
        case .invalidArguments(let msg): return "Argumentos inválidos: \(msg)"
        }
    }
}
