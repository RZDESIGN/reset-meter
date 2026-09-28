import CryptoKit
import Foundation

/// Preferences contain labels and IDs only. Claude Code manages credentials.
public struct ClaudeAccount: Codable, UsageAccount, Equatable {
    public let id: String
    public var name: String
    public var mode: ConnectionMode

    public init(id: String = UUID().uuidString, name: String, mode: ConnectionMode? = nil) {
        self.id = id
        self.name = name
        self.mode = mode ?? (id == "default" ? .local : .login)
    }

    public static let defaultAccount = ClaudeAccount(id: "default", name: "Default")
    public var isDefault: Bool { id == Self.defaultAccount.id }
    public var isValid: Bool { isDefault || UUID(uuidString: id) != nil }

    public var homeDirectory: URL? {
        mode == .login ? loginDirectory : nil
    }

    public var loginDirectory: URL? {
        guard isValid else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Reset Meter/Claude Accounts")
            .appending(path: id)
    }

    func configPath(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let home = homeDirectory { return home.path.precomposedStringWithCanonicalMapping }
        guard isValid, mode == .local else { throw UsageReadError.claudeSignedOut }
        return (environment["CLAUDE_CONFIG_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path)
            .precomposedStringWithCanonicalMapping
    }

    func keychainService(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let path = try configPath(environment: environment)
        guard mode == .login || environment["CLAUDE_CONFIG_DIR"] != nil else { return "Claude Code-credentials" }
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hash.prefix(8))"
    }

    private enum CodingKeys: String, CodingKey { case id, name, mode }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        self.init(id: id, name: try values.decode(String.self, forKey: .name),
                  mode: try values.decodeIfPresent(ConnectionMode.self, forKey: .mode))
    }
}
