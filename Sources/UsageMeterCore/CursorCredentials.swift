import Foundation
import Security

public struct CursorCredentials: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String

    public init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    public func needsRefresh(now: Date = .now) -> Bool {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = object["exp"] as? Double else { return false }
        return expiry <= now.timeIntervalSince1970 + 60
    }

    static let serviceName = "app.resetmeter.macos.cursor"
    public static let defaultSecurityExecutable = URL(fileURLWithPath: "/usr/bin/security")

    // MARK: - Reset Meter Isolated Session (for Cursor 3.29+ encrypted desktop storage)

    public static func hasSavedSession(
        account: ProviderAccount,
        securityTool: URL = defaultSecurityExecutable
    ) -> Bool {
        (try? readSaved(account: account, securityTool: securityTool)) != nil
    }

    public static func readSaved(
        account: ProviderAccount,
        securityTool: URL = defaultSecurityExecutable,
        allowLegacyFrameworkFallback: Bool = true
    ) throws -> Self {
        guard account.isValid, account.provider == .cursor else {
            throw UsageReadError.cursorCredentialsUnavailable
        }

        // Check `/usr/bin/security` first (owns the ACL so ad-hoc rebuilds never trigger prompts).
        if let raw = readSecurityPassword(service: serviceName, account: account.id, securityTool: securityTool),
           let decoded = decodeStoredCredentials(raw) {
            return decoded
        }

        // Fallback to legacy Security.framework item if present from v0.5.
        if allowLegacyFrameworkFallback {
            for accountKey in legacyAccountKeys(for: account) {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: serviceName,
                    kSecAttrAccount as String: accountKey,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var item: CFTypeRef?
                if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                   let data = item as? Data,
                   let raw = String(data: data, encoding: .utf8),
                   let decoded = decodeStoredCredentials(raw) {
                    return decoded
                }
            }
        }

        throw UsageReadError.cursorSignedOut
    }

    public static func save(
        _ credentials: Self,
        account: ProviderAccount,
        securityTool: URL = defaultSecurityExecutable
    ) throws {
        guard account.isValid,
              account.provider == .cursor,
              !credentials.accessToken.isEmpty,
              !credentials.refreshToken.isEmpty else {
            throw UsageReadError.cursorCredentialsUnavailable
        }
        let encoded = try JSONEncoder().encode(credentials)
        // Encode as Base64 (`[A-Za-z0-9+/=]`) before passing via `/usr/bin/security -i` stdin:
        // Apple's `SecurityTool` interactive line splitter toggles on `"` without honoring `\"`,
        // whereas Base64 contains zero quotes, spaces, or backslashes, and keeps tokens out of `ps`.
        let payload = encoded.base64EncodedString()
        let command = "add-generic-password -U -a \"\(account.id)\" -s \"\(serviceName)\" -w \"\(payload)\"\n"

        guard let result = SubprocessRunner.run(
            executable: securityTool,
            arguments: ["-i"],
            stdinData: Data(command.utf8),
            timeout: 5
        ), result.succeeded else {
            throw UsageReadError.cursorCredentialsUnavailable
        }
    }

    public static func remove(
        account: ProviderAccount,
        securityTool: URL = defaultSecurityExecutable,
        removeLegacyFrameworkItems: Bool = true
    ) {
        guard account.isValid, account.provider == .cursor else { return }
        for accountKey in legacyAccountKeys(for: account) {
            _ = SubprocessRunner.run(
                executable: securityTool,
                arguments: ["delete-generic-password", "-a", accountKey, "-s", serviceName],
                timeout: 5
            )
            if removeLegacyFrameworkItems {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: serviceName,
                    kSecAttrAccount as String: accountKey,
                ]
                SecItemDelete(query as CFDictionary)
            }
        }
    }

    // MARK: - Read-Only Local Cursor CLI (`cursor-agent`) Credentials

    /// Reads existing `cursor-agent` CLI credentials (`~/.cursor/auth.json` or Keychain `cursor-access-token`)
    /// in strictly read-only mode without prompting or modifying them.
    public static func readLocalCLI(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        securityTool: URL = defaultSecurityExecutable
    ) -> String? {
        let authFile = home.appending(path: ".cursor/auth.json")
        if let data = try? Data(contentsOf: authFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = (json["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty,
           !token.hasPrefix("cursor-safe-storage:") {
            return token
        }

        if let token = readSecurityPassword(
            service: "cursor-access-token",
            account: "cursor-user",
            securityTool: securityTool
        ), !token.hasPrefix("cursor-safe-storage:") {
            return token
        }
        return nil
    }

    // MARK: - Helpers

    static func decodeStoredCredentials(_ raw: String) -> Self? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = [Data(base64Encoded: trimmed), Data(trimmed.utf8)].compactMap { $0 }
        for data in candidates {
            if let decoded = try? JSONDecoder().decode(Self.self, from: data),
               !decoded.accessToken.isEmpty,
               !decoded.refreshToken.isEmpty {
                return decoded
            }
        }
        return nil
    }

    private static func legacyAccountKeys(for account: ProviderAccount) -> [String] {
        if account.id == "cursor:default" {
            return ["cursor:default", "default"]
        }
        return [account.id]
    }

    private static func readSecurityPassword(
        service: String,
        account: String,
        securityTool: URL
    ) -> String? {
        guard let output = SubprocessRunner.runString(
            executable: securityTool,
            arguments: ["find-generic-password", "-a", account, "-s", service, "-w"],
            timeout: 5
        ) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
