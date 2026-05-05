import Foundation
import AppKit

/// Gerencia backups e operações de rollback de file actions reversíveis.
///
/// Antes de uma operação destrutiva (write/move/rename/delete), o caller pede
/// um backup; recebe de volta uma `RollbackOperation` que descreve EXATAMENTE
/// como reverter. O conteúdo dos arquivos vai para
/// `~/Library/Application Support/NexOperator/rollback/<step_id>/`.
final class RollbackStore {

    static let shared = RollbackStore()

    private let fileManager = FileManager.default

    private var rootDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let dir = appSupport.appendingPathComponent("NexOperator/rollback", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    // MARK: - Backup builders

    /// Faz backup de um arquivo antes de escrever/sobrescrever.
    /// Retorna `nil` se o arquivo não existia (rollback será deleteCreated).
    func backupForWrite(originalPath: String, stepId: UUID) -> RollbackOperation? {
        let originalURL = URL(fileURLWithPath: originalPath)

        if !fileManager.fileExists(atPath: originalPath) {
            // Arquivo não existia — rollback é apagar o que foi criado.
            return .deleteCreated(path: originalPath)
        }

        do {
            let backupDir = rootDirectory.appendingPathComponent(stepId.uuidString, isDirectory: true)
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let backupURL = backupDir.appendingPathComponent(originalURL.lastPathComponent)
            try fileManager.copyItem(at: originalURL, to: backupURL)
            return .restoreFromBackup(originalPath: originalPath, backupPath: backupURL.path)
        } catch {
            NexLog.ai.warning("Backup for write failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Para move/rename: registra apenas os caminhos, não copia conteúdo.
    func rollbackForMove(from currentPath: String, originalPath: String) -> RollbackOperation {
        .moveBack(currentPath: currentPath, originalPath: originalPath)
    }

    /// Para delete via Lixeira: anota o path original; recuperação manual via Finder.
    func rollbackForTrashDelete(originalPath: String) -> RollbackOperation {
        .restoreFromTrash(originalPath: originalPath)
    }

    /// Para criação de pasta/duplicate: rollback é apagar.
    func rollbackForCreated(path: String) -> RollbackOperation {
        .deleteCreated(path: path)
    }

    // MARK: - Execute rollback

    /// Executa a operação de rollback descrita.
    func execute(_ operation: RollbackOperation) throws {
        switch operation {
        case .restoreFromBackup(let originalPath, let backupPath):
            try restoreFromBackup(originalPath: originalPath, backupPath: backupPath)

        case .moveBack(let currentPath, let originalPath):
            try moveBack(currentPath: currentPath, originalPath: originalPath)

        case .deleteCreated(let path):
            try deleteCreated(path: path)

        case .restoreFromTrash(let originalPath):
            try openTrashForRestore(originalPath: originalPath)
        }
    }

    private func restoreFromBackup(originalPath: String, backupPath: String) throws {
        let original = URL(fileURLWithPath: originalPath)
        let backup = URL(fileURLWithPath: backupPath)

        guard fileManager.fileExists(atPath: backup.path) else {
            throw NSError(domain: "RollbackStore", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Backup não encontrado em \(backupPath)"
            ])
        }

        if fileManager.fileExists(atPath: original.path) {
            try fileManager.removeItem(at: original)
        } else {
            try fileManager.createDirectory(
                at: original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try fileManager.copyItem(at: backup, to: original)
    }

    private func moveBack(currentPath: String, originalPath: String) throws {
        let current = URL(fileURLWithPath: currentPath)
        let original = URL(fileURLWithPath: originalPath)

        guard fileManager.fileExists(atPath: current.path) else {
            throw NSError(domain: "RollbackStore", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Arquivo não está em \(currentPath); pode ter sido movido novamente."
            ])
        }

        try fileManager.createDirectory(
            at: original.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: current, to: original)
    }

    private func deleteCreated(path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    private func openTrashForRestore(originalPath: String) throws {
        // macOS não permite acesso programático à Lixeira fora do sandbox.
        // Abrimos a Lixeira no Finder e copiamos o nome para o clipboard
        // pra facilitar a busca manual.
        let name = URL(fileURLWithPath: originalPath).lastPathComponent
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)

        if let trashURL = try? fileManager.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            NSWorkspace.shared.open(trashURL)
        }

        throw NSError(domain: "RollbackStore", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "Lixeira aberta. Arraste \"\(name)\" de volta manualmente (nome copiado para o clipboard)."
        ])
    }

    // MARK: - Cleanup

    /// Remove backups antigos (default 30 dias). Chamado periodicamente.
    func cleanupOldBackups(olderThan days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        for url in urls {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
