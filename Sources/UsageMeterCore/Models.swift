import Foundation

public enum UsageProvider: String, Sendable {
    case codex
    case claude
    case cursor

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        }
    }
}

public enum UsageDisplayMode: Equatable, Sendable {
    case consumed
    case remaining

    public var qualifier: String {
        switch self {
        case .consumed: return "used"
        case .remaining: return "left"
        }
    }
}

public struct UsageLimit: Identifiable, Equatable, Sendable {
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
        case .consumed: return usedPercent
        case .remaining: return 100 - usedPercent
        }
    }
}

public struct ProviderUsage: Equatable, Sendable {
    public let provider: UsageProvider
    public let limits: [UsageLimit]
    public let updatedAt: Date
    public let sourceDescription: String
    public let isStale: Bool
    public let bankedResets: BankedResets?
    public let planName: String?

    public init(
        provider: UsageProvider,
        limits: [UsageLimit],
        updatedAt: Date,
        sourceDescription: String,
        isStale: Bool = false,
        bankedResets: BankedResets? = nil,
        planName: String? = nil
    ) {
        self.provider = provider
        self.limits = limits
        self.updatedAt = updatedAt
        self.sourceDescription = sourceDescription
        self.isStale = isStale
        self.bankedResets = bankedResets
        self.planName = planName
    }

    public var headlinePercent: Int? {
        limits.max(by: { $0.usedPercent < $1.usedPercent })
            .map { Int($0.displayPercent.rounded()) }
    }
}

public enum UsageReadError: LocalizedError, Sendable {
    case codexNotFound
    case codexTimedOut
    case malformedCodexResponse
    case codexAccountUnavailable
    case codexLoginFailed
    case claudeNotFound
    case claudeLocalUnavailable
    case claudeSignedOut
    case claudeAuthorizationFailed
    case claudeLoginFailed
    case claudeTimedOut
    case claudeCredentialsUnavailable
    case claudeRateLimited
    case malformedClaudeResponse
    case cursorNotFound
    case cursorSignedOut
    case cursorAuthorizationFailed
    case cursorLoginFailed
    case cursorCredentialsUnavailable
    case malformedCursorResponse

    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            "Codex CLI was not found. Open Codex once or install its CLI."
        case .codexTimedOut:
            "Codex did not return usage in time."
        case .malformedCodexResponse:
            "Codex returned an unfamiliar usage response."
        case .codexAccountUnavailable:
            "Usage is unavailable for this account. Check its ChatGPT subscription or sign in again."
        case .codexLoginFailed:
            "Sign-in did not finish. Try again and complete the browser sign-in within three minutes."
        case .claudeNotFound:
            "Claude's sign-in helper was not found. Open the Claude app's Code tab once so it finishes setup, then click Sign In again."
        case .claudeLocalUnavailable:
            "No current Claude reading on this Mac. Open the Claude app and view your usage, then refresh. Or choose Login for live account usage with reset times."
        case .claudeSignedOut:
            "This Claude account is not signed in. Click Sign In in Providers to connect it."
        case .claudeAuthorizationFailed:
            "This Claude login has expired or was signed out elsewhere. Click Sign In in Providers to reconnect it."
        case .claudeLoginFailed:
            "Claude sign-in did not finish. Try again and complete the browser sign-in within three minutes."
        case .claudeTimedOut:
            "Claude took too long to renew this login. Refresh to try again."
        case .claudeCredentialsUnavailable:
            "Could not read this Claude login from Keychain. Make sure your login keychain is unlocked, then refresh."
        case .claudeRateLimited:
            "Claude is limiting usage checks. Wait a few minutes, then refresh."
        case .malformedClaudeResponse:
            "Claude returned an unfamiliar usage response."
        case .cursorNotFound:
            "Cursor's local state was not found. Install and open Cursor once."
        case .cursorSignedOut:
            "No Cursor login found for this connection. Choose Login and Sign In, or sign in to Cursor for Local mode."
        case .cursorAuthorizationFailed:
            "Cursor's login needs refreshing. Sign In again in Login mode, or open Cursor in Local mode, then refresh."
        case .cursorLoginFailed:
            "Cursor sign-in did not finish. Try again and complete the browser sign-in within three minutes."
        case .cursorCredentialsUnavailable:
            "Could not access this Cursor login. Allow Keychain access, then try again."
        case .malformedCursorResponse:
            "Cursor returned an unfamiliar usage response."
        }
    }
}
