import Foundation

/// Lightweight token estimator + breakdown of what goes into the next LLM call.
/// Used by the UI to show a Cursor/Claude-style "context window usage" indicator.
///
/// Heuristic: `tokens ≈ characters / 4`. This is the standard rule of thumb for
/// English/Portuguese with GPT/Claude/Gemini tokenizers — close enough to be
/// useful in a UI without requiring a real tokenizer dependency.
enum ContextEstimator {

    /// Average chars-per-token across modern LLM tokenizers for Latin scripts.
    /// Slightly conservative (3.8) so the bar fills a bit faster — better to
    /// warn the user early than to surprise them with an overflow.
    private static let charsPerToken: Double = 3.8

    /// Approximate tokens emitted by the model in its response. Reserved out of
    /// the visible context budget so the bar is honest about *usable* room.
    private static let reservedOutputTokens: Int = 4_000

    struct Breakdown {
        let systemPromptTokens: Int
        let conversationTokens: Int
        let attachmentTokens: Int
        let terminalContextTokens: Int
        let userInputTokens: Int
        let reservedOutputTokens: Int
        let contextWindow: Int

        var promptTokens: Int {
            systemPromptTokens
                + conversationTokens
                + attachmentTokens
                + terminalContextTokens
                + userInputTokens
        }

        /// Total budgeted tokens (prompt + reserved response). What "usage" means.
        var usedTokens: Int { promptTokens + reservedOutputTokens }

        /// 0.0 ... 1.0+ (can exceed 1 if the user overpacks the window).
        var fillRatio: Double {
            guard contextWindow > 0 else { return 0 }
            return Double(usedTokens) / Double(contextWindow)
        }

        var isWarning: Bool { fillRatio >= 0.70 && fillRatio < 0.90 }
        var isCritical: Bool { fillRatio >= 0.90 }
    }

    /// Estimates tokens for an arbitrary string. Treats nil/empty as zero.
    static func tokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int((Double(text.count) / charsPerToken).rounded(.up))
    }

    /// Estimates a system-prompt size based on the tab mode. We don't rebuild the
    /// real prompt every keystroke (too expensive); instead we use measured
    /// constants that closely match the actual `PromptBuilder` output.
    /// Update these when the system prompt grows substantially.
    static func systemPromptTokens(for tabMode: TabMode) -> Int {
        switch tabMode {
        case .terminal, .mosaic:      return 1_400
        case .git:                    return 1_200
        case .explorer, .diskAnalyzer: return 900
        }
    }

    /// Estimates tokens for the conversation history block as it will be rendered.
    /// Mirrors the truncation rules in `ConversationTurn.from(...)` and
    /// `PromptBuilder.buildConversationHistoryBlock`.
    static func conversationTokens(_ turns: [ConversationTurn]) -> Int {
        guard !turns.isEmpty else { return 0 }
        var total = 60
        for turn in turns {
            total += tokens(in: turn.userMessage)
            total += tokens(in: turn.planTitle)
            total += tokens(in: turn.planExplanation)
            total += tokens(in: turn.summary)
            for brief in turn.stepBriefs {
                total += tokens(in: brief.command)
                total += tokens(in: brief.stdoutHead)
                total += tokens(in: brief.stderrHead)
            }
            total += 40
        }
        return total
    }

    static func attachmentTokens(_ attachments: [FileAttachment]) -> Int {
        attachments.reduce(0) { acc, att in acc + tokens(in: att.truncatedContent) + 60 }
    }

    /// Builds the full breakdown for the active tab. Cheap to call on every
    /// keystroke (string lengths only, no allocations beyond the struct).
    static func breakdown(
        tabMode: TabMode,
        contextWindow: Int,
        userInput: String,
        attachments: [FileAttachment],
        turns: [ConversationTurn],
        terminalContextChars: Int
    ) -> Breakdown {
        let terminalTokens = Int((Double(max(0, terminalContextChars)) / charsPerToken).rounded(.up))
        return Breakdown(
            systemPromptTokens: systemPromptTokens(for: tabMode),
            conversationTokens: conversationTokens(turns),
            attachmentTokens: attachmentTokens(attachments),
            terminalContextTokens: terminalTokens,
            userInputTokens: tokens(in: userInput),
            reservedOutputTokens: reservedOutputTokens,
            contextWindow: contextWindow
        )
    }

    /// Compact human-friendly token formatter (e.g. `1.2K`, `47K`, `1.0M`).
    static func formatTokens(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 10_000 {
            let v = Double(count) / 1_000.0
            return String(format: "%.1fK", v)
        }
        if count < 1_000_000 {
            let v = Int((Double(count) / 1_000.0).rounded())
            return "\(v)K"
        }
        let v = Double(count) / 1_000_000.0
        return String(format: "%.1fM", v)
    }
}
