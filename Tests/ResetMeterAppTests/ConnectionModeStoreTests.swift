import Foundation
import Testing
import UsageMeterCore
@testable import ResetMeterApp

@Test @MainActor func localConnectionsShareOneReadSoCredentialRenewalsCannotRace() async throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(try JSONEncoder().encode([CodexAccount.defaultAccount, CodexAccount(name: "Copy", mode: .local)]), forKey: "codexAccounts.v1")
    preferences.set(try JSONEncoder().encode([ClaudeAccount.defaultAccount, ClaudeAccount(name: "Copy", mode: .local)]), forKey: "claudeAccounts.v1")
    preferences.set(try JSONEncoder().encode([CursorAccount.defaultAccount, CursorAccount(name: "Copy", mode: .local)]), forKey: "cursorAccounts.v1")
    let events = ModeStoreEvents()
    let store = UsageStore(autoRefresh: false, preferences: preferences,
        codexFetcher: { await events.fetch(.codex, mode: $0.mode) },
        claudeFetcher: { await events.fetch(.claude, mode: $0.mode) },
        cursorFetcher: { await events.fetch(.cursor, mode: $0.mode) })
    await store.refresh()
    #expect(store.entries.count == 6)
    #expect(store.entries.allSatisfy { $0.usage?.headlinePercent == 90 })
    #expect(await events.fetchCounts == ["codex": 1, "claude": 1, "cursor": 1])
}

@Test @MainActor func everyProviderCanSwitchModesAndPersistWithoutReusingOldUsage() async throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let events = ModeStoreEvents()
    let store = UsageStore(autoRefresh: false, preferences: preferences,
        codexFetcher: { await events.fetch(.codex, mode: $0.mode) },
        claudeFetcher: { await events.fetch(.claude, mode: $0.mode) },
        cursorFetcher: { await events.fetch(.cursor, mode: $0.mode) })
    await store.refresh()
    #expect(store.entries.allSatisfy { $0.usage?.headlinePercent == 90 && $0.mode == .local })
    let ids = store.entries.map(\.id)
    for id in ids {
        store.setVisible(false, entryID: id)
        store.setMode(.login, entryID: id)
        #expect(store.entries.first(where: { $0.id == id })?.usage == nil)
    }
    #expect(store.hiddenEntryIDs == Set(ids))
    let restored = UsageStore(autoRefresh: false, preferences: preferences)
    #expect(restored.entries.map(\.mode) == [.login, .login, .login])
    #expect(restored.hiddenEntryIDs == Set(ids))
    await store.refresh()
    #expect(store.entries.allSatisfy { $0.usage?.headlinePercent == 40 })
    for id in ids { store.setMode(.local, entryID: id) }
    #expect(store.entries.allSatisfy { $0.usage == nil })
    await store.refresh()
    #expect(store.entries.allSatisfy { $0.usage?.headlinePercent == 90 })
    #expect(UsageStore(autoRefresh: false, preferences: preferences).entries.map(\.mode) == [.local, .local, .local])
}

@Test @MainActor func defaultAccountsCanSignInOnlyAfterChoosingLoginForEveryProvider() async throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let events = ModeStoreEvents()
    let store = UsageStore(autoRefresh: false, preferences: preferences,
        codexFetcher: { await events.fetch(.codex, mode: $0.mode) },
        claudeFetcher: { await events.fetch(.claude, mode: $0.mode) },
        codexSigner: { await events.sign(.codex, mode: $0.mode) },
        claudeSigner: { await events.sign(.claude, mode: $0.mode) },
        cursorFetcher: { await events.fetch(.cursor, mode: $0.mode) },
        cursorSigner: { await events.sign(.cursor, mode: $0.mode) })
    store.signIn(CodexAccount.defaultAccount)
    store.signIn(ClaudeAccount.defaultAccount)
    store.signIn(CursorAccount.defaultAccount)
    #expect(store.signingInAccountID == nil)
    #expect(await events.signedProviders.isEmpty)
    for id in ["codex:default", "claude:default", "cursor"] { store.setMode(.login, entryID: id) }
    // Even a stale view value must resolve to the stored connection mode.
    store.signIn(CodexAccount.defaultAccount)
    await settleModeStore(store)
    store.signIn(ClaudeAccount.defaultAccount)
    await settleModeStore(store)
    store.signIn(CursorAccount.defaultAccount)
    await settleModeStore(store)
    #expect(await events.signedProviders == [.codex, .claude, .cursor])
    #expect(store.entries.allSatisfy { $0.usage?.headlinePercent == 40 })
}

