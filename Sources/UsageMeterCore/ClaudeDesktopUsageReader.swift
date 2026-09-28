import Foundation

/// Local Desktop readings are useful even when no Claude Code OAuth login exists.
/// The cache has no reset timestamps or plan metadata; never invent either.
enum ClaudeDesktopUsageReader {
    static func fetch(
        now: Date = .now,
        historyURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/plan-usage-history.json")
    ) throws -> ProviderUsage {
        guard let data = try? Data(contentsOf: historyURL) else { throw UsageReadError.claudeLocalUnavailable }
        return try parse(data: data, now: now)
    }

    static func parse(data: Data, now: Date) throws -> ProviderUsage {
        struct Sample: Decodable {
            let t: Double
            let u: [String: Double]
        }
        struct History: Decodable { let samples: [Sample] }
        guard let history = try? JSONDecoder().decode(History.self, from: data),
              let latest = history.samples.filter({ $0.t.isFinite && $0.t > 0 })
                .max(by: { $0.t < $1.t }) else { throw UsageReadError.claudeLocalUnavailable }
        let windows = [("fh", "5-hour", 300), ("sd", "Weekly", 10_080)]
        let limits = windows.compactMap { key, label, duration -> UsageLimit? in
            guard let used = latest.u[key], used.isFinite else { return nil }
            return UsageLimit(id: "claude-local-\(key)", label: label, usedPercent: used,
                              resetsAt: nil, durationMinutes: duration, displayMode: .remaining)
        }
        guard !limits.isEmpty else { throw UsageReadError.claudeLocalUnavailable }
        return ProviderUsage(provider: .claude, limits: limits,
                             updatedAt: Date(timeIntervalSince1970: latest.t / 1_000),
                             sourceDescription: "Claude Desktop cache · open Claude to update",
                             isStale: true)
    }
}
