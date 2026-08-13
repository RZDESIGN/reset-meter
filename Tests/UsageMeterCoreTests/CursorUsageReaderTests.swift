import Foundation
import Testing
@testable import UsageMeterCore

@Test func cursorFirstPartyUsageDisplaysRemainingPercentAndReset() throws {
    let data = #"{"billingCycleStart":"1785235728000","billingCycleEnd":"1787914128000","planUsage":{"autoPercentUsed":14.007142857142856,"apiPercentUsed":100}}"#.data(using: .utf8)!
    let now = Date(timeIntervalSince1970: 1_785_500_000)

    let usage = try CursorUsageReader.parse(data: data, now: now)

    #expect(usage.provider == .cursor)
    #expect(usage.headlinePercent == 86)
    #expect(usage.limits.first?.label == "Composer + Grok")
    #expect(usage.limits.first?.resetsAt == Date(timeIntervalSince1970: 1_787_914_128))
}

@Test func cursorUsageRejectsResponseWithoutFirstPartyPool() {
    let data = #"{"planUsage":{"apiPercentUsed":100}}"#.data(using: .utf8)!

    #expect(throws: UsageReadError.self) {
        try CursorUsageReader.parse(data: data, now: .now)
    }
}
