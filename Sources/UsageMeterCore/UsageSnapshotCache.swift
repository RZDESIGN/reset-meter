import CryptoKit
import Foundation

/// Privacy-safe local cache storing only anonymized percentages, reset dates, and plan labels
/// (never tokens, cookies, or personal identifiers). Allows showing last-known quotas when a
/// local desktop client (such as Antigravity or Claude) is temporarily closed.
public enum UsageSnapshotCache {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Reset Meter/Usage Cache", directoryHint: .isDirectory)
    }

    public static func save(_ usage: ProviderUsage, accountID: String, directory: URL = defaultDirectory) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = fileURL(for: accountID, in: directory)
        guard let data = try? JSONEncoder().encode(usage) else { return }
        try? data.write(to: file, options: .atomic)
    }

    public static func load(accountID: String, directory: URL = defaultDirectory) -> ProviderUsage? {
        let file = fileURL(for: accountID, in: directory)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ProviderUsage.self, from: data)
    }

    /// Loads a cached usage snapshot as an offline/closed-app fallback, marking `isStale = true`
    /// and rolling over any quota window whose verified `resetsAt` has already passed.
    public static func staleFallback(
        accountID: String,
        now: Date = .now,
        sourceDescription: String,
        directory: URL = defaultDirectory
    ) -> ProviderUsage? {
        guard let cached = load(accountID: accountID, directory: directory) else {
            return nil
        }
        let adjustedLimits = cached.limits.map { limit -> UsageLimit in
            if let reset = limit.resetsAt, reset <= now {
                return UsageLimit(
                    id: limit.id,
                    label: limit.label,
                    usedPercent: 0,
                    resetsAt: nil,
                    durationMinutes: limit.durationMinutes,
                    displayMode: limit.displayMode
                )
            }
            return limit
        }
        return ProviderUsage(
            provider: cached.provider,
            limits: adjustedLimits,
            updatedAt: cached.updatedAt,
            sourceDescription: sourceDescription,
            isStale: true,
            bankedResets: cached.bankedResets,
            planName: cached.planName,
            footnote: cached.footnote
        )
    }

    private static func fileURL(for accountID: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest.prefix(16)).json")
    }
}
