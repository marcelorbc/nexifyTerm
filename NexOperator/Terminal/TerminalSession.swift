import Foundation
import SwiftTerm
import AppKit

class TerminalSession {
    let id: UUID
    let terminalView: LocalProcessTerminalView
    private var hasStarted = false
    var initialDirectory: String?
    private var fontObserver: NSObjectProtocol?

    init(id: UUID, initialDirectory: String? = nil) {
        self.id = id
        self.initialDirectory = initialDirectory
        self.terminalView = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        applyFontSize(ConfigStore.shared.terminalFontSize)
        observeFontSizeChanges()
    }

    private func observeFontSizeChanges() {
        fontObserver = NotificationCenter.default.addObserver(
            forName: .terminalFontSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let size = notification.object as? CGFloat else { return }
            self?.applyFontSize(size)
        }
    }

    func applyFontSize(_ size: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        terminalView.font = font
    }

    deinit {
        if let observer = fontObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Safety net: if destroySession() wasn't called explicitly, still terminate the
        // shell process to avoid orphan PTYs/PIDs. terminate() is idempotent in SwiftTerm.
        if hasStarted {
            terminalView.terminate()
        }
    }

    /// Terminates the underlying shell process (SIGTERM via SwiftTerm). Safe to call
    /// multiple times; only sends the signal if the process is alive.
    /// Should be called by `TerminalSessionManager.destroySession(for:)` before the
    /// session is dropped from the registry.
    func terminate() {
        guard hasStarted else { return }
        let pid = terminalView.process.shellPid
        terminalView.terminate()
        hasStarted = false
        NexLog.terminal.info("Terminated terminal session \(self.id, privacy: .public) (pid=\(pid, privacy: .public))")
    }

    /// Visually echoes a command/output line in the terminal display **without**
    /// sending it to the underlying shell. Used by the agent to surface what is
    /// being executed in the parallel `Process` without duplicating side effects.
    /// - Note: text is fed verbatim; pass ANSI escapes (e.g., colors) if desired.
    func echoText(_ text: String) {
        if Thread.isMainThread {
            terminalView.feed(text: text)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.terminalView.feed(text: text)
            }
        }
    }

    /// Visually echoes an agent command line as if the user had typed and run it,
    /// but without actually sending anything to the shell. Used to surface agent
    /// activity in the terminal while the real execution happens via `CommandExecutor`.
    func echoAgentCommand(_ command: String) {
        let line = "\r\n\u{1B}[2m\u{1B}[36m▸ agent\u{1B}[0m \u{1B}[1m$\u{1B}[0m \(command)\r\n"
        echoText(line)
    }

    /// Echoes the captured output of an agent command into the terminal display.
    /// Output is normalized to use `\r\n` line endings (required by the emulator).
    func echoAgentOutput(_ output: String, exitCode: Int32) {
        var normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\n", with: "\r\n")
        if !normalized.isEmpty, !normalized.hasSuffix("\r\n") {
            normalized += "\r\n"
        }
        let footer = exitCode == 0
            ? "\u{1B}[2m▸ agent ok (exit 0)\u{1B}[0m\r\n"
            : "\u{1B}[2m\u{1B}[31m▸ agent exit \(exitCode)\u{1B}[0m\r\n"
        echoText(normalized + footer)
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        guard terminalView.frame.width > 0, terminalView.frame.height > 0 else {
            NexLog.terminal.warning("Terminal view has zero frame, deferring process start")
            return
        }

        hasStarted = true
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        NexLog.terminal.info("Starting terminal session \(self.id) with shell: \(shell)")

        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: nil,
            execName: nil
        )

        if let dir = initialDirectory,
           dir != FileManager.default.homeDirectoryForCurrentUser.path,
           FileManager.default.fileExists(atPath: dir) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.terminalView.send(txt: "cd \"\(dir)\" && clear\n")
            }
        }
    }

    func sendCommand(_ command: String) {
        guard hasStarted else {
            NexLog.terminal.error("Cannot send command: terminal not started")
            return
        }
        if Thread.isMainThread {
            terminalView.send(txt: command + "\n")
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.terminalView.send(txt: command + "\n")
            }
        }
    }

    var isRunning: Bool {
        hasStarted
    }

    /// Extracts the last N visible lines of terminal text for LLM context.
    /// Safe to call from any thread. Returns empty string on failure.
    func getTerminalText(maxLines: Int = 80) -> String {
        do {
            let terminal = terminalView.getTerminal()
            let totalRows = terminal.rows

            guard totalRows > 0 else { return "" }

            var lines: [String] = []
            for row in 0..<totalRows {
                guard let bufferLine = terminal.getLine(row: row) else { continue }
                let text = bufferLine.translateToString(trimRight: true)
                lines.append(text)
            }

            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }

            let trimmed = lines.suffix(maxLines)
            return Array(trimmed).joined(separator: "\n")
        } catch {
            NexLog.terminal.error("Failed to get terminal text: \(error.localizedDescription)")
            return ""
        }
    }
}
