import Foundation
import Testing
import UsageMeterCore
@testable import ResetMeterApp

@Test @MainActor func localAccountsPersistNamesAndRecoverIndependentUsage() async throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    let discovered: [ProviderAccount] = [
        ProviderAccount(id: "codex:default", provider: .codex, name: "Personal", profilePath: "/Users/test/.codex"),
        ProviderAccount(id: "codex:work", provider: .codex, name: "Work", profilePath: "/Users/test/.codex-work"),
        ProviderAccount(
            id: "claude:default",
            provider: .claude,
            name: "Personal",
            profilePath: "/Users/test/Library/Application Support/Claude",
            secondaryPath: "/Users/test/.claude"
        ),
        ProviderAccount(
            id: "claude:work",
            provider: .claude,
            name: "Work",
            profilePath: "/Users/test/Library/Application Support/Claude-Work",
            secondaryPath: "/Users/test/.claude-work"
        ),
        ProviderAccount(id: "antigravity:default", provider: .antigravity, name: "Default"),
        ProviderAccount(id: "cursor:default", provider: .cursor, name: "Default"),
    ]

    let fetcher = TestAccountFetcher(failingIDs: ["codex:work", "cursor:default"])
    let store = UsageStore(
        autoRefresh: false,
        preferences: preferences,
        discoverer: { discovered },
        antigravityInstalled: { true },
        cursorInstalled: { false },
        fetcher: { try await fetcher.fetch($0) }
    )

    // Uninstalled Cursor is hidden initially; installed Antigravity + Codex + Claude are visible.
    #expect(store.visibleEntries.map(\.id) == [
        "codex:default", "codex:work", "claude:default", "claude:work", "antigravity:default",
    ])

    store.renameAccount(discovered[0], name: "Privé")
    let restored = UsageStore(
        autoRefresh: false,
        preferences: preferences,
        discoverer: { discovered },
        antigravityInstalled: { true },
        cursorInstalled: { false }
    )
    #expect(restored.accounts.filter { $0.provider == .codex }.map(\.name) == ["Privé", "Work"])

    await store.refresh()
    #expect(store.usageByID["codex:default"]?.headlinePercent == 80)
    #expect(store.usageByID["codex:work"] == nil)
    #expect(store.errorsByID["codex:work"] != nil)
    #expect(store.usageByID["claude:default"]?.headlinePercent == 65)
    #expect(store.usageByID["claude:work"]?.headlinePercent == 90)
    #expect(store.usageByID["antigravity:default"]?.headlinePercent == 88)
    #expect(!store.isRefreshing)

    await fetcher.setFailingIDs([])
    await store.refresh()
    #expect(store.usageByID["codex:work"]?.headlinePercent == 71)
    #expect(store.errorsByID["codex:work"] == nil)
    #expect(store.menuSummary.contains("Codex Privé 80%"))
    #expect(store.menuSummary.contains("Codex Work 71%"))
    #expect(store.menuSummary.contains("Claude Work 90%"))
    #expect(store.menuSummary.contains("Antigravity 88%"))

    // Never keep stale live state when a non-cached fetch fails later.
    await fetcher.setFailingIDs(["codex:work"])
    await store.refresh()
    #expect(store.usageByID["codex:work"] == nil)
    #expect(store.usageByID["codex:default"]?.headlinePercent == 80)

    store.removeAccount(discovered[1])
    #expect(store.accounts.filter { $0.provider == .codex }.map(\.id) == ["codex:default"])
    #expect(store.errorsByID["codex:work"] == nil)
}

