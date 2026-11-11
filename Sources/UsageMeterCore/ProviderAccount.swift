import CryptoKit
import Foundation

/// Represents a purely local installation or profile for a usage provider.
/// Only user-facing labels and local directory paths are stored in preferences.
public struct ProviderAccount: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: UsageProvider
    public var name: String
    /// Primary local profile path (e.g. `~/.codex-work` for Codex, `~/Library/Application Support/Claude-Work` for Claude).
    public var profilePath: String?
    /// Optional paired config path (e.g. `~/.claude-work` paired with `Claude-Work`).
    public var secondaryPath: String?

    public init(
        id: String? = nil,
        provider: UsageProvider,
        name: String,
        profilePath: String? = nil,
        secondaryPath: String? = nil
    ) {
        let resolvedID = id ?? "\(provider.rawValue):\(UUID().uuidString.lowercased())"
        self.id = resolvedID
        self.provider = provider
        self.name = name
        self.profilePath = Self.cleanPath(profilePath)
        self.secondaryPath = Self.cleanPath(secondaryPath)
    }

    public static func defaultAccount(for provider: UsageProvider, name: String = "Default") -> ProviderAccount {
        ProviderAccount(id: "\(provider.rawValue):default", provider: provider, name: name)
    }

    public var isDefault: Bool {
        id == "\(provider.rawValue):default" || id == "default"
    }

    public var isValid: Bool {
        guard !id.isEmpty,
              !id.contains(".."),
              !id.contains("/"),
              !id.contains("\\") else { return false }
        for path in [profilePath, secondaryPath].compactMap({ $0 }) {
            guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/..") else {
                return false
            }
        }
        return true
    }

    // MARK: - Resolved Local Paths

    public func resolvedCodexHome(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let profilePath {
            return URL(fileURLWithPath: profilePath, isDirectory: true)
        }
        return home.appending(path: ".codex", directoryHint: .isDirectory)
    }

    public func resolvedClaudeDesktopDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let profilePath {
            return URL(fileURLWithPath: profilePath, isDirectory: true)
        }
        return home.appending(path: "Library/Application Support/Claude", directoryHint: .isDirectory)
    }

    public func resolvedClaudeCodeDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let secondaryPath {
            return URL(fileURLWithPath: secondaryPath, isDirectory: true)
        }
        if let profilePath {
            let url = URL(fileURLWithPath: profilePath, isDirectory: true)
            if url.lastPathComponent.hasPrefix(".claude") {
                return url
            }
            let suffix = Self.profileSuffix(from: url.lastPathComponent, prefix: "Claude")
            if let suffix {
                return home.appending(path: ".claude-\(suffix.lowercased())", directoryHint: .isDirectory)
            }
        }
        return home.appending(path: ".claude", directoryHint: .isDirectory)
    }

    public func isDefaultClaudeCodeDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let defaultPath = home.appending(path: ".claude").path.precomposedStringWithCanonicalMapping
        let resolved = resolvedClaudeCodeDirectory(home: home).path.precomposedStringWithCanonicalMapping
        return resolved == defaultPath
    }

    public func claudeKeychainService(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if isDefaultClaudeCodeDirectory(home: home) {
            return "Claude Code-credentials"
        }
        let canonical = resolvedClaudeCodeDirectory(home: home).path.precomposedStringWithCanonicalMapping
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hash.prefix(8))"
    }

    public func resolvedAntigravityDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let profilePath {
            return URL(fileURLWithPath: profilePath, isDirectory: true)
        }
        return home.appending(path: "Library/Application Support/Antigravity", directoryHint: .isDirectory)
    }

    public func resolvedCursorDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let profilePath {
            return URL(fileURLWithPath: profilePath, isDirectory: true)
        }
        return home.appending(path: "Library/Application Support/Cursor", directoryHint: .isDirectory)
    }

    public func displaySourcePath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let raw: String
        switch provider {
        case .codex:
            raw = resolvedCodexHome(home: home).path
        case .claude:
            raw = resolvedClaudeDesktopDirectory(home: home).path
        case .antigravity:
            raw = resolvedAntigravityDirectory(home: home).path
        case .cursor:
            raw = resolvedCursorDirectory(home: home).path
        }
        let homePrefix = home.path.hasSuffix("/") ? String(home.path.dropLast()) : home.path
        if raw == homePrefix { return "~" }
        if raw.hasPrefix(homePrefix + "/") {
            return "~" + raw.dropFirst(homePrefix.count)
        }
        return raw
    }

    public func revealDirectoryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        switch provider {
        case .codex: resolvedCodexHome(home: home)
        case .claude: resolvedClaudeDesktopDirectory(home: home)
        case .antigravity: resolvedAntigravityDirectory(home: home)
        case .cursor: resolvedCursorDirectory(home: home)
        }
    }

    static func profileSuffix(from directoryName: String, prefix: String) -> String? {
        let lower = directoryName.lowercased()
        let p = prefix.lowercased()
        for separator in ["-", "_", " "] {
            let candidate = p + separator
            if lower.hasPrefix(candidate), directoryName.count > candidate.count {
                let raw = String(directoryName.dropFirst(candidate.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.isEmpty ? nil : raw
            }
        }
        return nil
    }

    private static func cleanPath(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return trimmed }
        var normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
