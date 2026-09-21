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

    public init(
        provider: UsageProvider,
        limits: [UsageLimit],
        updatedAt: Date,
        sourceDescription: String,
        isStale: Bool = false,
        bankedResets: BankedResets? = nil
    ) {
        self.provider = provider
        self.limits = limits
        self.updatedAt = updatedAt
        self.sourceDescription = sourceDescription
        self.isStale = isStale
        self.bankedResets = bankedResets
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
    case claudeHistoryMissing
    case claudeHistoryEmpty
    case cursorNotFound
    case cursorSignedOut
    case cursorAuthorizationFailed
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
        case .claudeHistoryMissing:
            "Claude Desktop's local usage cache was not found."
        case .claudeHistoryEmpty:
            "Claude Desktop has not cached usage yet. Open Claude's usage menu once."
        case .cursorNotFound:
            "Cursor's local state was not found. Install and open Cursor once."
        case .cursorSignedOut:
            "Cursor is not signed in. Sign in to Cursor, then refresh."
        case .cursorAuthorizationFailed:
            "Cursor's login needs refreshing. Open Cursor, then refresh."
        case .malformedCursorResponse:
            "Cursor returned an unfamiliar usage response."
        }
    }
}