@Test @MainActor func defaultAccountsStayProtectedAndRescanDiscoversNewClients() throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    // Corrupt/invalid saved IDs must be filtered out while preserving default accounts.
    let invalid = ProviderAccount(id: "../invalid", provider: .codex, name: "Invalid", profilePath: "/tmp/x")
    try preferences.set(
        JSONEncoder().encode([ProviderAccount.defaultAccount(for: .codex), invalid]),
        forKey: "localAccounts.v2"
    )

    let box = DiscoveryBox(accounts: UsageProvider.allCases.map { ProviderAccount.defaultAccount(for: $0) })
    let store = UsageStore(
        autoRefresh: false,
        preferences: preferences,
        discoverer: { box.accounts },
        antigravityInstalled: { true },
        cursorInstalled: { true },
        fetcher: { account in
            ProviderUsage(
                provider: account.provider,
                limits: [UsageLimit(id: "w", label: "Weekly", usedPercent: 10, resetsAt: nil)],
                updatedAt: .now,
                sourceDescription: "Test"
            )
        }
    )

    #expect(!store.accounts.contains(where: { $0.id == "../invalid" }))
    store.removeAccount(.defaultAccount(for: .codex))
    #expect(store.accounts.contains(where: { $0.id == "codex:default" }))

    // Simulate user installing a second Claude client ("Claude-Work") and clicking Scan Local Apps.
    box.accounts = [
        ProviderAccount(id: "codex:default", provider: .codex, name: "Default", profilePath: "/Users/test/.codex"),
        ProviderAccount(
            id: "claude:default",
            provider: .claude,
            name: "Personal",
            profilePath: "/Users/test/Library/Application Support/Claude",
            secondaryPath: "/Users/test/.claude"
        ),
        ProviderAccount(
            id: "claude:work",
            provider: .claude,
            name: "Work",
            profilePath: "/Users/test/Library/Application Support/Claude-Work",
            secondaryPath: "/Users/test/.claude-work"
        ),
        ProviderAccount(id: "antigravity:default", provider: .antigravity, name: "Default"),
        ProviderAccount(id: "cursor:default", provider: .cursor, name: "Default"),
    ]

    store.rescanLocalInstallations()
    let claudeAccounts = store.accounts.filter { $0.provider == .claude }
    #expect(claudeAccounts.map(\.id) == ["claude:default", "claude:work"])
    // Untouched "Default" upgrades to "Personal" once a second profile exists.
    #expect(claudeAccounts.map(\.name) == ["Personal", "Work"])

    // Custom local profile addition and removal.
    store.addLocalAccount(name: "Sandbox", provider: .codex, profilePath: "/Users/test/.codex-sandbox")
    let sandbox = try #require(store.accounts.first(where: { $0.name == "Sandbox" }))
    #expect(sandbox.provider == .codex)
    #expect(!sandbox.isDefault)
}

@Test @MainActor func visibilityLegacyMigrationAndMenuBarStylePersist() throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    preferences.set(["cursor"], forKey: "hiddenUsageEntries.v1")

    let store = UsageStore(
        autoRefresh: false,
        preferences: preferences,
        discoverer: { UsageProvider.allCases.map { ProviderAccount.defaultAccount(for: $0) } },
        antigravityInstalled: { true },
        cursorInstalled: { true }
    )

    #expect(!store.isVisible("cursor:default"))
    #expect(store.isVisible("codex:default"))
    #expect(store.isVisible("claude:default"))
    #expect(store.isVisible("antigravity:default"))

    store.setVisible(false, entryID: "claude:default")
    store.menuBarStyle = .barsOnly

    let restored = UsageStore(
        autoRefresh: false,
        preferences: preferences,
        discoverer: { UsageProvider.allCases.map { ProviderAccount.defaultAccount(for: $0) } },
        antigravityInstalled: { true },
        cursorInstalled: { true }
    )
    #expect(restored.visibleEntries.map(\.id) == ["codex:default", "antigravity:default"])
    #expect(restored.menuBarStyle == .barsOnly)

    for entry in restored.entries {
        restored.setVisible(false, entryID: entry.id)
    }
    #expect(restored.menuEntries.isEmpty)
    #expect(restored.menuSummary.contains("All meters hidden"))

    restored.setVisible(true, entryID: "antigravity:default")
    #expect(restored.visibleEntries.map(\.id) == ["antigravity:default"])
    restored.setVisible(false, entryID: "unknown:id")
    #expect(!restored.hiddenEntryIDs.contains("unknown:id"))
}

