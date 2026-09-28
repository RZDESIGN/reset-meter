import Foundation

public enum ClaudeUsageReader {
    public static func signIn(account: ClaudeAccount) async throws {
        guard let home = account.homeDirectory else { throw UsageReadError.claudeLoginFailed }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try await ClaudeCommand.execute(account: account)
    }

    public static func removeLogin(account: ClaudeAccount) throws {
        try ClaudeCredentials.remove(account: account)
    }

    public static func fetch(account: ClaudeAccount = .defaultAccount) async throws -> ProviderUsage {
        try await fetchLocalOrLogin(account: account, live: {
            try await fetchLive(account: account)
        }, desktop: {
            try await Task.detached(priority: .utility) { try ClaudeDesktopUsageReader.fetch() }.value
        })
    }

    static func fetchLocalOrLogin(
        account: ClaudeAccount,
        live: @Sendable () async throws -> ProviderUsage,
        desktop: @Sendable () async throws -> ProviderUsage
    ) async throws -> ProviderUsage {
        guard account.isValid else { throw UsageReadError.claudeSignedOut }
        do { return try await live() }
        catch {
            try Task.checkCancellation()
            guard account.mode == .local else { throw error }
            if let cached = try? await desktop() {
                try Task.checkCancellation()
                return cached
            }
            // Neither a current installed login nor the Claude app's cache is available.
            switch error as? UsageReadError {
            case .claudeSignedOut?, .claudeAuthorizationFailed?, .claudeCredentialsUnavailable?:
                throw UsageReadError.claudeLocalUnavailable
            default: throw error
            }
        }
    }

    private static func fetchLive(account: ClaudeAccount) async throws -> ProviderUsage {
        try await fetch(account: account, loadCredentials: { account in
            try await Task.detached(priority: .utility) { try ClaudeCredentials.read(account: account) }.value
        }, refreshCredentials: { account, credentials in
            try await ClaudeCommand.renew(account: account, replacing: credentials)
        }, request: { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw UsageReadError.malformedClaudeResponse }
            return (data, response)
        })
    }

    static func fetch(
        account: ClaudeAccount,
        loadCredentials: @Sendable (ClaudeAccount) async throws -> ClaudeCredentials,
        refreshCredentials: @Sendable (ClaudeAccount, ClaudeCredentials) async throws -> Void,
        request: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> ProviderUsage {
        var credentials = try await loadCredentials(account)
        // Local only reads the installed login. Claude keeps it current while in
        // use; renewing it here would rotate the refresh token Claude relies on.
        let renewable = account.mode == .login
        var refreshed = false
        if credentials.needsRefresh(now: Date()) {
            guard renewable else { throw UsageReadError.claudeAuthorizationFailed }
            try await refreshCredentials(account, credentials)
            credentials = try await loadCredentials(account)
            refreshed = true
        }
        var (data, response) = try await request(usageRequest(token: credentials.accessToken))
        if response.statusCode == 401 && renewable && !refreshed {
            try await refreshCredentials(account, credentials)
            credentials = try await loadCredentials(account)
            (data, response) = try await request(usageRequest(token: credentials.accessToken))
        }
        try validate(response)
        var plan = credentials.planName
        // Refresh plan metadata after upgrades. A profile failure must not discard valid usage.
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
        ]
        let limits = windows.compactMap { key, label, duration -> UsageLimit? in
            guard let window = root[key] as? [String: Any],
                  let number = window["utilization"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return UsageLimit(id: "claude-\(key)", label: label, usedPercent: number.doubleValue,
                              resetsAt: parseDate(window["resets_at"] as? String),
                              durationMinutes: duration, displayMode: .remaining)
        }
        guard !limits.isEmpty else { throw UsageReadError.malformedClaudeResponse }
        return ProviderUsage(provider: .claude, limits: limits, updatedAt: now,
                             sourceDescription: "Live Claude account usage", planName: planName)
    }

    static func parsePlan(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organization = root["organization"] as? [String: Any] else { return nil }
        return AccountPlan.claude(organization["organization_type"] as? String,
                                  rateLimitTier: organization["rate_limit_tier"] as? String)
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
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
