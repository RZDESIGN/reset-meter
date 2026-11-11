import Foundation

/// Discovers locally installed AI clients and isolated multi-client profiles on macOS
/// (e.g. separate Personal & Work installations for ChatGPT/Codex and Claude, plus Antigravity & Cursor).
public enum LocalInstallationDiscovery {
    public static func discoverAll(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    ) -> [ProviderAccount] {
        discoverCodex(home: home)
            + discoverClaude(home: home)
            + discoverAntigravity(home: home, applicationsDirectories: applicationsDirectories)
            + discoverCursor(home: home)
    }

    // MARK: - Codex / ChatGPT

    public static func discoverCodex(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ProviderAccount] {
        let fm = FileManager.default
        let defaultDir = home.appending(path: ".codex", directoryHint: .isDirectory)

        var extras: [(slug: String, label: String, path: URL)] = []
        if let homeItems = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for item in homeItems {
                let name = item.lastPathComponent
                guard name.lowercased().hasPrefix(".codex-"),
                      isDirectory(item, fm: fm),
                      looksLikeCodexHome(item, fm: fm) else { continue }
                let rawSuffix = String(name.dropFirst(".codex-".count))
                guard let slug = sanitizeSlug(rawSuffix) else { continue }
                extras.append((slug, displayLabel(for: rawSuffix), item.standardizedFileURL))
            }
        }

