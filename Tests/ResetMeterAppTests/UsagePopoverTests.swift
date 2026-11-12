import AppKit
import SwiftUI
import Testing
import UsageMeterCore
@testable import ResetMeterApp

@Test @MainActor func compactMenuProposalSizesDynamicallyFromOneToManyProviders() throws {
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
    let window = NSWindow(
        contentRect: NSRect(x: 80, y: 200, width: 364, height: 700),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    let sixAccountHeight = hosting.fittingSize.height
    #expect(hosting.fittingSize.width == 364)
    #expect(sixAccountHeight > 500)
    #expect(sixAccountHeight <= UsagePopover.maximumListHeight + 110)

    // Keep only 2 providers visible: height must shrink dynamically below 400pt on the first pass.
    let allIDs = store.entries.map(\.id)
    for id in allIDs.dropFirst(2) {
        store.setVisible(false, entryID: id)
    }
    let twoHosting = NSHostingView(rootView: UsagePopover(store: store))
    let twoHeight = twoHosting.fittingSize.height
    #expect(twoHeight > 220)
    #expect(twoHeight < 400)

    // Keep only 1 provider visible: height must shrink tightly around the single card (< 260pt).
    store.setVisible(false, entryID: allIDs[1])
    let oneHosting = NSHostingView(rootView: UsagePopover(store: store))
    let oneHeight = oneHosting.fittingSize.height
    #expect(oneHeight > 140)
    #expect(oneHeight < 260)
    #expect(oneHeight < twoHeight)
    #expect(twoHeight < sixAccountHeight)

    // Existing borderless panel window must also shrink dynamically while preserving its top edge (maxY).
    hosting.layoutSubtreeIfNeeded()
    let maxYBefore = window.frame.maxY
    if let observer = findObserverView(in: hosting) {
        observer.syncWindowHeight()
    }
    #expect(abs(window.frame.height - oneHeight) <= 1)
    #expect(abs(window.frame.maxY - maxYBefore) <= 1)

    let fullBar = MenuBarArtwork.image(groups: store.menuGroups, style: .barsAndPercent)
    let barsOnly = MenuBarArtwork.image(groups: store.menuGroups, style: .barsOnly)
    let percentOnly = MenuBarArtwork.image(groups: store.menuGroups, style: .percentOnly)

    #expect(fullBar.isTemplate)
    #expect(fullBar.size.height == 18)
    #expect(barsOnly.size.width > 30)
    #expect(percentOnly.size.width > 30)
    #expect(fullBar.size.width > barsOnly.size.width)
    #expect(fullBar.size.width > percentOnly.size.width)
}

@MainActor
private func findObserverView(in root: NSView) -> PopoverWindowObserverView? {
    if let match = root as? PopoverWindowObserverView {
        return match
    }
    for child in root.subviews {
        if let found = findObserverView(in: child) {
            return found
        }
    }
    return nil
}
