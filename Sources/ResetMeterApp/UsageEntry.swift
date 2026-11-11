import Foundation
import UsageMeterCore

public enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
    case barsAndPercent
    case barsOnly
    case percentOnly

    public var label: String {
        switch self {
        case .barsAndPercent: "Bars & %"
        case .barsOnly: "Bars Only"
        case .percentOnly: "% Only"
        }
    }
}

struct UsageEntry: Identifiable {
    let account: ProviderAccount
    let usage: ProviderUsage?
    let error: String?
    var fallbackPlanName: String? = nil
    var hasMultipleProviderAccounts = false
    var isConnecting = false
    var canConnectCursor = false
    var hasSavedCursorSession = false

    var id: String { account.id }
    var provider: UsageProvider { account.provider }

    var displayName: String {
        if let subtitle = visibleAccountSubtitle {
            return "\(provider.displayName) \(subtitle)"
        }
        return provider.displayName
    }

    var accountName: String { account.name }

    /// Hide redundant "Default" subtitle when there is only a single account for that provider.
    var visibleAccountSubtitle: String? {
        let trimmed = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !hasMultipleProviderAccounts && trimmed.caseInsensitiveCompare("Default") == .orderedSame {
            return nil
        }
        return trimmed
    }

    var planLabel: String? {
        usage?.planName ?? fallbackPlanName
    }
}
