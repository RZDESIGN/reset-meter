import Foundation
import UsageMeterCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var codexAccounts: [CodexAccount]
    @Published private(set) var codexUsage: [String: ProviderUsage] = [:]
    @Published private(set) var codexErrors: [String: String] = [:]
    @Published private(set) var signingInAccountID: String?
    @Published private(set) var accountError: String?
    private var signInTask: Task<Void, Never>?
    private let preferences: UserDefaults
    private static let accountsKey = "codexAccounts.v1"
    private static let claudeAccountsKey = "claudeAccounts.v1"
    private static let cursorAccountsKey = "cursorAccounts.v1"
    private static let hiddenEntriesKey = "hiddenUsageEntries.v1"
    @Published private(set) var hiddenEntryIDs: Set<String>
    @Published private(set) var claudeAccounts: [ClaudeAccount]
    @Published private(set) var claudeUsage: [String: ProviderUsage] = [:]
    @Published private(set) var claudeErrors: [String: String] = [:]
    @Published private(set) var cursorAccounts: [CursorAccount]
    @Published private(set) var cursorUsage: [String: ProviderUsage] = [:]
    @Published private(set) var cursorErrors: [String: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private var refreshTimer: Timer?
    private let codexFetcher: @Sendable (CodexAccount) async throws -> ProviderUsage
    private let claudeFetcher: @Sendable (ClaudeAccount) async throws -> ProviderUsage
    private let codexSigner: @Sendable (CodexAccount) async throws -> Void
    private let claudeSigner: @Sendable (ClaudeAccount) async throws -> Void
    private let claudeLoginRemover: @Sendable (ClaudeAccount) throws -> Void
    private let cursorFetcher: @Sendable (CursorAccount) async throws -> ProviderUsage
    private let cursorSigner: @Sendable (CursorAccount) async throws -> Void
    private let cursorLoginRemover: @Sendable (CursorAccount) throws -> Void

    init(
        autoRefresh: Bool = true,
        preferences: UserDefaults = .standard,
        codexFetcher: @escaping @Sendable (CodexAccount) async throws -> ProviderUsage = { try await CodexUsageReader.fetch(account: $0) },
        claudeFetcher: @escaping @Sendable (ClaudeAccount) async throws -> ProviderUsage = { try await ClaudeUsageReader.fetch(account: $0) },
        codexSigner: @escaping @Sendable (CodexAccount) async throws -> Void = { try await CodexUsageReader.signIn(account: $0) },
        claudeSigner: @escaping @Sendable (ClaudeAccount) async throws -> Void = { try await ClaudeUsageReader.signIn(account: $0) },
        claudeLoginRemover: @escaping @Sendable (ClaudeAccount) throws -> Void = { try ClaudeUsageReader.removeLogin(account: $0) },
        cursorFetcher: @escaping @Sendable (CursorAccount) async throws -> ProviderUsage = { try await CursorUsageReader.fetch(account: $0) },
        cursorSigner: @escaping @Sendable (CursorAccount) async throws -> Void = { try await CursorUsageReader.signIn(account: $0) },
        cursorLoginRemover: @escaping @Sendable (CursorAccount) throws -> Void = { try CursorUsageReader.removeLogin(account: $0) }
    ) {
        self.preferences = preferences
        hiddenEntryIDs = Set(preferences.stringArray(forKey: Self.hiddenEntriesKey) ?? [])
        self.codexFetcher = codexFetcher
        self.claudeFetcher = claudeFetcher
        self.codexSigner = codexSigner
        self.claudeSigner = claudeSigner
        self.claudeLoginRemover = claudeLoginRemover
        self.cursorFetcher = cursorFetcher
        self.cursorSigner = cursorSigner
        self.cursorLoginRemover = cursorLoginRemover
        let saved = preferences.data(forKey: Self.accountsKey)
            .flatMap { try? JSONDecoder().decode([CodexAccount].self, from: $0) } ?? []
        var seen = Set<String>()
        let valid = saved.filter {
            $0.isValid && seen.insert($0.id).inserted
        }
        codexAccounts = valid.isEmpty ? [.defaultAccount] : valid
        let savedClaude = preferences.data(forKey: Self.claudeAccountsKey)
            .flatMap { try? JSONDecoder().decode([ClaudeAccount].self, from: $0) } ?? []
        var seenClaude = Set<String>()
        let validClaude = savedClaude.filter {
            $0.isValid && seenClaude.insert($0.id).inserted
        }
        claudeAccounts = validClaude.isEmpty ? [.defaultAccount] : validClaude
        let savedCursor = preferences.data(forKey: Self.cursorAccountsKey)
            .flatMap { try? JSONDecoder().decode([CursorAccount].self, from: $0) } ?? []
        var seenCursor = Set<String>()
        let validCursor = savedCursor.filter { $0.isValid && seenCursor.insert($0.id).inserted }
        cursorAccounts = validCursor.isEmpty ? [.defaultAccount] : validCursor
        if hiddenEntryIDs.remove("claude") != nil {
            hiddenEntryIDs.insert("claude:default")
            preferences.set(hiddenEntryIDs.sorted(), forKey: Self.hiddenEntriesKey)
        }
        if autoRefresh {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
            }

            Task { [weak self] in
                await self?.refresh()
            }
        }
    }

    func loadDemoData(now: Date = .now, multipleAccounts: Bool = false) {
        hiddenEntryIDs = []
        let codexReset = now.addingTimeInterval(
            TimeInterval(6 * 86_400 + 16 * 3_600 + 59 * 60)
        )
        let codexLimit = UsageLimit(
            id: "codex-demo-weekly",
            label: "Weekly",
            usedPercent: 19,
            resetsAt: codexReset,
            durationMinutes: 10_080,
            displayMode: .remaining
        )
        let codexDemo = ProviderUsage(
            provider: .codex,
            limits: [codexLimit],
            updatedAt: now,
            sourceDescription: "Live Codex status",
            bankedResets: BankedResets(availableCount: 2, credits: [
                BankedReset(id: "demo-reset-1", expiration: .date(now.addingTimeInterval(2 * 86_400))),
                BankedReset(id: "demo-reset-2", expiration: .date(now.addingTimeInterval(14 * 86_400)))
            ]),
            planName: "Pro"
        )

        let claudeFiveHourReset = now.addingTimeInterval(
            TimeInterval(1 * 3_600 + 38 * 60 + 50)
        )
        let claudeFiveHourLimit = UsageLimit(
            id: "claude-demo-five-hour",
            label: "5-hour",
            usedPercent: 42,
            resetsAt: claudeFiveHourReset,
            durationMinutes: 300,
            displayMode: .remaining
        )
        let claudeWeeklyReset = now.addingTimeInterval(
            TimeInterval(5 * 86_400 + 17 * 3_600 + 59 * 60)
        )
        let claudeWeeklyLimit = UsageLimit(
            id: "claude-demo-weekly",
            label: "Weekly",
            usedPercent: 56,
            resetsAt: claudeWeeklyReset,
            durationMinutes: 10_080,
            displayMode: .remaining
        )
        let claudeDemo = ProviderUsage(
            provider: .claude,
            limits: [claudeFiveHourLimit, claudeWeeklyLimit],
            updatedAt: now,
            sourceDescription: "Live Claude account usage",
            planName: "Max 5×"
        )

        let cursorReset = now.addingTimeInterval(
            TimeInterval(14 * 86_400 + 12 * 3_600 + 59 * 60)
        )
        let cursorLimit = UsageLimit(
            id: "cursor-demo-included",
            label: "Composer + Grok",
            usedPercent: 14,
            resetsAt: cursorReset,
            displayMode: .remaining
        )
        let cursorDemo = ProviderUsage(
            provider: .cursor,
            limits: [cursorLimit],
            updatedAt: now,
            sourceDescription: "Live Cursor first-party pool"
        )

        codexAccounts = [.defaultAccount]
        codexUsage = [CodexAccount.defaultAccount.id: codexDemo]
        claudeAccounts = [.defaultAccount]
        claudeUsage = [ClaudeAccount.defaultAccount.id: claudeDemo]
        if multipleAccounts {
            let second = CodexAccount(name: "Work")
            codexAccounts[0].name = "Personal"
            codexAccounts.append(second)
            codexUsage[second.id] = ProviderUsage(
                provider: .codex,
                limits: [UsageLimit(id: "second-weekly", label: "Weekly", usedPercent: 63,
                    resetsAt: now.addingTimeInterval(2 * 86_400), durationMinutes: 10_080,
                    displayMode: .remaining)],
                updatedAt: now, sourceDescription: "Live Codex status",
                bankedResets: BankedResets(availableCount: 1, credits: [
                    BankedReset(id: "demo-work-reset", expiration: .date(now.addingTimeInterval(7 * 86_400)))
                ]), planName: "Business"
            )
            let claudeWork = ClaudeAccount(name: "Work")
            claudeAccounts[0].name = "Personal"
            claudeAccounts.append(claudeWork)
            claudeUsage[claudeWork.id] = ProviderUsage(
                provider: .claude,
                limits: [UsageLimit(id: "claude-work-weekly", label: "Weekly", usedPercent: 18,
                    resetsAt: now.addingTimeInterval(3 * 86_400), durationMinutes: 10_080,
                    displayMode: .remaining)],
                updatedAt: now, sourceDescription: "Live Claude account usage", planName: "Pro"
            )
        }
        cursorAccounts = [.defaultAccount]
        cursorUsage = ["default": cursorDemo]
        codexErrors = [:]
        claudeErrors = [:]
        cursorErrors = [:]
        lastRefresh = now
    }

    var entries: [UsageEntry] {
        codexAccounts.map {
            UsageEntry(provider: .codex, account: $0, usage: codexUsage[$0.id],
                       error: codexErrors[$0.id] ?? (codexUsage[$0.id] == nil && $0.mode == .login ? "Sign in from Providers to load usage." : nil))
        } + claudeAccounts.map {
            UsageEntry(provider: .claude, claudeAccount: $0, usage: claudeUsage[$0.id],
                       error: claudeErrors[$0.id] ?? (claudeUsage[$0.id] == nil && $0.mode == .login ? "Sign in from Providers to load usage." : nil))
        } + cursorAccounts.map {
            UsageEntry(provider: .cursor, cursorAccount: $0, usage: cursorUsage[$0.id],
                       error: cursorErrors[$0.id] ?? (cursorUsage[$0.id] == nil && $0.mode == .login ? "Sign in from Providers to load usage." : nil))
        }
    }

    var visibleEntries: [UsageEntry] {
        entries.filter { isVisible($0.id) }
    }

    func isVisible(_ entryID: String) -> Bool { !hiddenEntryIDs.contains(entryID) }

    func setVisible(_ visible: Bool, entryID: String) {
        guard entries.contains(where: { $0.id == entryID }) else { return }
        if visible { hiddenEntryIDs.remove(entryID) }
        else { hiddenEntryIDs.insert(entryID) }
        preferences.set(hiddenEntryIDs.sorted(), forKey: Self.hiddenEntriesKey)
    }

    var menuEntries: [(UsageProvider, Int?)] {
        visibleEntries.map { ($0.provider, $0.usage?.headlinePercent) }
    }

    /// Accounts of one provider share a single menu-bar logo followed by their
    /// own meters, so additional logins do not repeat the icon.
    var menuGroups: [(provider: UsageProvider, percents: [Int?])] {
        menuEntries.reduce(into: []) { groups, entry in
            if let last = groups.indices.last, groups[last].provider == entry.0 {
                groups[last].percents.append(entry.1)
            } else {
                groups.append((provider: entry.0, percents: [entry.1]))
            }
        }
    }

    var menuSummary: String {
        guard !visibleEntries.isEmpty else { return "Reset Meter. All meters hidden. Open Providers to show them." }
        return visibleEntries.map {
            "\($0.displayName) \($0.usage?.headlinePercent.map { "\($0)%" } ?? "unavailable") remaining"
        }.joined(separator: ", ")
    }

    func addAccount(name: String, provider: UsageProvider = .codex, mode: ConnectionMode = .login) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, signingInAccountID == nil, !isRefreshing else { return }
        switch provider {
        case .codex:
            let account = CodexAccount(name: trimmed, mode: mode)
            codexAccounts.append(account)
            saveAccounts()
            if mode == .login { signIn(account) }
        case .claude:
            let account = ClaudeAccount(name: trimmed, mode: mode)
            claudeAccounts.append(account)
            saveAccounts()
            if mode == .login { signIn(account) }
        case .cursor:
            let account = CursorAccount(name: trimmed, mode: mode)
            cursorAccounts.append(account)
            saveAccounts()
            if mode == .login { signIn(account) }
        }
        if mode == .local { Task { await refresh() } }
    }

    func setMode(_ mode: ConnectionMode, entryID: String) {
        guard !isRefreshing, signingInAccountID == nil else { return }
        if let index = codexAccounts.firstIndex(where: { "codex:\($0.id)" == entryID }) {
            guard codexAccounts[index].mode != mode else { return }
            codexAccounts[index].mode = mode
            codexUsage[codexAccounts[index].id] = nil
            codexErrors[codexAccounts[index].id] = nil
        } else if let index = claudeAccounts.firstIndex(where: { "claude:\($0.id)" == entryID }) {
            guard claudeAccounts[index].mode != mode else { return }
            claudeAccounts[index].mode = mode
            claudeUsage[claudeAccounts[index].id] = nil
            claudeErrors[claudeAccounts[index].id] = nil
        } else if let index = cursorAccounts.firstIndex(where: { $0.entryID == entryID }) {
            guard cursorAccounts[index].mode != mode else { return }
            cursorAccounts[index].mode = mode
            cursorUsage[cursorAccounts[index].id] = nil
            cursorErrors[cursorAccounts[index].id] = nil
        } else { return }
        accountError = nil
        saveAccounts()
    }

    func renameAccount(_ account: CodexAccount, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = codexAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        codexAccounts[index].name = trimmed
        saveAccounts()
    }

    func removeAccount(_ account: CodexAccount) {
        guard !account.isDefault, !isRefreshing, signingInAccountID == nil,
              codexAccounts.contains(where: { $0.id == account.id }) else { return }
        do {
            if let home = account.loginDirectory, FileManager.default.fileExists(atPath: home.path) {
                try FileManager.default.removeItem(at: home)
            }
            codexAccounts.removeAll { $0.id == account.id }
            codexUsage.removeValue(forKey: account.id)
            codexErrors.removeValue(forKey: account.id)
            hiddenEntryIDs.remove("codex:\(account.id)")
            preferences.set(hiddenEntryIDs.sorted(), forKey: Self.hiddenEntriesKey)
            saveAccounts()
            accountError = nil
        } catch {
            accountError = "Could not remove this account's local login. Try again."
        }
    }

    func renameAccount(_ account: ClaudeAccount, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = claudeAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        claudeAccounts[index].name = trimmed
        saveAccounts()
    }

    func removeAccount(_ account: ClaudeAccount) {
        guard !account.isDefault, !isRefreshing, signingInAccountID == nil,
              claudeAccounts.contains(where: { $0.id == account.id }) else { return }
        do {
            try claudeLoginRemover(account)
            claudeAccounts.removeAll { $0.id == account.id }
            claudeUsage.removeValue(forKey: account.id)
            claudeErrors.removeValue(forKey: account.id)
            hiddenEntryIDs.remove("claude:\(account.id)")
            preferences.set(hiddenEntryIDs.sorted(), forKey: Self.hiddenEntriesKey)
            saveAccounts()
            accountError = nil
        } catch {
            accountError = "Could not remove this account's local login. Try again."
        }
    }

    func signIn(_ account: CodexAccount) {
        guard signingInAccountID == nil, !isRefreshing,
              let account = codexAccounts.first(where: { $0.id == account.id }), account.mode == .login else { return }
        codexUsage[account.id] = nil
        codexErrors[account.id] = nil
        let signer = codexSigner
        startSignIn(entryID: "codex:\(account.id)") { try await signer(account) }
    }

    func signIn(_ account: ClaudeAccount) {
        guard signingInAccountID == nil, !isRefreshing,
              let account = claudeAccounts.first(where: { $0.id == account.id }), account.mode == .login else { return }
        claudeUsage[account.id] = nil
        claudeErrors[account.id] = nil
        let signer = claudeSigner
        startSignIn(entryID: "claude:\(account.id)") { try await signer(account) }
    }

    func renameAccount(_ account: CursorAccount, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = cursorAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        cursorAccounts[index].name = trimmed
        saveAccounts()
    }

    func removeAccount(_ account: CursorAccount) {
        guard !account.isDefault, !isRefreshing, signingInAccountID == nil,
              cursorAccounts.contains(where: { $0.id == account.id }) else { return }
        do {
            try cursorLoginRemover(account)
            cursorAccounts.removeAll { $0.id == account.id }
            cursorUsage[account.id] = nil
            cursorErrors[account.id] = nil
            hiddenEntryIDs.remove(account.entryID)
            preferences.set(hiddenEntryIDs.sorted(), forKey: Self.hiddenEntriesKey)
            saveAccounts()
            accountError = nil
        } catch {
            accountError = "Could not remove this account's Reset Meter login. Try again."
        }
    }

    func signIn(_ account: CursorAccount) {
        guard signingInAccountID == nil, !isRefreshing,
              let account = cursorAccounts.first(where: { $0.id == account.id }), account.mode == .login else { return }
        cursorUsage[account.id] = nil
        cursorErrors[account.id] = nil
        let signer = cursorSigner
        startSignIn(entryID: account.entryID) { try await signer(account) }
    }

    private func startSignIn(entryID: String, operation: @escaping @Sendable () async throws -> Void) {
        signingInAccountID = entryID
        accountError = nil
        signInTask = Task { [weak self] in
            do {
                try await operation()
                try Task.checkCancellation()
                self?.signingInAccountID = nil
                await self?.refresh()
            } catch is CancellationError {
                self?.signingInAccountID = nil
            } catch {
                self?.accountError = error.localizedDescription
                self?.signingInAccountID = nil
            }
            self?.signInTask = nil
        }
    }

    func cancelSignIn() { signInTask?.cancel() }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(codexAccounts) {
            preferences.set(data, forKey: Self.accountsKey)
        }
        if let data = try? JSONEncoder().encode(claudeAccounts) {
            preferences.set(data, forKey: Self.claudeAccountsKey)
        }
        if let data = try? JSONEncoder().encode(cursorAccounts) {
            preferences.set(data, forKey: Self.cursorAccountsKey)
        }
    }

    func refresh() async {
        guard !isRefreshing, signingInAccountID == nil else { return }
        isRefreshing = true

        async let codexResults = Self.fetchAccounts(codexAccounts, using: codexFetcher)
        async let claudeResults = Self.fetchAccounts(claudeAccounts, using: claudeFetcher)
        async let cursorResults = Self.fetchAccounts(cursorAccounts, using: cursorFetcher)

        for (id, usage, error) in await codexResults {
            guard codexAccounts.contains(where: { $0.id == id }) else { continue }
            codexUsage[id] = usage
            codexErrors[id] = error
        }
        for (id, usage, error) in await claudeResults {
            guard claudeAccounts.contains(where: { $0.id == id }) else { continue }
            claudeUsage[id] = usage
            claudeErrors[id] = error
        }

        for (id, usage, error) in await cursorResults {
            guard cursorAccounts.contains(where: { $0.id == id }) else { continue }
            cursorUsage[id] = usage
            cursorErrors[id] = error
        }

        lastRefresh = Date()
        isRefreshing = false
    }

    private nonisolated static func fetchAccounts<Account: UsageAccount>(
        _ accounts: [Account], using fetcher: @escaping @Sendable (Account) async throws -> ProviderUsage
    ) async -> [(String, ProviderUsage?, String?)] {
        await withTaskGroup(of: (String, ProviderUsage?, String?).self) { group in
            // All Local cards of a provider share one account. Fetch it once so
            // simultaneous token renewals cannot race against each other.
            let local = accounts.first(where: { $0.mode == .local })
            for account in accounts where account.mode == .login || account.id == local?.id {
                group.addTask {
                    do { return (account.id, try await fetcher(account), nil) }
                    catch { return (account.id, nil, error.localizedDescription) }
                }
            }
            var results: [(String, ProviderUsage?, String?)] = []
            for await result in group {
                results.append(result)
                if result.0 == local?.id {
                    for account in accounts where account.mode == .local && account.id != result.0 {
                        results.append((account.id, result.1, result.2))
                    }
                }
            }
            return results
        }
    }

}
