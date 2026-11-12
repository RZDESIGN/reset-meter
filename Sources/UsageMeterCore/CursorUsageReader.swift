import Foundation

public enum CursorUsageReader {
    private static let usageEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!
    private static let planInfoEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo"
    )!

    public struct LocalCursorState: Sendable {
        public let databaseExists: Bool
        public let plaintextAccessToken: String?
        public let isEncryptedAtRest: Bool
        public let planName: String?

        public init(
            databaseExists: Bool,
            plaintextAccessToken: String?,
            isEncryptedAtRest: Bool,
            planName: String?
        ) {
            self.databaseExists = databaseExists
            self.plaintextAccessToken = plaintextAccessToken
            self.isEncryptedAtRest = isEncryptedAtRest
            self.planName = planName
        }
    }

    public static func readLocalPlan(
        account: ProviderAccount = .defaultAccount(for: .cursor),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        readLocalState(account: account, home: home).planName
    }

    public static func fetch(
        account: ProviderAccount = .defaultAccount(for: .cursor),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheDirectory: URL = UsageSnapshotCache.defaultDirectory
    ) async throws -> ProviderUsage {
        guard account.isValid, account.provider == .cursor else {
            throw UsageReadError.cursorSignedOut
        }

        let localState = await Task.detached(priority: .utility) {
            readLocalState(account: account, home: home)
        }.value
        let savedCredentials = try? await Task.detached(priority: .utility) {
            try CursorCredentials.readSaved(account: account)
        }.value
        let cliToken = await Task.detached(priority: .utility) {
            CursorCredentials.readLocalCLI(home: home)
        }.value

        do {
            let usage = try await fetchPipeline(
                account: account,
                localState: localState,
                savedCredentials: savedCredentials,
                cliToken: cliToken,
                saveCredentials: { updated in
                    try CursorCredentials.save(updated, account: account)
                },
                request: { try await CursorHTTP.request($0) }
            )
            UsageSnapshotCache.save(usage, accountID: account.id, directory: cacheDirectory)
            return usage
        } catch let error as UsageReadError {
            // Do not mask explicit sign-out or encrypted-session setup states with old cache,
            // except on transient network errors.
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let cached = UsageSnapshotCache.staleFallback(
                accountID: account.id,
                now: Date(),
                sourceDescription: "Cursor cache · reconnect to update",
                directory: cacheDirectory
            ) {
                return cached
            }
            throw error
        }
    }

    static func fetchPipeline(
        account: ProviderAccount,
        localState: LocalCursorState,
        savedCredentials: CursorCredentials?,
        cliToken: String?,
        saveCredentials: @Sendable (CursorCredentials) throws -> Void,
        request: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> ProviderUsage {
        var authFailed = false

        // 1. Saved Reset Meter Cursor PKCE session (supports silent OAuth token refresh).
        if var credentials = savedCredentials {
            do {
                if credentials.needsRefresh() {
                    credentials = try await refreshCredentials(credentials, save: saveCredentials, request: request)
                }
                do {
                    return try await fetchWithToken(
                        credentials.accessToken,
                        fallbackPlan: localState.planName,
                        sourceDescription: "Live Cursor usage",
                        request: request
                    )
                } catch UsageReadError.cursorAuthorizationFailed {
                    credentials = try await refreshCredentials(credentials, save: saveCredentials, request: request)
                    return try await fetchWithToken(
                        credentials.accessToken,
                        fallbackPlan: localState.planName,
                        sourceDescription: "Live Cursor usage",
                        request: request
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch UsageReadError.cursorAuthorizationFailed {
                authFailed = true
            } catch let error as UsageReadError where error == .malformedCursorResponse {
                throw error
            } catch {
                // Fall through to CLI or local desktop token if available.
            }
        }

        // 2. Local `cursor-agent` CLI token (strictly read-only).
        if let cliToken {
            do {
                return try await fetchWithToken(
                    cliToken,
                    fallbackPlan: localState.planName,
                    sourceDescription: "Live local Cursor CLI usage",
                    request: request
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch UsageReadError.cursorAuthorizationFailed {
                authFailed = true
            } catch let error as UsageReadError where error == .malformedCursorResponse {
                throw error
            } catch {}
        }

        // 3. Plaintext `state.vscdb` token (when `authTokenEncryptionAtRest` is disabled).
        if let desktopToken = localState.plaintextAccessToken {
            return try await fetchWithToken(
                desktopToken,
                fallbackPlan: localState.planName,
                sourceDescription: "Live local Cursor pool",
                request: request
            )
        }

        if authFailed {
            throw UsageReadError.cursorAuthorizationFailed
        }
        if localState.isEncryptedAtRest {
            throw UsageReadError.cursorEncryptedLocalSession
        }
        if !localState.databaseExists {
            throw UsageReadError.cursorNotFound
        }
        throw UsageReadError.cursorSignedOut
    }

    private static func refreshCredentials(
        _ credentials: CursorCredentials,
        save: @Sendable (CursorCredentials) throws -> Void,
        request: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> CursorCredentials {
        let (data, response) = try await request(CursorLogin.refreshRequest(credentials: credentials))
        if response.statusCode == 401 || response.statusCode == 403 {
            throw UsageReadError.cursorAuthorizationFailed
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UsageReadError.malformedCursorResponse
        }
        let renewed = try CursorLogin.refreshedCredentials(data: data)
        try save(renewed)
        return renewed
    }

    private static func fetchWithToken(
        _ token: String,
        fallbackPlan: String?,
        sourceDescription: String,
        request: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> ProviderUsage {
        let (data, response) = try await request(usageRequest(token: token))
        if response.statusCode == 401 || response.statusCode == 403 {
            throw UsageReadError.cursorAuthorizationFailed
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UsageReadError.malformedCursorResponse
        }
        var plan = fallbackPlan
        if plan == nil,
           let (planData, planResp) = try? await request(planInfoRequest(token: token)),
           planResp.statusCode == 200 {
            plan = parsePlanInfo(planData)
        }
        try Task.checkCancellation()
        return try parse(
            data: data,
            now: Date(),
            planName: plan,
            sourceDescription: sourceDescription
        )
    }

    static func usageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"includePooledUsage":true}"#.utf8)
        request.timeoutInterval = 12
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(cursorVersion(), forHTTPHeaderField: "x-cursor-client-version")
        return request
    }

    private static func planInfoRequest(token: String) -> URLRequest {
        var request = URLRequest(url: planInfoEndpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(cursorVersion(), forHTTPHeaderField: "x-cursor-client-version")
        return request
    }

    public static func parse(
        data: Data,
        now: Date,
        planName: String? = nil,
        sourceDescription: String = "Live local Cursor pool"
    ) throws -> ProviderUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageReadError.malformedCursorResponse
        }

        let reset = milliseconds(from: root["billingCycleEnd"])
            .map { Date(timeIntervalSince1970: $0 / 1_000) }

        var limits: [UsageLimit] = []
        var footnotes: [String] = []

        if let planUsage = root["planUsage"] as? [String: Any] {
            if let autoPercent = finiteDouble(planUsage["autoPercentUsed"]) {
                limits.append(
                    UsageLimit(
                        id: "cursor-first-party",
                        label: "Composer + Grok",
                        usedPercent: autoPercent,
                        resetsAt: reset,
                        displayMode: .remaining
                    )
                )
            } else if let limitCents = finiteDouble(planUsage["limit"]), limitCents > 0 {
                let includedCents = finiteDouble(planUsage["includedSpend"]) ?? 0
                let usedPercent = min(max((includedCents / limitCents) * 100, 0), 100)
                limits.append(
                    UsageLimit(
                        id: "cursor-included-spend",
                        label: "Included usage",
                        usedPercent: usedPercent,
                        resetsAt: reset,
                        displayMode: .remaining
                    )
                )
                footnotes.append("\(formatDollars(cents: includedCents)) / \(formatDollars(cents: limitCents)) included")
            } else if let totalPercent = finiteDouble(planUsage["totalPercentUsed"]) {
                limits.append(
                    UsageLimit(
                        id: "cursor-total-percent",
                        label: "Included usage",
                        usedPercent: totalPercent,
                        resetsAt: reset,
                        displayMode: .remaining
                    )
                )
            }
        }

        if let spendLimit = root["spendLimitUsage"] as? [String: Any] {
            let individualUsed = finiteDouble(spendLimit["individualUsed"]) ?? 0
            if let individualLimit = finiteDouble(spendLimit["individualLimit"]), individualLimit > 0 {
                let pct = min(max((individualUsed / individualLimit) * 100, 0), 100)
                limits.append(
                    UsageLimit(
                        id: "cursor-individual-spend",
                        label: "Spend limit",
                        usedPercent: pct,
                        resetsAt: reset,
                        displayMode: .remaining
                    )
                )
                footnotes.append("\(formatDollars(cents: individualUsed)) / \(formatDollars(cents: individualLimit)) spend cap")
            }
            if let pooledLimit = finiteDouble(spendLimit["pooledLimit"]), pooledLimit > 0 {
                let pooledUsed = finiteDouble(spendLimit["pooledUsed"]) ?? 0
                let pct = min(max((pooledUsed / pooledLimit) * 100, 0), 100)
                limits.append(
                    UsageLimit(
                        id: "cursor-pooled-spend",
                        label: "Team pool",
                        usedPercent: pct,
                        resetsAt: reset,
                        displayMode: .remaining
                    )
                )
            } else if limits.isEmpty,
                      let overallLimit = finiteDouble(spendLimit["overallLimit"]),
                      overallLimit > 0 {
                let overallUsed = finiteDouble(spendLimit["overallUsed"]) ?? 0
                let pct = min(max((overallUsed / overallLimit) * 100, 0), 100)
                limits.append(
                    UsageLimit(
                        id: "cursor-overall-spend",
                        label: "Spend limit",
                        usedPercent: pct,
                        resetsAt: reset,
                        displayMode: .remaining
                    )
                )
            } else if limits.isEmpty {
                // Unlimited Enterprise / Team seat with uncapped spend tracking.
                let cycleCents = finiteDouble(spendLimit["totalSpend"]) ?? individualUsed
                limits.append(
                    UsageLimit(
                        id: "cursor-unlimited-seat",
                        label: "Included pool",
                        usedPercent: 0,
                        resetsAt: reset,
                        displayMode: .remaining
                    )
                )
                if cycleCents > 0 {
                    footnotes.append("\(formatDollars(cents: cycleCents)) used this cycle · Unlimited")
                } else {
                    footnotes.append("Unlimited seat")
                }
            }
        }

        guard !limits.isEmpty else {
            throw UsageReadError.malformedCursorResponse
        }

        return ProviderUsage(
            provider: .cursor,
            limits: limits,
            updatedAt: now,
            sourceDescription: sourceDescription,
            planName: planName,
            footnote: footnotes.isEmpty ? nil : footnotes.joined(separator: " · ")
        )
    }

    static func parsePlanInfo(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let planInfo = root["planInfo"] as? [String: Any] else { return nil }
        return AccountPlan.cursor(planInfo["planName"] as? String)
    }

    static func readLocalState(account: ProviderAccount, home: URL) -> LocalCursorState {
        let database = account.resolvedCursorDirectory(home: home)
            .appending(path: "User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path) else {
            return LocalCursorState(
                databaseExists: false,
                plaintextAccessToken: nil,
                isEncryptedAtRest: false,
                planName: nil
            )
        }

        let values = queryStateValues(
            database: database,
            keys: ["cursorAuth/stripeMembershipType", "cursorAuth/accessToken"]
        )
        let planName = AccountPlan.cursor(values["cursorAuth/stripeMembershipType"])

        guard let rawToken = values["cursorAuth/accessToken"] else {
            return LocalCursorState(
                databaseExists: true,
                plaintextAccessToken: nil,
                isEncryptedAtRest: false,
                planName: planName
            )
        }

        if rawToken.hasPrefix("cursor-safe-storage:") {
            return LocalCursorState(
                databaseExists: true,
                plaintextAccessToken: nil,
                isEncryptedAtRest: true,
                planName: planName
            )
        }

        return LocalCursorState(
            databaseExists: true,
            plaintextAccessToken: rawToken,
            isEncryptedAtRest: false,
            planName: planName
        )
    }

    private static func queryStateValues(database: URL, keys: [String]) -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        let pairs = keys.map { key -> String in
            let escaped = key.replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)', (SELECT value FROM ItemTable WHERE key = '\(escaped)' LIMIT 1)"
        }.joined(separator: ", ")
        let sql = "SELECT json_object(\(pairs));"

        guard let rawOutput = SubprocessRunner.runString(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-readonly", database.path, sql],
            timeout: 5
        ) else {
            return [:]
        }
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var resolved: [String: String] = [:]
        for (key, rawValue) in dict {
            guard let stringValue = (rawValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !stringValue.isEmpty else { continue }
            if let encoded = stringValue.data(using: .utf8),
               let unwrapped = try? JSONDecoder().decode(String.self, from: encoded),
               !unwrapped.isEmpty {
                resolved[key] = unwrapped
            } else {
                resolved[key] = stringValue
            }
        }
        return resolved
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
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let string = value as? String {
            return TimeInterval(string)
        }
        return nil
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue.isFinite {
            return number.doubleValue
        }
        if let string = value as? String, let parsed = Double(string), parsed.isFinite {
            return parsed
        }
        return nil
    }

    private static func formatDollars(cents: Double) -> String {
        let dollars = cents / 100
        if abs(dollars.rounded() - dollars) < 0.005 {
            return "$\(Int(dollars.rounded()))"
        }
        return String(format: "$%.2f", dollars)
    }
}
