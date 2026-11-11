import Foundation
import Testing
@testable import UsageMeterCore

@Test func antigravityGroupsSharedModelQuotaPoolsAndReadsTierAndCredits() throws {
    let json = Data(#"""
    {
      "userStatus": {
        "userTier": {
          "id": "g1-ultra-tier",
          "name": "Google AI Ultra",
          "availableCredits": [
            {"creditType": "GOOGLE_ONE_AI", "creditAmount": "2414", "minimumCreditAmountForUsage": "50"}
          ]
        },
        "planStatus": {"planInfo": {"planName": "Pro"}},
        "cascadeModelConfigData": {
          "clientModelConfigs": [
            {"label": "Gemini 4 Carbon (High)", "quotaInfo": {"remainingFraction": 0.88, "resetTime": "2026-11-11T18:50:48Z"}},
            {"label": "Gemini 4 Carbon (Low)", "quotaInfo": {"remainingFraction": 0.88, "resetTime": "2026-11-11T18:50:48Z"}},
            {"label": "Gemini 3.8 Flash (High)", "quotaInfo": {"remainingFraction": 0.88, "resetTime": "2026-11-11T18:50:48Z"}},
            {"label": "Claude Opus 5.5 (High)", "quotaInfo": {"remainingFraction": 0.65, "resetTime": "2026-11-11T18:53:17Z"}},
            {"label": "Claude Sonnet 5.5 (Medium)", "quotaInfo": {"remainingFraction": 0.65, "resetTime": "2026-11-11T18:53:17Z"}},
            {"label": "GPT-OSS 120B (Medium)", "quotaInfo": {"remainingFraction": 0.65, "resetTime": "2026-11-11T18:53:17Z"}}
          ]
        }
      }
    }
    """#.utf8)

    let usage = try AntigravityUsageReader.parse(data: json, now: Date(timeIntervalSince1970: 1_794_400_000))
    #expect(usage.provider == .antigravity)
    #expect(usage.planName == "Google AI Ultra")
    #expect(usage.footnote?.contains("2") == true && usage.footnote?.contains("AI credits") == true)
    #expect(usage.limits.map(\.label) == ["Gemini", "Claude & GPT"])
    #expect(usage.limits.map { Int($0.displayPercent.rounded()) } == [88, 65])
    #expect(usage.headlinePercent == 65)
    #expect(!usage.isStale)
}

@Test func antigravitySplitsDivergedSubPoolsAndHandlesExhaustedZeroQuota() throws {
    // In Protobuf3 JSON, remainingFraction == 0.0 is omitted while resetTime remains set.
    let json = Data(#"""
    {
      "userStatus": {
        "planStatus": {"planInfo": {"planName": "Pro"}},
        "cascadeModelConfigData": {
          "clientModelConfigs": [
            {"label": "Gemini 4 Carbon (High)", "quotaInfo": {"resetTime": "2026-11-11T18:50:48Z"}},
            {"label": "Gemini 3.8 Flash (High)", "quotaInfo": {"remainingFraction": 0.95, "resetTime": "2026-11-11T19:10:00Z"}}
          ]
        }
      }
    }
    """#.utf8)

    let usage = try AntigravityUsageReader.parse(data: json, now: .now)
    #expect(usage.planName == "Pro")
    #expect(usage.limits.map(\.label) == ["Gemini Pro", "Gemini Flash"])
    #expect(usage.limits.map { Int($0.displayPercent.rounded()) } == [0, 95])
    #expect(usage.headlinePercent == 0)
}

@Test func antigravityDiscoversProcessTargetAndFallsBackToOfflineCache() throws {
    let psOutput = """
      82926 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --csrf_token synthetic-csrf-123 --app_data_dir antigravity
      99999 /usr/sbin/other_daemon
    """
    let lsofOutput = """
    COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
    language_ 82926 user  7u  IPv4 0x01   0t0      TCP 127.0.0.1:63203 (LISTEN)
    language_ 82926 user  8u  IPv4 0x02   0t0      TCP 127.0.0.1:63204 (LISTEN)
    """
    let targets = AntigravityUsageReader.parseTargets(psOutput: psOutput) { pid in
        #expect(pid == "82926")
        return AntigravityUsageReader.parseListeningPorts(lsofOutput: lsofOutput)
    }
    #expect(targets.count == 1)
    #expect(targets.first?.csrfToken == "synthetic-csrf-123")
    #expect(targets.first?.ports == [63203, 63204])

    let cacheDir = FileManager.default.temporaryDirectory.appending(path: "ResetMeterAGCache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: cacheDir) }

    let pastReset = Date(timeIntervalSince1970: 1_000)
    let futureReset = Date(timeIntervalSince1970: 5_000)
    let saved = ProviderUsage(
        provider: .antigravity,
        limits: [
            UsageLimit(id: "g", label: "Gemini", usedPercent: 80, resetsAt: pastReset, displayMode: .remaining),
            UsageLimit(id: "c", label: "Claude & GPT", usedPercent: 40, resetsAt: futureReset, displayMode: .remaining),
        ],
        updatedAt: Date(timeIntervalSince1970: 900),
        sourceDescription: "Live",
        planName: "Google AI Ultra"
    )
    UsageSnapshotCache.save(saved, accountID: "antigravity:default", directory: cacheDir)

    let fallback = try #require(
        AntigravityUsageReader.cachedFallback(
            accountID: "antigravity:default",
            now: Date(timeIntervalSince1970: 2_000),
            cacheDirectory: cacheDir
        )
    )
    #expect(fallback.isStale)
    #expect(fallback.limits[0].displayPercent == 100) // Past reset window cleared to 100% remaining.
    #expect(fallback.limits[0].resetsAt == nil)
    #expect(fallback.limits[1].displayPercent == 60)
    #expect(fallback.limits[1].resetsAt == futureReset)
}
