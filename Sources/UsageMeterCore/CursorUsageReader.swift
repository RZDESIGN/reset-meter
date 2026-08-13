import Foundation

public enum CursorUsageReader {
    private static let endpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!

    public static func fetch() async throws -> ProviderUsage {
        let token = try await Task.detached(priority: .utility) {
            try readAccessToken()
        }.value

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(cursorVersion(), forHTTPHeaderField: "x-cursor-client-version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageReadError.malformedCursorResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageReadError.cursorAuthorizationFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageReadError.malformedCursorResponse
        }

        return try parse(data: data, now: Date())
    }

    public static func parse(data: Data, now: Date) throws -> ProviderUsage {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let planUsage = root["planUsage"] as? [String: Any],
            let usedPercent = (planUsage["autoPercentUsed"] as? NSNumber)?.doubleValue
        else {
            throw UsageReadError.malformedCursorResponse
        }

        let reset = milliseconds(from: root["billingCycleEnd"])
            .map { Date(timeIntervalSince1970: $0 / 1_000) }
        let limit = UsageLimit(
            id: "cursor-first-party",
            label: "Composer + Grok",
            usedPercent: usedPercent,
            resetsAt: reset,
            displayMode: .remaining
        )

        return ProviderUsage(
            provider: .cursor,
            limits: [limit],
            updatedAt: now,
            sourceDescription: "Live Cursor first-party pool"
        )
    }

    private static func readAccessToken() throws -> String {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw UsageReadError.cursorNotFound
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            database.path,
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;",
        ]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        guard
            process.terminationStatus == 0,
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            throw UsageReadError.cursorSignedOut
        }

        if
            let encoded = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(String.self, from: encoded),
            !decoded.isEmpty
        {
            return decoded
        }
        return raw
    }

    private static func cursorVersion() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Cursor.app"),
            home.appending(path: "Applications/Cursor.app"),
        ]
        return candidates.lazy
            .compactMap(Bundle.init(url:))
            .compactMap { $0.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            .first ?? "unknown"
    }

    private static func milliseconds(from value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return TimeInterval(string) }
        return nil
    }
}
