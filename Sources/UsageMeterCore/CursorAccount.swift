import Foundation

/// Labels and mode are preferences. Independent login credentials live in Keychain.
public struct CursorAccount: Codable, UsageAccount, Equatable {
    public let id: String
    public var name: String
    public var mode: ConnectionMode

    public init(id: String = UUID().uuidString, name: String, mode: ConnectionMode? = nil) {
        self.id = id
        self.name = name
        self.mode = mode ?? (id == "default" ? .local : .login)
    }

    public static let defaultAccount = CursorAccount(id: "default", name: "Default")
    public var isDefault: Bool { id == Self.defaultAccount.id }
    public var isValid: Bool { isDefault || UUID(uuidString: id) != nil }

    // Preserve the existing Cursor visibility preference.
    public var entryID: String { isDefault ? "cursor" : "cursor:\(id)" }
}
