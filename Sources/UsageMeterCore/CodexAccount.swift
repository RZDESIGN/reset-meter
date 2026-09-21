import Foundation

/// Only labels and identifiers are saved in preferences. Codex owns credentials.
public struct CodexAccount: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    public static let defaultAccount = CodexAccount(id: "default", name: "Default")
    public var isDefault: Bool { id == Self.defaultAccount.id }

    public var homeDirectory: URL? {
        guard !isDefault, UUID(uuidString: id) != nil else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Reset Meter/Codex Accounts")
            .appending(path: id)
    }
}
