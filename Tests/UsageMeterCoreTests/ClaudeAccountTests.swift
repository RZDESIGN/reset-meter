import Foundation
import Testing
@testable import UsageMeterCore

@Test func claudeAccountsIsolateDirectoriesCredentialsAndEnvironment() throws {
    let first = ClaudeAccount(name: "Personal")
    let second = ClaudeAccount(name: "Work")
    let inherited = [
        "CLAUDE_CONFIG_DIR": "/tmp/existing-claude", "CLAUDE_CODE_OAUTH_TOKEN": "synthetic",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN": "synthetic-refresh", "CLAUDE_CODE_USE_BEDROCK": "1",
        "ANTHROPIC_API_KEY": "synthetic-key", "ANTHROPIC_BASE_URL": "https://example.invalid",
        "PATH": "/bin", "HOME": "/synthetic-home"
    ]
    let executable = URL(fileURLWithPath: "/tools/claude")
    let a = try ClaudeCommand.environment(account: first, executable: executable, inherited: inherited)
    let b = try ClaudeCommand.environment(account: second, executable: executable, inherited: inherited)
    let original = try ClaudeCommand.environment(account: .defaultAccount, executable: executable, inherited: inherited)
    #expect(a["CLAUDE_CONFIG_DIR"] == first.homeDirectory?.path)
    #expect(a["CLAUDE_CONFIG_DIR"] != b["CLAUDE_CONFIG_DIR"])
    #expect(original["CLAUDE_CONFIG_DIR"] == "/tmp/existing-claude")
    #expect(a["HOME"] == inherited["HOME"])
    #expect(a["ANTHROPIC_API_KEY"] == nil)
    #expect(a["ANTHROPIC_BASE_URL"] == nil)
    #expect(a["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    #expect(a["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] == nil)
    #expect(a["CLAUDE_CODE_USE_BEDROCK"] == nil)
    #expect(try first.keychainService() != second.keychainService())
    #expect(try ClaudeAccount.defaultAccount.keychainService(environment: [:]) == "Claude Code-credentials")
    #expect(try ClaudeAccount.defaultAccount.keychainService(environment: inherited) != first.keychainService())
    #expect(ClaudeAccount(id: "../../escape", name: "Invalid").homeDirectory == nil)
    #expect(throws: UsageReadError.self) { try ClaudeAccount(id: "../../escape", name: "Invalid").keychainService() }
    #expect(try JSONDecoder().decode(ClaudeAccount.self, from: JSONEncoder().encode(first)) == first)
}

@Test func claudeLoginUsesOnlyItsSelectedProfileAndRenewsWithoutBrowser() throws {
    let account = ClaudeAccount(name: "Work")
    let executable = try fakeClaude(#"""
    [ "$1" = auth ] || exit 1
    [ "$2" = login ] || exit 2
    case "$CLAUDE_CONFIG_DIR" in *'/Reset Meter/Claude Accounts/'*) ;; *) exit 3;; esac
    [ -z "$ANTHROPIC_API_KEY" ] || exit 4
    [ "$CLAUDE_CODE_OAUTH_REFRESH_TOKEN" = synthetic-refresh ] || exit 5
    [ "$CLAUDE_CODE_OAUTH_SCOPES" = 'user:profile user:inference' ] || exit 6
    """#)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let credentials = ClaudeCredentials(accessToken: "synthetic", refreshToken: "synthetic-refresh", expiresAt: 1,
        scopes: ["user:profile", "user:inference"], subscriptionType: nil, rateLimitTier: nil)
    try ClaudeCommand.run(executable: executable, account: account, refresh: credentials, timeout: 2)
    // Local never signs in to or renews the installed login, even when the command would succeed.
    let succeeding = try fakeClaude("exit 0")
    defer { try? FileManager.default.removeItem(at: succeeding.deletingLastPathComponent()) }
    for refresh in [nil, credentials] {
        #expect(throws: UsageReadError.self) {
            try ClaudeCommand.run(executable: succeeding, account: .defaultAccount, refresh: refresh, timeout: 2)
        }
    }
}

@Test func claudeRenewalsNeverOverlapAndSkipAnAlreadyRenewedLogin() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let running = directory.appending(path: "running").path
    let runs = directory.appending(path: "runs")
    // Fails if a second renewal starts while the first is still running.
    let executable = try fakeClaude("""
    [ ! -e '\(running)' ] || exit 9
    touch '\(running)'
    /bin/sleep 0.3
    echo run >> '\(runs.path)'
    rm '\(running)'
    """)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    @Sendable func login(_ token: String) -> ClaudeCredentials {
        ClaudeCredentials(accessToken: token, refreshToken: "synthetic-refresh", expiresAt: 1,
            scopes: ["user:profile"], subscriptionType: nil, rateLimitTier: nil)
    }
    let failures = FailureCount()
    DispatchQueue.concurrentPerform(iterations: 3) { _ in
        do {
            try ClaudeCommand.renew(executable: executable, account: ClaudeAccount(name: "Work"),
                replacing: login("synthetic-old"), timeout: 5, lock: directory.appending(path: "renewal.lock")) {
                FileManager.default.fileExists(atPath: runs.path) ? login("synthetic-new") : login("synthetic-old")
            }
        } catch { failures.add() }
    }
    #expect(failures.value == 0)
    #expect(try String(contentsOf: runs, encoding: .utf8) == "run\n")
}

@Test func claudeLoginTimesOutAndCancelsWithoutLeakingDiagnostics() throws {
    let sleeper = try fakeClaude("exec /bin/sleep 30")
    defer { try? FileManager.default.removeItem(at: sleeper.deletingLastPathComponent()) }
    let account = ClaudeAccount(name: "Work")
    let start = ProcessInfo.processInfo.systemUptime
    #expect(throws: UsageReadError.self) {
        try ClaudeCommand.run(executable: sleeper, account: account, timeout: 0.1)
    }
    let cancellation = CommandCancellation()
    cancellation.cancel()
    #expect(throws: CancellationError.self) {
        try ClaudeCommand.run(executable: sleeper, account: account, timeout: 30, cancellation: cancellation)
    }
    #expect(ProcessInfo.processInfo.systemUptime - start < 5)
    let failing = try fakeClaude("echo 'synthetic private diagnostic' >&2\nexit 1")
    defer { try? FileManager.default.removeItem(at: failing.deletingLastPathComponent()) }
    do {
        try ClaudeCommand.run(executable: failing, account: account, timeout: 2)
        Issue.record("Expected login error")
    } catch {
        #expect(error is UsageReadError)
        #expect(!error.localizedDescription.contains("private diagnostic"))
    }
}

private final class FailureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private func fakeClaude(_ script: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "claude")
    try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}
