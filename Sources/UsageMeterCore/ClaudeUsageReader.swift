import Foundation

public enum ClaudeUsageReader {
    private static let fiveHours: TimeInterval = 5 * 60 * 60
    private static let sevenDays: TimeInterval = 7 * 24 * 60 * 60

    public static func fetch() async throws -> ProviderUsage {
        try await Task.detached(priority: .utility) {
            try self.fetchSynchronously(now: Date())
        }.value
    }

    public static func fetchSynchronously(
        now: Date,
        historyURL: URL? = nil
    ) throws -> ProviderUsage {
        let fileManager = FileManager.default
        let url = historyURL ?? fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/plan-usage-history.json")

        guard fileManager.fileExists(atPath: url.path) else {
            throw UsageReadError.claudeHistoryMissing
        }

        let data = try Data(contentsOf: url)
        return try parse(data: data, now: now)
    }

    public static func parse(data: Data, now: Date) throws -> ProviderUsage {
        let envelope = try JSONDecoder().decode(HistoryEnvelope.self, from: data)
        guard let latest = envelope.samples.max(by: { $0.timestamp < $1.timestamp }) else {
            throw UsageReadError.claudeHistoryEmpty
        }

        let accountSamples = envelope.samples
            .filter { $0.organization == latest.organization }
            .sorted { $0.timestamp < $1.timestamp }

        let configurations: [(String, String, TimeInterval)] = [
            ("fh", "5-hour", fiveHours),
            ("sd", "Weekly", sevenDays),
        ]

        let limits = configurations.compactMap { key, label, duration -> UsageLimit? in
            guard let used = latest.usage[key] else { return nil }
            let reset = estimateReset(
                samples: accountSamples,
                key: key,
                duration: duration,
                now: now
            )
            return UsageLimit(
                id: "claude-\(key)",
                label: label,
                usedPercent: used,
                resetsAt: reset,
                resetIsEstimated: reset != nil,
                durationMinutes: Int(duration / 60),
                displayMode: .remaining
            )
        }

        guard !limits.isEmpty else {
            throw UsageReadError.claudeHistoryEmpty
        }

        let updatedAt = Date(timeIntervalSince1970: latest.timestamp / 1_000)
        return ProviderUsage(
            provider: .claude,
            limits: limits,
            updatedAt: updatedAt,
            sourceDescription: "Claude Desktop cache",
            isStale: now.timeIntervalSince(updatedAt) > 30 * 60
        )
    }

    /// Claude Desktop stores utilization locally but omits reset timestamps.
    /// A new rolling window begins when usage drops and then becomes positive.
    /// Samples are written roughly every 4.5 minutes, so estimates are marked.
    public static func estimateReset(
        samples: [HistorySample],
        key: String,
        duration: TimeInterval,
        now: Date
    ) -> Date? {
        let points = samples.compactMap { sample -> (time: TimeInterval, value: Double)? in
            guard let value = sample.usage[key] else { return nil }
            return (sample.timestamp / 1_000, value)
        }
        guard let latest = points.last, latest.value > 0.5 else { return nil }

        var segmentStart = 0
        if points.count > 1 {
            for index in stride(from: points.count - 1, through: 1, by: -1) {
                if points[index].value + 0.5 < points[index - 1].value {
                    segmentStart = index
                    break
                }
            }
        }

        guard let anchor = points[segmentStart...].first(where: { $0.value > 0.5 })?.time else {
            return nil
        }

        let reset = Date(timeIntervalSince1970: anchor + duration)
        guard reset > now, reset.timeIntervalSince(now) <= duration + 10 * 60 else {
            return nil
        }
        return reset
    }
}

public struct HistoryEnvelope: Decodable, Sendable {
    public let version: Int
    public let samples: [HistorySample]
}

public struct HistorySample: Decodable, Sendable {
    public let timestamp: Double
    public let organization: String?
    public let usage: [String: Double]

    enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case organization = "org"
        case usage = "u"
    }

    public init(timestamp: Double, organization: String?, usage: [String: Double]) {
        self.timestamp = timestamp
        self.organization = organization
        self.usage = usage
    }
}
