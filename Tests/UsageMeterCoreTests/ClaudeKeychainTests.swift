import Foundation
import Testing
@testable import UsageMeterCore

@Test func claudeKeychainReadsLikeClaudeCodeSoMacOSNeverPrompts() throws {
    let account = ClaudeAccount(name: "Work")
    let service = try account.keychainService()
    let login = #"{"claudeAiOauth":{"accessToken":"synthetic","scopes":["user:profile"],"subscriptionType":"max"}}"#
    let tool = try fakeSecurity("""
    [ "$1" = find-generic-password ] || exit 1
    [ "$2" = -a ] && [ "$3" = '\(ClaudeKeychain.accountName())' ] || exit 2
    [ "$4" = -w ] && [ "$5" = -s ] && [ "$6" = '\(service)' ] || exit 3
    printf '%s\\n' '\(login)'
    """)
    defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
    let credentials = try ClaudeCredentials.read(account: account, keychain: tool)
    #expect(credentials.accessToken == "synthetic")
    #expect(credentials.planName == "Max")

    // `security -w` prints nonprintable secrets as hex.
    let hex = Data(login.utf8).map { String(format: "%02x", $0) }.joined()
    #expect(ClaudeKeychain.decode(Data((hex + "\n").utf8)) == Data(login.utf8))
    #expect(ClaudeKeychain.decode(Data("\n".utf8)) == nil)
}

@Test func claudeKeychainSeparatesMissingLockedAndInterruptedLogins() throws {
    let account = ClaudeAccount(name: "Work")
    let cases: [(String, UsageReadError)] = [
        ("exit 44", .claudeSignedOut),                                 // No item and no fallback file.
        ("exit 36", .claudeCredentialsUnavailable),                    // Locked or inaccessible keychain.
        (#"printf '{}\n'"#, .claudeSignedOut),                         // Renewal stopped after clearing.
        (#"printf '{"claudeAiOauth":{"accessToken":"a","scopes":["user:inference"]}}'"#,
         .claudeAuthorizationFailed),
        // Claude blanks the login after the server rejects a spent refresh token.
        (#"printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"scopes":["user:profile"]}}'"#,
         .claudeAuthorizationFailed),
    ]
    for (script, expected) in cases {
        let tool = try fakeSecurity(script)
        defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
        #expect(throws: expected) { try ClaudeCredentials.read(account: account, keychain: tool) }
    }
    #expect(ClaudeKeychain.read(service: "synthetic", tool: URL(fileURLWithPath: "/nonexistent/security")) == .unavailable)
    let hanging = try fakeSecurity("exec /bin/sleep 30")
    defer { try? FileManager.default.removeItem(at: hanging.deletingLastPathComponent()) }
    let start = ProcessInfo.processInfo.systemUptime
    #expect(ClaudeKeychain.read(service: "synthetic", tool: hanging, timeout: 0.2) == .unavailable)
    #expect(ProcessInfo.processInfo.systemUptime - start < 5)
}

@Test func claudeKeychainDeletesOnlyTheScopedItem() throws {
    let service = try ClaudeAccount(name: "Work").keychainService()
    let deleting = try fakeSecurity("""
    [ "$1" = delete-generic-password ] && [ "$3" = '\(ClaudeKeychain.accountName())' ] || exit 1
    [ "$4" = -s ] && [ "$5" = '\(service)' ] || exit 2
    """)
    let absent = try fakeSecurity("exit 44")
    let locked = try fakeSecurity("exit 36")
    defer {
        for tool in [deleting, absent, locked] { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
    }
    #expect(ClaudeKeychain.delete(service: service, tool: deleting))
    #expect(!ClaudeKeychain.delete(service: "Claude Code-credentials", tool: deleting))
    #expect(ClaudeKeychain.delete(service: service, tool: absent))
    #expect(!ClaudeKeychain.delete(service: service, tool: locked))
}

@Test func claudeKeychainAccountMatchesClaudeCode() {
    #expect(ClaudeKeychain.accountName(environment: ["USER": "synthetic.user-1"]) == "synthetic.user-1")
    #expect(ClaudeKeychain.accountName(environment: ["USER": "has space"]) == "claude-code-user")
    #expect(ClaudeKeychain.accountName(environment: ["USER": ""]) == ClaudeKeychain.accountName(environment: [:]))
}

private func fakeSecurity(_ script: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "security")
    try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}
