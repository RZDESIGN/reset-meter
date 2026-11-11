import Foundation

public enum UsageProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case antigravity
    case cursor

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .antigravity: "Antigravity"
        case .cursor: "Cursor"
        }
    }

    public var localSourceHint: String {
        switch self {
        case .codex: "Reads local ChatGPT / Codex profile via bundled Codex CLI"
        case .claude: "Reads local Claude app & Claude Code profile (read-only)"
        case .antigravity: "Reads live quotas from local Antigravity language server"
        case .cursor: "Reads local Cursor app database (read-only)"
        }
    }
}

public enum UsageDisplayMode: String, Codable, Equatable, Sendable {
    case consumed
    case remaining

    public var qualifier: String {
        switch self {
        case .consumed: "used"
        case .remaining: "left"
        }
    }
}

public struct UsageLimit: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let resetIsEstimated: Bool
    public let durationMinutes: Int?
    public let displayMode: UsageDisplayMode

    public init(
        id: String,
        label: String,
        usedPercent: Double,
        resetsAt: Date?,
        resetIsEstimated: Bool = false,
        durationMinutes: Int? = nil,
        displayMode: UsageDisplayMode = .consumed
    ) {
        self.id = id
        self.label = label
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.resetIsEstimated = resetIsEstimated
        self.durationMinutes = durationMinutes
        self.displayMode = displayMode
    }

    public var displayPercent: Double {
        switch displayMode {
        case .consumed: usedPercent
        case .remaining: 100 - usedPercent
        }
    }
}

public struct ProviderUsage: Codable, Equatable, Sendable {
    public let provider: UsageProvider
    public let limits: [UsageLimit]
    public let updatedAt: Date
    public let sourceDescription: String
    public let isStale: Bool
    public let bankedResets: BankedResets?
    public let planName: String?
    public let footnote: String?

    public init(
        provider: UsageProvider,
        limits: [UsageLimit],
        updatedAt: Date,
        sourceDescription: String,
        isStale: Bool = false,
        bankedResets: BankedResets? = nil,
        planName: String? = nil,
        footnote: String? = nil
    ) {
        self.provider = provider
        self.limits = limits
        self.updatedAt = updatedAt
        self.sourceDescription = sourceDescription
        self.isStale = isStale
        self.bankedResets = bankedResets
        self.planName = planName
        self.footnote = footnote
    }

    public var headlinePercent: Int? {
        limits.max(by: { $0.usedPercent < $1.usedPercent })
            .map { Int($0.displayPercent.rounded()) }
    }
}

public enum UsageReadError: LocalizedError, Equatable, Sendable {
    case codexNotFound
    case codexTimedOut
    case malformedCodexResponse
    case codexAccountUnavailable
    case claudeLocalUnavailable
    case claudeAuthorizationFailed
    case claudeCredentialsUnavailable
    case claudeRateLimited
    case malformedClaudeResponse
    case antigravityNotRunning
    case malformedAntigravityResponse
    case cursorNotFound
    case cursorSignedOut
    case cursorAuthorizationFailed
    case malformedCursorResponse

    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            "ChatGPT or Codex CLI was not found. Install ChatGPT or Codex and open it once."
        case .codexTimedOut:
            "Codex did not return usage in time."
        case .malformedCodexResponse:
            "Codex returned an unfamiliar usage response."
        case .codexAccountUnavailable:
            "No active ChatGPT / Codex login in this local profile. Open the corresponding ChatGPT or Codex client once."
        case .claudeLocalUnavailable:
            "No local Claude reading found for this profile yet. Open the corresponding Claude app once to populate its usage."
        case .claudeAuthorizationFailed:
            "Local Claude token expired. Open the corresponding Claude app to refresh its session."
        case .claudeCredentialsUnavailable:
            "Could not access local Claude credentials. Unlock your login keychain or open Claude."
        case .claudeRateLimited:
            "Claude is temporarily limiting usage checks. Wait a few minutes, then refresh."
        case .malformedClaudeResponse:
            "Claude returned an unfamiliar usage response."
        case .antigravityNotRunning:
            "Antigravity is not running. Open Antigravity to view live model quotas."
        case .malformedAntigravityResponse:
            "Antigravity returned an unfamiliar quota response."
        case .cursorNotFound:
            "Cursor's local database was not found. Install and open Cursor once."
        case .cursorSignedOut:
            "No active login in this local Cursor profile."
        case .cursorAuthorizationFailed:
            "Cursor's local token needs refreshing. Open Cursor once, then refresh."
        case .malformedCursorResponse:
            "Cursor returned an unfamiliar usage response."
        }
    }
}
