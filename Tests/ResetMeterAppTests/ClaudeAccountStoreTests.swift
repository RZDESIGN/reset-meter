import Foundation
import Testing
import UsageMeterCore
@testable import ResetMeterApp

@Test @MainActor func claudeAccountsPersistAndRefreshIndependently() async throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let second = ClaudeAccount(name: "Work")
    preferences.set(try JSONEncoder().encode([ClaudeAccount.defaultAccount, second]), forKey: "claudeAccounts.v1")
    let fetcher = ClaudeStoreFetcher(failingID: second.id)
    let store = UsageStore(autoRefresh: false, preferences: preferences,
        codexFetcher: { _ in throw UsageReadError.codexAccountUnavailable },
        claudeFetcher: { try await fetcher.fetch($0) },
        claudeLoginRemover: { _ in },
        cursorFetcher: { _ in throw UsageReadError.cursorNotFound })
    store.renameAccount(ClaudeAccount.defaultAccount, name: "Personal")
    #expect(UsageStore(autoRefresh: false, preferences: preferences).claudeAccounts.map(\.name) == ["Personal", "Work"])
    await store.refresh()
    #expect(store.claudeUsage["default"]?.headlinePercent == 80)
    #expect(store.claudeUsage[second.id] == nil)
    #expect(store.claudeErrors[second.id] != nil)
    await fetcher.fail(nil)
    await store.refresh()
    #expect(store.claudeUsage[second.id]?.headlinePercent == 35)
    #expect(store.claudeUsage["default"]?.planName == "Max 5×")
    #expect(store.claudeUsage[second.id]?.planName == "Pro")
    #expect(store.menuGroups.map { $0.percents } == [[nil], [80, 35], [nil]])
    #expect(store.entries.first(where: { $0.id == "claude:\(second.id)" })?.planLabel == "Pro")
    #expect(store.menuSummary.contains("Claude Personal 80%"))

    store.setVisible(false, entryID: "claude:default")
    #expect(store.menuGroups.first(where: { $0.provider == .claude })?.percents == [35])
    #expect(UsageStore(autoRefresh: false, preferences: preferences).hiddenEntryIDs == ["claude:default"])
    await fetcher.fail(second.id)
    await store.refresh()
    #expect(store.claudeUsage[second.id] == nil) // No old usage or plan shown as live after failure.
    #expect(store.claudeUsage["default"]?.headlinePercent == 80)
    store.setVisible(false, entryID: "claude:\(second.id)")
    store.removeAccount(second)
    #expect(store.claudeAccounts.count == 1)
    #expect(store.claudeErrors[second.id] == nil)
    #expect(!store.hiddenEntryIDs.contains("claude:\(second.id)"))
    #expect(UsageStore(autoRefresh: false, preferences: preferences).claudeAccounts.count == 1)
}

@Test @MainActor func claudeMigratesOldVisibilityAndRejectsInvalidProfiles() throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(["claude", "codex:default"], forKey: "hiddenUsageEntries.v1")
    preferences.set(try JSONEncoder().encode([ClaudeAccount.defaultAccount, .defaultAccount,
        ClaudeAccount(id: "../../invalid", name: "Invalid")]), forKey: "claudeAccounts.v1")
    let store = UsageStore(autoRefresh: false, preferences: preferences)
    #expect(store.claudeAccounts == [.defaultAccount])
    #expect(store.hiddenEntryIDs == ["claude:default", "codex:default"])
    store.removeAccount(ClaudeAccount.defaultAccount)
    #expect(store.claudeAccounts == [.defaultAccount])
    #expect(UsageStore(autoRefresh: false, preferences: preferences).hiddenEntryIDs == store.hiddenEntryIDs)
}

@Test @MainActor func claudeAddSignInReconnectAndCancelKeepOtherAccountsIntact() async throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let signer = ClaudeStoreSigner()
    let store = UsageStore(autoRefresh: false, preferences: preferences,
        codexFetcher: { _ in throw UsageReadError.codexAccountUnavailable },
        claudeFetcher: { _ in ProviderUsage(provider: .claude, limits: [], updatedAt: .now, sourceDescription: "Synthetic", planName: "Pro") },
        claudeSigner: { try await signer.signIn($0) },
        claudeLoginRemover: { _ in },
        cursorFetcher: { _ in throw UsageReadError.cursorNotFound })
    store.addAccount(name: " Work ", provider: .claude)
    let account = try #require(store.claudeAccounts.last)
    #expect(account.name == "Work")
    #expect(store.signingInAccountID == "claude:\(account.id)")
    await waitForSignIn(store)
    #expect(store.claudeUsage[account.id]?.planName == "Pro")
    #expect(await signer.signedInIDs == [account.id])
    #expect(store.codexAccounts == [.defaultAccount])
    #expect(UsageStore(autoRefresh: false, preferences: preferences).claudeAccounts == store.claudeAccounts)

    await signer.setWait(true)
    store.signIn(account)
    #expect(store.claudeUsage[account.id] == nil)
    store.addAccount(name: "Blocked while signing in", provider: .claude)
    store.removeAccount(account)
    #expect(store.claudeAccounts.count == 2)
    store.cancelSignIn()
    await waitForSignIn(store)
    #expect(store.accountError == nil)
    #expect(store.claudeUsage[account.id] == nil)
    #expect(store.claudeUsage["default"]?.planName == "Pro")
}

@Test @MainActor func failedClaudeRemovalKeepsAccountAndVisibility() throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let account = ClaudeAccount(name: "Work")
    preferences.set(try JSONEncoder().encode([ClaudeAccount.defaultAccount, account]), forKey: "claudeAccounts.v1")
    let store = UsageStore(autoRefresh: false, preferences: preferences,
        claudeLoginRemover: { _ in throw UsageReadError.claudeCredentialsUnavailable })
    store.setVisible(false, entryID: "claude:\(account.id)")
    store.removeAccount(account)
    #expect(store.claudeAccounts.count == 2)
    #expect(store.accountError != nil)
    #expect(store.hiddenEntryIDs == ["claude:\(account.id)"])
}

@MainActor private func waitForSignIn(_ store: UsageStore) async {
    for _ in 0..<200 {
        if store.signingInAccountID == nil && !store.isRefreshing { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Sign-in task did not settle")
}

private actor ClaudeStoreFetcher {
    var failingID: String?
    init(failingID: String?) { self.failingID = failingID }
    func fail(_ id: String?) { failingID = id }
    func fetch(_ account: ClaudeAccount) throws -> ProviderUsage {
        if account.id == failingID { throw UsageReadError.claudeAuthorizationFailed }
        return ProviderUsage(provider: .claude, limits: [
            UsageLimit(id: "weekly", label: "Weekly", usedPercent: account.isDefault ? 20 : 65,
                       resetsAt: nil, displayMode: .remaining)
        ], updatedAt: .now, sourceDescription: "Synthetic", planName: account.isDefault ? "Max 5×" : "Pro")
    }
}

private actor ClaudeStoreSigner {
    var signedInIDs: [String] = []
    var shouldWait = false
    func setWait(_ value: Bool) { shouldWait = value }
    func signIn(_ account: ClaudeAccount) async throws {
        signedInIDs.append(account.id)
        if shouldWait { try await Task.sleep(for: .seconds(30)) }
    }
}
