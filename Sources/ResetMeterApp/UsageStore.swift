import Foundation
import UsageMeterCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var codex: ProviderUsage?
    @Published private(set) var claude: ProviderUsage?
    @Published private(set) var cursor: ProviderUsage?
    @Published private(set) var codexError: String?
    @Published private(set) var claudeError: String?
    @Published private(set) var cursorError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private var refreshTimer: Timer?

    init(autoRefresh: Bool = true) {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }

        if autoRefresh {
            Task { [weak self] in
                await self?.refresh()
            }
        }
    }

    func menuPercent(for provider: UsageProvider) -> String {
        menuRemainingPercent(for: provider).map { "\($0)%" } ?? "–"
    }

    func menuRemainingPercent(for provider: UsageProvider) -> Int? {
        usage(for: provider)?.headlinePercent
    }

    var menuSummary: String {
        "Codex \(menuPercent(for: .codex)) remaining, Claude \(menuPercent(for: .claude)) remaining, Cursor \(menuPercent(for: .cursor)) remaining"
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        let codexTask = Task { try await CodexUsageReader.fetch() }
        let claudeTask = Task { try await ClaudeUsageReader.fetch() }
        let cursorTask = Task { try await CursorUsageReader.fetch() }

        do {
            codex = try await codexTask.value
            codexError = nil
        } catch {
            codexError = error.localizedDescription
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

    private func usage(for provider: UsageProvider) -> ProviderUsage? {
        switch provider {
        case .codex: codex
        case .claude: claude
        case .cursor: cursor
        }
    }
}
