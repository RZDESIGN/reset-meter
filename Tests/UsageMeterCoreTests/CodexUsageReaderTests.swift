import Foundation
import Testing
@testable import UsageMeterCore

@Test func codexUsedPercentIsPresentedAsRemainingCapacity() throws {
    let response = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":19,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":null}}}"#.utf8)

    let usage = try CodexUsageReader.parse(
        output: response,
        now: Date(timeIntervalSince1970: 1_900_000_000)
    )

    let weekly = try #require(usage.limits.first)
    #expect(weekly.usedPercent == 19)
    #expect(weekly.displayPercent == 81)
    #expect(weekly.displayMode == .remaining)
    #expect(usage.headlinePercent == 81)
}

@Test func codexPlanUsesAccountMetadataRegardlessOfResponseOrder() throws {
    let account = #"{"id":3,"result":{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"business"}}}"#
    let limits = #"{"id":2,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":10}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":20}},"other":{"planType":"free"}}}}"#
    for output in [account + "\n" + limits, limits + "\n" + account] {
        let usage = try CodexUsageReader.parse(output: Data(output.utf8), now: .now)
        #expect(usage.planName == "Business")
        #expect(usage.headlinePercent == 80)
    }
    #expect(try CodexUsageReader.parse(output: Data(limits.utf8), now: .now).planName == "Pro")
}

@Test func codexUsageWorksWhenAccountPlanIsUnavailable() throws {
    let output = Data(#"""
    {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":10}}}}
    {"id":3,"error":{"message":"synthetic private diagnostic"}}
    """#.utf8)
    let usage = try CodexUsageReader.parse(output: output, now: .now)
    #expect(usage.planName == nil)
    #expect(usage.headlinePercent == 90)
}
