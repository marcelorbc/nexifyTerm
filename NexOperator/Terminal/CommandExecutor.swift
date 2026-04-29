import Foundation

// MARK: - ANSI Code Stripping

extension String {
    func strippingANSICodes() -> String {
        var cleaned = self
            .replacingOccurrences(
                of: "\\\\033\\[[0-9;]*[a-zA-Z]",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\x1B\\[[0-9;]*[a-zA-Z]",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*[a-zA-Z]",
                with: "",
                options: .regularExpression
            )

        if cleaned.hasPrefix("/bin/echo ") || cleaned.hasPrefix("echo ") {
            let parts = cleaned.components(separatedBy: ";")
            let meaningful = parts.map { part in
                part.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "^\\s*/bin/echo\\s+", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "^\\s*echo\\s+", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "^\"", with: "")
                    .replacingOccurrences(of: "\"$", with: "")
                    .replacingOccurrences(of: "\\\\n", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }

            let joined = meaningful.joined(separator: " | ")
            if !joined.isEmpty {
                cleaned = joined
            }
        }

        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

struct CommandOutput {
    let command: String
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool

    init(command: String, stdout: String, stderr: String, exitCode: Int32, timedOut: Bool = false) {
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }

    var combinedOutput: String {
        var result = stdout
        if !stderr.isEmpty {
            result += (result.isEmpty ? "" : "\n") + stderr
        }
        return result
    }

    var succeeded: Bool { exitCode == 0 && !timedOut }

    var truncatedOutput: String {
        let max = 3000
        let output = combinedOutput
        if output.count <= max { return output }
        let head = output.prefix(max / 2)
        let tail = output.suffix(max / 2)
        return head + "\n... [truncated \(output.count) chars total] ...\n" + tail
    }
}

enum SlowCommandEstimate {
    case fast
    case moderate(reason: String)
    case slow(reason: String)
    case verySlow(reason: String)

    var isSlow: Bool {
        switch self {
        case .fast: return false
        default: return true
        }
    }

    var warningText: String? {
        switch self {
        case .fast: return nil
        case .moderate(let reason): return "⏱ Pode demorar: \(reason)"
        case .slow(let reason): return "⏳ Provavelmente lento: \(reason)"
        case .verySlow(let reason): return "🐢 Comando muito lento: \(reason)"
        }
    }

    var shortLabel: String? {
        switch self {
        case .fast: return nil
        case .moderate: return "PODE DEMORAR"
        case .slow: return "LENTO"
        case .verySlow: return "MUITO LENTO"
        }
    }
}

struct SlowCommandClassifier {
    private static let networkScanPatterns: [(pattern: String, reason: String)] = [
        ("dns-sd", "varredura DNS/Bonjour na rede"),
        ("mdns", "consulta mDNS na rede"),
        ("bonjour", "descoberta Bonjour"),
        ("nmap", "scan de rede com nmap"),
        ("arp -a", "listagem ARP da rede"),
        ("avahi", "descoberta de serviços na rede"),
        ("ping -c", "teste de ping múltiplo"),
        ("traceroute", "rastreamento de rota"),
        ("netstat", "listagem de conexões de rede"),
    ]

    private static let installPatterns: [(pattern: String, reason: String)] = [
        ("brew install", "instalação via Homebrew"),
        ("brew upgrade", "atualização via Homebrew"),
        ("pip install", "instalação de pacote Python"),
        ("pip3 install", "instalação de pacote Python"),
        ("npm install", "instalação de pacotes Node"),
        ("yarn install", "instalação de pacotes Yarn"),
        ("cargo build", "compilação Rust"),
        ("cargo install", "instalação de pacote Rust"),
        ("gem install", "instalação de gem Ruby"),
        ("apt install", "instalação de pacote"),
        ("apt-get install", "instalação de pacote"),
        ("softwareupdate", "atualização do sistema"),
        ("mas install", "instalação da App Store"),
    ]

    private static let buildPatterns: [(pattern: String, reason: String)] = [
        ("xcodebuild", "compilação Xcode"),
        ("swift build", "compilação Swift"),
        ("make", "compilação via make"),
        ("cmake", "compilação via cmake"),
        ("gradle", "build Gradle"),
        ("mvn", "build Maven"),
        ("docker build", "construção de imagem Docker"),
        ("docker-compose up", "subindo containers Docker"),
    ]

    private static let downloadPatterns: [(pattern: String, reason: String)] = [
        ("curl -o", "download de arquivo"),
        ("curl -O", "download de arquivo"),
        ("wget", "download de arquivo"),
        ("git clone", "clonagem de repositório"),
        ("git pull", "pull de repositório"),
        ("scp", "transferência via SCP"),
        ("rsync", "sincronização de arquivos"),
    ]

    private static let heavyPatterns: [(pattern: String, reason: String)] = [
        ("find /", "busca recursiva no disco"),
        ("du -sh /", "cálculo de uso de disco"),
        ("tar czf", "compressão de arquivo"),
        ("tar xzf", "extração de arquivo"),
        ("zip -r", "compressão ZIP"),
        ("hdiutil", "operação com imagem de disco"),
        ("diskutil", "operação de disco"),
    ]

    private static let loopPatterns: [(pattern: String, reason: String)] = [
        ("for ", "loop em shell"),
        ("while ", "loop em shell"),
        ("xargs", "execução em lote"),
    ]

    static func classify(_ command: String) -> SlowCommandEstimate {
        let lowered = command.lowercased()

        for (pattern, reason) in networkScanPatterns {
            if lowered.contains(pattern.lowercased()) {
                return .verySlow(reason: reason)
            }
        }

        for (pattern, reason) in buildPatterns {
            if lowered.contains(pattern.lowercased()) {
                return .slow(reason: reason)
            }
        }

        for (pattern, reason) in installPatterns {
            if lowered.contains(pattern.lowercased()) {
                return .slow(reason: reason)
            }
        }

        for (pattern, reason) in downloadPatterns {
            if lowered.contains(pattern.lowercased()) {
                return .moderate(reason: reason)
            }
        }

        for (pattern, reason) in heavyPatterns {
            if lowered.contains(pattern.lowercased()) {
                return .moderate(reason: reason)
            }
        }

        let hasLoop = loopPatterns.first { lowered.contains($0.pattern.lowercased()) }
        let hasPipe = lowered.contains("|")
        let hasMultipleCommands = lowered.contains("&&") || lowered.contains(";")

        if hasLoop != nil && hasPipe {
            return .slow(reason: hasLoop!.reason + " com pipes")
        }
        if hasLoop != nil {
            return .moderate(reason: hasLoop!.reason)
        }
        if hasMultipleCommands && hasPipe {
            return .moderate(reason: "múltiplos comandos encadeados")
        }

        return .fast
    }
}

struct CommandExecutor {
    static let defaultTimeout: TimeInterval = 60
    static let longTimeout: TimeInterval = 300

    private static let longRunningCommands: Set<String> = [
        "brew", "pip", "pip3", "npm", "yarn", "cargo", "gem",
        "apt", "curl", "wget", "git", "xcodebuild", "swift",
        "softwareupdate", "mas", "docker", "unzip", "tar", "hdiutil"
    ]

    static func timeoutFor(_ command: String) -> TimeInterval {
        let base = ShellEscaping.extractBaseCommand(command)
        return longRunningCommands.contains(base) ? longTimeout : defaultTimeout
    }

    static func needsSudo(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sudo ") || trimmed.contains("| sudo") || trimmed.contains("&& sudo")
    }

    static func isSudoPasswordError(_ output: CommandOutput) -> Bool {
        let combined = (output.stderr + output.stdout).lowercased()
        return combined.contains("a terminal is required to read the password") ||
               combined.contains("sudo: a password is required") ||
               combined.contains("sudo: no tty present") ||
               combined.contains("askpass") ||
               (combined.contains("sudo") && combined.contains("password") && output.exitCode != 0)
    }

    static func run(_ command: String, workingDirectory: String? = nil, timeout: TimeInterval? = nil, sudoPassword: String? = nil) async -> CommandOutput {
        let effectiveTimeout = timeout ?? timeoutFor(command)

        if Task.isCancelled {
            return CommandOutput(command: command, stdout: "", stderr: "Cancelado", exitCode: -1)
        }

        let process = Process()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var hasResumed = false
                    let resumeLock = NSLock()

                    func safeResume(_ output: CommandOutput) {
                        resumeLock.lock()
                        defer { resumeLock.unlock() }
                        guard !hasResumed else { return }
                        hasResumed = true
                        continuation.resume(returning: output)
                    }

                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")

                    var actualCommand = command
                    if let password = sudoPassword, needsSudo(command) {
                        let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
                        actualCommand = command.replacingOccurrences(
                            of: "sudo ",
                            with: "echo '\(escaped)' | sudo -S "
                        )
                    }

                    process.arguments = ["-l", "-c", actualCommand]

                    if let dir = workingDirectory {
                        process.currentDirectoryURL = URL(fileURLWithPath: dir)
                    }

                    var env = ProcessInfo.processInfo.environment
                    env["TERM"] = "xterm-256color"
                    env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                    env["NONINTERACTIVE"] = "1"
                    process.environment = env

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = FileHandle.nullDevice

                    var stdoutData = Data()
                    var stderrData = Data()
                    let dataLock = NSLock()

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            dataLock.lock()
                            stdoutData.append(data)
                            dataLock.unlock()
                        }
                    }

                    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            dataLock.lock()
                            stderrData.append(data)
                            dataLock.unlock()
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        NexLog.terminal.error("Failed to start process: \(error.localizedDescription)")
                        safeResume(CommandOutput(
                            command: command, stdout: "", stderr: "Failed to execute: \(error.localizedDescription)", exitCode: -1
                        ))
                        return
                    }

                    var didTimeout = false

                    let timer = DispatchSource.makeTimerSource(queue: .global())
                    timer.schedule(deadline: .now() + effectiveTimeout)
                    timer.setEventHandler {
                        if process.isRunning {
                            didTimeout = true
                            NexLog.terminal.warning("Command timed out after \(Int(effectiveTimeout))s: \(command.prefix(80))")
                            process.terminate()
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                                if process.isRunning { process.interrupt() }
                            }
                        }
                    }
                    timer.resume()

