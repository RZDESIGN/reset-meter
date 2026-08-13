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
