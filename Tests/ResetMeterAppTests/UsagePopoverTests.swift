import AppKit
import SwiftUI
import Testing
@testable import ResetMeterApp

@Test @MainActor func compactMenuProposalKeepsUsageDetailsVisible() throws {
    let suite = "ResetMeterTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let store = UsageStore(autoRefresh: false, preferences: preferences)
    store.loadDemoData(multipleAccounts: true)

    // Reproduce the small proposal from the status-item popover, rather than
    // the unrestricted proposal used when generating promotional snapshots.
    let renderer = ImageRenderer(content: UsagePopover(store: store))
    renderer.proposedSize = ProposedViewSize(width: 348, height: 100)
    let image = try #require(renderer.nsImage)
    #expect(image.size.height > 500)
}