@Test @MainActor func cursorAddedAccountsStayIndependentAndRemovalPersists() async throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let events = ModeStoreEvents()
    let store = UsageStore(autoRefresh: false, preferences: preferences,
        codexFetcher: { _ in throw UsageReadError.codexAccountUnavailable },
        claudeFetcher: { _ in throw UsageReadError.claudeSignedOut },
        cursorFetcher: { await events.fetch(.cursor, mode: $0.mode) },
        cursorSigner: { await events.sign(.cursor, mode: $0.mode) },
        cursorLoginRemover: { account in #expect(!account.isDefault) })
    store.addAccount(name: " Work ", provider: .cursor)
    await settleModeStore(store)
    let work = try #require(store.cursorAccounts.last)
    #expect(work.name == "Work")
    #expect(store.cursorUsage["default"]?.headlinePercent == 90)
    #expect(store.cursorUsage[work.id]?.headlinePercent == 40)
    #expect(store.menuGroups.last?.percents == [90, 40])
    store.renameAccount(work, name: "Business")
    store.setVisible(false, entryID: work.entryID)
    #expect(UsageStore(autoRefresh: false, preferences: preferences).cursorAccounts.last?.name == "Business")
    store.setMode(.local, entryID: work.entryID)
    store.removeAccount(work)
    #expect(store.cursorAccounts == [.defaultAccount])
    #expect(store.cursorUsage["default"]?.headlinePercent == 90)
    #expect(!store.hiddenEntryIDs.contains(work.entryID))
    #expect(UsageStore(autoRefresh: false, preferences: preferences).cursorAccounts == [.defaultAccount])
}

@Test @MainActor func cursorFailureClearsStaleUsageAndCancelUnlocksModeChoice() async throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = UsageStore(autoRefresh: false, preferences: preferences,
        codexFetcher: { _ in throw UsageReadError.codexAccountUnavailable },
        claudeFetcher: { _ in throw UsageReadError.claudeSignedOut },
        cursorFetcher: { _ in throw UsageReadError.cursorAuthorizationFailed },
        cursorSigner: { _ in try await Task.sleep(for: .seconds(30)) })
    store.loadDemoData()
    await store.refresh()
    #expect(store.cursorUsage.isEmpty)
    #expect(store.cursorErrors["default"] != nil)
    store.setMode(.login, entryID: "cursor")
    store.signIn(CursorAccount.defaultAccount)
    store.setMode(.local, entryID: "cursor")
    #expect(store.cursorAccounts[0].mode == .login) // Busy operation cannot race a mode change.
    store.cancelSignIn()
    await settleModeStore(store)
    #expect(store.accountError == nil)
    store.setMode(.local, entryID: "cursor")
    #expect(store.cursorAccounts[0].mode == .local)
}

@MainActor private func settleModeStore(_ store: UsageStore) async {
    for _ in 0..<200 {
        if store.signingInAccountID == nil && !store.isRefreshing { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Sign-in did not finish")
}

private actor ModeStoreEvents {
    var signedProviders: [UsageProvider] = []
    var fetchCounts: [String: Int] = [:]
    func sign(_ provider: UsageProvider, mode: ConnectionMode) {
        #expect(mode == .login)
        signedProviders.append(provider)
    }
    func fetch(_ provider: UsageProvider, mode: ConnectionMode) -> ProviderUsage {
        fetchCounts[provider.rawValue, default: 0] += 1
        return ProviderUsage(provider: provider,
            limits: [UsageLimit(id: "synthetic", label: "Weekly", usedPercent: mode == .local ? 10 : 60,
                                resetsAt: nil, displayMode: .remaining)],
            updatedAt: .now, sourceDescription: "Synthetic")
    }
}
