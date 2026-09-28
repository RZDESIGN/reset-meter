import Darwin
import Foundation

enum ClaudeCommand {
    static func environment(
        account: ClaudeAccount, executable: URL,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: String] {
        // Inherited tokens, endpoints, and provider settings must not select a different account.
        var environment = inherited.filter {
            !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE_")
        }
        if account.mode == .login || inherited["CLAUDE_CONFIG_DIR"] != nil {
            environment["CLAUDE_CONFIG_DIR"] = try account.configPath(environment: inherited)
        }
        environment["PATH"] = executable.deletingLastPathComponent().path
            + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DISABLE_ERROR_REPORTING"] = "1"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return environment
    }

    static func execute(account: ClaudeAccount) async throws {
        guard let executable = findExecutable() else { throw UsageReadError.claudeNotFound }
        let cancellation = CommandCancellation()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try run(executable: executable, account: account, timeout: 180, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    /// Renewal spends the old refresh token, clears the login, then saves the new
    /// one, with several network round trips in between. Claude rejects a spent
    /// token and then clears the login for good, so renewals are never cancelled
    /// or overlapped, including across Reset Meter processes.
    static func renew(account: ClaudeAccount, replacing stale: ClaudeCredentials) async throws {
        guard let executable = findExecutable() else { throw UsageReadError.claudeNotFound }
        guard let home = account.homeDirectory else { throw UsageReadError.claudeAuthorizationFailed }
        try await Task.detached(priority: .utility) {
            try renew(executable: executable, account: account, replacing: stale, timeout: 120,
                      lock: home.appending(path: ".reset-meter-renewal.lock")) {
                try ClaudeCredentials.read(account: account)
            }
        }.value
    }

    static func renew(
        executable: URL, account: ClaudeAccount, replacing stale: ClaudeCredentials,
        timeout: TimeInterval, lock: URL, current: () throws -> ClaudeCredentials
    ) throws {
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UsageReadError.claudeCredentialsUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw UsageReadError.claudeCredentialsUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        // A renewal that finished while this one waited already replaced the login.
        guard try current().accessToken == stale.accessToken else { return }
        try run(executable: executable, account: account, refresh: stale, timeout: timeout)
    }

    static func run(
        executable: URL, account: ClaudeAccount, refresh: ClaudeCredentials? = nil,
        timeout: TimeInterval, cancellation: CommandCancellation = CommandCancellation()
    ) throws {
        // Reset Meter never signs in to, renews, or rewrites the installed Claude login.
        guard account.isValid, account.mode == .login else { throw UsageReadError.claudeLoginFailed }
        if cancellation.isCancelled { throw CancellationError() }
        var environment = try environment(account: account, executable: executable)
        if let refresh {
            guard let token = refresh.refreshToken, !token.isEmpty, !refresh.scopes.isEmpty else {
                throw UsageReadError.claudeAuthorizationFailed
            }
            environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = token
            environment["CLAUDE_CODE_OAUTH_SCOPES"] = refresh.scopes.joined(separator: " ")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "login"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        // The CLI opens the browser. Auth diagnostics and tokens never enter logs.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if cancellation.isCancelled { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw refresh == nil ? UsageReadError.claudeLoginFailed : UsageReadError.claudeTimedOut
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        if cancellation.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw refresh == nil ? UsageReadError.claudeLoginFailed : UsageReadError.claudeAuthorizationFailed
        }
    }

    static func findExecutable(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        systemDirectories: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
    ) -> URL? {
        let manager = FileManager.default
        var candidates = [
            home.appending(path: ".local/bin/claude"),
            home.appending(path: ".bun/bin/claude"),
        ]
        candidates += systemDirectories.map { $0.appending(path: "claude") }
        // Desktop downloads a native CLI here. The separate claude-code-vm
        // directory contains a Linux executable and must never be selected.
        let desktopRoot = home.appending(path: "Library/Application Support/Claude/claude-code")
        if let versions = try? manager.contentsOfDirectory(
            at: desktopRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            candidates += versions.sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }.flatMap { [$0.appending(path: "claude.app/Contents/MacOS/claude"), $0.appending(path: "claude")] }
        }
        candidates += (environment["PATH"] ?? "")
            .split(separator: ":").filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)).appending(path: "claude") }
        if let versions = try? manager.contentsOfDirectory(
            at: home.appending(path: ".nvm/versions/node"), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates += versions.sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }.map { $0.appending(path: "bin/claude") }
        }
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }
}
