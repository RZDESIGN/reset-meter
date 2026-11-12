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

@Test func claudePlanAndMetadataParseAcrossTiersAndLocalConfig() {
    let profile = Data(#"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#.utf8)
    #expect(ClaudeUsageReader.parsePlan(profile) == "Max 20×")
    #expect(AccountPlan.claude("max", rateLimitTier: "default_claude_max_5x") == "Max 5×")
    #expect(AccountPlan.claude("claude_team") == "Team")
    #expect(AccountPlan.codex("self_serve_business_prolite") == "Business Pro Lite")

    let localConfig = Data(#"""
    {"oauthAccount":{"organizationUuid":"org-work-1","organizationType":"claude_team","userRateLimitTier":"default_raven"}}
    """#.utf8)
    let metadata = ClaudeLocalMetadata.parseClaudeJSON(localConfig)
    #expect(metadata?.organizationUUID == "org-work-1")
    #expect(metadata?.planName == "Team")
}

@Test func claudeMatchesActiveDesktopProcessStrictlyByOrganizationOrProfile() {
    let psPersonal = "/Users/demo/Library/Application Support/Claude/claude-code/2.1.321/claude.app/Contents/MacOS/claude CLAUDE_CODE_OAUTH_TOKEN=tok-personal CLAUDE_CODE_ORGANIZATION_UUID=org-personal CLAUDE_CODE_SUBSCRIPTION_TYPE=max CLAUDE_CODE_RATE_LIMIT_TIER=default_claude_max_20x"
    let psWork = "/Users/demo/Library/Application Support/Claude-Work/claude-code/2.1.321/claude.app/Contents/MacOS/claude CLAUDE_CONFIG_DIR=/Users/demo/.claude-work CLAUDE_CODE_OAUTH_TOKEN=tok-work CLAUDE_CODE_ORGANIZATION_UUID=org-work CLAUDE_CODE_SUBSCRIPTION_TYPE=team"

    let matchedPersonal = ClaudeCredentials.matchDesktopProcessEnvironment(
        psOutput: psPersonal,
        expectedOrganizationUUID: "org-personal",
        expectedCodeDir: "/Users/demo/.claude",
        expectedDesktopPrefix: "/Users/demo/Library/Application Support/Claude/claude-code",
        isDefaultCodeDir: true
    )
    #expect(matchedPersonal?.accessToken == "tok-personal")
    #expect(matchedPersonal?.planName == "Max 20×")

    // Work account must reject personal process and accept only work process.
    let rejectedCrossMatch = ClaudeCredentials.matchDesktopProcessEnvironment(
        psOutput: psPersonal,
        expectedOrganizationUUID: "org-work",
        expectedCodeDir: "/Users/demo/.claude-work",
        expectedDesktopPrefix: "/Users/demo/Library/Application Support/Claude-Work/claude-code",
        isDefaultCodeDir: false
    )
    #expect(rejectedCrossMatch == nil)

    let matchedWork = ClaudeCredentials.matchDesktopProcessEnvironment(
        psOutput: psWork,
        expectedOrganizationUUID: "org-work",
        expectedCodeDir: "/Users/demo/.claude-work",
        expectedDesktopPrefix: "/Users/demo/Library/Application Support/Claude-Work/claude-code",
        isDefaultCodeDir: false
    )
    #expect(matchedWork?.accessToken == "tok-work")
    #expect(matchedWork?.planName == "Team")

    // Multi-word scope lists and config directories containing spaces (e.g. `Application Support`) must parse intact.
    let psSpaced = "/Applications/Claude.app/Contents/MacOS/Claude CLAUDE_CONFIG_DIR=/Users/demo/Library/Application Support/Claude-Work CLAUDE_CODE_OAUTH_TOKEN=tok-spaced CLAUDE_CODE_OAUTH_SCOPES=user:inference user:profile CLAUDE_CODE_SUBSCRIPTION_TYPE=team"
    let matchedSpaced = ClaudeCredentials.matchDesktopProcessEnvironment(
        psOutput: psSpaced,
        expectedOrganizationUUID: nil,
        expectedCodeDir: "/Users/demo/Library/Application Support/Claude-Work",
        expectedDesktopPrefix: "/Users/demo/Library/Application Support/Claude-Work/claude-code",
        isDefaultCodeDir: false
    )
    #expect(matchedSpaced?.accessToken == "tok-spaced")
    #expect(matchedSpaced?.scopes == ["user:inference", "user:profile"])
}

@Test func claudeDesktopCacheIgnoresExtraUsageCapAndPreservesVerifiedFutureReset() throws {
    // `xu: 100` (extra usage spend cap) must never override `fh: 0, sd: 0` (100% included capacity left).
    let data = Data(#"""
    {"version":2,"samples":[
      {"t":1000000,"org":"org-personal","u":{"sd":80}},
      {"t":2000000,"org":"org-work","u":{"fh":0,"sd":0,"xu":100}}
    ]}
    """#.utf8)

    let futureReset = Date(timeIntervalSince1970: 10_000)
    let previous = ProviderUsage(
        provider: .claude,
        limits: [UsageLimit(id: "claude-seven_day", label: "Weekly", usedPercent: 10, resetsAt: futureReset, displayMode: .remaining)],
        updatedAt: Date(timeIntervalSince1970: 1_500),
        sourceDescription: "Live",
        planName: "Team"
    )

    let workUsage = try ClaudeDesktopUsageReader.parse(
        data: data,
        now: Date(timeIntervalSince1970: 2_100),
        organizationUUID: "org-work",
        planName: "Team",
        previousSnapshot: previous
    )
    #expect(workUsage.headlinePercent == 100)
    #expect(workUsage.planName == "Team")
    #expect(workUsage.limits.map(\.label) == ["5-hour", "Weekly"])
    #expect(workUsage.limits[1].resetsAt == futureReset)

    // A 5-hour sample older than 5 hours rolls over to 100% remaining while preserving recent 7-day usage.
    let staleSampleData = Data(#"{"version":2,"samples":[{"t":1000000,"org":"org-work","u":{"fh":85,"sd":40}}]}"#.utf8)
    let rolledOver = try ClaudeDesktopUsageReader.parse(
        data: staleSampleData,
        now: Date(timeIntervalSince1970: 1_000 + 6 * 3_600),
        organizationUUID: "org-work",
        planName: "Team"
    )
    #expect(rolledOver.limits[0].displayPercent == 100)
    #expect(rolledOver.limits[1].displayPercent == 60)
}

@Test func claudeLocalLayerPipelineFallsThroughGracefullyWithoutMutatingLogins() async throws {
    let account = ProviderAccount.defaultAccount(for: .claude)
    let cachedUsage = ProviderUsage(
        provider: .claude,
        limits: [UsageLimit(id: "claude-seven_day", label: "Weekly", usedPercent: 25, resetsAt: nil, displayMode: .remaining)],
        updatedAt: .now,
        sourceDescription: "Local Claude Desktop cache",
        isStale: true,
        planName: "Max 20×"
    )

    let resolved = try await ClaudeUsageReader.fetchLocalLayers(
        account: account,
        activeSession: { throw UsageReadError.claudeLocalUnavailable },
        storedCredentials: { throw UsageReadError.claudeAuthorizationFailed },
        desktopCache: { cachedUsage }
    )
    #expect(resolved.headlinePercent == 75)
    #expect(resolved.planName == "Max 20×")
}
