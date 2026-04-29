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
