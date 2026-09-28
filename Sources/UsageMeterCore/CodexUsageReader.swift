import Foundation

public enum CodexUsageReader {
    public static func fetch(account: CodexAccount = .defaultAccount) async throws -> ProviderUsage {
        let output = try await execute(account: account, login: false)
        return try parse(output: output, now: Date())
    }

    public static func signIn(account: CodexAccount) async throws {
        // Never change the login used by the user's regular Codex installation.
        guard let home = account.homeDirectory else { throw UsageReadError.codexLoginFailed }
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try await execute(account: account, login: true)
    }

    private static func execute(account: CodexAccount, login: Bool) async throws -> Data {
        guard let executable = findCodexExecutable() else { throw UsageReadError.codexNotFound }
        let cancellation = CommandCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try CodexCommand.run(
                    executable: executable, account: account, login: login,
                    timeout: login ? 180 : 20, cancellation: cancellation
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    public static func parse(output: Data, now: Date) throws -> ProviderUsage {
        guard let text = String(data: output, encoding: .utf8) else {
            throw UsageReadError.malformedCodexResponse
        }

        let messages = text.split(whereSeparator: \Character.isNewline).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        let accountPlan = messages.reversed().compactMap { object -> String? in
            guard (object["id"] as? NSNumber)?.intValue == 3,
                  let result = object["result"] as? [String: Any],
                  let account = result["account"] as? [String: Any] else { return nil }
            return AccountPlan.codex(account["planType"] as? String)
        }.first

        for object in messages.reversed() {
            guard
                (object["id"] as? NSNumber)?.intValue == 2
            else { continue }
            if object["error"] != nil { throw UsageReadError.codexAccountUnavailable }
            guard let result = object["result"] as? [String: Any] else { continue }

            let rateLimits: [String: Any]?
            if
                let buckets = result["rateLimitsByLimitId"] as? [String: Any],
                let codex = buckets["codex"] as? [String: Any]
            {
                rateLimits = codex
            } else {
                rateLimits = result["rateLimits"] as? [String: Any]
            }

            let bankedResets = BankedResets.parse(result["rateLimitResetCredits"])
            let limits = ["primary", "secondary"].compactMap { key in
                parseWindow(rateLimits?[key], key: key)
            }

            guard !limits.isEmpty || bankedResets != nil else { continue }
            return ProviderUsage(
                provider: .codex,
                limits: limits,
                updatedAt: now,
                sourceDescription: "Live Codex status",
                bankedResets: bankedResets,
                planName: accountPlan ?? AccountPlan.codex(rateLimits?["planType"] as? String)
            )
        }

        throw UsageReadError.malformedCodexResponse
    }

    private static func parseWindow(_ raw: Any?, key: String) -> UsageLimit? {
        guard
            let window = raw as? [String: Any],
            let used = (window["usedPercent"] as? NSNumber)?.doubleValue
        else { return nil }

        let duration = (window["windowDurationMins"] as? NSNumber)?.intValue
        let resetSeconds = (window["resetsAt"] as? NSNumber)?.doubleValue
        let reset = resetSeconds.map(Date.init(timeIntervalSince1970:))
        let label = label(for: duration, fallback: key)

        return UsageLimit(
            id: "codex-\(key)-\(duration ?? 0)",
            label: label,
            usedPercent: used,
            resetsAt: reset,
            durationMinutes: duration,
            displayMode: .remaining
        )
    }

    private static func label(for duration: Int?, fallback: String) -> String {
        guard let duration else { return fallback.capitalized }
        switch duration {
        case 0...360: return "5-hour"
        case 361...10_080: return duration == 10_080 ? "Weekly" : "\(duration / 60)-hour"
        case 10_081...50_000: return "Monthly"
        default: return "Usage window"
        }
    }

    private static func findCodexExecutable() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appending(path: ".local/bin/codex"),
            home.appending(path: ".bun/bin/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            home.appending(path: "Applications/Codex.app/Contents/Resources/codex"),
            home.appending(path: "Applications/ChatGPT.app/Contents/Resources/codex"),
        ]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex") }

        let nvmRoot = home.appending(path: ".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions
                .sorted { semanticVersion($0.lastPathComponent) > semanticVersion($1.lastPathComponent) }
                .map { $0.appending(path: "bin/codex") })
        }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
    }

    private static func semanticVersion(_ value: String) -> [Int] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}

private func > (lhs: [Int], rhs: [Int]) -> Bool {
    let count = max(lhs.count, rhs.count)
    for index in 0..<count {
        let left = index < lhs.count ? lhs[index] : 0
        let right = index < rhs.count ? rhs[index] : 0
        if left != right { return left > right }
    }
    return false
}
