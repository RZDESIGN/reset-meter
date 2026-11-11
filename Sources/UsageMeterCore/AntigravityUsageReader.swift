import Foundation

/// Reads live model quota pools, reset times, subscription tier, and AI credits directly
/// from the local Antigravity `language_server` loopback RPC — no login or Keychain access required.
public enum AntigravityUsageReader {
    struct ServerTarget: Equatable, Sendable {
        let pid: String
        let csrfToken: String
        let ports: [Int]
    }

    public static func fetch(
        account: ProviderAccount = .defaultAccount(for: .antigravity),
        cacheDirectory: URL = UsageSnapshotCache.defaultDirectory
    ) async throws -> ProviderUsage {
        guard account.isValid, account.provider == .antigravity else {
            throw UsageReadError.antigravityNotRunning
        }

        do {
            let live = try await fetchLive(account: account)
            UsageSnapshotCache.save(live, accountID: account.id, directory: cacheDirectory)
            return live
        } catch let error as UsageReadError where error == .antigravityNotRunning {
            if let cached = cachedFallback(accountID: account.id, now: Date(), cacheDirectory: cacheDirectory) {
                return cached
            }
            throw error
        }
    }

    static func cachedFallback(
        accountID: String,
        now: Date,
        cacheDirectory: URL
    ) -> ProviderUsage? {
        guard let cached = UsageSnapshotCache.load(accountID: accountID, directory: cacheDirectory) else {
            return nil
        }
        // If a quota window's reset timestamp has already passed while Antigravity was closed,
        // reflect that the window has reset to full capacity rather than showing a past countdown.
        let adjustedLimits = cached.limits.map { limit -> UsageLimit in
            if let reset = limit.resetsAt, reset <= now {
                return UsageLimit(
                    id: limit.id,
                    label: limit.label,
                    usedPercent: 0,
                    resetsAt: nil,
                    durationMinutes: limit.durationMinutes,
                    displayMode: limit.displayMode
                )
            }
            return limit
        }
        return ProviderUsage(
            provider: .antigravity,
            limits: adjustedLimits,
            updatedAt: cached.updatedAt,
            sourceDescription: "Antigravity cache · open Antigravity to update",
            isStale: true,
            planName: cached.planName,
            footnote: cached.footnote
        )
    }

    private static func fetchLive(account: ProviderAccount) async throws -> ProviderUsage {
        let targets = await Task.detached(priority: .utility) {
            discoverTargets(account: account)
        }.value
        guard !targets.isEmpty else {
            throw UsageReadError.antigravityNotRunning
        }

        var sawMalformed = false
        for target in targets {
            for port in target.ports {
                for scheme in ["http", "https"] {
                    do {
                        let data = try await queryUserStatus(scheme: scheme, port: port, csrfToken: target.csrfToken)
                        try Task.checkCancellation()
                        return try parse(data: data, now: Date())
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch UsageReadError.malformedAntigravityResponse {
                        sawMalformed = true
                    } catch {
                        continue
                    }
                }
            }
        }
        throw sawMalformed ? UsageReadError.malformedAntigravityResponse : UsageReadError.antigravityNotRunning
    }

    private static func queryUserStatus(scheme: String, port: Int, csrfToken: String) async throws -> Data {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus") else {
            throw UsageReadError.antigravityNotRunning
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2.5
        request.httpShouldHandleCookies = false
        request.httpBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")

        let client = scheme == "https" ? loopbackTLSClient : plainLoopbackClient
        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UsageReadError.antigravityNotRunning
        }
        return data
    }

    public static func parse(data: Data, now: Date) throws -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userStatus = (root["userStatus"] as? [String: Any]) ?? (root["cascadeModelConfigData"] != nil ? root : nil) else {
            throw UsageReadError.malformedAntigravityResponse
        }

        let userTier = userStatus["userTier"] as? [String: Any]
        let planStatus = userStatus["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]
        let planName = AccountPlan.antigravity(
            tierName: userTier?["name"] as? String,
            planName: planInfo?["planName"] as? String
        )
        let footnote = parseCreditsFootnote(from: userTier)

        let cascade = userStatus["cascadeModelConfigData"] as? [String: Any]
        let configs = (cascade?["clientModelConfigs"] as? [[String: Any]]) ?? []
        let limits = groupQuotaLimits(configs: configs)

        guard !limits.isEmpty else {
            throw UsageReadError.malformedAntigravityResponse
        }

        return ProviderUsage(
            provider: .antigravity,
            limits: limits,
            updatedAt: now,
            sourceDescription: "Live local Antigravity status",
            planName: planName,
            footnote: footnote
        )
    }

