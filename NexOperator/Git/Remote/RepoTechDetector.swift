import Foundation

/// Inspeciona a raiz de um repositório remoto e infere quais tecnologias
/// estão em uso. Faz no máximo 2 chamadas por repo:
///
///   1) `provider.fileTree(repo:path:"":ref:default)` — lista da raiz
///   2) Se houver `package.json`, `provider.fileContent(...)` para parsear
///      `dependencies` + `devDependencies` — como o Azure DevOps Git API
///      não devolve `language`, é o jeito mais barato de descobrir
///      framework (React/Next/Vue/etc.) sem clonar.
///
/// Mantém um cache em memória `[fullName: Set<RepoTech>]` para que
/// re-renderizar a lista não dispare requests novos.
@MainActor
final class RepoTechDetector: ObservableObject {
    static let shared = RepoTechDetector()

    /// Resultado por `repository.fullName`. Vazio = ainda não foi
    /// detectado; mapping para conjunto vazio = detectado mas nada
    /// reconhecido.
    @Published private(set) var techsByRepo: [String: Set<RepoTech>] = [:]
    @Published private(set) var inFlight: Set<String> = []

    private init() {}

    func techs(for repo: RemoteRepository) -> Set<RepoTech>? {
        techsByRepo[repo.fullName]
    }

    func isDetecting(_ repo: RemoteRepository) -> Bool {
        inFlight.contains(repo.fullName)
    }

    func clear() {
        techsByRepo.removeAll()
        inFlight.removeAll()
    }

    /// Detecta em paralelo (cap 4) para evitar martelar a API. Pula repos
    /// já no cache. Re-detecção forçada precisa chamar `clear()` antes.
    func detectMany(
        repos: [RemoteRepository],
        provider: any RemoteGitProvider,
        maxConcurrent: Int = 4
    ) async {
        let pending = repos.filter { techsByRepo[$0.fullName] == nil && !inFlight.contains($0.fullName) }
        guard !pending.isEmpty else { return }

        for r in pending { inFlight.insert(r.fullName) }

        let limit = max(1, min(maxConcurrent, pending.count))
        await withTaskGroup(of: (String, Set<RepoTech>).self) { group in
            var iterator = pending.makeIterator()
            var inFlightCount = 0

            func enqueueNext() {
                guard let next = iterator.next() else { return }
                group.addTask { [weak self] in
                    let detected = await self?.detectOne(repo: next, provider: provider) ?? []
                    return (next.fullName, detected)
                }
                inFlightCount += 1
            }

            while inFlightCount < limit { enqueueNext() }
            while let (fullName, techs) = await group.next() {
                inFlightCount -= 1
                techsByRepo[fullName] = techs
                inFlight.remove(fullName)
                enqueueNext()
            }
        }
    }

    // MARK: - Single-repo detection

    private func detectOne(repo: RemoteRepository, provider: any RemoteGitProvider) async -> Set<RepoTech> {
        var techs: Set<RepoTech> = []

        // 1) Listing the root
        let nodes: [RemoteFileNode]
        do {
            nodes = try await provider.fileTree(
                repo: repo.fullName,
                path: "",
                ref: repo.defaultBranch
            )
        } catch {
            return []
        }

        let names = Set(nodes.map { $0.name.lowercased() })

        // 2) File-name heuristics (fast path, no extra fetches)
        Self.applyFileHeuristics(names: names, into: &techs)

        // 3) Hint by the GitHub-supplied language field (Azure doesn't send it)
        if let lang = repo.language?.lowercased() {
            Self.applyLanguageHint(lang, into: &techs)
        }

        // 4) Optional second fetch: package.json drives Node/JS deeper
        if names.contains("package.json") {
            let extra = await detectFromPackageJSON(repo: repo, provider: provider)
            techs.formUnion(extra)
        }

        return techs
    }

    /// File-presence heuristics. No I/O — purely string set lookups.
    private static func applyFileHeuristics(names: Set<String>, into techs: inout Set<RepoTech>) {
        // Node ecosystem
        if names.contains("package.json") { techs.insert(.nodejs) }
        if names.contains("tsconfig.json") || names.contains("tsconfig.base.json") { techs.insert(.typescript) }
        if names.contains("next.config.js") || names.contains("next.config.mjs") || names.contains("next.config.ts") {
            techs.insert(.nextjs); techs.insert(.react)
        }
        if names.contains("nuxt.config.ts") || names.contains("nuxt.config.js") {
            techs.insert(.nuxt); techs.insert(.vue)
        }
        if names.contains("angular.json") { techs.insert(.angular) }
        if names.contains("svelte.config.js") || names.contains("svelte.config.cjs") { techs.insert(.svelte) }
        if names.contains("vue.config.js") { techs.insert(.vue) }
        if names.contains("tailwind.config.js") || names.contains("tailwind.config.ts") || names.contains("tailwind.config.cjs") {
            techs.insert(.tailwind)
        }
        if names.contains("pnpm-workspace.yaml") || names.contains("lerna.json") || names.contains("turbo.json") || names.contains("nx.json") {
            techs.insert(.monorepo)
        }

        // Python
        if names.contains("requirements.txt") || names.contains("pipfile") || names.contains("pipfile.lock")
            || names.contains("pyproject.toml") || names.contains("setup.py") || names.contains("setup.cfg") {
            techs.insert(.python)
        }
        if names.contains("manage.py") { techs.insert(.django); techs.insert(.python) }
        if names.contains("app.py") || names.contains("wsgi.py") {
            // Could be Flask/FastAPI — package.json equivalent for Python is
            // requirements.txt, which we'd need to fetch to know for sure.
            techs.insert(.python)
        }

        // JVM
        if names.contains("pom.xml") { techs.insert(.maven); techs.insert(.java) }
        if names.contains("build.gradle") || names.contains("build.gradle.kts") || names.contains("settings.gradle") || names.contains("settings.gradle.kts") {
            techs.insert(.gradle); techs.insert(.java)
        }
        if names.contains("build.gradle.kts") { techs.insert(.kotlin) }

        // Go / Rust
        if names.contains("go.mod") || names.contains("go.sum") { techs.insert(.go) }
        if names.contains("cargo.toml") || names.contains("cargo.lock") { techs.insert(.rust) }

        // Ruby / PHP / .NET
        if names.contains("gemfile") || names.contains("gemfile.lock") { techs.insert(.ruby) }
        if names.contains("config") && names.contains("app") { /* heurística fraca para Rails */ }
        if names.contains("composer.json") || names.contains("composer.lock") { techs.insert(.php) }
        if names.contains("artisan") { techs.insert(.laravel); techs.insert(.php) }
        if names.contains("global.json") || names.contains("nuget.config") { techs.insert(.dotnet) }
        if names.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") || $0.hasSuffix(".fsproj") }) {
            techs.insert(.dotnet)
        }