@Test @MainActor func menuBarGroupsOneIconPerProviderAcrossAllFourTools() throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    let store = UsageStore(
        autoRefresh: false,
        preferences: preferences,
        discoverer: { UsageProvider.allCases.map { ProviderAccount.defaultAccount(for: $0) } },
        antigravityInstalled: { true },
        cursorInstalled: { true }
    )
    store.loadDemoData(multipleAccounts: true)

    #expect(store.menuEntries.count == 6)
    #expect(store.menuGroups.map(\.provider) == [.codex, .claude, .antigravity, .cursor])
    #expect(store.menuGroups.map(\.percents) == [[81, 71], [44, 82], [76], [86]])

    store.setVisible(false, entryID: "codex:default")
    #expect(store.menuGroups.first?.percents == [71])

    for entry in store.entries where entry.provider == .codex {
        store.setVisible(false, entryID: entry.id)
    }
    #expect(store.menuGroups.map(\.provider) == [.claude, .antigravity, .cursor])
}

@Test @MainActor func duplicateProfileSourcesAreFetchedOncePerRefresh() async throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }

    let a = ProviderAccount(id: "codex:default", provider: .codex, name: "A", profilePath: "/Users/test/.codex")
    let b = ProviderAccount(id: "codex:dup", provider: .codex, name: "B", profilePath: "/Users/test/.codex")
    let counter = CallCounter()

    let store = UsageStore(
        autoRefresh: false,
        preferences: preferences,
        discoverer: { [a, b] },
        antigravityInstalled: { false },
        cursorInstalled: { false },
        fetcher: { account in
            await counter.record(account.provider)
            return ProviderUsage(
                provider: account.provider,
                limits: [UsageLimit(id: "w", label: "Weekly", usedPercent: 25, resetsAt: nil, displayMode: .remaining)],
                updatedAt: .now,
                sourceDescription: "Test"
            )
        }
    )

    await store.refresh()
    #expect(await counter.count(for: .codex) == 1)
    #expect(store.usageByID["codex:default"]?.headlinePercent == 75)
    #expect(store.usageByID["codex:dup"]?.headlinePercent == 75)
    // Hidden uninstalled providers are skipped during background refreshes unless includeHidden is requested.
    #expect(await counter.count(for: .antigravity) == 0)
    #expect(await counter.count(for: .cursor) == 0)

    let defaultWithHidden = UsageStore(
        autoRefresh: false,
        preferences: preferences,
        discoverer: { UsageProvider.allCases.map { ProviderAccount.defaultAccount(for: $0) } },
        antigravityInstalled: { false },
        cursorInstalled: { false },
        fetcher: { account in
            await counter.record(account.provider)
            return ProviderUsage(
                provider: account.provider,
                limits: [UsageLimit(id: "w", label: "Weekly", usedPercent: 10, resetsAt: nil, displayMode: .remaining)],
                updatedAt: .now,
                sourceDescription: "Test"
            )
        }
    )
    await defaultWithHidden.refresh(includeHidden: false)
    #expect(await counter.count(for: .cursor) == 0)
    await defaultWithHidden.refresh(includeHidden: true)
    #expect(await counter.count(for: .cursor) == 1)
}

private final class DiscoveryBox: @unchecked Sendable {
    var accounts: [ProviderAccount]
    init(accounts: [ProviderAccount]) {
        self.accounts = accounts
    }
}

private actor CallCounter {
    private var counts: [UsageProvider: Int] = [:]
    func record(_ provider: UsageProvider) {
        counts[provider, default: 0] += 1
    }
    func count(for provider: UsageProvider) -> Int {
        counts[provider, default: 0]
    }
}

private actor TestAccountFetcher {
    private var failingIDs: Set<String>

    init(failingIDs: Set<String>) {
        self.failingIDs = failingIDs
    }

    func setFailingIDs(_ ids: Set<String>) {
        failingIDs = ids
    }

    func fetch(_ account: ProviderAccount) throws -> ProviderUsage {
        if failingIDs.contains(account.id) {
            throw UsageReadError.codexAccountUnavailable
        }
        let usedByID: [String: Double] = [
            "codex:default": 20,
            "codex:work": 29,
            "claude:default": 35,
            "claude:work": 10,
            "antigravity:default": 12,
            "cursor:default": 15,
        ]
        return ProviderUsage(
            provider: account.provider,
            limits: [
                UsageLimit(
                    id: "weekly",
                    label: "Weekly",
                    usedPercent: usedByID[account.id] ?? 50,
                    resetsAt: nil,
                    displayMode: .remaining
                )
            ],
            updatedAt: .now,
            sourceDescription: "Synthetic local test usage"
        )
    }
}
