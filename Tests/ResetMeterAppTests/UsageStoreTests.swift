import Foundation
import Testing
import UsageMeterCore
@testable import ResetMeterApp

@Test @MainActor func accountsPersistNamesAndRecoverIndependentUsage() async throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let second = CodexAccount(name: "Work")
    try preferences.set(JSONEncoder().encode([CodexAccount.defaultAccount, second]), forKey: "codexAccounts.v1")
    let fetcher = TestFetcher(failingID: second.id)
    let store = UsageStore(
        autoRefresh: false, preferences: preferences,
        codexFetcher: { try await fetcher.fetch($0) },
        claudeFetcher: { throw UsageReadError.claudeHistoryMissing },
        cursorFetcher: { throw UsageReadError.cursorNotFound }
    )
    store.renameAccount(.defaultAccount, name: "Personal")
    let restored = UsageStore(autoRefresh: false, preferences: preferences)
    #expect(restored.codexAccounts.map(\.name) == ["Personal", "Work"])

    await store.refresh()
    #expect(store.codexUsage["default"]?.headlinePercent == 80)
    #expect(store.codexUsage[second.id] == nil)
    #expect(store.codexErrors[second.id] != nil)
    #expect(!store.isRefreshing)

    await fetcher.fail(nil)
    await store.refresh()
    #expect(store.codexUsage[second.id]?.headlinePercent == 35)
    #expect(store.codexUsage["default"]?.bankedResets?.availableCount == 1)
    #expect(store.codexUsage[second.id]?.bankedResets?.availableCount == 2)
    #expect(store.codexErrors[second.id] == nil)
    #expect(store.menuEntries.map { $0.1 } == [80, 35, nil, nil])
    #expect(store.menuSummary.contains("Personal 80%"))
    #expect(store.menuSummary.contains("Work 35%"))

    await fetcher.fail(second.id)
    await store.refresh()
    #expect(store.codexUsage[second.id] == nil) // Never present an old reading as live.
    #expect(store.codexUsage["default"]?.headlinePercent == 80)
    store.removeAccount(second)
    #expect(store.codexAccounts.count == 1)
    #expect(store.codexErrors[second.id] == nil)
    #expect(UsageStore(autoRefresh: false, preferences: preferences).codexAccounts.count == 1)
}

@Test @MainActor func freshInstallRetainsDefaultAndFiltersInvalidSavedAccounts() throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = UsageStore(autoRefresh: false, preferences: preferences)
    #expect(store.codexAccounts == [.defaultAccount])
    store.removeAccount(.defaultAccount)
    #expect(store.codexAccounts == [.defaultAccount])
    try preferences.set(JSONEncoder().encode([
        CodexAccount.defaultAccount, .defaultAccount, CodexAccount(id: "../invalid", name: "Invalid")
    ]), forKey: "codexAccounts.v1")
    #expect(UsageStore(autoRefresh: false, preferences: preferences).codexAccounts == [.defaultAccount])
}

private actor TestFetcher {
    var failingID: String?
    init(failingID: String?) { self.failingID = failingID }
    func fail(_ id: String?) { failingID = id }
    func fetch(_ account: CodexAccount) throws -> ProviderUsage {
        if account.id == failingID { throw UsageReadError.codexAccountUnavailable }
        return ProviderUsage(provider: .codex, limits: [
            UsageLimit(id: "weekly", label: "Weekly", usedPercent: account.isDefault ? 20 : 65,
                       resetsAt: nil, displayMode: .remaining)
        ], updatedAt: .now, sourceDescription: "Synthetic test usage",
            bankedResets: BankedResets(availableCount: account.isDefault ? 1 : 2, credits: nil))
    }
}

@Test @MainActor func visibilityPersistsPerAccountAndProviderWithoutChangingConnections() throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    // Identical names must still be independently toggleable.
    let second = CodexAccount(name: "Default")
    let accountData = try JSONEncoder().encode([CodexAccount.defaultAccount, second])
    preferences.set(accountData, forKey: "codexAccounts.v1")
    let store = UsageStore(autoRefresh: false, preferences: preferences)
    #expect(store.visibleEntries.count == 4)

    store.setVisible(false, entryID: "codex:default")
    store.setVisible(false, entryID: "claude")
    #expect(store.visibleEntries.map(\.id) == ["codex:\(second.id)", "cursor"])
    #expect(store.menuEntries.map { $0.0 } == [.codex, .cursor])
    #expect(!store.menuSummary.contains("Claude"))
    #expect(store.entries.count == 4) // Hidden entries remain available in Providers.
    #expect(preferences.data(forKey: "codexAccounts.v1") == accountData)

    let restored = UsageStore(autoRefresh: false, preferences: preferences)
    #expect(restored.visibleEntries.map(\.id) == store.visibleEntries.map(\.id))
    restored.setVisible(true, entryID: "codex:default")
    restored.setVisible(true, entryID: "claude")
    #expect(restored.visibleEntries.map(\.id) == restored.entries.map(\.id))
    #expect(UsageStore(autoRefresh: false, preferences: preferences).hiddenEntryIDs.isEmpty)
}

@Test @MainActor func allMetersCanBeHiddenAndRestored() throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = UsageStore(autoRefresh: false, preferences: preferences)
    store.loadDemoData(multipleAccounts: true)
    for entry in store.entries { store.setVisible(false, entryID: entry.id) }
    #expect(store.menuEntries.isEmpty)
    #expect(store.menuSummary.contains("All meters hidden"))
    #expect(store.entries.allSatisfy { $0.usage != nil })
    store.setVisible(true, entryID: "cursor")
    #expect(store.menuEntries.count == 1)
    #expect(store.menuEntries.first?.0 == .cursor)
    #expect(store.menuEntries.first?.1 == 86)
    store.setVisible(false, entryID: "unknown")
    #expect(!store.hiddenEntryIDs.contains("unknown"))
}

@Test @MainActor func menuBarShowsOneIconPerProviderWithAMeterPerAccount() throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = UsageStore(autoRefresh: false, preferences: preferences)
    store.loadDemoData(multipleAccounts: true)

    #expect(store.menuEntries.count == 4)
    #expect(store.menuGroups.map { $0.provider } == [.codex, .claude, .cursor])
    #expect(store.menuGroups.map { $0.percents } == [[81, 37], [44], [86]])

    store.setVisible(false, entryID: "codex:default")
    #expect(store.menuGroups.map { $0.provider } == [.codex, .claude, .cursor])
    #expect(store.menuGroups.first?.percents == [37])

    for entry in store.entries where entry.provider == .codex {
        store.setVisible(false, entryID: entry.id)
    }
    #expect(store.menuGroups.map { $0.provider } == [.claude, .cursor])
}
