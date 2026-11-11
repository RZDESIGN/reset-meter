import Darwin
import Foundation

final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

enum CodexCommand {
    static func environment(
        account: ProviderAccount,
        executable: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = inherited
        environment["PATH"] = executable.deletingLastPathComponent().path
            + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["CODEX_HOME"] = account.resolvedCodexHome(home: home).path
        // Never allow inherited API keys to override the selected local ChatGPT/Codex subscription.
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    static func run(
        executable: URL,
        account: ProviderAccount,
        timeout: TimeInterval,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        cancellation: CommandCancellation = CommandCancellation()
    ) throws -> Data {
        guard account.isValid, account.provider == .codex else {
            throw UsageReadError.codexAccountUnavailable
        }
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.environment = environment(account: account, executable: executable, home: home)
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        func send(_ message: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data((message + "\n").utf8))
        }
        try send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"reset-meter","version":"\#(CodexUsageReader.clientVersion)"},"capabilities":{"experimentalApi":true}}}"#)

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var pending = Data()
        var requested = false
        var received = Set<Int>()
        var usageReceivedAt: TimeInterval?
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            if let usageReceivedAt, ProcessInfo.processInfo.systemUptime - usageReceivedAt >= 1 {
                return data
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                if received.contains(2) { return data }
                throw UsageReadError.codexTimedOut
            }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                pending.append(contentsOf: buffer.prefix(count))
                guard data.count <= 1_048_576 else { throw UsageReadError.malformedCodexResponse }
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let id = (object["id"] as? NSNumber)?.intValue else { continue }
                    if id == 1 && !requested {
                        guard object["error"] == nil else { throw UsageReadError.malformedCodexResponse }
                        try send(#"{"method":"initialized"}"#)
                        try send(#"{"id":2,"method":"account/rateLimits/read"}"#)
                        try send(#"{"id":3,"method":"account/read","params":{"refreshToken":false}}"#)
                        requested = true
                    }
                    received.insert(id)
                    if id == 2 { usageReceivedAt = ProcessInfo.processInfo.systemUptime }
                    if received.contains(2) && received.contains(3) { return data }
                }
                continue
            }
            if !process.isRunning {
                return data
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }
}
