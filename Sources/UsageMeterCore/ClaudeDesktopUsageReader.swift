import Foundation

/// Reads Claude Desktop's local `plan-usage-history.json` for a specific local Claude profile.
/// Supports both v1 and v2 formats, matches the active organization when known, attaches local
/// plan metadata, and preserves any verified future reset timestamp from an earlier live read.
enum ClaudeDesktopUsageReader {
    private static let freshThresholdSeconds: TimeInterval = 15 * 60

    static func fetch(
        account: ProviderAccount,
        metadata: ClaudeLocalMetadata,
        previousSnapshot: ProviderUsage? = nil,
        now: Date = .now,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ProviderUsage {
        let historyURL = account.resolvedClaudeDesktopDirectory(home: home)
            .appending(path: "plan-usage-history.json")
        guard let data = try? Data(contentsOf: historyURL) else {
            throw UsageReadError.claudeLocalUnavailable
        }
        return try parse(
            data: data,
            now: now,
            organizationUUID: metadata.organizationUUID,
            planName: metadata.planName ?? previousSnapshot?.planName,
            previousSnapshot: previousSnapshot
        )
    }

    static func latestOrganizationUUID(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = root["samples"] as? [[String: Any]] else { return nil }
        return samples
            .compactMap { sample -> (Double, String)? in
                guard let t = (sample["t"] as? NSNumber)?.doubleValue, t.isFinite, t > 0,
                      let org = (sample["org"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !org.isEmpty else { return nil }
                return (t, org)
            }
            .max(by: { $0.0 < $1.0 })?
            .1
    }

    static func parse(
        data: Data,
        now: Date,
        organizationUUID: String? = nil,
        planName: String? = nil,
        previousSnapshot: ProviderUsage? = nil
    ) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSamples = root["samples"] as? [[String: Any]], !rawSamples.isEmpty else {
            throw UsageReadError.claudeLocalUnavailable
        }

        struct ParsedSample {
            let t: Double
            let org: String?
            let u: [String: Double]
        }

        let validSamples: [ParsedSample] = rawSamples.compactMap { row in
            guard let t = (row["t"] as? NSNumber)?.doubleValue, t.isFinite, t > 0 else { return nil }
            let org = row["org"] as? String
            var map: [String: Double] = [:]
            if let u = row["u"] as? [String: Any] {
                for (key, rawValue) in u {
                    if let num = rawValue as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue.isFinite {
                        map[key] = num.doubleValue
                    }
                }
            } else {
                // Legacy v1 sample format: {"t": ..., "fh": ..., "sd": ...}
                for key in ["fh", "sd"] {
                    if let num = row[key] as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue.isFinite {
                        map[key] = num.doubleValue
                    }
                }
            }
            return map.isEmpty ? nil : ParsedSample(t: t, org: org, u: map)
        }

        let matchingOrgSamples: [ParsedSample]
        if let expectedOrg = organizationUUID, !expectedOrg.isEmpty {
            let filtered = validSamples.filter { $0.org?.caseInsensitiveCompare(expectedOrg) == .orderedSame }
            matchingOrgSamples = filtered.isEmpty ? validSamples : filtered
        } else {
            matchingOrgSamples = validSamples
        }

        guard let latest = matchingOrgSamples.max(by: { $0.t < $1.t }) else {
            throw UsageReadError.claudeLocalUnavailable
        }

        let windows: [(shortKey: String, liveID: String, label: String, duration: Int)] = [
            ("fh", "claude-five_hour", "5-hour", 300),
            ("sd", "claude-seven_day", "Weekly", 10_080),
            ("so", "claude-seven_day_opus", "Weekly · Opus", 10_080),
            ("sn", "claude-seven_day_sonnet", "Weekly · Sonnet", 10_080),
            ("oa", "claude-seven_day_oauth_apps", "Weekly · OAuth apps", 10_080),
            ("cw", "claude-seven_day_cowork", "Weekly · Cowork", 10_080),
        ]

        let sampleDate = Date(timeIntervalSince1970: latest.t / 1_000)
        let limits = windows.compactMap { shortKey, liveID, label, duration -> UsageLimit? in
            guard let used = latest.u[shortKey], used.isFinite else { return nil }
            let preservedReset = previousSnapshot?.limits
                .first(where: { $0.id == liveID || $0.label == label })?
                .resetsAt
                .flatMap { $0 > now ? $0 : nil }
            return UsageLimit(
                id: liveID,
                label: label,
                usedPercent: used,
                resetsAt: preservedReset,
                durationMinutes: duration,
                displayMode: .remaining
            )
        }

        guard !limits.isEmpty else { throw UsageReadError.claudeLocalUnavailable }
        let ageSeconds = max(0, now.timeIntervalSince(sampleDate))
        let isStale = ageSeconds > freshThresholdSeconds || limits.allSatisfy { $0.resetsAt == nil }
        return ProviderUsage(
            provider: .claude,
            limits: limits,
            updatedAt: sampleDate,
            sourceDescription: "Local Claude Desktop cache",
            isStale: isStale,
            planName: planName
        )
    }
}
