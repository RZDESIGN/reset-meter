import Foundation

struct ClaudeLocalMetadata: Equatable, Sendable {
    let organizationUUID: String?
    let planName: String?

    static func read(
        account: ProviderAccount,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ClaudeLocalMetadata {
        let codeDir = account.resolvedClaudeCodeDirectory(home: home)
        var candidates = [codeDir.appending(path: ".claude.json")]
        if account.isDefaultClaudeCodeDirectory(home: home) {
            // Default Claude Code stores `.claude.json` directly in $HOME.
            candidates.insert(home.appending(path: ".claude.json"), at: 0)
        }

        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                  let parsed = parseClaudeJSON(data),
                  (parsed.organizationUUID != nil || parsed.planName != nil) else { continue }
            return parsed
        }

        // Fall back to latest org UUID recorded in Desktop's plan-usage-history.json.
        let historyURL = account.resolvedClaudeDesktopDirectory(home: home)
            .appending(path: "plan-usage-history.json")
        if let data = try? Data(contentsOf: historyURL),
           let org = ClaudeDesktopUsageReader.latestOrganizationUUID(from: data) {
            return ClaudeLocalMetadata(organizationUUID: org, planName: nil)
        }
        return ClaudeLocalMetadata(organizationUUID: nil, planName: nil)
    }

    static func parseClaudeJSON(_ data: Data) -> ClaudeLocalMetadata? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any] else { return nil }
        let orgUUID = (oauth["organizationUuid"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tier = (oauth["userRateLimitTier"] as? String)
            ?? (oauth["organizationRateLimitTier"] as? String)
        let plan = AccountPlan.claude(
            oauth["organizationType"] as? String,
            rateLimitTier: tier
        )
        return ClaudeLocalMetadata(
            organizationUUID: orgUUID?.isEmpty == true ? nil : orgUUID,
            planName: plan
        )
    }
}