        // Apple / mobile
        if names.contains("package.swift") || names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            techs.insert(.swift); techs.insert(.ios)
        }
        if names.contains("pubspec.yaml") || names.contains("pubspec.yml") {
            techs.insert(.flutter); techs.insert(.dart)
        }
        if names.contains("androidmanifest.xml") || names.contains(where: { $0.hasSuffix(".gradle") && $0.contains("app") }) {
            // Best-effort. The real Android signal is `app/build.gradle` —
            // requires recursing one level which we skip here for speed.
        }

        // Infra
        if names.contains("dockerfile") || names.contains("docker-compose.yml") || names.contains("docker-compose.yaml") {
            techs.insert(.docker)
        }
        if names.contains("kustomization.yaml") || names.contains("chart.yaml") || names.contains("helmfile.yaml") {
            techs.insert(.k8s)
        }
        if names.contains(where: { $0.hasSuffix(".tf") || $0.hasSuffix(".tfvars") }) { techs.insert(.terraform) }
        if names.contains("ansible.cfg") || names.contains("playbook.yml") || names.contains("playbook.yaml") {
            techs.insert(.ansible)
        }

        // Misc
        if names.contains(where: { $0.hasSuffix(".ipynb") }) { techs.insert(.jupyter); techs.insert(.python) }
        if names.contains("index.html") && !names.contains("package.json") { techs.insert(.html) }
        if names.contains(where: { $0.hasSuffix(".sh") || $0.hasSuffix(".bash") || $0.hasSuffix(".zsh") }) {
            techs.insert(.shell)
        }
    }

    /// Light hint based on the GitHub-supplied `language` (Azure leaves nil).
    private static func applyLanguageHint(_ lang: String, into techs: inout Set<RepoTech>) {
        switch lang {
        case "swift":               techs.insert(.swift)
        case "python":              techs.insert(.python)
        case "go":                  techs.insert(.go)
        case "rust":                techs.insert(.rust)
        case "java":                techs.insert(.java)
        case "kotlin":              techs.insert(.kotlin)
        case "ruby":                techs.insert(.ruby)
        case "php":                 techs.insert(.php)
        case "c#":                  techs.insert(.dotnet)
        case "javascript":          techs.insert(.javascript)
        case "typescript":          techs.insert(.typescript)
        case "html":                techs.insert(.html)
        case "dart":                techs.insert(.dart)
        case "shell":               techs.insert(.shell)
        case "jupyter notebook":    techs.insert(.jupyter)
        default: break
        }
    }

    /// Reads `package.json` (1 extra request) and looks at deps to find
    /// React/Next/Vue/Angular/Express/etc. Best-effort — failures fall
    /// back silently to the heuristics already gathered.
    private func detectFromPackageJSON(repo: RemoteRepository, provider: any RemoteGitProvider) async -> Set<RepoTech> {
        var techs: Set<RepoTech> = [.nodejs]

        let raw: String
        do {
            raw = try await provider.fileContent(
                repo: repo.fullName,
                path: "package.json",
                ref: repo.defaultBranch
            )
        } catch {
            return techs
        }

        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return techs }

        var deps: [String: Any] = [:]
        if let d = json["dependencies"] as? [String: Any] { d.forEach { deps[$0.key] = $0.value } }
        if let d = json["devDependencies"] as? [String: Any] { d.forEach { deps[$0.key] = $0.value } }
        if let d = json["peerDependencies"] as? [String: Any] { d.forEach { deps[$0.key] = $0.value } }

        let names = Set(deps.keys.map { $0.lowercased() })

        if names.contains("react") || names.contains("react-dom") { techs.insert(.react) }
        if names.contains("react-native") { techs.insert(.reactNative) }
        if names.contains("next") { techs.insert(.nextjs); techs.insert(.react) }
        if names.contains("vue") || names.contains("@vue/runtime-core") { techs.insert(.vue) }
        if names.contains("nuxt") || names.contains("nuxt3") { techs.insert(.nuxt); techs.insert(.vue) }
        if names.contains("@angular/core") { techs.insert(.angular) }
        if names.contains("svelte") { techs.insert(.svelte) }
        if names.contains("tailwindcss") { techs.insert(.tailwind) }
        if names.contains("typescript") { techs.insert(.typescript) }
        if names.contains("express") || names.contains("fastify") || names.contains("koa") || names.contains("nestjs") {
            techs.insert(.nodejs)
        }
        if names.contains("@nestjs/core") { techs.insert(.nodejs) }

        return techs
    }
}
