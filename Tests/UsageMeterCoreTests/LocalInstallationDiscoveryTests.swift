import Foundation
import Testing
@testable import UsageMeterCore

@Test func discoversDualChatGPTCodexAndClaudeClientsAutomatically() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appending(path: "ResetMeterDiscovery-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }

    func touch(_ relativePath: String) throws {
        let url = home.appending(path: relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
    }

    // Two separate ChatGPT / Codex local clients: ~/.codex and ~/.codex-work
    try touch(".codex/auth.json")
    try touch(".codex-work/auth.json")

    // Two separate Claude local clients: Claude + Claude-Work paired with ~/.claude + ~/.claude-work
    try touch("Library/Application Support/Claude/plan-usage-history.json")
    try touch(".claude/settings.json")
    try touch("Library/Application Support/Claude-Work/plan-usage-history.json")
    try touch(".claude-work/.claude.json")
    // Internal Claude helper folders must never be mistaken for user profiles.
    try touch("Library/Application Support/Claude Extensions/config.json")

    // Antigravity + Cursor
    try touch("Library/Application Support/Antigravity/app_storage.json")
    try touch("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    let codex = LocalInstallationDiscovery.discoverCodex(home: home)
    #expect(codex.map(\.id) == ["codex:default", "codex:work"])
    #expect(codex.map(\.name) == ["Personal", "Work"])
    #expect(codex[0].resolvedCodexHome(home: home).lastPathComponent == ".codex")
    #expect(codex[1].resolvedCodexHome(home: home).lastPathComponent == ".codex-work")

    let claude = LocalInstallationDiscovery.discoverClaude(home: home)
    #expect(claude.map(\.id) == ["claude:default", "claude:work"])
    #expect(claude.map(\.name) == ["Personal", "Work"])
    #expect(claude[0].isDefaultClaudeCodeDirectory(home: home))
    #expect(!claude[1].isDefaultClaudeCodeDirectory(home: home))
    #expect(claude[0].claudeKeychainService(home: home) == "Claude Code-credentials")
    #expect(claude[1].claudeKeychainService(home: home) != "Claude Code-credentials")
    #expect(claude[1].resolvedClaudeDesktopDirectory(home: home).lastPathComponent == "Claude-Work")
    #expect(claude[1].resolvedClaudeCodeDirectory(home: home).lastPathComponent == ".claude-work")
}

@Test func findsModernBundledCodexExecutableInsideChatGPTApp() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "ResetMeterCodexExec-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    let home = root.appending(path: "home")
    let apps = root.appending(path: "Applications")
    let bundled = apps.appending(path: "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    try fm.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundled.path)

    let found = CodexUsageReader.findCodexExecutable(
        home: home,
        environment: [:],
        systemDirectories: [],
        applicationDirectories: [apps]
    )
    #expect(found?.resolvingSymlinksInPath().path == bundled.resolvingSymlinksInPath().path)
}

@Test func rejectsTraversalAndMalformedAccountIdentifiers() {
    #expect(!ProviderAccount(id: "../escape", provider: .codex, name: "Bad").isValid)
    #expect(!ProviderAccount(id: "codex/sub", provider: .codex, name: "Bad").isValid)
    #expect(!ProviderAccount(id: "codex:ok", provider: .codex, name: "Bad", profilePath: "relative/path").isValid)
    #expect(ProviderAccount.defaultAccount(for: .antigravity).isValid)
}
