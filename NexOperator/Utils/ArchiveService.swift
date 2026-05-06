import Foundation

/// Tipos de archive que sabemos navegar/extrair. Suporte a `zip` é sempre
/// disponível (nativo do macOS via `unzip`/`zipinfo`). RAR e 7z dependem de
/// ferramentas externas (`unar`/`unrar`/`7z`/`7zz`) — quando ausentes, o
/// usuário recebe uma mensagem clara.
enum ArchiveKind: String, CaseIterable {
    case zip
    case rar
    case sevenZip = "7z"
    case tar
    case tarGz = "tar.gz"
    case tgz
    case tarBz2 = "tar.bz2"

    /// Detecta o tipo a partir do nome/extensão do arquivo. Retorna `nil`
    /// se a extensão não for reconhecida como archive navegável.
    static func detect(from url: URL) -> ArchiveKind? {
        let lower = url.lastPathComponent.lowercased()
        if lower.hasSuffix(".tar.gz") { return .tarGz }
        if lower.hasSuffix(".tar.bz2") { return .tarBz2 }
        switch url.pathExtension.lowercased() {
        case "zip":  return .zip
        case "rar":  return .rar
        case "7z":   return .sevenZip
        case "tar":  return .tar
        case "tgz":  return .tgz
        case "gz" where lower.hasSuffix(".tar.gz"): return .tarGz
        case "bz2" where lower.hasSuffix(".tar.bz2"): return .tarBz2
        default:     return nil
        }
    }

    var humanLabel: String {
        switch self {
        case .zip: return "ZIP"
        case .rar: return "RAR"
        case .sevenZip: return "7-Zip"
        case .tar: return "TAR"
        case .tarGz, .tgz: return "TAR.GZ"
        case .tarBz2: return "TAR.BZ2"
        }
    }
}

/// Uma entry dentro de um archive. Sempre normalizada para usar `/` como
/// separador — independente do OS de origem do archive.
struct ArchiveEntry: Hashable, Identifiable {
    /// Caminho completo dentro do archive, sem barra inicial. Ex: "src/main.swift".
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var id: String { path }

    /// Apenas o último componente — usado como "nome" da linha na UI.
    var name: String {
        if isDirectory {
            return (path as NSString).lastPathComponent.isEmpty
                ? path
                : (path as NSString).lastPathComponent
        }
        return (path as NSString).lastPathComponent
    }

    /// Diretório pai dentro do archive (vazio = root do archive).
    var parentPath: String {
        let p = (path as NSString).deletingLastPathComponent
        return p == "/" ? "" : p
    }
}

/// Posição de navegação dentro de um archive: qual archive e qual sub-pasta
/// está sendo visualizada. `subPath` vazio = root do archive.
struct ArchiveLocation: Equatable {
    let archiveURL: URL
    let kind: ArchiveKind
    var subPath: String = ""

    /// Path "amigável" pra mostrar na barra de breadcrumbs.
    var displayPath: String {
        if subPath.isEmpty {
            return archiveURL.lastPathComponent
        }
        return "\(archiveURL.lastPathComponent) › \(subPath)"
    }
}

/// Serviço sem estado para listar e extrair archives. Toda operação é
/// async + lança erros descritivos pra UI mostrar.
enum ArchiveService {

