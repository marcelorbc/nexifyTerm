import Foundation

final class CLIInstaller {
    static let shared = CLIInstaller()

    private let installPath = "/usr/local/bin/nexify"

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installPath)
    }

    var installedVersion: String? {
        guard isInstalled else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: installPath)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    func install() throws {
        let scriptContent = generateScript()

        let tmpPath = NSTemporaryDirectory() + "nexify"
        try scriptContent.write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let binDir = "/usr/local/bin"
        if !FileManager.default.fileExists(atPath: binDir) {
            let mkdirProcess = Process()
            mkdirProcess.executableURL = URL(fileURLWithPath: "/bin/mkdir")
            mkdirProcess.arguments = ["-p", binDir]
            try mkdirProcess.run()
            mkdirProcess.waitUntilExit()
        }

        let cpProcess = Process()
        cpProcess.executableURL = URL(fileURLWithPath: "/bin/cp")
        cpProcess.arguments = [tmpPath, installPath]
        try cpProcess.run()
        cpProcess.waitUntilExit()

        if cpProcess.terminationStatus != 0 {
            let script = "do shell script \"cp \(tmpPath) \(installPath) && chmod +x \(installPath)\" with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                throw NSError(
                    domain: "CLIInstaller",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: error["NSAppleScriptErrorMessage"] as? String ?? "Failed to install CLI"]
                )
            }
            return
        }

        let chmodProcess = Process()
        chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodProcess.arguments = ["+x", installPath]
        try chmodProcess.run()
        chmodProcess.waitUntilExit()
    }

    func uninstall() throws {
        guard isInstalled else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/rm")
        process.arguments = ["-f", installPath]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let script = "do shell script \"rm -f \(installPath)\" with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                throw NSError(
                    domain: "CLIInstaller",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: error["NSAppleScriptErrorMessage"] as? String ?? "Failed to uninstall CLI"]
                )
            }
        }
    }

    private func generateScript() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return """
        #!/bin/bash
        # nexify - NexifyTerm CLI launcher
        # Version: \(version)

        VERSION="\(version)"
        APP_SCHEME="nexifyterm"

        show_help() {
            echo "nexify v$VERSION - NexifyTerm CLI launcher"
            echo ""
            echo "Usage:"
            echo "  nexify [path]              Open directory in NexifyTerm"
            echo "  nexify .                   Open current directory"
            echo "  nexify --new-tab [path]    Open in a new tab"
            echo "  nexify --run <command>     Execute command in active terminal"
            echo "  nexify --version           Show version"
            echo "  nexify --help              Show this help"
        }

        url_encode() {
            python3 -c "import urllib.parse; print(urllib.parse.quote('$1', safe=''))"
        }

        open_url() {
            open "$1" 2>/dev/null || echo "Error: Could not open NexifyTerm. Is it running?"
        }

        case "${1:-}" in
            --help|-h)
                show_help
                ;;
            --version|-v)
                echo "$VERSION"
                ;;
            --run)
                shift
                CMD="$*"
                if [ -z "$CMD" ]; then
                    echo "Error: --run requires a command"
                    exit 1
                fi
                ENCODED=$(url_encode "$CMD")
                open_url "${APP_SCHEME}://run?command=${ENCODED}"
                ;;
            --new-tab)
                shift
                DIR="${1:-.}"
                DIR=$(cd "$DIR" 2>/dev/null && pwd || echo "$DIR")
                ENCODED=$(url_encode "$DIR")
                open_url "${APP_SCHEME}://open?path=${ENCODED}&newTab=true"
                ;;
            "")
                DIR=$(pwd)
                ENCODED=$(url_encode "$DIR")
                open_url "${APP_SCHEME}://open?path=${ENCODED}"
                ;;
            *)
                DIR="$1"
                if [ -d "$DIR" ]; then
                    DIR=$(cd "$DIR" && pwd)
                fi
                ENCODED=$(url_encode "$DIR")
                open_url "${APP_SCHEME}://open?path=${ENCODED}"
                ;;
        esac
        """
    }
}
