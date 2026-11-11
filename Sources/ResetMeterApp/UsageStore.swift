import Foundation
import UsageMeterCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [ProviderAccount]
    @Published private(set) var usageByID: [String: ProviderUsage] = [:]
    @Published private(set) var errorsByID: [String: String] = [:]
    @Published private(set) var localPlansByID: [String: String] = [:]
    @Published private(set) var connectingCursorIDs: Set<String> = []
    @Published private(set) var savedCursorSessionIDs: Set<String> = []
    @Published private(set) var hiddenEntryIDs: Set<String>
    @Published var menuBarStyle: MenuBarStyle {
        didSet {
            preferences.set(menuBarStyle.rawValue, forKey: Self.menuBarStyleKey)
        }
    }
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private let preferences: UserDefaults
    private static let accountsKey = "localAccounts.v2"
    private static let hiddenEntriesKey = "hiddenUsageEntries.v2"
    private static let legacyHiddenEntriesKey = "hiddenUsageEntries.v1"
    private static let menuBarStyleKey = "menuBarStyle.v1"

    private var refreshTimer: Timer?
    private var cursorConnectTasks: [String: Task<Void, Never>] = [:]
    private let fetcher: @Sendable (ProviderAccount) async throws -> ProviderUsage
    private let cursorSignIn: @Sendable (ProviderAccount) async throws -> Void
    private let discoverer: @Sendable () -> [ProviderAccount]
    private let antigravityInstalled: @Sendable () -> Bool
    private let cursorInstalled: @Sendable () -> Bool

    init(
        autoRefresh: Bool = true,
        preferences: UserDefaults = .standard,
        discoverer: @escaping @Sendable () -> [ProviderAccount] = { LocalInstallationDiscovery.discoverAll() },
        antigravityInstalled: @escaping @Sendable () -> Bool = { LocalInstallationDiscovery.isAntigravityInstalled() },
        cursorInstalled: @escaping @Sendable () -> Bool = { LocalInstallationDiscovery.isCursorInstalled() },
        cursorSignIn: @escaping @Sendable (ProviderAccount) async throws -> Void = { try await CursorLogin.signIn(account: $0) },
        fetcher: (@Sendable (ProviderAccount) async throws -> ProviderUsage)? = nil
    ) {
        self.preferences = preferences
        self.discoverer = discoverer
        self.antigravityInstalled = antigravityInstalled
        self.cursorInstalled = cursorInstalled
        self.cursorSignIn = cursorSignIn
        self.fetcher = fetcher ?? Self.defaultFetch

        if let rawStyle = preferences.string(forKey: Self.menuBarStyleKey),
           let parsedStyle = MenuBarStyle(rawValue: rawStyle) {
            self.menuBarStyle = parsedStyle
        } else {
            self.menuBarStyle = .barsAndPercent
        }

        let discovered = Self.sanitizedAccounts(discoverer())
        let hadSavedV2 = preferences.data(forKey: Self.accountsKey) != nil
        let savedAccounts = preferences.data(forKey: Self.accountsKey)
            .flatMap { try? JSONDecoder().decode([ProviderAccount].self, from: $0) }
            .map(Self.sanitizedAccounts) ?? []

        let merged = Self.mergeAccounts(saved: savedAccounts, discovered: discovered)
        self.accounts = merged

        if let savedHidden = preferences.array(forKey: Self.hiddenEntriesKey) as? [String] {
            self.hiddenEntryIDs = Set(savedHidden)
        } else {
            // Migrate cleanly from v1 or fresh install: keep active local installations visible,
            // while hiding unconfigured optional tools (e.g. Cursor if previously hidden or not installed).
            var initialHidden = Set<String>()
            let legacyHidden = Set(preferences.stringArray(forKey: Self.legacyHiddenEntriesKey) ?? [])
            if legacyHidden.contains("cursor") || legacyHidden.contains("cursor:default") || !cursorInstalled() {
                initialHidden.insert("cursor:default")
            }
            if !antigravityInstalled() {
                initialHidden.insert("antigravity:default")
            }
            self.hiddenEntryIDs = initialHidden
            preferences.set(initialHidden.sorted(), forKey: Self.hiddenEntriesKey)
        }

        if !hadSavedV2 || merged != savedAccounts {
            saveAccounts()
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

    private nonisolated static func defaultFetch(_ account: ProviderAccount) async throws -> ProviderUsage {
        switch account.provider {
        case .codex:
            try await CodexUsageReader.fetch(account: account)
        case .claude:
            try await ClaudeUsageReader.fetch(account: account)
        case .antigravity:
            try await AntigravityUsageReader.fetch(account: account)
        case .cursor:
            try await CursorUsageReader.fetch(account: account)
        }
    }

    // MARK: - Entries & Menu Bar

    var entries: [UsageEntry] {
        let counts = Dictionary(grouping: accounts, by: \.provider).mapValues(\.count)
        return UsageProvider.allCases.flatMap { provider in
            accounts
                .filter { $0.provider == provider }
                .map { account in
                    UsageEntry(
                        account: account,
                        usage: usageByID[account.id],
                        error: errorsByID[account.id],
                        fallbackPlanName: localPlansByID[account.id],
                        hasMultipleProviderAccounts: (counts[provider] ?? 0) > 1,
                        isConnecting: connectingCursorIDs.contains(account.id),
                        canConnectCursor: provider == .cursor && usageByID[account.id] == nil && errorsByID[account.id] != nil,
                        hasSavedCursorSession: savedCursorSessionIDs.contains(account.id)
                    )
                }
        }
    }

    var visibleEntries: [UsageEntry] {
        entries.filter { isVisible($0.id) }
    }

    func isVisible(_ entryID: String) -> Bool {
        !hiddenEntryIDs.contains(entryID)
    }

    func setVisible(_ visible: Bool, entryID: String) {
        guard entries.contains(where: { $0.id == entryID }) else { return }
        if visible {
            hiddenEntryIDs.remove(entryID)
        } else {
            hiddenEntryIDs.insert(entryID)
        }
        preferences.set(hiddenEntryIDs.sorted(), forKey: Self.hiddenEntriesKey)
    }

    var menuEntries: [(UsageProvider, Int?)] {
        visibleEntries.map { ($0.provider, $0.usage?.headlinePercent) }
    }

    /// Accounts of one provider share a single menu-bar logo followed by their
    /// own meters, so additional local profiles do not repeat the icon.
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
        guard !visibleEntries.isEmpty else {
            return "Reset Meter. All meters hidden. Open Providers to show them."
        }
        return visibleEntries.map {
            "\($0.displayName) \($0.usage?.headlinePercent.map { "\($0)%" } ?? "unavailable") remaining"
        }.joined(separator: ", ")
    }

    // MARK: - Account Management & Local Discovery

    func rescanLocalInstallations() {
        guard !isRefreshing else { return }
        let discovered = Self.sanitizedAccounts(discoverer())
        accounts = Self.mergeAccounts(saved: accounts, discovered: discovered)
        saveAccounts()
        Task { await refresh() }
    }

    func addLocalAccount(
        name: String,
        provider: UsageProvider,
        profilePath: String,
        secondaryPath: String? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = profilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPath.isEmpty, !isRefreshing else { return }
        let account = ProviderAccount(
            provider: provider,
            name: trimmedName,
            profilePath: trimmedPath,
            secondaryPath: secondaryPath
        )
        guard account.isValid else { return }
        accounts.append(account)
        saveAccounts()
        Task { await refresh() }
    }

    func renameAccount(_ account: ProviderAccount, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].name = trimmed
        saveAccounts()
    }

    func removeAccount(_ account: ProviderAccount) {
        guard !account.isDefault, !isRefreshing,
              accounts.contains(where: { $0.id == account.id }) else { return }
        cancelCursorConnect(account)
        if account.provider == .cursor {
            CursorLogin.disconnect(account: account)
            savedCursorSessionIDs.remove(account.id)
        }
        accounts.removeAll { $0.id == account.id }
        usageByID.removeValue(forKey: account.id)
        errorsByID.removeValue(forKey: account.id)
        localPlansByID.removeValue(forKey: account.id)
        hiddenEntryIDs.remove(account.id)
        preferences.set(hiddenEntryIDs.sorted(), forKey: Self.hiddenEntriesKey)
        saveAccounts()
    }

    // MARK: - Cursor PKCE Connection (for Cursor 3.29+ encrypted storage)

    func connectCursor(_ account: ProviderAccount) {
        guard account.provider == .cursor,
              !connectingCursorIDs.contains(account.id) else { return }
        connectingCursorIDs.insert(account.id)
        errorsByID[account.id] = nil

        let signIn = self.cursorSignIn
        cursorConnectTasks[account.id] = Task { [weak self] in
            do {
                try await signIn(account)
                guard !Task.isCancelled else { return }
                await self?.finishCursorConnect(account: account, error: nil)
            } catch is CancellationError {
                return
            } catch {
                await self?.finishCursorConnect(account: account, error: error.localizedDescription)
            }
        }
    }

    func cancelCursorConnect(_ account: ProviderAccount) {
        cursorConnectTasks[account.id]?.cancel()
        cursorConnectTasks.removeValue(forKey: account.id)
        connectingCursorIDs.remove(account.id)
    }

    func disconnectCursor(_ account: ProviderAccount) {
        guard account.provider == .cursor else { return }
        cancelCursorConnect(account)
        CursorLogin.disconnect(account: account)
        savedCursorSessionIDs.remove(account.id)
        usageByID.removeValue(forKey: account.id)
        Task { await refresh() }
    }

    private func finishCursorConnect(account: ProviderAccount, error: String?) async {
        cursorConnectTasks.removeValue(forKey: account.id)
        connectingCursorIDs.remove(account.id)
        if let error {
            errorsByID[account.id] = error
        } else {
            savedCursorSessionIDs.insert(account.id)
            await refresh()
        }
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        let snapshot = accounts
        let fetcher = self.fetcher
        async let cursorMetadata = Self.readCursorMetadata(for: snapshot)
        let results = await Self.fetchAll(snapshot, using: fetcher)
        let (plans, savedSessions) = await cursorMetadata

        for (id, plan) in plans {
            localPlansByID[id] = plan
        }
        savedCursorSessionIDs = savedSessions

        for (id, usage, error) in results {
            guard accounts.contains(where: { $0.id == id }) else { continue }
            usageByID[id] = usage
            errorsByID[id] = error
        }

        lastRefresh = Date()
        isRefreshing = false
    }

    private nonisolated static func readCursorMetadata(
        for accounts: [ProviderAccount]
    ) async -> ([String: String], Set<String>) {
        let cursorAccounts = accounts.filter { $0.provider == .cursor }
        guard !cursorAccounts.isEmpty else { return ([:], []) }
        return await Task.detached(priority: .utility) {
            var plans: [String: String] = [:]
            var saved: Set<String> = []
            for account in cursorAccounts {
                if let plan = CursorUsageReader.readLocalPlan(account: account) {
                    plans[account.id] = plan
                }
                if CursorCredentials.hasSavedSession(account: account) {
                    saved.insert(account.id)
                }
            }
            return (plans, saved)
        }.value
    }

    private nonisolated static func fetchAll(
        _ accounts: [ProviderAccount],
        using fetcher: @escaping @Sendable (ProviderAccount) async throws -> ProviderUsage
    ) async -> [(String, ProviderUsage?, String?)] {
        struct DedupeKey: Hashable {
            let provider: UsageProvider
            let source: String
        }

        var primaryBySource: [DedupeKey: ProviderAccount] = [:]
        var duplicatesByPrimaryID: [String: [String]] = [:]
        for account in accounts {
            let key = DedupeKey(provider: account.provider, source: account.displaySourcePath())
            if let existing = primaryBySource[key] {
                duplicatesByPrimaryID[existing.id, default: []].append(account.id)
            } else {
                primaryBySource[key] = account
            }
        }

        let uniqueAccounts = Array(primaryBySource.values)
        return await withTaskGroup(of: (String, ProviderUsage?, String?).self) { group in
            for account in uniqueAccounts {
                group.addTask {
                    do {
                        return (account.id, try await fetcher(account), nil)
                    } catch {
                        return (account.id, nil, error.localizedDescription)
                    }
                }
            }

            var output: [(String, ProviderUsage?, String?)] = []
            for await result in group {
                output.append(result)
                for duplicateID in duplicatesByPrimaryID[result.0] ?? [] {
                    output.append((duplicateID, result.1, result.2))
                }
            }
            return output
        }
    }

    // MARK: - Demo Fixtures

    func loadDemoData(now: Date = .now, multipleAccounts: Bool = false) {
        hiddenEntryIDs = []

        let codexDefault = ProviderAccount(id: "codex:default", provider: .codex, name: multipleAccounts ? "Personal" : "Default")
        let claudeDefault = ProviderAccount(id: "claude:default", provider: .claude, name: multipleAccounts ? "Personal" : "Default")
        let antigravityDefault = ProviderAccount(id: "antigravity:default", provider: .antigravity, name: "Default")
        let cursorDefault = ProviderAccount(id: "cursor:default", provider: .cursor, name: "Default")

        var demoAccounts = [codexDefault, claudeDefault, antigravityDefault, cursorDefault]
        var demoUsage: [String: ProviderUsage] = [:]

        let codexWeekly = UsageLimit(
            id: "codex-demo-weekly",
            label: "Weekly",
            usedPercent: 19,
            resetsAt: now.addingTimeInterval(583_140),
            durationMinutes: 10_080,
            displayMode: .remaining
        )
        let codexResets = BankedResets(
            availableCount: 2,
            credits: [
                BankedReset(id: "demo-reset-1", expiration: .date(now.addingTimeInterval(172_800))),
                BankedReset(id: "demo-reset-2", expiration: .date(now.addingTimeInterval(1_209_600))),
            ]
        )
        demoUsage[codexDefault.id] = ProviderUsage(
            provider: .codex,
            limits: [codexWeekly],
            updatedAt: now,
            sourceDescription: "Live local ChatGPT / Codex status",
            bankedResets: codexResets,
            planName: "Pro"
        )

        let claudeFiveHour = UsageLimit(
            id: "claude-demo-five-hour",
            label: "5-hour",
            usedPercent: 42,
            resetsAt: now.addingTimeInterval(5_930),
            durationMinutes: 300,
            displayMode: .remaining
        )
        let claudeWeekly = UsageLimit(
            id: "claude-demo-weekly",
            label: "Weekly",
            usedPercent: 56,
            resetsAt: now.addingTimeInterval(496_740),
            durationMinutes: 10_080,
            displayMode: .remaining
        )
        demoUsage[claudeDefault.id] = ProviderUsage(
            provider: .claude,
            limits: [claudeFiveHour, claudeWeekly],
            updatedAt: now,
            sourceDescription: "Live local Claude usage",
            planName: "Max 20×"
        )

        let agGemini = UsageLimit(
            id: "antigravity-demo-gemini",
            label: "Gemini",
            usedPercent: 12,
            resetsAt: now.addingTimeInterval(13_680),
            durationMinutes: 300,
            displayMode: .remaining
        )
        let agClaude = UsageLimit(
            id: "antigravity-demo-claude",
            label: "Claude & GPT",
            usedPercent: 24,
            resetsAt: now.addingTimeInterval(15_120),
            durationMinutes: 300,
            displayMode: .remaining
        )
        demoUsage[antigravityDefault.id] = ProviderUsage(
            provider: .antigravity,
            limits: [agGemini, agClaude],
            updatedAt: now,
            sourceDescription: "Live local Antigravity status",
            planName: "Google AI Ultra",
            footnote: "2,400 AI credits available"
        )

        let cursorIncluded = UsageLimit(
            id: "cursor-demo-included",
            label: "Composer + Grok",
            usedPercent: 14,
            resetsAt: now.addingTimeInterval(1_256_340),
            displayMode: .remaining
        )
        demoUsage[cursorDefault.id] = ProviderUsage(
            provider: .cursor,
            limits: [cursorIncluded],
            updatedAt: now,
            sourceDescription: "Live local Cursor pool",
            planName: "Pro"
        )

        if multipleAccounts {
            let codexWork = ProviderAccount(id: "codex:work", provider: .codex, name: "Work", profilePath: "/Users/demo/.codex-work")
            let claudeWork = ProviderAccount(
                id: "claude:work",
                provider: .claude,
                name: "Work",
                profilePath: "/Users/demo/Library/Application Support/Claude-Work",
                secondaryPath: "/Users/demo/.claude-work"
            )
            demoAccounts.insert(codexWork, at: 1)
            demoAccounts.insert(claudeWork, at: 3)

            let codexWorkWeekly = UsageLimit(
                id: "codex-work-weekly",
                label: "Weekly",
                usedPercent: 29,
                resetsAt: now.addingTimeInterval(172_800),
                durationMinutes: 10_080,
                displayMode: .remaining
            )
            let codexWorkResets = BankedResets(
                availableCount: 1,
                credits: [BankedReset(id: "demo-work-reset", expiration: .date(now.addingTimeInterval(604_800)))]
            )
            demoUsage[codexWork.id] = ProviderUsage(
                provider: .codex,
                limits: [codexWorkWeekly],
                updatedAt: now,
                sourceDescription: "Live local ChatGPT / Codex status",
                bankedResets: codexWorkResets,
                planName: "Business Pro Lite"
            )

            let claudeWorkWeekly = UsageLimit(
                id: "claude-work-weekly",
                label: "Weekly",
                usedPercent: 18,
                resetsAt: now.addingTimeInterval(259_200),
                durationMinutes: 10_080,
                displayMode: .remaining
            )
            demoUsage[claudeWork.id] = ProviderUsage(
                provider: .claude,
                limits: [claudeWorkWeekly],
                updatedAt: now,
                sourceDescription: "Live local Claude usage",
                planName: "Team"
            )
        }

        accounts = demoAccounts
        usageByID = demoUsage
        errorsByID = [:]
        lastRefresh = now
    }

    // MARK: - Persistence & Merging

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            preferences.set(data, forKey: Self.accountsKey)
        }
    }

    private static func sanitizedAccounts(_ list: [ProviderAccount]) -> [ProviderAccount] {
        var seen = Set<String>()
        return list.filter { $0.isValid && seen.insert($0.id).inserted }
    }

    private static func mergeAccounts(
        saved: [ProviderAccount],
        discovered: [ProviderAccount]
    ) -> [ProviderAccount] {
        let fallbackDefaults = UsageProvider.allCases.map { ProviderAccount.defaultAccount(for: $0) }
        let baselineDiscovered = discovered.isEmpty ? fallbackDefaults : discovered

        guard !saved.isEmpty else {
            return baselineDiscovered
        }

        var merged = saved
        let discoveredCounts = Dictionary(grouping: baselineDiscovered, by: \.provider).mapValues(\.count)

        for item in baselineDiscovered {
            if let existingIndex = merged.firstIndex(where: { $0.id == item.id }) {
                // Backfill newly discovered paired paths without overwriting user's custom name.
                if merged[existingIndex].profilePath == nil {
                    merged[existingIndex].profilePath = item.profilePath
                }
                if merged[existingIndex].secondaryPath == nil {
                    merged[existingIndex].secondaryPath = item.secondaryPath
                }
                // Upgrade untouched "Default" label to "Personal" when a second profile is discovered.
                if (discoveredCounts[item.provider] ?? 0) > 1,
                   merged[existingIndex].name == "Default",
                   item.name == "Personal" {
                    merged[existingIndex].name = "Personal"
                }
            } else if !merged.contains(where: {
                $0.provider == item.provider && $0.profilePath != nil && $0.profilePath == item.profilePath
            }) {
                merged.append(item)
            }
        }

        // Ensure every provider retains at least its default entry.
        for provider in UsageProvider.allCases where !merged.contains(where: { $0.provider == provider }) {
            merged.append(.defaultAccount(for: provider))
        }
        return merged
    }
}
