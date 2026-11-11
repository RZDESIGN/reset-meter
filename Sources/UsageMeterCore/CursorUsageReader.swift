import Foundation

public enum CursorUsageReader {
    private static let endpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!

    public static func fetch(
        account: ProviderAccount = .defaultAccount(for: .cursor),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> ProviderUsage {
        try await fetch(
            account: account,
            loadLocal: { account in
                try await Task.detached(priority: .utility) {
                    try readLocalAuth(account: account, home: home)
                }.value
            },
            request: { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw UsageReadError.malformedCursorResponse
                }
                return (data, http)
            }
        )
    }

    struct LocalCursorAuth: Sendable {
        let accessToken: String
        let planName: String?
    }

    static func fetch(
        account: ProviderAccount,
        loadLocal: @Sendable (ProviderAccount) async throws -> LocalCursorAuth,
        request: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> ProviderUsage {
        guard account.isValid, account.provider == .cursor else {
            throw UsageReadError.cursorSignedOut
        }
        let localAuth = try await loadLocal(account)
        let (data, response) = try await request(usageRequest(token: localAuth.accessToken))
        if response.statusCode == 401 || response.statusCode == 403 {
            throw UsageReadError.cursorAuthorizationFailed
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UsageReadError.malformedCursorResponse
        }
        try Task.checkCancellation()
        return try parse(data: data, now: Date(), planName: localAuth.planName)
    }

    static func usageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 12
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(cursorVersion(), forHTTPHeaderField: "x-cursor-client-version")
        return request
    }

    public static func parse(data: Data, now: Date, planName: String? = nil) throws -> ProviderUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let planUsage = root["planUsage"] as? [String: Any],
              let usedPercent = (planUsage["autoPercentUsed"] as? NSNumber)?.doubleValue else {
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
            sourceDescription: "Live local Cursor pool",
            planName: planName
        )
    }

    private static func readLocalAuth(account: ProviderAccount, home: URL) throws -> LocalCursorAuth {
        let database = account.resolvedCursorDirectory(home: home)
            .appending(path: "User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw UsageReadError.cursorNotFound
        }

        guard let rawToken = queryItemValue(database: database, key: "cursorAuth/accessToken") else {
            throw UsageReadError.cursorSignedOut
        }
        let rawPlan = queryItemValue(database: database, key: "cursorAuth/stripeMembershipType")
        return LocalCursorAuth(
            accessToken: rawToken,
            planName: AccountPlan.cursor(rawPlan)
        )
    }

    private static func queryItemValue(database: URL, key: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            database.path,
            "SELECT value FROM ItemTable WHERE key = '\(key)' LIMIT 1;",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let encoded = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: encoded),
           !decoded.isEmpty {
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

    private static let session = URLSession(configuration: .ephemeral, delegate: NoCursorRedirects(), delegateQueue: nil)
}

private final class NoCursorRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
