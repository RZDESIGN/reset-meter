import Foundation

public enum CodexUsageReader {
    public static func fetch() async throws -> ProviderUsage {
        try await Task.detached(priority: .utility) {
            try self.fetchSynchronously()
        }.value
    }

    static func fetchSynchronously() throws -> ProviderUsage {
        guard let executable = findCodexExecutable() else {
            throw UsageReadError.codexNotFound
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executable.deletingLastPathComponent().path
        environment["PATH"] = executableDirectory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        try process.run()

        let initialize = #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"reset-meter","version":"\#(clientVersion)"},"capabilities":{"experimentalApi":true}}}"#
        let request = #"{"id":2,"method":"account/rateLimits/read"}"#
        let payload = Data((initialize + "\n" + request + "\n").utf8)
        try standardInput.fileHandleForWriting.write(contentsOf: payload)

        // The app server stays alive while stdin is open. Give the read-only
        // account request a short window to finish, then close it cleanly.
        Thread.sleep(forTimeInterval: 2.5)
        try? standardInput.fileHandleForWriting.close()

        let output = try standardOutput.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        guard !output.isEmpty else {
            throw UsageReadError.codexTimedOut
        }
        return try parse(output: output, now: Date())
    }

    public static func parse(output: Data, now: Date) throws -> ProviderUsage {
        guard let text = String(data: output, encoding: .utf8) else {
            throw UsageReadError.malformedCodexResponse
        }

        for line in text.split(whereSeparator: \Character.isNewline).reversed() {
            guard
                let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                (object["id"] as? NSNumber)?.intValue == 2,
                let result = object["result"] as? [String: Any]
            else { continue }

            let rateLimits: [String: Any]?
            if
                let buckets = result["rateLimitsByLimitId"] as? [String: Any],
                let codex = buckets["codex"] as? [String: Any]
            {
                rateLimits = codex
            } else {
                rateLimits = result["rateLimits"] as? [String: Any]
            }

            guard let rateLimits else { continue }
            let limits = ["primary", "secondary"].compactMap { key in
                parseWindow(rateLimits[key], key: key)
            }

            guard !limits.isEmpty else { continue }
            return ProviderUsage(
                provider: .codex,
                limits: limits,
                updatedAt: now,
                sourceDescription: "Live Codex status"
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
        ]

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

    private static var clientVersion: String {
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
