import Foundation
import Testing
@testable import UsageMeterCore

@Test func estimatesRollingWindowFromFirstPositiveSampleAfterDrop() {
    let now = Date(timeIntervalSince1970: 20_000)
    let samples = [
        HistorySample(timestamp: 1_000_000, organization: "a", usage: ["fh": 80]),
        HistorySample(timestamp: 2_000_000, organization: "a", usage: ["fh": 0]),
        HistorySample(timestamp: 3_000_000, organization: "a", usage: ["fh": 12]),
    ]

    let reset = ClaudeUsageReader.estimateReset(
        samples: samples,
        key: "fh",
        duration: 5 * 60 * 60,
        now: now
    )

    #expect(reset == Date(timeIntervalSince1970: 21_000))
}

@Test func omitsResetForUnusedWindow() {
    let samples = [
        HistorySample(timestamp: 1_000_000, organization: "a", usage: ["fh": 0]),
    ]

    let reset = ClaudeUsageReader.estimateReset(
        samples: samples,
        key: "fh",
        duration: 5 * 60 * 60,
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(reset == nil)
}

@Test func claudeUsageDisplaysRemainingPercent() throws {
    let data = #"{"version":1,"samples":[{"t":10000000,"org":"a","u":{"fh":100,"sd":44}}]}"#.data(using: .utf8)!
    let usage = try ClaudeUsageReader.parse(
        data: data,
        now: Date(timeIntervalSince1970: 10_000)
    )

    #expect(usage.limits.first(where: { $0.id == "claude-fh" })?.displayPercent == 0)
    #expect(usage.limits.first(where: { $0.id == "claude-sd" })?.displayPercent == 56)
}