                    process.terminationHandler = { proc in
                        timer.cancel()

                        Thread.sleep(forTimeInterval: 0.1)

                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil

                        let remaining1 = stdoutPipe.fileHandleForReading.availableData
                        let remaining2 = stderrPipe.fileHandleForReading.availableData

                        dataLock.lock()
                        if !remaining1.isEmpty { stdoutData.append(remaining1) }
                        if !remaining2.isEmpty { stderrData.append(remaining2) }
                        let finalStdout = String(data: stdoutData, encoding: .utf8) ?? ""
                        var finalStderr = String(data: stderrData, encoding: .utf8) ?? ""
                        dataLock.unlock()

                        if sudoPassword != nil {
                            finalStderr = finalStderr
                                .replacingOccurrences(of: "Password:", with: "")
                                .replacingOccurrences(of: "[sudo] password for", with: "[sudo]")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }

                        safeResume(CommandOutput(
                            command: command,
                            stdout: finalStdout,
                            stderr: didTimeout ? finalStderr + "\n[TIMEOUT after \(Int(effectiveTimeout))s]" : finalStderr,
                            exitCode: proc.terminationStatus,
                            timedOut: didTimeout
                        ))
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                NexLog.terminal.info("Task cancelled, terminating process: \(command.prefix(60))")
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { process.interrupt() }
                }
            }
        }
    }
}
