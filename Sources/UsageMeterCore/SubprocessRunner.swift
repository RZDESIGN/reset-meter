import Foundation

enum SubprocessRunner {
    struct Result: Sendable {
        let status: Int32
        let reason: Process.TerminationReason
        let stdout: Data

        var succeeded: Bool {
            reason == .exit && status == 0
        }
    }

    static func run(
        executable: URL,
        arguments: [String] = [],
        stdinData: Data? = nil,
        timeout: TimeInterval = 5
    ) -> Result? {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let stdinPipe: Pipe?
        if stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if let stdinData, let writeHandle = stdinPipe?.fileHandleForWriting {
            DispatchQueue.global(qos: .utility).async {
                try? writeHandle.write(contentsOf: stdinData)
                try? writeHandle.close()
            }
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return Result(
            status: process.terminationStatus,
            reason: process.terminationReason,
            stdout: output
        )
    }

    static func runString(
        executable: URL,
        arguments: [String] = [],
        timeout: TimeInterval = 5
    ) -> String? {
        guard let result = run(executable: executable, arguments: arguments, timeout: timeout),
              result.succeeded else {
            return nil
        }
        return String(data: result.stdout, encoding: .utf8)
    }
}
