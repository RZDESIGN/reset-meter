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
    private static let hiddenEntriesKey = "hiddenUsageEntries.v1"
    @Published private(set) var hiddenEntryIDs: Set<String>
    @Published private(set) var claude: ProviderUsage?
    @Published private(set) var cursor: ProviderUsage?
    @Published private(set) var claudeError: String?
    @Published private(set) var cursorError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private var refreshTimer: Timer?
    private let codexFetcher: @Sendable (CodexAccount) async throws -> ProviderUsage
    private let claudeFetcher: @Sendable () async throws -> ProviderUsage
    private let cursorFetcher: @Sendable () async throws -> ProviderUsage

    init(
        autoRefresh: Bool = true,
        preferences: UserDefaults = .standard,
        codexFetcher: @escaping @Sendable (CodexAccount) async throws -> ProviderUsage = { try await CodexUsageReader.fetch(account: $0) },
        claudeFetcher: @escaping @Sendable () async throws -> ProviderUsage = { try await ClaudeUsageReader.fetch() },
        cursorFetcher: @escaping @Sendable () async throws -> ProviderUsage = { try await CursorUsageReader.fetch() }
    ) {
        self.preferences = preferences
        hiddenEntryIDs = Set(preferences.stringArray(forKey: Self.hiddenEntriesKey) ?? [])
        self.codexFetcher = codexFetcher
        self.claudeFetcher = claudeFetcher
        self.cursorFetcher = cursorFetcher
        let saved = preferences.data(forKey: Self.accountsKey)
            .flatMap { try? JSONDecoder().decode([CodexAccount].self, from: $0) } ?? []
        var seen = Set<String>()
        let valid = saved.filter {
            ($0.isDefault || $0.homeDirectory != nil) && seen.insert($0.id).inserted
        }
        codexAccounts = valid.isEmpty ? [.defaultAccount] : valid
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
            ])
        )

        let claudeFiveHourReset = now.addingTimeInterval(
            TimeInterval(1 * 3_600 + 38 * 60 + 50)
        )
        let claudeFiveHourLimit = UsageLimit(
            id: "claude-demo-five-hour",
            label: "5-hour",
            usedPercent: 42,
            resetsAt: claudeFiveHourReset,
            resetIsEstimated: true,
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
            resetIsEstimated: true,
            durationMinutes: 10_080,
            displayMode: .remaining
        )
        let claudeDemo = ProviderUsage(
            provider: .claude,
            limits: [claudeFiveHourLimit, claudeWeeklyLimit],
            updatedAt: now,
            sourceDescription: "Claude Desktop cache"
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
                ])
            )
        }
        claude = claudeDemo
        cursor = cursorDemo
        codexErrors = [:]
        claudeError = nil
        cursorError = nil
        lastRefresh = now
    }

    var entries: [UsageEntry] {
        codexAccounts.map {
            UsageEntry(provider: .codex, account: $0, usage: codexUsage[$0.id],
                       error: codexErrors[$0.id] ?? ($0.isDefault ? nil : "Sign in from Providers to load usage."))
        } + [
            UsageEntry(provider: .claude, usage: claude, error: claudeError),
            UsageEntry(provider: .cursor, usage: cursor, error: cursorError),
        ]
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
    /// own meters, so a second Codex login does not repeat the icon.
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

    func addAccount(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, signingInAccountID == nil, !isRefreshing else { return }
        let account = CodexAccount(name: trimmed)
        codexAccounts.append(account)
        saveAccounts()
        signIn(account)
    }

    func renameAccount(_ account: CodexAccount, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = codexAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        codexAccounts[index].name = trimmed
        saveAccounts()
    }

    func removeAccount(_ account: CodexAccount) {
        guard !account.isDefault, !isRefreshing, signingInAccountID == nil else { return }
        do {
            if let home = account.homeDirectory, FileManager.default.fileExists(atPath: home.path) {
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

    func signIn(_ account: CodexAccount) {
        guard !account.isDefault, signingInAccountID == nil, !isRefreshing else { return }
        signingInAccountID = account.id
        accountError = nil
        signInTask = Task { [weak self] in
            do {
                try await CodexUsageReader.signIn(account: account)
                try Task.checkCancellation()
                self?.codexUsage[account.id] = nil
                self?.codexErrors[account.id] = nil
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
    }

    func refresh() async {
        guard !isRefreshing, signingInAccountID == nil else { return }
        isRefreshing = true

        let accounts = codexAccounts
        let fetchCodex = codexFetcher
        let codexTask = Task {
            await withTaskGroup(of: (String, ProviderUsage?, String?).self) { group in
                for account in accounts {
                    group.addTask {
                        do { return (account.id, try await fetchCodex(account), nil) }
                        catch { return (account.id, nil, error.localizedDescription) }
                    }
                }
                var results: [(String, ProviderUsage?, String?)] = []
                for await result in group { results.append(result) }
                return results
            }
        }
        let claudeTask = Task { try await claudeFetcher() }
        let cursorTask = Task { try await cursorFetcher() }

        for (id, usage, error) in await codexTask.value {
            guard codexAccounts.contains(where: { $0.id == id }) else { continue }
            codexUsage[id] = usage
            codexErrors[id] = error
        }

        do {
            claude = try await claudeTask.value
            claudeError = nil
        } catch {
            claudeError = error.localizedDescription
        }

        do {
            cursor = try await cursorTask.value
            cursorError = nil
        } catch {
            cursorError = error.localizedDescription
        }

        lastRefresh = Date()
        isRefreshing = false
    }

}
