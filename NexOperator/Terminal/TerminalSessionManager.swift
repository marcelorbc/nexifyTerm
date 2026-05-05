import Foundation

class TerminalSessionManager {
    private var sessions: [UUID: TerminalSession] = [:]

    func session(for tabId: UUID, initialDirectory: String? = nil) -> TerminalSession {
        if let existing = sessions[tabId] {
            return existing
        }
        let session = TerminalSession(id: tabId, initialDirectory: initialDirectory)
        sessions[tabId] = session
        return session
    }

    func destroySession(for tabId: UUID) {
        if let session = sessions.removeValue(forKey: tabId) {
            session.terminate()
        }
        NexLog.terminal.info("Destroyed terminal session for tab \(tabId)")
    }

    func hasSession(for tabId: UUID) -> Bool {
        sessions[tabId] != nil
    }
}
