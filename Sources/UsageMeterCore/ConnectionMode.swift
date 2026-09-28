import Foundation

public protocol UsageAccount: Identifiable, Sendable where ID == String {
    var mode: ConnectionMode { get }
}

public enum ConnectionMode: String, Codable, CaseIterable, Sendable {
    case local
    case login

    public var label: String { self == .local ? "Local" : "Login" }
}