    // MARK: - Smart Quota Pool Grouping

    private enum MacroPool: Int, Comparable {
        case gemini = 0
        case claudeGPT = 1
        case other = 2

        static func < (lhs: MacroPool, rhs: MacroPool) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct RawModelQuota {
        let macro: MacroPool
        let subFamily: String
        let usedPercent: Double
        let resetsAt: Date?
    }

    private static func groupQuotaLimits(configs: [[String: Any]]) -> [UsageLimit] {
        var entries: [RawModelQuota] = []
        for config in configs {
            guard let rawLabel = config["label"] as? String,
                  let quotaInfo = config["quotaInfo"] as? [String: Any] else { continue }
            let resetDate = parseDate(quotaInfo["resetTime"] as? String)

            let usedPercent: Double
            if let number = quotaInfo["remainingFraction"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite {
                let clamped = min(max(number.doubleValue, 0), 1)
                usedPercent = (1.0 - clamped) * 100.0
            } else if resetDate != nil {
                // In Protobuf3 JSON, remainingFraction == 0.0 is omitted as default scalar value.
                usedPercent = 100.0
            } else {
                continue
            }

            let baseName = stripEffortSuffix(rawLabel)
            let (macro, subFamily) = classifyModel(baseName)
            entries.append(RawModelQuota(macro: macro, subFamily: subFamily, usedPercent: usedPercent, resetsAt: resetDate))
        }

        guard !entries.isEmpty else { return [] }

        var limits: [UsageLimit] = []
        for macro in [MacroPool.gemini, .claudeGPT, .other] {
            let groupEntries = entries.filter { $0.macro == macro }
            guard !groupEntries.isEmpty else { continue }

            struct BucketKey: Hashable {
                let tenthPercentUsed: Int
                let resetMinuteBucket: Int?
            }

            var bucketOrder: [BucketKey] = []
            var buckets: [BucketKey: [RawModelQuota]] = [:]
            for item in groupEntries {
                let key = BucketKey(
                    tenthPercentUsed: Int((item.usedPercent * 10).rounded()),
                    resetMinuteBucket: item.resetsAt.map { Int(($0.timeIntervalSince1970 / 60).rounded()) }
                )
                if buckets[key] == nil { bucketOrder.append(key) }
                buckets[key, default: []].append(item)
            }

            for (index, key) in bucketOrder.enumerated() {
                guard let items = buckets[key], let representative = items.first else { continue }
                let distinctFamilies = orderedUnique(items.map(\.subFamily))
                let label = poolDisplayLabel(
                    macro: macro,
                    families: distinctFamilies,
                    singleBucketForMacro: bucketOrder.count == 1
                )
                let worstUsed = items.map(\.usedPercent).max() ?? representative.usedPercent
                let earliestReset = items.compactMap(\.resetsAt).min()
                let slug = label.lowercased()
                    .replacingOccurrences(of: " & ", with: "-")
                    .replacingOccurrences(of: " ", with: "-")
                limits.append(
                    UsageLimit(
                        id: "antigravity-\(slug)-\(index)",
                        label: label,
                        usedPercent: worstUsed,
                        resetsAt: earliestReset,
                        durationMinutes: 300,
                        displayMode: .remaining
                    )
                )
            }
        }
        return limits
    }

    private static func poolDisplayLabel(
        macro: MacroPool,
        families: [String],
        singleBucketForMacro: Bool
    ) -> String {
        switch macro {
        case .gemini:
            if singleBucketForMacro { return "Gemini" }
            return families.joined(separator: " + ")
        case .claudeGPT:
            let hasClaude = families.contains { $0.hasPrefix("Claude") }
            let hasGPT = families.contains { $0.hasPrefix("GPT") }
            if singleBucketForMacro {
                if hasClaude && hasGPT { return "Claude & GPT" }
                if hasClaude { return "Claude" }
                if hasGPT { return "GPT" }
            }
            return families.joined(separator: " + ")
        case .other:
            return families.joined(separator: " + ")
        }
    }

    private static func stripEffortSuffix(_ label: String) -> String {
        var result = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [" (High)", " (Medium)", " (Low)", " (Thinking)", " (Fast)"]
        for suffix in suffixes where result.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
        }
        return result
    }

