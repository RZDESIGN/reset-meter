import Foundation

/// Only labels and identifiers are saved in preferences. Codex owns credentials.
public struct CodexAccount: Codable, UsageAccount, Equatable {
    public let id: String
    public var name: String
    public var mode: ConnectionMode

    public init(id: String = UUID().uuidString, name: String, mode: ConnectionMode? = nil) {
        self.id = id
        self.name = name
        self.mode = mode ?? (id == "default" ? .local : .login)
    }

    public static let defaultAccount = CodexAccount(id: "default", name: "Default")
    public var isDefault: Bool { id == Self.defaultAccount.id }
    public var isValid: Bool { isDefault || UUID(uuidString: id) != nil }

    public var homeDirectory: URL? {
        mode == .login ? loginDirectory : nil
    }

    public var loginDirectory: URL? {
        guard isValid else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Reset Meter/Codex Accounts")
            .appending(path: id)
    }

    private enum CodingKeys: String, CodingKey { case id, name, mode }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        self.init(id: id, name: try values.decode(String.self, forKey: .name),
                  mode: try values.decodeIfPresent(ConnectionMode.self, forKey: .mode))
    }
}
