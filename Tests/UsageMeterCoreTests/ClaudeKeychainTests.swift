import Foundation
import Testing
@testable import UsageMeterCore

@Test func claudeKeychainReadsScopedProfileWithoutPrompting() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let workAccount = ProviderAccount(
        id: "claude:work",
        provider: .claude,
        name: "Work",
        profilePath: home.appending(path: "Library/Application Support/Claude-Work").path,
        secondaryPath: home.appending(path: ".claude-work").path
    )
    let service = workAccount.claudeKeychainService(home: home)
    #expect(service != "Claude Code-credentials")

    let login = #"{"claudeAiOauth":{"accessToken":"synthetic","scopes":["user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
    let tool = try fakeSecurity("""
    [ "$1" = find-generic-password ] || exit 1
    [ "$2" = -a ] && [ "$3" = '\(ClaudeKeychain.accountName())' ] || exit 2
    [ "$4" = -w ] && [ "$5" = -s ] && [ "$6" = '\(service)' ] || exit 3
    printf '%s\\n' '\(login)'
    """)
    defer { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }

    let credentials = try ClaudeCredentials.readStored(account: workAccount, home: home, keychain: tool)
    #expect(credentials.accessToken == "synthetic")
    #expect(credentials.planName == "Max 20×")

    let hex = Data(login.utf8).map { String(format: "%02x", $0) }.joined()
    #expect(ClaudeKeychain.decode(Data((hex + "\n").utf8)) == Data(login.utf8))
    #expect(ClaudeKeychain.decode(Data("\n".utf8)) == nil)
}

@Test func claudeKeychainHandlesMissingAndLockedItemsGracefully() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let account = ProviderAccount.defaultAccount(for: .claude)

    let missing = try fakeSecurity("exit 44")
    let locked = try fakeSecurity("exit 36")
    defer {
        for tool in [missing, locked] {
            try? FileManager.default.removeItem(at: tool.deletingLastPathComponent())
        }
    }

    #expect(throws: UsageReadError.claudeLocalUnavailable) {
        try ClaudeCredentials.readStored(account: account, home: home, keychain: missing)
    }
    #expect(throws: UsageReadError.claudeCredentialsUnavailable) {
        try ClaudeCredentials.readStored(account: account, home: home, keychain: locked)
    }
    #expect(ClaudeKeychain.accountName(environment: ["USER": "synthetic.user-1"]) == "synthetic.user-1")
    #expect(ClaudeKeychain.accountName(environment: ["USER": "has space"]) == "claude-code-user")
}

private func fakeSecurity(_ script: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "security")
    try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}