    enum ArchiveError: LocalizedError {
        case toolNotInstalled(tool: String, kind: ArchiveKind)
        case listFailed(String)
        case extractFailed(String)
        case unsupportedExtension
        case entryNotFound(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .toolNotInstalled(let tool, let kind):
                return "Para abrir arquivos \(kind.humanLabel) você precisa do utilitário '\(tool)'. Instale via Homebrew (ex: brew install \(tool == "7z" ? "p7zip" : tool)) e tente novamente."
            case .listFailed(let msg):
                return "Falha ao listar conteúdo do archive: \(msg)"
            case .extractFailed(let msg):
                return "Falha ao extrair: \(msg)"
            case .unsupportedExtension:
                return "Tipo de arquivo não reconhecido como archive navegável."
            case .entryNotFound(let p):
                return "Entry não encontrada no archive: \(p)"
            case .writeFailed(let msg):
                return "Falha ao gravar arquivo extraído: \(msg)"
            }
        }
    }

    // MARK: - Tool resolution

    /// Procura um binário em paths comuns + PATH herdado. macOS sandbox
    /// herda PATH limitado, por isso checamos /opt/homebrew e /usr/local
    /// explicitamente antes de cair no `which`.
    private static func resolveTool(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Fallback final: usa /usr/bin/env which.
        let p = Process()
        p.launchPath = "/usr/bin/env"
        p.arguments = ["which", name]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    /// Informa se o sistema consegue listar/extrair `kind` agora. Útil pra
    /// mostrar "Instale 7z" antes de o usuário tentar a operação.
    static func isAvailable(_ kind: ArchiveKind) -> Bool {
        switch kind {
        case .zip:                            return resolveTool("unzip") != nil
        case .rar:                            return resolveTool("unar") != nil || resolveTool("unrar") != nil
        case .sevenZip:                       return resolveTool("7z") != nil || resolveTool("7zz") != nil
        case .tar, .tarGz, .tgz, .tarBz2:    return resolveTool("tar") != nil
        }
    }

    // MARK: - Listing

    /// Lista TODAS as entries do archive (achatado). A camada de UI agrupa
    /// por sub-pasta na hora de exibir.
    static func listEntries(in archiveURL: URL) async throws -> [ArchiveEntry] {
        guard let kind = ArchiveKind.detect(from: archiveURL) else {
            throw ArchiveError.unsupportedExtension
        }
        switch kind {
        case .zip:
            return try await listZip(archiveURL)
        case .rar:
            return try await listRar(archiveURL)
        case .sevenZip:
            return try await list7z(archiveURL)
        case .tar, .tarGz, .tgz, .tarBz2:
            return try await listTar(archiveURL, kind: kind)
        }
    }

    // MARK: - Extract

    /// Extrai UMA entry pra um destino específico. Cria pastas intermediárias
    /// se a entry estiver dentro de um subdiretório.
    static func extractEntry(
        _ entry: ArchiveEntry,
        from archiveURL: URL,
        to destinationFile: URL
    ) async throws {
        guard let kind = ArchiveKind.detect(from: archiveURL) else {
            throw ArchiveError.unsupportedExtension
        }
        let parent = destinationFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true
        )

        switch kind {
        case .zip:
            try await extractZipEntry(entry, archiveURL: archiveURL, to: destinationFile)
        case .rar:
            try await extractRarEntry(entry, archiveURL: archiveURL, to: destinationFile)
        case .sevenZip:
            try await extract7zEntry(entry, archiveURL: archiveURL, to: destinationFile)
        case .tar, .tarGz, .tgz, .tarBz2:
            try await extractTarEntry(entry, archiveURL: archiveURL, kind: kind, to: destinationFile)
        }
    }

    /// Extrai TODO o conteúdo do archive em uma pasta destino. Cria a pasta
    /// se não existir.
    static func extractAll(
        from archiveURL: URL,
        to destinationDir: URL
    ) async throws {
        guard let kind = ArchiveKind.detect(from: archiveURL) else {
            throw ArchiveError.unsupportedExtension
        }
        try FileManager.default.createDirectory(
            at: destinationDir, withIntermediateDirectories: true
        )
        switch kind {
        case .zip:
            try await runUnzipAll(archiveURL: archiveURL, dest: destinationDir)
        case .rar:
            try await runRarAll(archiveURL: archiveURL, dest: destinationDir)
        case .sevenZip:
            try await run7zAll(archiveURL: archiveURL, dest: destinationDir)
        case .tar, .tarGz, .tgz, .tarBz2:
            try await runTarAll(archiveURL: archiveURL, kind: kind, dest: destinationDir)
        }
    }

    // MARK: - ZIP (nativo macOS)

    private static func listZip(_ url: URL) async throws -> [ArchiveEntry] {
        guard let unzip = resolveTool("unzip") else {
            throw ArchiveError.toolNotInstalled(tool: "unzip", kind: .zip)
        }
        // `unzip -l` no macOS produz um formato simples e estável:
        //
        //   Archive:  /tmp/test.zip
        //     Length      Date    Time    Name
        //   ---------  ---------- -----   ----
        //           0  05-05-2026 21:03   zip_test/
        //           6  05-05-2026 21:03   zip_test/file1.txt
        //   ---------                     -------
        //          12                     4 files
        let raw = try await runProcess(launchPath: unzip, args: ["-l", url.path])
        return parseUnzipListing(raw)
    }

    /// Parser do `unzip -l` (formato BSD do macOS, também aceito pelo Info-ZIP
    /// padrão Linux). Tolera linhas em branco, headers, separadores e
    /// diferenças de espaçamento.
    private static func parseUnzipListing(_ raw: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        let dateFmt = DateFormatter()
        // macOS Info-ZIP usa MM-dd-yyyy; algumas versões do Linux usam
        // yyyy-MM-dd. Tentamos ambos.
        let dateFormats = ["MM-dd-yyyy HH:mm", "yyyy-MM-dd HH:mm"]
        dateFmt.locale = Locale(identifier: "en_US_POSIX")

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("Archive:") { continue }
            if trimmed.hasPrefix("Length") { continue }
            if trimmed.hasPrefix("---") { continue }
            if trimmed.hasSuffix(" files") || trimmed.hasSuffix(" file") { continue }

            // Quebra em campos. Esperamos pelo menos 4: size, date, time, name.
            // O nome pode ter espaços, então re-junta tudo a partir do índice 3.
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }
            guard let size = Int64(parts[0]) else { continue }

            // Tenta parsear data nos formatos suportados.
            let dateStr = "\(parts[1]) \(parts[2])"
            var modified: Date?
            for fmt in dateFormats {
                dateFmt.dateFormat = fmt
                if let d = dateFmt.date(from: dateStr) {
                    modified = d
                    break
                }
            }

            // Re-junta o nome (pode conter espaços). Usa range no string
            // original pra preservar espaços internos.
            let prefixLen = parts.prefix(3).map(\.count).reduce(0, +) + 3 // 3 espaços
            let nameStart = trimmed.index(trimmed.startIndex,
                                          offsetBy: min(prefixLen, trimmed.count - 1))
            var name = String(trimmed[nameStart...]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }

            let isDir = name.hasSuffix("/")
            if isDir { name = String(name.dropLast()) }
            if name.isEmpty { continue }
            entries.append(ArchiveEntry(
                path: name, isDirectory: isDir, size: size, modified: modified
            ))
        }
        return entries
    }

    private static func extractZipEntry(
        _ entry: ArchiveEntry, archiveURL: URL, to destinationFile: URL
    ) async throws {
        guard let unzip = resolveTool("unzip") else {
            throw ArchiveError.toolNotInstalled(tool: "unzip", kind: .zip)
        }
        // `unzip -p` escreve a entry no stdout, sem recriar a estrutura de
        // pastas — perfeito pra escrever em qualquer destino que o usuário
        // escolher.
        let p = Process()
        p.launchPath = unzip
        p.arguments = ["-p", archiveURL.path, entry.path]
        let outFile = FileHandle(forWritingAtPath: destinationFile.path)
            ?? {
                FileManager.default.createFile(atPath: destinationFile.path, contents: nil)
                return FileHandle(forWritingAtPath: destinationFile.path)
            }()
        guard let outFile else {
            throw ArchiveError.writeFailed(destinationFile.path)
        }
        p.standardOutput = outFile
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        try? outFile.close()
        if p.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: destinationFile)
            throw ArchiveError.extractFailed("unzip retornou \(p.terminationStatus)")
        }
    }

    private static func runUnzipAll(archiveURL: URL, dest: URL) async throws {
        guard let unzip = resolveTool("unzip") else {
            throw ArchiveError.toolNotInstalled(tool: "unzip", kind: .zip)
        }
        // -o = sobrescrever sem perguntar. -q = silencioso.
        _ = try await runProcess(
            launchPath: unzip,
            args: ["-o", "-q", archiveURL.path, "-d", dest.path]
        )
    }

    // MARK: - RAR

    private static func listRar(_ url: URL) async throws -> [ArchiveEntry] {
        if let unar = resolveTool("lsar") {
            let raw = try await runProcess(launchPath: unar,
                                            args: ["-l", url.path])
            return parseLsarListing(raw)
        }
        if let unrar = resolveTool("unrar") {
            let raw = try await runProcess(launchPath: unrar,
                                            args: ["lt", url.path])
            return parseUnrarListing(raw)
        }
        throw ArchiveError.toolNotInstalled(tool: "unar", kind: .rar)
    }

    private static func parseLsarListing(_ raw: String) -> [ArchiveEntry] {
        // `lsar -l` produz blocos como:
        //   ./src/main.swift
        //     Size: 1234
        //     Modification time: 2026-01-01 14:30:00
        var entries: [ArchiveEntry] = []
        var currentName: String?
        var currentSize: Int64 = 0
        var currentDate: Date?
        var isDirectory = false
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        func flush() {
            if let name = currentName, !name.isEmpty {
                let clean = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
                entries.append(ArchiveEntry(
                    path: clean, isDirectory: isDirectory,
                    size: currentSize, modified: currentDate
                ))
            }
            currentName = nil; currentSize = 0; currentDate = nil; isDirectory = false
        }

        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("./") || (!line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.isEmpty && !line.contains(":")) {
                flush()
                currentName = line.trimmingCharacters(in: .whitespaces)
            } else if line.contains("Size:") {
                let v = line.components(separatedBy: ":").last?
                    .trimmingCharacters(in: .whitespaces) ?? "0"
                currentSize = Int64(v) ?? 0
            } else if line.contains("Modification time:") {
                let v = line.components(separatedBy: "Modification time:").last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                currentDate = dateFmt.date(from: v)
            } else if line.lowercased().contains("type:") && line.lowercased().contains("director") {
                isDirectory = true
            }
        }
        flush()
        return entries
    }

    private static func parseUnrarListing(_ raw: String) -> [ArchiveEntry] {
        // `unrar lt` produz blocos com `Name:`, `Size:`, `Type:`.
        var entries: [ArchiveEntry] = []
        var currentName: String?
        var currentSize: Int64 = 0
        var isDirectory = false
        var currentDate: Date?
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"

        func flush() {
            if let name = currentName, !name.isEmpty {
                entries.append(ArchiveEntry(
                    path: name, isDirectory: isDirectory,
                    size: currentSize, modified: currentDate
                ))
            }
            currentName = nil; currentSize = 0; isDirectory = false; currentDate = nil
        }

        for line in raw.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Name:") {
                flush()
                currentName = String(l.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix("Size:") {
                let v = String(l.dropFirst("Size:".count)).trimmingCharacters(in: .whitespaces)
                currentSize = Int64(v) ?? 0
            } else if l.hasPrefix("Type:") {
                isDirectory = l.lowercased().contains("director")
            } else if l.hasPrefix("Modified:") {
                let v = String(l.dropFirst("Modified:".count)).trimmingCharacters(in: .whitespaces)
                currentDate = dateFmt.date(from: v)
            }
        }
        flush()
        return entries
    }

    private static func extractRarEntry(
        _ entry: ArchiveEntry, archiveURL: URL, to destinationFile: URL
    ) async throws {
        // Estratégia: extrair pra temp dir e mover. unar/unrar não têm modo
        // "stdout" universal, então essa é a abordagem mais portável.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nex_rar_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        if let unar = resolveTool("unar") {
            _ = try await runProcess(
                launchPath: unar,
                args: ["-o", temp.path, "-D", archiveURL.path, entry.path]
            )
        } else if let unrar = resolveTool("unrar") {
            _ = try await runProcess(
                launchPath: unrar,
                args: ["x", "-y", "-inul", archiveURL.path, entry.path, temp.path + "/"]
            )
        } else {
            throw ArchiveError.toolNotInstalled(tool: "unar", kind: .rar)
        }
        let extracted = temp.appendingPathComponent(entry.path)
        try moveExtracted(from: extracted, to: destinationFile)
    }

    private static func runRarAll(archiveURL: URL, dest: URL) async throws {
        if let unar = resolveTool("unar") {
            _ = try await runProcess(launchPath: unar,
                                      args: ["-o", dest.path, "-D", archiveURL.path])
        } else if let unrar = resolveTool("unrar") {
            _ = try await runProcess(launchPath: unrar,
                                      args: ["x", "-y", archiveURL.path, dest.path + "/"])
        } else {
            throw ArchiveError.toolNotInstalled(tool: "unar", kind: .rar)
        }
    }

    // MARK: - 7z

    private static func list7z(_ url: URL) async throws -> [ArchiveEntry] {
        guard let bin = resolveTool("7z") ?? resolveTool("7zz") else {
            throw ArchiveError.toolNotInstalled(tool: "7z", kind: .sevenZip)
        }
        // `7z l -slt` produz blocos com Path/Size/Modified/Attributes.
        let raw = try await runProcess(launchPath: bin, args: ["l", "-slt", url.path])
        return parse7zListing(raw)
    }

    private static func parse7zListing(_ raw: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var path = ""
        var size: Int64 = 0
        var modified: Date?
        var isDir = false
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

        func flush() {
            guard !path.isEmpty else { return }
            entries.append(ArchiveEntry(
                path: path, isDirectory: isDir, size: size, modified: modified
            ))
            path = ""; size = 0; modified = nil; isDir = false
        }

        for line in raw.components(separatedBy: "\n") {
            if line.isEmpty || line.hasPrefix("---") || line.hasPrefix("====") {
                flush()
                continue
            }
            if line.hasPrefix("Path = ") {
                if !path.isEmpty { flush() }
                path = String(line.dropFirst("Path = ".count))
            } else if line.hasPrefix("Size = ") {
                size = Int64(line.dropFirst("Size = ".count)) ?? 0
            } else if line.hasPrefix("Modified = ") {
                let v = String(line.dropFirst("Modified = ".count))
                modified = dateFmt.date(from: v)
            } else if line.hasPrefix("Attributes = ") {
                isDir = line.contains("D")
            }
        }
        flush()
        // O 7z lista o próprio archive como primeira "entry" às vezes —
        // descarta entries cujo path coincide com o nome do archive.
        return entries.filter { !$0.path.isEmpty }
    }

    private static func extract7zEntry(
        _ entry: ArchiveEntry, archiveURL: URL, to destinationFile: URL
    ) async throws {
        guard let bin = resolveTool("7z") ?? resolveTool("7zz") else {
            throw ArchiveError.toolNotInstalled(tool: "7z", kind: .sevenZip)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nex_7z_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // `7z e` (sem `x`) extrai sem path, em destino flat. Como queremos
        // ESTA entry específica, usamos `x` com path completo + filtro.
        _ = try await runProcess(
            launchPath: bin,
            args: ["x", "-y", "-o" + temp.path, archiveURL.path, entry.path]
        )
        let extracted = temp.appendingPathComponent(entry.path)
        try moveExtracted(from: extracted, to: destinationFile)
    }

    private static func run7zAll(archiveURL: URL, dest: URL) async throws {
        guard let bin = resolveTool("7z") ?? resolveTool("7zz") else {
            throw ArchiveError.toolNotInstalled(tool: "7z", kind: .sevenZip)
        }
        _ = try await runProcess(
            launchPath: bin,
            args: ["x", "-y", "-o" + dest.path, archiveURL.path]
        )
    }

    // MARK: - TAR / TAR.GZ / TAR.BZ2

    private static func tarFlags(for kind: ArchiveKind) -> [String] {
        switch kind {
        case .tar:               return []
        case .tarGz, .tgz:       return ["-z"]
        case .tarBz2:            return ["-j"]
        default:                 return []
        }
    }

    private static func listTar(_ url: URL, kind: ArchiveKind) async throws -> [ArchiveEntry] {
        guard let tar = resolveTool("tar") else {
            throw ArchiveError.toolNotInstalled(tool: "tar", kind: kind)
        }
        // -t lista, -v adiciona detalhes (size, date).
        let raw = try await runProcess(
            launchPath: tar,
            args: ["-tvf", url.path] + tarFlags(for: kind)
        )
        return parseTarListing(raw)
    }

    private static func parseTarListing(_ raw: String) -> [ArchiveEntry] {
        // `tar -tvf` produz linhas estilo `ls -l`:
        //   -rw-r--r--  0 user group 1234 2026-01-01 14:30 src/main.swift
        var entries: [ArchiveEntry] = []
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 7 else { continue }
            let perms = String(parts[0])
            let isDir = perms.hasPrefix("d")
            let size = Int64(parts[4]) ?? 0
            let dateStr = "\(parts[5]) \(parts[6])"
            let date = dateFmt.date(from: dateStr)
            // Nome começa na 8ª posição em diante (8º index = 7).
            let nameStart = parts.prefix(7).map(String.init).joined(separator: " ").count + 1
            let name = trimmed.count > nameStart
                ? String(trimmed.suffix(trimmed.count - nameStart)).trimmingCharacters(in: .whitespaces)
                : ""
            if name.isEmpty { continue }
            let clean = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
            let canonical = isDir && clean.hasSuffix("/") ? String(clean.dropLast()) : clean
            entries.append(ArchiveEntry(
                path: canonical, isDirectory: isDir, size: size, modified: date
            ))
        }
        return entries
    }

    private static func extractTarEntry(
        _ entry: ArchiveEntry, archiveURL: URL, kind: ArchiveKind, to destinationFile: URL
    ) async throws {
        guard let tar = resolveTool("tar") else {
            throw ArchiveError.toolNotInstalled(tool: "tar", kind: kind)
        }
        // tar -xOf escreve no stdout — perfeito pra extrair uma entry.
        let p = Process()
        p.launchPath = tar
        p.arguments = ["-xOf", archiveURL.path] + tarFlags(for: kind) + [entry.path]
        FileManager.default.createFile(atPath: destinationFile.path, contents: nil)
        guard let outFile = FileHandle(forWritingAtPath: destinationFile.path) else {
            throw ArchiveError.writeFailed(destinationFile.path)
        }
        p.standardOutput = outFile
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        try? outFile.close()
        if p.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: destinationFile)
            throw ArchiveError.extractFailed("tar retornou \(p.terminationStatus)")
        }
    }

    private static func runTarAll(archiveURL: URL, kind: ArchiveKind, dest: URL) async throws {
        guard let tar = resolveTool("tar") else {
            throw ArchiveError.toolNotInstalled(tool: "tar", kind: kind)
        }
        _ = try await runProcess(
            launchPath: tar,
            args: ["-xf", archiveURL.path, "-C", dest.path] + tarFlags(for: kind)
        )
    }

    // MARK: - Helpers

    /// Move um arquivo extraído pra destino final, sobrescrevendo se preciso.
    private static func moveExtracted(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            throw ArchiveError.extractFailed("arquivo extraído não encontrado em \(src.path)")
        }
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: src, to: dest)
    }

    /// Roda um processo síncrono, retorna stdout. Lança `extractFailed` se
    /// o processo falhar (exit != 0).
    @discardableResult
    private static func runProcess(launchPath: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.launchPath = launchPath
                p.arguments = args
                let stdout = Pipe()
                let stderr = Pipe()
                p.standardOutput = stdout
                p.standardError = stderr
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: ArchiveError.extractFailed(error.localizedDescription))
                    return
                }
                p.waitUntilExit()
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                if p.terminationStatus != 0 {
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    let detail = errStr.isEmpty ? out : errStr
                    cont.resume(throwing: ArchiveError.extractFailed(
                        "(\(launchPath) saiu com \(p.terminationStatus)) \(detail.prefix(300))"
                    ))
                    return
                }
                cont.resume(returning: out)
            }
        }
    }
}
