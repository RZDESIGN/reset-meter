import Foundation
import Testing
@testable import UsageMeterCore

@Test func separateAccountsKeepSeparateHomesAndIgnoreInheritedCredentials() throws {
    let first = CodexAccount(name: "Personal")
    let second = CodexAccount(name: "Work")
    let inherited = ["CODEX_HOME": "/existing-codex", "OPENAI_API_KEY": "synthetic", "PATH": "/bin"]
    let executable = URL(fileURLWithPath: "/tools/codex")
    let a = CodexCommand.environment(account: first, executable: executable, inherited: inherited)
    let b = CodexCommand.environment(account: second, executable: executable, inherited: inherited)
    let original = CodexCommand.environment(account: .defaultAccount, executable: executable, inherited: inherited)
    #expect(a["CODEX_HOME"] == first.homeDirectory?.path)
    #expect(a["CODEX_HOME"] != b["CODEX_HOME"])
    #expect(a["OPENAI_API_KEY"] == nil)
    #expect(original["CODEX_HOME"] == "/existing-codex")
    #expect(original["OPENAI_API_KEY"] == "synthetic")
    #expect(CodexAccount(id: "../../escape", name: "Invalid").homeDirectory == nil)
    #expect(try JSONDecoder().decode(CodexAccount.self, from: JSONEncoder().encode(first)) == first)
}

@Test func codexCommandWaitsForInitializationAndUsesSelectedHome() throws {
    let account = CodexAccount(name: "Work")
    let executable = try fakeCodex(#"""
    IFS= read -r initialize
    case "$initialize" in *'"method":"initialize"'*) ;; *) exit 1;; esac
    printf '%s\n' '{"id":1,"result":{}}'
    IFS= read -r initialized
    case "$initialized" in *'"method":"initialized"'*) ;; *) exit 2;; esac
    IFS= read -r request
    case "$request" in *'"method":"account/rateLimits/read"'*) ;; *) exit 3;; esac
    [ "$3" = '-c' ] || exit 4
    [ "$4" = 'cli_auth_credentials_store="file"' ] || exit 5
    printf '{"id":2,"result":{"home":"%s","rateLimits":{"primary":{"usedPercent":37}}}}\n' "$CODEX_HOME"
    IFS= read -r done
    """#)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let output = try CodexCommand.run(executable: executable, account: account, login: false, timeout: 2)
    #expect(String(decoding: output, as: UTF8.self).contains(try #require(account.homeDirectory).path))
    #expect(try CodexUsageReader.parse(output: output, now: .now).headlinePercent == 63)
}

@Test func codexCommandTimesOutAndCanBeCancelled() throws {
    let executable = try fakeCodex("exec /bin/sleep 30")
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let start = ProcessInfo.processInfo.systemUptime
    #expect(throws: UsageReadError.self) {
        try CodexCommand.run(executable: executable, account: .defaultAccount, login: false, timeout: 0.1)
    }
    let cancellation = CodexCancellation()
    cancellation.cancel()
    #expect(throws: CancellationError.self) {
        try CodexCommand.run(executable: executable, account: .defaultAccount, login: false, timeout: 30, cancellation: cancellation)
    }
    #expect(ProcessInfo.processInfo.systemUptime - start < 5)
}

@Test func codexAccountErrorsDoNotExposeServerDiagnostics() {
    let output = Data(#"{"id":2,"error":{"message":"synthetic private diagnostic"}}"#.utf8)
    do {
        _ = try CodexUsageReader.parse(output: output, now: .now)
        Issue.record("Expected an account error")
    } catch {
        #expect(error.localizedDescription.contains("subscription"))
        #expect(!error.localizedDescription.contains("private diagnostic"))
    }
}

private func fakeCodex(_ script: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "codex")
    try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}
