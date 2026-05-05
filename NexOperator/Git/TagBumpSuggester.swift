import Foundation

/// Generates "next tag" suggestions from an existing tag, mimicking the
/// behaviour the user expects from GitKraken/Tower etc.: clicking a tag
/// `v1.2.3` proposes `v1.2.4` / `v1.3.0` / `v2.0.0`. Falls back to a generic
/// numeric bump for non-semver tags (`release-12` → `release-13`).
enum TagBumpSuggester {
    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        /// Short label shown in the UI (e.g. "Patch", "Minor", "Major").
        let label: String
        /// Final tag name to be created (e.g. "v1.2.4").
        let name: String
        /// Free-form hint for the tooltip / detail row.
        let hint: String
    }

    /// Returns up to 3 ordered suggestions. An empty array means we couldn't
    /// derive a sensible next name — UI should fall back to a free text field.
    static func suggestions(from current: String) -> [Suggestion] {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        if let semver = parseSemver(trimmed) {
            let prefix = semver.prefix
            let major = semver.major
            let minor = semver.minor
            let patch = semver.patch
            return [
                Suggestion(
                    label: "Patch",
                    name: "\(prefix)\(major).\(minor).\(patch + 1)",
                    hint: "Correção de bug · \(major).\(minor).\(patch) → \(major).\(minor).\(patch + 1)"
                ),
                Suggestion(
                    label: "Minor",
                    name: "\(prefix)\(major).\(minor + 1).0",
                    hint: "Nova funcionalidade · \(major).\(minor).\(patch) → \(major).\(minor + 1).0"
                ),
                Suggestion(
                    label: "Major",
                    name: "\(prefix)\(major + 1).0.0",
                    hint: "Quebra de compatibilidade · \(major).\(minor).\(patch) → \(major + 1).0.0"
                )
            ]
        }

        // CalVer-ish heuristic: dates like 2024.04 / 2024-04-15 / 2024_04_15
        if let calver = bumpCalver(trimmed) {
            return [calver]
        }

        // Trailing integer fallback: "release-12" → "release-13",
        // "rc1" → "rc2", "build_42" → "build_43".
        if let bumped = bumpTrailingInteger(trimmed) {
            return [
                Suggestion(
                    label: "Próximo",
                    name: bumped,
                    hint: "Incrementa o número final"
                )
            ]
        }

        return []
    }

    // MARK: - Semver

    struct Semver: Equatable {
        let prefix: String   // "v" or "" (kept for output)
        let major: Int
        let minor: Int
        let patch: Int
    }

    /// Parses `v1.2.3`, `1.2.3`, `release-1.2.3` shapes. Suffixes after the
    /// patch (e.g. `-rc.1`, `+build.42`) are dropped on output — the user
    /// typically wants to drop pre-release tags when bumping.
    static func parseSemver(_ tag: String) -> Semver? {
        // Find the first digit; everything before it (typically "v" or
        // "release-") becomes the preserved prefix.
        guard let firstDigit = tag.firstIndex(where: { $0.isNumber }) else {
            return nil
        }
        let prefix = String(tag[..<firstDigit])
        let rest = String(tag[firstDigit...])

        // Strip pre-release / build metadata.
        let core = rest.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? rest
        let parts = core.split(separator: ".").map(String.init)
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1])
        else { return nil }
        let patch = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
        return Semver(prefix: prefix, major: major, minor: minor, patch: patch)
    }

    // MARK: - CalVer

    /// Bumps the last numeric segment of a date-like tag (`2024.04`,
    /// `2024-04-15`). Returns nil for shapes that aren't obviously CalVer.
    static func bumpCalver(_ tag: String) -> Suggestion? {
        // Matches: optional letter prefix + 4-digit year + separator + groups of digits.
        let pattern = "^([A-Za-z._-]*)(\\d{4})([._-])(\\d{1,2})(?:([._-])(\\d{1,2}))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return nil }

        func capture(_ idx: Int) -> String? {
            guard match.range(at: idx).location != NSNotFound,
                  let r = Range(match.range(at: idx), in: tag) else { return nil }
            return String(tag[r])
        }

        let prefix = capture(1) ?? ""
        let year = capture(2) ?? ""
        let sep1 = capture(3) ?? "."
        guard let monthStr = capture(4), let month = Int(monthStr) else { return nil }
        let dayStr = capture(6)

        if let dayStr, let day = Int(dayStr) {
            let sep2 = capture(5) ?? sep1
            let nextDay = day + 1
            return Suggestion(
                label: "Próximo dia",
                name: "\(prefix)\(year)\(sep1)\(String(format: "%02d", month))\(sep2)\(String(format: "%02d", nextDay))",
                hint: "CalVer · próximo dia"
            )
        }

        let nextMonth = month + 1
        if nextMonth > 12 {
            // Roll year. Year format kept at 4 digits.
            let intYear = (Int(year) ?? 2024) + 1
            return Suggestion(
                label: "Próximo ano",
                name: "\(prefix)\(intYear)\(sep1)01",
                hint: "CalVer · próximo ano"
            )
        }
        return Suggestion(
            label: "Próximo mês",
            name: "\(prefix)\(year)\(sep1)\(String(format: "%02d", nextMonth))",
            hint: "CalVer · próximo mês"
        )
    }

    // MARK: - Trailing integer

    /// Bumps the last integer found in the string. Used for tags like
    /// `release-12`, `rc1`, `build_42`.
    static func bumpTrailingInteger(_ tag: String) -> String? {
        var idx = tag.endIndex
        while idx > tag.startIndex {
            let prev = tag.index(before: idx)
            if tag[prev].isNumber { idx = prev } else { break }
        }
        guard idx < tag.endIndex,
              let n = Int(tag[idx...]) else { return nil }
        return String(tag[..<idx]) + String(n + 1)
    }
}
