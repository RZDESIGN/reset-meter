import AppKit
import SwiftUI
import Testing
import UsageMeterCore
@testable import ResetMeterApp

@Test @MainActor func compactMenuProposalKeepsUsageDetailsVisible() throws {
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

    // Measure via AppKit NSHostingView (the same host MenuBarExtra(.window) uses) rather than
    // SwiftUI.ImageRenderer so headless Intel CI VMs without Metal devices never initialize MTLLoader.
    let hosting = NSHostingView(rootView: UsagePopover(store: store))
    hosting.frame = NSRect(x: 0, y: 0, width: 364, height: 100)
    hosting.layoutSubtreeIfNeeded()
    let fitted = hosting.fittingSize
    #expect(fitted.width >= 364)
    #expect(fitted.height > 450)

    let fullBar = MenuBarArtwork.image(groups: store.menuGroups, style: .barsAndPercent)
    let barsOnly = MenuBarArtwork.image(groups: store.menuGroups, style: .barsOnly)
    let percentOnly = MenuBarArtwork.image(groups: store.menuGroups, style: .percentOnly)

    #expect(fullBar.isTemplate)
    #expect(fullBar.size.height == 18)
    #expect(barsOnly.size.width > 40)
    #expect(percentOnly.size.width > 40)
    #expect(fullBar.size.width > barsOnly.size.width)
    #expect(fullBar.size.width > percentOnly.size.width)
}
