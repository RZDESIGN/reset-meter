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

    let renderer = ImageRenderer(content: UsagePopover(store: store))
    renderer.proposedSize = ProposedViewSize(width: 364, height: 100)
    let image = try #require(renderer.nsImage)
    #expect(image.size.height > 450)

    for style in MenuBarStyle.allCases {
        store.menuBarStyle = style
        let labelRenderer = ImageRenderer(content: StatusLabel(store: store))
        let labelImage = try #require(labelRenderer.nsImage)
        #expect(labelImage.size.width > 40)
        #expect(labelImage.size.height >= 18)
    }
}
