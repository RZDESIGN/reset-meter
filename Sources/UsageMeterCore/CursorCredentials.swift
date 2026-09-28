import Foundation
import Security

struct CursorCredentials: Codable, Sendable {
    let accessToken: String
    let refreshToken: String

    func needsRefresh(now: Date = .now) -> Bool {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = object["exp"] as? Double else { return false }
        return expiry <= now.timeIntervalSince1970 + 60
    }

    private static func query(account: CursorAccount) throws -> [String: Any] {
        guard account.isValid else { throw UsageReadError.cursorCredentialsUnavailable }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "app.resetmeter.macos.cursor",
                kSecAttrAccount as String: account.id]
    }

    static func read(account: CursorAccount) throws -> Self {
        guard account.mode == .login else { throw UsageReadError.cursorSignedOut }
        var query = try query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw UsageReadError.cursorSignedOut }
        guard status == errSecSuccess, let data = item as? Data,
              let credentials = try? JSONDecoder().decode(Self.self, from: data),
              !credentials.accessToken.isEmpty, !credentials.refreshToken.isEmpty else {
            throw UsageReadError.cursorCredentialsUnavailable
        }
        return credentials
    }

    static func save(_ credentials: Self, account: CursorAccount) throws {
        guard account.mode == .login, !credentials.accessToken.isEmpty, !credentials.refreshToken.isEmpty else {
            throw UsageReadError.cursorCredentialsUnavailable
        }
        let query = try query(account: account)
        // The login keychain supports ad-hoc-signed community builds. Its normal
        // per-application ACL protects the item; iOS accessibility classes do
        // not apply to this legacy macOS keychain.
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credentials)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw UsageReadError.cursorCredentialsUnavailable }
    }

    static func remove(account: CursorAccount) throws {
        guard !account.isDefault else { return }
        let query = try query(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw UsageReadError.cursorCredentialsUnavailable
        }
    }
}
