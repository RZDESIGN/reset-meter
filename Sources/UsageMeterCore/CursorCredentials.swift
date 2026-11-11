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

    private static let serviceName = "app.resetmeter.macos.cursor"
    private static let securityExecutable = URL(fileURLWithPath: "/usr/bin/security")

    // MARK: - Reset Meter Isolated Session (for Cursor 3.29+ encrypted desktop storage)

    public static func hasSavedSession(account: ProviderAccount) -> Bool {
        (try? readSaved(account: account)) != nil
    }

    public static func readSaved(account: ProviderAccount) throws -> Self {
        guard account.isValid, account.provider == .cursor else {
            throw UsageReadError.cursorCredentialsUnavailable
        }

        // Try /usr/bin/security first (never triggers Keychain prompts across ad-hoc rebuilds).
        for accountKey in candidateAccountKeys(for: account) {
            if let raw = readSecurityPassword(service: serviceName, account: accountKey),
               let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(Self.self, from: data),
               !decoded.accessToken.isEmpty,
               !decoded.refreshToken.isEmpty {
                return decoded
            }
        }

        // Fallback to legacy Security.framework item if present from v0.5.
        for accountKey in candidateAccountKeys(for: account) {
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
               let decoded = try? JSONDecoder().decode(Self.self, from: data),
               !decoded.accessToken.isEmpty,
               !decoded.refreshToken.isEmpty {
                return decoded
            }
        }

        throw UsageReadError.cursorSignedOut
    }

    public static func save(_ credentials: Self, account: ProviderAccount) throws {
        guard account.isValid,
              account.provider == .cursor,
              !credentials.accessToken.isEmpty,
              !credentials.refreshToken.isEmpty else {
            throw UsageReadError.cursorCredentialsUnavailable
        }
        let encoded = try JSONEncoder().encode(credentials)
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw UsageReadError.cursorCredentialsUnavailable
        }

        // Pass command via `/usr/bin/security -i` stdin so tokens never appear in `ps` arguments
        // and `/usr/bin/security` owns the ACL (avoiding Keychain prompts across ad-hoc app updates).
        let escapedAccount = escapeSecurityArg(account.id)
        let escapedService = escapeSecurityArg(serviceName)
        let escapedSecret = escapeSecurityArg(json)
        let command = "add-generic-password -U -a \"\(escapedAccount)\" -s \"\(escapedService)\" -w \"\(escapedSecret)\"\n"

        let process = Process()
        let stdinPipe = Pipe()
        process.executableURL = securityExecutable
        process.arguments = ["-i"]
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(command.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UsageReadError.cursorCredentialsUnavailable
        }
    }

    public static func remove(account: ProviderAccount) {
        guard account.isValid, account.provider == .cursor else { return }
        for accountKey in candidateAccountKeys(for: account) {
            let process = Process()
            process.executableURL = securityExecutable
            process.arguments = ["delete-generic-password", "-a", accountKey, "-s", serviceName]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: accountKey,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - Read-Only Local Cursor CLI (`cursor-agent`) Credentials

    /// Reads existing `cursor-agent` CLI credentials (`~/.cursor/auth.json` or Keychain `cursor-access-token`)
    /// in strictly read-only mode without prompting or modifying them.
    public static func readLocalCLI(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let authFile = home.appending(path: ".cursor/auth.json")
        if let data = try? Data(contentsOf: authFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = (json["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty,
           !token.hasPrefix("cursor-safe-storage:") {
            return token
        }

        if let token = readSecurityPassword(service: "cursor-access-token", account: "cursor-user"),
           !token.hasPrefix("cursor-safe-storage:") {
            return token
        }
        return nil
    }

    // MARK: - Helpers

    private static func candidateAccountKeys(for account: ProviderAccount) -> [String] {
        if account.id == "cursor:default" {
            return ["cursor:default", "default"]
        }
        return [account.id]
    }

    private static func readSecurityPassword(service: String, account: String) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = securityExecutable
        process.arguments = ["find-generic-password", "-a", account, "-s", service, "-w"]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func escapeSecurityArg(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