struct ClaudeCredentials: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Double?
    let scopes: [String]
    let subscriptionType: String?
    let rateLimitTier: String?

    var planName: String? { AccountPlan.claude(subscriptionType, rateLimitTier: rateLimitTier) }

    func isExpired(now: Date) -> Bool {
        expiresAt.map { $0 > 0 && $0 / 1_000 <= now.timeIntervalSince1970 + 15 } ?? false
    }

    static func parse(_ data: Data) throws -> Self {
        struct Envelope: Decodable { let claudeAiOauth: ClaudeCredentials }
        guard let credentials = try? JSONDecoder().decode(Envelope.self, from: data).claudeAiOauth else {
            throw UsageReadError.claudeLocalUnavailable
        }
        guard !credentials.accessToken.isEmpty, credentials.scopes.contains("user:profile") else {
            throw UsageReadError.claudeAuthorizationFailed
        }
        return credentials
    }

    /// Reads an active OAuth token from a running Claude Desktop subprocess belonging strictly
    /// to this local profile/organization. Never touches refresh tokens or Keychain.
    static func readActiveDesktopSession(
        account: ProviderAccount,
        metadata: ClaudeLocalMetadata,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self? {
        guard let pidsOutput = SubprocessRunner.runString(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-i", "-u", "\(getuid())", "-f", #"claude\.app/Contents/MacOS/claude|claude-code/.*/claude"#],
            timeout: 3
        ) else { return nil }

        let pids = pidsOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let expectedCodeDir = account.resolvedClaudeCodeDirectory(home: home).path.precomposedStringWithCanonicalMapping
        let expectedDesktopPrefix = account.resolvedClaudeDesktopDirectory(home: home)
            .appending(path: "claude-code").path.precomposedStringWithCanonicalMapping
        let isDefaultCodeDir = account.isDefaultClaudeCodeDirectory(home: home)

        for pid in pids {
            guard let psOutput = SubprocessRunner.runString(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["eww", "-p", pid],
                timeout: 3
            ) else { continue }
            guard let credentials = matchDesktopProcessEnvironment(
                psOutput: psOutput,
                expectedOrganizationUUID: metadata.organizationUUID,
                expectedCodeDir: expectedCodeDir,
                expectedDesktopPrefix: expectedDesktopPrefix,
                isDefaultCodeDir: isDefaultCodeDir
            ) else { continue }
            return credentials
        }
        return nil
    }

    static func matchDesktopProcessEnvironment(
        psOutput: String,
        expectedOrganizationUUID: String?,
        expectedCodeDir: String,
        expectedDesktopPrefix: String,
        isDefaultCodeDir: Bool
    ) -> Self? {
        guard let token = extractEnv("CLAUDE_CODE_OAUTH_TOKEN", from: psOutput),
              !token.isEmpty else { return nil }

        let processOrg = extractEnv("CLAUDE_CODE_ORGANIZATION_UUID", from: psOutput)
        let processConfigDir = extractEnv("CLAUDE_CONFIG_DIR", from: psOutput)?
            .precomposedStringWithCanonicalMapping

        if let expectedOrg = expectedOrganizationUUID, !expectedOrg.isEmpty,
           let processOrg, !processOrg.isEmpty {
            guard processOrg.caseInsensitiveCompare(expectedOrg) == .orderedSame else { return nil }
        } else if let processConfigDir, !processConfigDir.isEmpty {
            guard processConfigDir == expectedCodeDir else { return nil }
        } else {
            guard isDefaultCodeDir, psOutput.precomposedStringWithCanonicalMapping.contains(expectedDesktopPrefix) else {
                return nil
            }
        }

        let scopes = (extractEnv("CLAUDE_CODE_OAUTH_SCOPES", from: psOutput) ?? "user:profile")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let subType = extractEnv("CLAUDE_CODE_SUBSCRIPTION_TYPE", from: psOutput)
        let tier = extractEnv("CLAUDE_CODE_RATE_LIMIT_TIER", from: psOutput)
        return ClaudeCredentials(
            accessToken: token,
            refreshToken: nil,
            expiresAt: nil,
            scopes: scopes.isEmpty ? ["user:profile"] : scopes,
            subscriptionType: subType,
            rateLimitTier: tier
        )
    }

    static func readStored(
        account: ProviderAccount,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        keychain: URL = ClaudeKeychain.tool
    ) throws -> Self {
        let service = account.claudeKeychainService(home: home)
        switch ClaudeKeychain.read(service: service, tool: keychain) {
        case .found(let data): return try parse(data)
        case .unavailable: throw UsageReadError.claudeCredentialsUnavailable
        case .missing: break
        }
        let file = account.resolvedClaudeCodeDirectory(home: home).appending(path: ".credentials.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw UsageReadError.claudeLocalUnavailable
        }
        guard let data = try? Data(contentsOf: file) else {
            throw UsageReadError.claudeCredentialsUnavailable
        }
        return try parse(data)
    }

    static func extractEnv(_ key: String, from psOutput: String) -> String? {
        let marker = key + "="
        var searchStart = psOutput.startIndex
        while let range = psOutput.range(of: marker, range: searchStart..<psOutput.endIndex) {
            let validBoundary = range.lowerBound == psOutput.startIndex
                || psOutput[psOutput.index(before: range.lowerBound)].isWhitespace
            guard validBoundary else {
                searchStart = range.upperBound
                continue
            }

            let lineEnd = psOutput[range.upperBound...].firstIndex(where: \.isNewline) ?? psOutput.endIndex
            let tail = psOutput[range.upperBound..<lineEnd]
            var cursor = tail.startIndex
            var valueEnd = tail.endIndex

            while cursor < tail.endIndex {
                if tail[cursor].isWhitespace {
                    var nameStart = cursor
                    while nameStart < tail.endIndex, tail[nameStart].isWhitespace {
                        nameStart = tail.index(after: nameStart)
                    }
                    if Self.startsEnvironmentAssignment(in: tail, at: nameStart) {
                        valueEnd = cursor
                        break
                    }
                    cursor = nameStart
                } else {
                    cursor = tail.index(after: cursor)
                }
            }

            let value = String(tail[..<valueEnd]).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func startsEnvironmentAssignment(in text: Substring, at start: Substring.Index) -> Bool {
        guard start < text.endIndex else { return false }
        let first = text[start]
        guard first.isASCII && (first.isLetter || first == "_") else { return false }
        var idx = text.index(after: start)
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "=" { return true }
            if !(ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_")) { return false }
            idx = text.index(after: idx)
        }
        return false
    }
}
