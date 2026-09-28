import Foundation
import Testing
@testable import UsageMeterCore

@Test func legacyAccountsKeepTheirOriginalSourceAndNewModesPersist() throws {
    for id in ["default", UUID().uuidString] {
        let legacy = try JSONSerialization.data(withJSONObject: ["id": id, "name": "Saved"])
        var codex = try JSONDecoder().decode(CodexAccount.self, from: legacy)
        var claude = try JSONDecoder().decode(ClaudeAccount.self, from: legacy)
        #expect(codex.mode == (id == "default" ? .local : .login))
        #expect(claude.mode == codex.mode)
        codex.mode = .login
        claude.mode = .login
        #expect(codex.homeDirectory?.lastPathComponent == id)
        #expect(claude.homeDirectory?.lastPathComponent == id)
        #expect(try claude.keychainService(environment: [:]) != "Claude Code-credentials")
        #expect(try JSONDecoder().decode(CodexAccount.self, from: JSONEncoder().encode(codex)) == codex)
        #expect(try JSONDecoder().decode(ClaudeAccount.self, from: JSONEncoder().encode(claude)) == claude)
        let savedCodex = codex.loginDirectory
        let savedClaude = claude.loginDirectory
        codex.mode = .local
        claude.mode = .local
        #expect(codex.homeDirectory == nil)
        #expect(claude.homeDirectory == nil)
        #expect(codex.loginDirectory == savedCodex)
        #expect(claude.loginDirectory == savedClaude)
        #expect(try claude.keychainService(environment: [:]) == "Claude Code-credentials")
        #expect(try claude.configPath(environment: ["CLAUDE_CONFIG_DIR": "/local-claude"]) == "/local-claude")
    }
}

@Test func defaultLoginModeIsolatesCliEnvironments() throws {
    let codex = CodexAccount(id: "default", name: "Default", mode: .login)
    let claude = ClaudeAccount(id: "default", name: "Default", mode: .login)
    let codexEnvironment = CodexCommand.environment(account: codex, executable: URL(fileURLWithPath: "/bin/codex"),
        inherited: ["CODEX_HOME": "/local-codex", "OPENAI_API_KEY": "synthetic"])
    let claudeEnvironment = try ClaudeCommand.environment(account: claude, executable: URL(fileURLWithPath: "/bin/claude"),
        inherited: ["CLAUDE_CONFIG_DIR": "/local-claude", "CLAUDE_CODE_OAUTH_TOKEN": "synthetic"])
    #expect(codexEnvironment["CODEX_HOME"] == codex.loginDirectory?.path)
    #expect(codexEnvironment["OPENAI_API_KEY"] == nil)
    #expect(claudeEnvironment["CLAUDE_CONFIG_DIR"] == claude.loginDirectory?.path)
    #expect(claudeEnvironment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
}

@Test func claudeFindsNewestUsableDesktopCliWithoutStandaloneInstallation() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    func binary(_ path: String, executable: Bool = true) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
        return url
    }
    let prefix = "Library/Application Support/Claude/"
    _ = try binary(prefix + "claude-code-vm/99.0.0/claude")
    #expect(ClaudeCommand.findExecutable(home: home, environment: [:], systemDirectories: []) == nil)
    _ = try binary(prefix + "claude-code/2.1.9/claude.app/Contents/MacOS/claude")
    let newest = try binary(prefix + "claude-code/2.1.281/claude.app/Contents/MacOS/claude")
    _ = try binary(prefix + "claude-code/2.1.300/claude.app/Contents/MacOS/claude", executable: false)
    let resolved = ClaudeCommand.findExecutable(home: home, environment: [:], systemDirectories: [])
    #expect(resolved?.resolvingSymlinksInPath().path == newest.resolvingSymlinksInPath().path)
    let standalone = try binary(".local/bin/claude")
    #expect(ClaudeCommand.findExecutable(home: home, environment: [:], systemDirectories: [])?.path == standalone.path)
}

@Test func claudeLocalDesktopFallbackNeverLeaksIntoLoginMode() async throws {
    let data = Data(#"{"version":1,"samples":[{"t":1000000,"org":"synthetic-a","u":{"fh":70,"sd":90}},{"t":2000000,"org":"synthetic-b","u":{"fh":20,"sd":35}}]}"#.utf8)
    let usage = try await ClaudeUsageReader.fetchLocalOrLogin(account: .defaultAccount,
        live: { throw UsageReadError.claudeSignedOut },
        desktop: { try ClaudeDesktopUsageReader.parse(data: data, now: .now) })
    #expect(usage.limits.map(\.displayPercent) == [80, 65])
    #expect(usage.isStale)
    #expect(usage.limits.allSatisfy { $0.resetsAt == nil && !$0.resetIsEstimated })
    #expect(usage.planName == nil)
    #expect(usage.updatedAt == Date(timeIntervalSince1970: 2000))
    await #expect(throws: UsageReadError.self) {
        try await ClaudeUsageReader.fetchLocalOrLogin(account: ClaudeAccount(id: "default", name: "Login", mode: .login),
            live: { throw UsageReadError.claudeSignedOut },
            desktop: { Issue.record("Login must not use another account's cache"); return usage })
    }
    let live = try await ClaudeUsageReader.fetchLocalOrLogin(account: .defaultAccount,
        live: { usage }, desktop: { Issue.record("Should prefer available live usage"); return usage })
    #expect(live == usage)
    // Without an installed login or cache, Local points to the Claude app rather than to Sign In.
    for missing in [UsageReadError.claudeSignedOut, .claudeAuthorizationFailed, .claudeCredentialsUnavailable] {
        await #expect(throws: UsageReadError.claudeLocalUnavailable) {
            try await ClaudeUsageReader.fetchLocalOrLogin(account: .defaultAccount,
                live: { throw missing }, desktop: { throw UsageReadError.claudeLocalUnavailable })
        }
    }
    await #expect(throws: UsageReadError.claudeRateLimited) {
        try await ClaudeUsageReader.fetchLocalOrLogin(account: .defaultAccount,
            live: { throw UsageReadError.claudeRateLimited }, desktop: { throw UsageReadError.claudeLocalUnavailable })
    }
}

@Test(arguments: ["{}", #"{"samples":[]}"#, #"{"samples":[{"t":1,"u":{}}]}"#])
func claudeMissingCacheNeverInventsUsage(_ json: String) {
    #expect(throws: UsageReadError.self) { try ClaudeDesktopUsageReader.parse(data: Data(json.utf8), now: .now) }
}
