import Foundation

class SudoManager {
    static let shared = SudoManager()

    private let store = NexPersistence.shared
    private static let key = "sudoPassword"

    private var sessionPassword: String?

    var savedPassword: String? {
        if let session = sessionPassword { return session }
        let stored = store.getSecret(SudoManager.key)
        return (stored?.isEmpty == false) ? stored : nil
    }

    func savePassword(_ password: String) {
        sessionPassword = password
        store.setSecret(SudoManager.key, value: password)
        NexLog.config.info("Sudo password saved")
    }

    func setSessionOnly(_ password: String) {
        sessionPassword = password
    }

    func clear() {
        sessionPassword = nil
        store.setSecret(SudoManager.key, value: "")
        NexLog.config.info("Sudo password cleared")
    }

    var hasSavedPassword: Bool {
        savedPassword != nil
    }
}
