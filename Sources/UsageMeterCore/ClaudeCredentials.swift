import Foundation

struct ClaudeCredentials: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Double?
    let scopes: [String]
    let subscriptionType: String?
    let rateLimitTier: String?

    var planName: String? { AccountPlan.claude(subscriptionType, rateLimitTier: rateLimitTier) }

    /// Unknown expiries rely on the usage request's 401 instead of renewing on every read.
    func needsRefresh(now: Date) -> Bool {
        expiresAt.map { $0 > 0 && $0 / 1_000 <= now.timeIntervalSince1970 + 60 } ?? false
    }

    static func parse(_ data: Data) throws -> Self {
        struct Envelope: Decodable { let claudeAiOauth: ClaudeCredentials }
        // An interrupted renewal can leave an item without its OAuth login.
        guard let credentials = try? JSONDecoder().decode(Envelope.self, from: data).claudeAiOauth else {
            throw UsageReadError.claudeSignedOut
        }
        // Claude blanks the tokens after the server rejects a spent refresh token.
        guard !credentials.accessToken.isEmpty, credentials.scopes.contains("user:profile") else {
            throw UsageReadError.claudeAuthorizationFailed
        }
        return credentials
    }

    static func read(account: ClaudeAccount, keychain: URL = ClaudeKeychain.tool) throws -> Self {
        switch ClaudeKeychain.read(service: try account.keychainService(), tool: keychain) {
        case .found(let data): return try parse(data)
        case .unavailable: throw UsageReadError.claudeCredentialsUnavailable
        case .missing: break
        }
        // Claude Code uses this fallback if Keychain storage was unavailable.
        let file = URL(fileURLWithPath: try account.configPath()).appending(path: ".credentials.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw UsageReadError.claudeSignedOut }
        guard let data = try? Data(contentsOf: file) else { throw UsageReadError.claudeCredentialsUnavailable }
        return try parse(data)
    }

    static func remove(account: ClaudeAccount) throws {
        guard !account.isDefault, let home = account.loginDirectory else { return }
        var loginAccount = account
        loginAccount.mode = .login
        guard ClaudeKeychain.delete(service: try loginAccount.keychainService()) else {
            throw UsageReadError.claudeCredentialsUnavailable
        }
        if FileManager.default.fileExists(atPath: home.path) {
            try FileManager.default.removeItem(at: home)
        }
    }
}
