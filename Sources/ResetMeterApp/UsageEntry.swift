import Foundation
import UsageMeterCore

struct UsageEntry: Identifiable {
    let provider: UsageProvider
    var account: CodexAccount? = nil
    var claudeAccount: ClaudeAccount? = nil
    var cursorAccount: CursorAccount? = nil
    let usage: ProviderUsage?
    let error: String?

    var id: String {
        account.map { "codex:\($0.id)" }
            ?? claudeAccount.map { "claude:\($0.id)" } ?? cursorAccount?.entryID ?? provider.rawValue
    }

    var displayName: String {
        accountName.map { "\(provider.displayName) \($0)" } ?? provider.displayName
    }

    var accountName: String? { account?.name ?? claudeAccount?.name ?? cursorAccount?.name }

    var mode: ConnectionMode { account?.mode ?? claudeAccount?.mode ?? cursorAccount?.mode ?? .local }

    var planLabel: String? {
        guard provider == .codex || provider == .claude else { return nil }
        return usage?.planName ?? "Plan unavailable"
    }
}
