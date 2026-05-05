import Foundation

/// Static (or rarely changing) information about the user's machine. Collected
/// once per app launch (with manual refresh) and injected into every LLM plan
/// so the agent already knows hardware, OS and which tools are available —
/// avoiding wasted "let me check if X is installed" round-trips.
struct SystemProfile: Codable, Equatable {
    var hardware: Hardware
    var os: OSInfo
    var shellEnv: ShellEnv
    var tools: [DetectedTool]
    var packageManagers: [PackageManager]
    var collectedAt: Date

    struct Hardware: Codable, Equatable {
        var model: String          // e.g. "MacBookPro18,2"
        var chip: String           // e.g. "Apple M1 Max"
        var architecture: String   // e.g. "arm64"
        var physicalCores: Int
        var logicalCores: Int
        var memoryGB: Int
        var hostname: String
    }

    struct OSInfo: Codable, Equatable {
        var name: String           // "macOS"
        var version: String        // e.g. "14.5"
        var build: String          // e.g. "23F79"
        var locale: String         // e.g. "pt_BR.UTF-8"
        var timezone: String       // e.g. "America/Sao_Paulo"
    }

    struct ShellEnv: Codable, Equatable {
        var defaultShell: String   // /bin/zsh
        var homePath: String       // /Users/marcelo
        var pathHasHomebrew: Bool
        var defaultEditor: String? // $EDITOR
    }

    /// A CLI / app detected on PATH or known location. We keep both whether it's
    /// installed and (when cheap) its `--version` first line.
    struct DetectedTool: Codable, Equatable, Identifiable {
        var name: String           // "node"
        var path: String?          // /opt/homebrew/bin/node
        var version: String?       // "v20.10.0"
        var category: Category

        var id: String { name }

        enum Category: String, Codable, CaseIterable {
            case runtime       // node, python, ruby, go, rust, java
            case devops        // docker, kubectl, terraform, ansible
            case cloud         // aws, gcloud, az, gh
            case editor        // code, vim, nvim
            case shell         // tmux, fzf, rg, jq, bat
            case database      // psql, mysql, redis-cli, mongo
            case versionControl // git

            var label: String {
                switch self {
                case .runtime:        return "Runtimes"
                case .devops:         return "DevOps"
                case .cloud:          return "Cloud"
                case .editor:         return "Editores"
                case .shell:          return "Shell tools"
                case .database:       return "Databases"
                case .versionControl: return "VCS"
                }
            }

            var icon: String {
                switch self {
                case .runtime:        return "cpu"
                case .devops:         return "shippingbox"
                case .cloud:          return "cloud"
                case .editor:         return "pencil.and.outline"
                case .shell:          return "terminal"
                case .database:       return "cylinder.split.1x2"
                case .versionControl: return "arrow.triangle.branch"
                }
            }
        }

        var installed: Bool { path != nil }
    }

    struct PackageManager: Codable, Equatable, Identifiable {
        var name: String                // "Homebrew"
        var version: String?            // "4.3.0"
        var packagesCount: Int          // total formulae installed
        var topPackages: [String]       // sample of recently used / top names

        var id: String { name }
    }

    static let empty = SystemProfile(
        hardware: Hardware(model: "", chip: "", architecture: "", physicalCores: 0, logicalCores: 0, memoryGB: 0, hostname: ""),
        os: OSInfo(name: "macOS", version: "", build: "", locale: "", timezone: ""),
        shellEnv: ShellEnv(defaultShell: "/bin/zsh", homePath: "", pathHasHomebrew: false, defaultEditor: nil),
        tools: [],
        packageManagers: [],
        collectedAt: .distantPast
    )

    var isEmpty: Bool {
        tools.isEmpty && hardware.chip.isEmpty
    }

    /// Tools that are confirmed installed (have a path).
    var installedTools: [DetectedTool] {
        tools.filter { $0.installed }
    }
}
