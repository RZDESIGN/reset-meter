import Foundation
import UsageMeterCore

struct UsageEntry: Identifiable {
    let provider: UsageProvider
    var account: CodexAccount? = nil
    let usage: ProviderUsage?
    let error: String?

    var id: String {
        account.map { "codex:\($0.id)" } ?? provider.rawValue
    }

    var displayName: String {
        account.map { "Codex \($0.name)" } ?? provider.displayName
    }
}
