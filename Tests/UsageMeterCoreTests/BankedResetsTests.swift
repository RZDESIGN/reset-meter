import Foundation
import Testing
@testable import UsageMeterCore

@Test func bankedResetCountIsAuthoritativeAndExpiryDetailsAreSorted() throws {
    let resets = try #require(BankedResets.parse([
        "availableCount": 5,
        "credits": [
            ["id": "later", "status": "available", "expiresAt": 2_000_000_000],
            ["id": "used", "status": "redeemed", "expiresAt": 1_800_000_000],
            ["id": "sooner", "status": "available", "expiresAt": 1_900_000_000],
            ["id": "sooner", "status": "available", "expiresAt": 1_900_000_000],
        ]
    ]))
    #expect(resets.availableCount == 5)
    #expect(resets.credits?.map(\.id) == ["sooner", "later"])
    #expect(resets.missingDetailCount == 3)
    #expect(resets.credits?.first?.expiration == .date(Date(timeIntervalSince1970: 1_900_000_000)))
}

@Test func unknownResetAvailabilityIsDifferentFromZeroAndCountOnly() throws {
    #expect(BankedResets.parse(nil) == nil)
    #expect(BankedResets.parse(NSNull()) == nil)
    #expect(BankedResets.parse(["availableCount": -1]) == nil)
    #expect(BankedResets.parse(["availableCount": true]) == nil)
    let zero = try #require(BankedResets.parse(["availableCount": 0, "credits": []]))
    #expect(zero.availableCount == 0)
    #expect(zero.credits == [])
    let countOnly = try #require(BankedResets.parse(["availableCount": 3, "credits": NSNull()]))
    #expect(countOnly.availableCount == 3)
    #expect(countOnly.credits == nil)
    #expect(countOnly.missingDetailCount == 3)
}

@Test func resetExpiryDistinguishesNoExpiryFromMissingDetails() throws {
    let resets = try #require(BankedResets.parse([
        "availableCount": 2,
        "credits": [
            ["id": "never", "status": "available", "expiresAt": NSNull()],
            ["id": "unknown", "status": "available"],
        ]
    ]))
    #expect(resets.credits?.first(where: { $0.id == "never" })?.expiration == .never)
    #expect(resets.credits?.first(where: { $0.id == "unknown" })?.expiration == .unknown)
}

@Test func codexReadsBankedResetsEvenWithoutUsageWindows() throws {
    let output = Data(#"{"id":2,"result":{"rateLimits":{},"rateLimitResetCredits":{"availableCount":2,"credits":null}}}"#.utf8)
    let usage = try CodexUsageReader.parse(output: output, now: .now)
    #expect(usage.limits.isEmpty)
    #expect(usage.headlinePercent == nil)
    #expect(usage.bankedResets?.availableCount == 2)
}

@Test func malformedBankedResetsDoNotDiscardValidUsage() throws {
    let output = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":19}},"rateLimitResetCredits":{"availableCount":"invalid"}}}"#.utf8)
    let usage = try CodexUsageReader.parse(output: output, now: .now)
    #expect(usage.headlinePercent == 81)
    #expect(usage.bankedResets == nil)
}
