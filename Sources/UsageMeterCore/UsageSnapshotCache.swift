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

    private static func fileURL(for accountID: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest.prefix(16)).json")
    }
}
