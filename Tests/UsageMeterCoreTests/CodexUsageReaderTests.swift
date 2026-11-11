import Foundation
import Testing
@testable import UsageMeterCore

@Test func codexUsedPercentIsPresentedAsRemainingCapacity() throws {
    let response = Data(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":19,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":null}}}"#.utf8)

    let usage = try CodexUsageReader.parse(
        output: response,
        now: Date(timeIntervalSince1970: 1_900_000_000)
    )

    let weekly = try #require(usage.limits.first)
    #expect(weekly.usedPercent == 19)
    #expect(weekly.displayPercent == 81)
    #expect(weekly.displayMode == .remaining)
    #expect(usage.headlinePercent == 81)
}

@Test func codexPlanUsesAccountMetadataAndFormatsBusinessProLite() throws {
    let account = #"{"id":3,"result":{"account":{"type":"chatgpt","email":"synthetic@example.invalid","planType":"self_serve_business_prolite"}}}"#
    let limits = #"{"id":2,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":10}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":20}},"other":{"planType":"free"}}}}"#
    for output in [account + "\n" + limits, limits + "\n" + account] {
        let usage = try CodexUsageReader.parse(output: Data(output.utf8), now: .now)
        #expect(usage.planName == "Business Pro Lite")
        #expect(usage.headlinePercent == 80)
    }
    #expect(try CodexUsageReader.parse(output: Data(limits.utf8), now: .now).planName == "Pro")
}

@Test func codexIsolatesMultipleLocalHomesAndStripsAmbientKeys() throws {
    let home = URL(fileURLWithPath: "/Users/demo")
    let personal = ProviderAccount(id: "codex:default", provider: .codex, name: "Personal", profilePath: "/Users/demo/.codex")
    let work = ProviderAccount(id: "codex:work", provider: .codex, name: "Work", profilePath: "/Users/demo/.codex-work")
    let inherited = [
        "CODEX_HOME": "/tmp/ambient",
        "OPENAI_API_KEY": "sk-ambient",
        "CODEX_ACCESS_TOKEN": "tok-ambient",
        "PATH": "/bin",
    ]
    let exe = URL(fileURLWithPath: "/tools/codex")
    let envPersonal = CodexCommand.environment(account: personal, executable: exe, home: home, inherited: inherited)
    let envWork = CodexCommand.environment(account: work, executable: exe, home: home, inherited: inherited)

    #expect(envPersonal["CODEX_HOME"] == "/Users/demo/.codex")
    #expect(envWork["CODEX_HOME"] == "/Users/demo/.codex-work")
    #expect(envPersonal["OPENAI_API_KEY"] == nil)
    #expect(envWork["CODEX_ACCESS_TOKEN"] == nil)
}

@Test func codexCommandQueriesSelectedLocalHomeAndSanitizesErrors() throws {
    let work = ProviderAccount(id: "codex:work", provider: .codex, name: "Work", profilePath: "/tmp/synthetic-codex-work")
    let executable = try fakeCodex(#"""
    IFS= read -r initialize
    printf '%s\n' '{"id":1,"result":{}}'
    IFS= read -r initialized
    IFS= read -r request
    IFS= read -r account_request
    printf '%s\n' '{"id":3,"result":{"account":{"type":"chatgpt","planType":"pro"}}}'
    printf '{"id":2,"result":{"home":"%s","rateLimits":{"primary":{"usedPercent":37}}}}\n' "$CODEX_HOME"
    IFS= read -r done
    """#)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

    let output = try CodexCommand.run(executable: executable, account: work, timeout: 2)
    #expect(String(decoding: output, as: UTF8.self).contains("/tmp/synthetic-codex-work"))
    let usage = try CodexUsageReader.parse(output: output, now: .now)
    #expect(usage.headlinePercent == 63)
    #expect(usage.planName == "Pro")

    let errOutput = Data(#"{"id":2,"error":{"message":"synthetic private diagnostic"}}"#.utf8)
    do {
        _ = try CodexUsageReader.parse(output: errOutput, now: .now)
        Issue.record("Expected error")
    } catch {
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