        // Also check Application Support for custom CodexHomes if any exist without a ~/.codex-* pair.
        let appSupport = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        if let supportItems = try? fm.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in supportItems {
                let name = item.lastPathComponent
                guard let rawSuffix = ProviderAccount.profileSuffix(from: name, prefix: "Codex")
                        ?? ProviderAccount.profileSuffix(from: name, prefix: "ChatGPT"),
                      let slug = sanitizeSlug(rawSuffix),
                      !extras.contains(where: { $0.slug == slug }),
                      isDirectory(item, fm: fm),
                      looksLikeCodexHome(item, fm: fm) else { continue }
                extras.append((slug, displayLabel(for: rawSuffix), item.standardizedFileURL))
            }
        }

        extras.sort { $0.slug < $1.slug }
        let primaryName = extras.isEmpty ? "Default" : "Personal"
        var result = [
            ProviderAccount(
                id: "codex:default",
                provider: .codex,
                name: primaryName,
                profilePath: defaultDir.standardizedFileURL.path
            )
        ]
        for extra in extras {
            result.append(
                ProviderAccount(
                    id: "codex:\(extra.slug)",
                    provider: .codex,
                    name: extra.label,
                    profilePath: extra.path.path
                )
            )
        }
        return result
    }

    // MARK: - Claude

    public static func discoverClaude(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ProviderAccount] {
        let fm = FileManager.default
        let appSupport = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let defaultDesktop = appSupport.appending(path: "Claude", directoryHint: .isDirectory)
        let defaultCode = home.appending(path: ".claude", directoryHint: .isDirectory)

        struct ClaudePair {
            var label: String
            var desktopPath: String?
            var codePath: String?
        }

        var pairsBySlug: [String: ClaudePair] = [:]

        // 1. Scan ~/Library/Application Support/Claude-* (excluding internal helper folders like "Claude Extensions").
        let excludedDesktopSuffixes: Set<String> = ["extensions", "extensions-settings", "code", "code-vm"]
        if let supportItems = try? fm.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in supportItems {
                let name = item.lastPathComponent
                guard let rawSuffix = ProviderAccount.profileSuffix(from: name, prefix: "Claude"),
                      let slug = sanitizeSlug(rawSuffix),
                      !excludedDesktopSuffixes.contains(slug),
                      isDirectory(item, fm: fm),
                      looksLikeClaudeDesktopDirectory(item, fm: fm) else { continue }
                var entry = pairsBySlug[slug] ?? ClaudePair(label: displayLabel(for: rawSuffix))
                entry.desktopPath = item.standardizedFileURL.path
                pairsBySlug[slug] = entry
            }
        }

        // 2. Scan ~/.claude-* for isolated Claude Code config directories and pair with matching Desktop profiles.
        if let homeItems = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for item in homeItems {
                let name = item.lastPathComponent
                guard name.lowercased().hasPrefix(".claude-"),
                      isDirectory(item, fm: fm),
                      looksLikeClaudeCodeDirectory(item, fm: fm) else { continue }
                let rawSuffix = String(name.dropFirst(".claude-".count))
                guard let slug = sanitizeSlug(rawSuffix) else { continue }
                var entry = pairsBySlug[slug] ?? ClaudePair(label: displayLabel(for: rawSuffix))
                entry.codePath = item.standardizedFileURL.path
                pairsBySlug[slug] = entry
            }
        }

        let sortedSlugs = pairsBySlug.keys.sorted()
        let primaryName = sortedSlugs.isEmpty ? "Default" : "Personal"
        var result = [
            ProviderAccount(
                id: "claude:default",
                provider: .claude,
                name: primaryName,
                profilePath: defaultDesktop.standardizedFileURL.path,
                secondaryPath: defaultCode.standardizedFileURL.path
            )
        ]

        for slug in sortedSlugs {
            guard let pair = pairsBySlug[slug] else { continue }
            result.append(
                ProviderAccount(
                    id: "claude:\(slug)",
                    provider: .claude,
                    name: pair.label,
                    profilePath: pair.desktopPath ?? pair.codePath,
                    secondaryPath: pair.codePath
                )
            )
        }
        return result
    }

    // MARK: - Antigravity

    public static func discoverAntigravity(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    ) -> [ProviderAccount] {
        let fm = FileManager.default
        let appSupport = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let defaultDir = appSupport.appending(path: "Antigravity", directoryHint: .isDirectory)

        var extras: [(slug: String, label: String, path: String)] = []
        if let supportItems = try? fm.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in supportItems {
                let name = item.lastPathComponent
                guard let rawSuffix = ProviderAccount.profileSuffix(from: name, prefix: "Antigravity"),
                      let slug = sanitizeSlug(rawSuffix),
                      isDirectory(item, fm: fm),
                      looksLikeAntigravityDirectory(item, fm: fm) else { continue }
                extras.append((slug, displayLabel(for: rawSuffix), item.standardizedFileURL.path))
            }
        }
        extras.sort { $0.slug < $1.slug }
        let primaryName = extras.isEmpty ? "Default" : "Personal"
        var result = [
            ProviderAccount(
                id: "antigravity:default",
                provider: .antigravity,
                name: primaryName,
                profilePath: defaultDir.standardizedFileURL.path
            )
        ]
        for extra in extras {
            result.append(
                ProviderAccount(
                    id: "antigravity:\(extra.slug)",
                    provider: .antigravity,
                    name: extra.label,
                    profilePath: extra.path
                )
            )
        }
        return result
    }

    public static func isAntigravityInstalled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    ) -> Bool {
        let fm = FileManager.default
        if applicationsDirectories.contains(where: { fm.fileExists(atPath: $0.appending(path: "Antigravity.app").path) }) {
            return true
        }
        return fm.fileExists(atPath: home.appending(path: "Library/Application Support/Antigravity").path)
            || fm.fileExists(atPath: home.appending(path: ".gemini/antigravity").path)
    }

    // MARK: - Cursor

    public static func discoverCursor(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ProviderAccount] {
        let fm = FileManager.default
        let appSupport = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let defaultDir = appSupport.appending(path: "Cursor", directoryHint: .isDirectory)

        var extras: [(slug: String, label: String, path: String)] = []
        if let supportItems = try? fm.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in supportItems {
                let name = item.lastPathComponent
                guard let rawSuffix = ProviderAccount.profileSuffix(from: name, prefix: "Cursor"),
                      let slug = sanitizeSlug(rawSuffix),
                      isDirectory(item, fm: fm),
                      fm.fileExists(atPath: item.appending(path: "User/globalStorage/state.vscdb").path) else { continue }
                extras.append((slug, displayLabel(for: rawSuffix), item.standardizedFileURL.path))
            }
        }
        extras.sort { $0.slug < $1.slug }
        let primaryName = extras.isEmpty ? "Default" : "Personal"
        var result = [
            ProviderAccount(
                id: "cursor:default",
                provider: .cursor,
                name: primaryName,
                profilePath: defaultDir.standardizedFileURL.path
            )
        ]
        for extra in extras {
            result.append(
                ProviderAccount(
                    id: "cursor:\(extra.slug)",
                    provider: .cursor,
                    name: extra.label,
                    profilePath: extra.path
                )
            )
        }
        return result
    }

    public static func isCursorInstalled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    ) -> Bool {
        let fm = FileManager.default
        if applicationsDirectories.contains(where: { fm.fileExists(atPath: $0.appending(path: "Cursor.app").path) }) {
            return true
        }
        return fm.fileExists(atPath: home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path)
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func looksLikeCodexHome(_ url: URL, fm: FileManager) -> Bool {
        ["auth.json", "config.toml", ".codex-global-state.json"].contains {
            fm.fileExists(atPath: url.appending(path: $0).path)
        }
    }

    private static func looksLikeClaudeDesktopDirectory(_ url: URL, fm: FileManager) -> Bool {
        ["plan-usage-history.json", "config.json", "Local State", "claude_desktop_config.json"].contains {
            fm.fileExists(atPath: url.appending(path: $0).path)
        }
    }

    private static func looksLikeClaudeCodeDirectory(_ url: URL, fm: FileManager) -> Bool {
        [".claude.json", ".credentials.json", "settings.json", "policy-limits.json"].contains {
            fm.fileExists(atPath: url.appending(path: $0).path)
        }
    }

    private static func looksLikeAntigravityDirectory(_ url: URL, fm: FileManager) -> Bool {
        ["app_storage.json", "Local State", "Preferences"].contains {
            fm.fileExists(atPath: url.appending(path: $0).path)
        }
    }

    private static func sanitizeSlug(_ raw: String) -> String? {
        let cleaned = raw.lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let collapsed = String(cleaned)
            .split(separator: "-")
            .joined(separator: "-")
        guard !collapsed.isEmpty, collapsed != "default" else { return nil }
        return collapsed
    }

    private static func displayLabel(for rawSuffix: String) -> String {
        let words = rawSuffix
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { $0.capitalized }
        return words.isEmpty ? "Secondary" : words.joined(separator: " ")
    }
}
