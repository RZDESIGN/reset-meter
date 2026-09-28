import Foundation
import Testing
@testable import UsageMeterCore

@Test func claudeReadsLiveWindowsAndExactResetDates() throws {
    let usage = try ClaudeUsageReader.parse(data: Data(#"""
    {"five_hour":{"utilization":42,"resets_at":"2026-09-24T18:00:00.000Z"},
     "seven_day":{"utilization":56,"resets_at":"2026-09-30T12:00:00Z"},
     "seven_day_sonnet":{"utilization":0,"resets_at":null},"seven_day_opus":null}
    """#.utf8), now: .now, planName: "Pro")
    #expect(usage.limits.map(\.displayPercent) == [58, 44, 100])
    #expect(usage.limits.map(\.durationMinutes) == [300, 10080, 10080])
    #expect(usage.limits[0].resetsAt == ISO8601DateFormatter().date(from: "2026-09-24T18:00:00Z"))
    #expect(usage.limits[1].resetsAt == ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z"))
    #expect(usage.limits[2].resetsAt == nil)
    #expect(usage.limits.allSatisfy { !$0.resetIsEstimated && $0.displayMode == .remaining })
    #expect(usage.headlinePercent == 44)
    #expect(usage.planName == "Pro")
    #expect(!usage.isStale)
}

@Test(arguments: ["{}", "null", "not json", #"{"five_hour":{"utilization":null}}"#,
                  #"{"five_hour":{"utilization":true}}"#, #"{"five_hour":{"utilization":"20"}}"#])
func claudeDoesNotInventUsageForMissingOrMalformedWindows(_ json: String) {
    #expect(throws: UsageReadError.self) { try ClaudeUsageReader.parse(data: Data(json.utf8), now: .now) }
}

@Test func claudeToleratesUnknownWindowsAndMissingReset() throws {
    let usage = try ClaudeUsageReader.parse(data: Data(#"{"future_window":{"utilization":10},"five_hour":{"utilization":100,"resets_at":"invalid"}}"#.utf8), now: .now)
    #expect(usage.headlinePercent == 0)
    #expect(usage.limits.count == 1)
    #expect(usage.limits[0].resetsAt == nil)
    #expect(usage.planName == nil)
}

@Test func claudePlanComesFromProfileIncludingMaxTier() {
    let profile = Data(#"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#.utf8)
    #expect(ClaudeUsageReader.parsePlan(profile) == "Max 20×")
    #expect(AccountPlan.claude("max", rateLimitTier: "default_claude_max_5x") == "Max 5×")
    #expect(AccountPlan.claude("max", rateLimitTier: "future_tier") == "Max")
    #expect(AccountPlan.claude("claude_team") == "Team")
    #expect(AccountPlan.claude("individual") == nil)
    #expect(ClaudeUsageReader.parsePlan(Data("{}".utf8)) == nil)
    #expect(AccountPlan.codex("unknown") == nil)
    #expect(AccountPlan.codex(" ") == nil)
}

@Test func claudeCredentialsRequireProfileScopeAndDetectExpiration() throws {
    let data = Data(#"{"claudeAiOauth":{"accessToken":"synthetic","refreshToken":"synthetic-refresh","expiresAt":1000000,"scopes":["user:profile"],"subscriptionType":"pro"}}"#.utf8)
    let credentials = try ClaudeCredentials.parse(data)
    #expect(credentials.planName == "Pro")
    #expect(!credentials.needsRefresh(now: Date(timeIntervalSince1970: 900)))
    #expect(credentials.needsRefresh(now: Date(timeIntervalSince1970: 941)))
    // An unknown expiry waits for a 401 instead of renewing on every read.
    let unknown = try ClaudeCredentials.parse(Data(#"{"claudeAiOauth":{"accessToken":"synthetic","expiresAt":0,"scopes":["user:profile"]}}"#.utf8))
    #expect(!unknown.needsRefresh(now: .now))
    #expect(throws: UsageReadError.self) {
        try ClaudeCredentials.parse(Data(#"{"claudeAiOauth":{"accessToken":"synthetic","scopes":["user:inference"]}}"#.utf8))
    }
    #expect(throws: UsageReadError.self) { try ClaudeCredentials.parse(Data("{}".utf8)) }
}

@Test(arguments: [false, true]) func claudeRenewsExpiredOrRejectedCredentialsOnce(expired: Bool) async throws {
    let transport = ClaudeTestTransport(expired: expired)
    let account = ClaudeAccount(name: "Work")
    let usage = try await ClaudeUsageReader.fetch(account: account,
        loadCredentials: { try await transport.credentials(for: $0) },
        refreshCredentials: { try await transport.refresh($0, credentials: $1) },
        request: { await transport.request($0) })
    #expect(usage.headlinePercent == 80)
    #expect(usage.planName == "Max 20×") // Live profile replaces cached Pro metadata.
    #expect(await transport.refreshCount == 1)
    #expect(await transport.accountIDs == [account.id, account.id, account.id])
    #expect(await transport.usageRequestCount == (expired ? 1 : 2))
}

@Test func claudeUsageSurvivesProfileFailureWithoutGuessingPlan() async throws {
    let credentials = ClaudeCredentials(accessToken: "synthetic", refreshToken: nil, expiresAt: nil,
        scopes: ["user:profile"], subscriptionType: nil, rateLimitTier: nil)
    let usage = try await ClaudeUsageReader.fetch(account: .defaultAccount,
        loadCredentials: { _ in credentials },
        refreshCredentials: { _, _ in Issue.record("Should not refresh a valid token") },
        request: { request in
            let isUsage = request.url?.lastPathComponent == "usage"
            let response = HTTPURLResponse(url: request.url!, statusCode: isUsage ? 200 : 503,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(#"{"five_hour":{"utilization":0}}"#.utf8), response)
        })
    #expect(usage.headlinePercent == 100)
    #expect(usage.planName == nil)
}

@Test(arguments: [false, true]) func claudeLocalNeverRenewsTheInstalledLogin(expired: Bool) async {
    let transport = ClaudeTestTransport(expired: expired)
    await #expect(throws: UsageReadError.claudeAuthorizationFailed) {
        try await ClaudeUsageReader.fetch(account: .defaultAccount,
            loadCredentials: { try await transport.credentials(for: $0) },
            refreshCredentials: { try await transport.refresh($0, credentials: $1) },
            request: { await transport.request($0) })
    }
    #expect(await transport.refreshCount == 0)
    #expect(await transport.usageRequestCount == (expired ? 0 : 1))
}

@Test(arguments: [401, 403, 429, 500]) func claudeFailuresDoNotExposeResponseBodies(status: Int) async {
    let transport = ClaudeTestTransport(expired: false, failureStatus: status)
    do {
        _ = try await ClaudeUsageReader.fetch(account: ClaudeAccount(name: "Work"),
            loadCredentials: { try await transport.credentials(for: $0) },
            refreshCredentials: { try await transport.refresh($0, credentials: $1) },
            request: { await transport.request($0) })
        Issue.record("Expected usage failure")
    } catch {
        #expect(error is UsageReadError)
        #expect(!error.localizedDescription.contains("private diagnostic"))
        #expect(await transport.refreshCount == (status == 401 ? 1 : 0))
    }
}

private actor ClaudeTestTransport {
    let expired: Bool
    let failureStatus: Int?
    var refreshCount = 0
    var usageRequestCount = 0
    var accountIDs: [String] = []

    init(expired: Bool, failureStatus: Int? = nil) {
        self.expired = expired
        self.failureStatus = failureStatus
    }

    func credentials(for account: ClaudeAccount) throws -> ClaudeCredentials {
        accountIDs.append(account.id)
        return ClaudeCredentials(accessToken: refreshCount == 0 ? "synthetic-old" : "synthetic-new",
            refreshToken: "synthetic-refresh", expiresAt: expired && refreshCount == 0 ? 1000 : nil,
            scopes: ["user:profile"], subscriptionType: "pro", rateLimitTier: nil)
    }

    func refresh(_ account: ClaudeAccount, credentials: ClaudeCredentials) throws {
        accountIDs.append(account.id)
        #expect(credentials.refreshToken == "synthetic-refresh")
        refreshCount += 1
    }

    func request(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        #expect(request.url?.host == "api.anthropic.com")
        #expect(request.url?.scheme == "https")
        #expect(request.httpMethod == "GET")
        #expect(!request.httpShouldHandleCookies)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        let isUsage = request.url?.lastPathComponent == "usage"
        if isUsage { usageRequestCount += 1 }
        let status = failureStatus ?? (isUsage && refreshCount == 0 ? 401 : 200)
        let json = status != 200 ? #"{"error":"private diagnostic"}"# : isUsage
            ? #"{"five_hour":{"utilization":20,"resets_at":null}}"#
            : #"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-\(refreshCount == 0 ? "old" : "new")")
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
