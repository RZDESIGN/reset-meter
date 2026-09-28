import Foundation

/// Claude Code writes each login with `/usr/bin/security`, which makes that
/// tool the item's only trusted application. Reading it through the Security
/// framework prompts for access, and that grant is lost whenever a renewal
/// re-creates the item or Reset Meter's signature changes. Claude Code reads
/// its own items through the same tool and arguments, which never prompts.
enum ClaudeKeychain {
    enum Lookup: Equatable, Sendable {
        case found(Data)
        case missing
        case unavailable
    }

    static let tool = URL(fileURLWithPath: "/usr/bin/security")
    private static let itemNotFound: Int32 = 44 // errSecItemNotFound & 0xff

    /// Claude Code's account attribute, including its fallback for unusual names.
    static func accountName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let name = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        return name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) == nil ? "claude-code-user" : name
    }

    static func read(service: String, tool: URL = tool, timeout: TimeInterval = 10) -> Lookup {
        guard let (status, output) = run(tool, ["find-generic-password", "-a", accountName(), "-w", "-s", service],
                                         timeout: timeout) else { return .unavailable }
        if status == itemNotFound { return .missing }
        guard status == 0 else { return .unavailable }
        return decode(output).map(Lookup.found) ?? .missing
    }

    static func delete(service: String, tool: URL = tool) -> Bool {
        guard let (status, _) = run(tool, ["delete-generic-password", "-a", accountName(), "-s", service])
        else { return false }
        return status == 0 || status == itemNotFound
    }

    /// `security -w` prints printable secrets verbatim and anything else as hex.
    static func decode(_ output: Data) -> Data? {
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) else { return Data(text.utf8) }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    private static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval = 10) -> (Int32, Data)? {
        let process = Process()
        let output = Pipe()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        // Diagnostics can include item attributes. Credentials never enter logs.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit else { return nil }
        return (process.terminationStatus, data)
    }
}