    private static func classifyModel(_ baseName: String) -> (MacroPool, String) {
        let lower = baseName.lowercased()
        if lower.contains("gemini") {
            if lower.contains("flash") || lower.contains("lite") {
                return (.gemini, "Gemini Flash")
            }
            return (.gemini, "Gemini Pro")
        }
        if lower.contains("claude") {
            if lower.contains("opus") { return (.claudeGPT, "Claude Opus") }
            if lower.contains("sonnet") { return (.claudeGPT, "Claude Sonnet") }
            if lower.contains("haiku") { return (.claudeGPT, "Claude Haiku") }
            return (.claudeGPT, "Claude")
        }
        if lower.contains("gpt") || lower.contains("o1") || lower.contains("o3") || lower.contains("o4") {
            return (.claudeGPT, "GPT")
        }
        return (.other, baseName)
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func parseCreditsFootnote(from userTier: [String: Any]?) -> String? {
        guard let credits = userTier?["availableCredits"] as? [[String: Any]] else { return nil }
        for entry in credits {
            let rawAmount = entry["creditAmount"]
            let amount: Int?
            if let str = rawAmount as? String { amount = Int(str) }
            else if let num = rawAmount as? NSNumber { amount = num.intValue }
            else { amount = nil }
            if let amount, amount >= 0 {
                let formatted = NumberFormatter.localizedString(from: NSNumber(value: amount), number: .decimal)
                return "\(formatted) AI credits available"
            }
        }
        return nil
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    // MARK: - Process Discovery

    static func discoverTargets(account: ProviderAccount) -> [ServerTarget] {
        guard let psOutput = runCommand(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid,command"]) else {
            return []
        }
        return parseTargets(psOutput: psOutput) { pid in
            guard let lsofOutput = runCommand(
                URL(fileURLWithPath: "/usr/sbin/lsof"),
                ["-Pan", "-p", pid, "-iTCP", "-sTCP:LISTEN"]
            ) else { return [] }
            return parseListeningPorts(lsofOutput: lsofOutput)
        }
    }

    static func parseTargets(
        psOutput: String,
        portsProvider: (String) -> [Int]
    ) -> [ServerTarget] {
        var targets: [ServerTarget] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("language_server"),
                  line.localizedCaseInsensitiveContains("antigravity"),
                  let csrf = extractFlag("--csrf_token", from: line) else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let pid = parts.first.map(String.init), !pid.isEmpty else { continue }
            let ports = portsProvider(pid)
            guard !ports.isEmpty else { continue }
            targets.append(ServerTarget(pid: pid, csrfToken: csrf, ports: ports))
        }
        return targets
    }

    static func parseListeningPorts(lsofOutput: String) -> [Int] {
        var ports: [Int] = []
        var seen = Set<Int>()
        for line in lsofOutput.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "127.0.0.1:") else { continue }
            let suffix = line[range.upperBound...]
            let digits = suffix.prefix(while: \.isNumber)
            if let port = Int(digits), port > 0, seen.insert(port).inserted {
                ports.append(port)
            }
        }
        return ports
    }

    private static func extractFlag(_ flag: String, from commandLine: String) -> String? {
        let tokens = commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, token) in tokens.enumerated() {
            if token == flag, index + 1 < tokens.count {
                return tokens[index + 1]
            }
            if token.hasPrefix(flag + "=") {
                return String(token.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    private static func runCommand(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 3) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static let plainLoopbackClient = URLSession(configuration: .ephemeral)
    private static let loopbackTLSClient = URLSession(
        configuration: .ephemeral,
        delegate: LoopbackTLSDelegate(),
        delegateQueue: nil
    )
}

/// Accepts self-signed TLS certificates strictly on `127.0.0.1` for Antigravity's local language_server.
private final class LoopbackTLSDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "127.0.0.1",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

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
