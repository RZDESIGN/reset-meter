import Foundation

/// Purely local, read-only Claude usage reader supporting multiple separate Claude installations/profiles:
/// 1. Active Claude Desktop Code/Cowork session token for this exact profile (live usage + exact reset dates).
/// 2. Standalone local Claude Code credentials for this profile's config directory (read-only; never renews/rotates).
/// 3. Claude Desktop's local `plan-usage-history.json` paired with `.claude.json` plan metadata.
public enum ClaudeUsageReader {
    public static func fetch(
        account: ProviderAccount = .defaultAccount(for: .claude),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheDirectory: URL = UsageSnapshotCache.defaultDirectory
    ) async throws -> ProviderUsage {
        guard account.isValid, account.provider == .claude else {
            throw UsageReadError.claudeLocalUnavailable
        }
        let metadata = await Task.detached(priority: .utility) {
            ClaudeLocalMetadata.read(account: account, home: home)
        }.value
        let previousSnapshot = UsageSnapshotCache.load(accountID: account.id, directory: cacheDirectory)

        return try await fetchLocalLayers(
            account: account,
            activeSession: {
                let active = await Task.detached(priority: .utility) {
                    ClaudeCredentials.readActiveDesktopSession(account: account, metadata: metadata, home: home)
                }.value
                guard let active else { throw UsageReadError.claudeLocalUnavailable }
                return try await fetchWithCredentials(active, fallbackPlan: metadata.planName)
            },
            storedCredentials: {
                let stored = try await Task.detached(priority: .utility) {
                    try ClaudeCredentials.readStored(account: account, home: home)
                }.value
                guard !stored.isExpired(now: Date()) else {
                    throw UsageReadError.claudeAuthorizationFailed
                }
                return try await fetchWithCredentials(stored, fallbackPlan: metadata.planName)
            },
            desktopCache: {
                try await Task.detached(priority: .utility) {
                    try ClaudeDesktopUsageReader.fetch(
                        account: account,
                        metadata: metadata,
                        previousSnapshot: previousSnapshot,
                        home: home
                    )
                }.value
            },
            onLiveSuccess: { liveUsage in
                UsageSnapshotCache.save(liveUsage, accountID: account.id, directory: cacheDirectory)
            }
        )
    }

    static func fetchLocalLayers(
        account: ProviderAccount,
        activeSession: @Sendable () async throws -> ProviderUsage,
        storedCredentials: @Sendable () async throws -> ProviderUsage,
        desktopCache: @Sendable () async throws -> ProviderUsage,
        onLiveSuccess: @Sendable (ProviderUsage) -> Void = { _ in }
    ) async throws -> ProviderUsage {
        guard account.isValid else { throw UsageReadError.claudeLocalUnavailable }

        var rateLimited = false
        func tryLive(_ source: () async throws -> ProviderUsage) async throws -> ProviderUsage? {
            do {
                let usage = try await source()
                try Task.checkCancellation()
                onLiveSuccess(usage)
                return usage
            } catch is CancellationError {
                throw CancellationError()
            } catch UsageReadError.claudeRateLimited {
                rateLimited = true
                return nil
            } catch {
                return nil
            }
        }

        if let usage = try await tryLive(activeSession) {
            return usage
        }
        if let usage = try await tryLive(storedCredentials) {
            return usage
        }

        if let cached = try? await desktopCache() {
            try Task.checkCancellation()
            return cached
        }

        if rateLimited {
            throw UsageReadError.claudeRateLimited
        }
        throw UsageReadError.claudeLocalUnavailable
    }

    private static func fetchWithCredentials(
        _ credentials: ClaudeCredentials,
        fallbackPlan: String?
    ) async throws -> ProviderUsage {
        try await fetch(
            credentials: credentials,
            fallbackPlan: fallbackPlan,
            request: { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw UsageReadError.malformedClaudeResponse
                }
                return (data, response)
            }
        )
    }

    static func fetch(
        credentials: ClaudeCredentials,
        fallbackPlan: String? = nil,
        request: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> ProviderUsage {
        let (data, response) = try await request(usageRequest(token: credentials.accessToken))
        try validate(response)
        var plan = credentials.planName ?? fallbackPlan
        if let (profile, profileResponse) = try? await request(authenticatedRequest(path: "profile", token: credentials.accessToken)),
           profileResponse.statusCode == 200 {
            plan = parsePlan(profile) ?? plan
        }
        try Task.checkCancellation()
        return try parse(data: data, now: Date(), planName: plan)
    }

    static func usageRequest(token: String) -> URLRequest {
        authenticatedRequest(path: "usage", token: token)
    }

    private static func authenticatedRequest(path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(path)")!)
        request.timeoutInterval = 12
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw UsageReadError.claudeAuthorizationFailed
        case 429: throw UsageReadError.claudeRateLimited
        default: throw UsageReadError.malformedClaudeResponse
        }
    }

    public static func parse(data: Data, now: Date, planName: String? = nil) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageReadError.malformedClaudeResponse
        }
        let windows: [(String, String, Int?)] = [
            ("five_hour", "5-hour", 300),
            ("seven_day", "Weekly", 10_080),
            ("seven_day_opus", "Weekly · Opus", 10_080),
            ("seven_day_sonnet", "Weekly · Sonnet", 10_080),
            ("seven_day_oauth_apps", "Weekly · OAuth apps", 10_080),
            ("seven_day_cowork", "Weekly · Cowork", 10_080),
        ]
        var limits = windows.compactMap { key, label, duration -> UsageLimit? in
            guard let window = root[key] as? [String: Any],
                  let number = window["utilization"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return UsageLimit(
                id: "claude-\(key)",
                label: label,
                usedPercent: number.doubleValue,
                resetsAt: parseDate(window["resets_at"] as? String),
                durationMinutes: duration,
                displayMode: .remaining
            )
        }

        // Fallback to active entries in modern `limits[]` array if legacy top-level windows were omitted.
        if limits.isEmpty, let array = root["limits"] as? [[String: Any]] {
            limits = array.enumerated().compactMap { index, item -> UsageLimit? in
                if let active = item["is_active"] as? Bool, !active { return nil }
                guard let number = item["percent"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
                let group = (item["group"] as? String)?.lowercased()
                let label = group == "weekly" ? "Weekly" : (group == "five_hour" ? "5-hour" : "Usage window")
                let duration: Int? = group == "weekly" ? 10_080 : (group == "five_hour" ? 300 : nil)
                return UsageLimit(
                    id: "claude-limit-\(index)",
                    label: label,
                    usedPercent: number.doubleValue,
                    resetsAt: parseDate(item["resets_at"] as? String),
                    durationMinutes: duration,
                    displayMode: .remaining
                )
            }
        }

        guard !limits.isEmpty else { throw UsageReadError.malformedClaudeResponse }
        return ProviderUsage(
            provider: .claude,
            limits: limits,
            updatedAt: now,
            sourceDescription: "Live local Claude usage",
            planName: planName
        )
    }

    static func parsePlan(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organization = root["organization"] as? [String: Any] else { return nil }
        return AccountPlan.claude(
            organization["organization_type"] as? String,
            rateLimitTier: organization["rate_limit_tier"] as? String
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
