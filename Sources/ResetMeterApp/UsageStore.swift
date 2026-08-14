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

    func loadDemoData(now: Date = .now) {
        codex = ProviderUsage(
            provider: .codex,
            limits: [
                UsageLimit(
                    id: "codex-demo-weekly",
                    label: "Weekly",
                    usedPercent: 19,
                    resetsAt: now.addingTimeInterval(6 * 86_400 + 16 * 3_600 + 59 * 60),
                    durationMinutes: 10_080,
                    displayMode: .remaining
                ),
            ],
            updatedAt: now,
            sourceDescription: "Live Codex status"
        )
        claude = ProviderUsage(
            provider: .claude,
            limits: [
                UsageLimit(
                    id: "claude-demo-five-hour",
                    label: "5-hour",
                    usedPercent: 42,
                    resetsAt: now.addingTimeInterval(1 * 3_600 + 38 * 60 + 50),
                    resetIsEstimated: true,
                    durationMinutes: 300,
                    displayMode: .remaining
                ),
                UsageLimit(
                    id: "claude-demo-weekly",
                    label: "Weekly",
                    usedPercent: 56,
                    resetsAt: now.addingTimeInterval(5 * 86_400 + 17 * 3_600 + 59 * 60),
                    resetIsEstimated: true,
                    durationMinutes: 10_080,
                    displayMode: .remaining
                ),
            ],
            updatedAt: now,
            sourceDescription: "Claude Desktop cache"
        )
        cursor = ProviderUsage(
            provider: .cursor,
            limits: [
                UsageLimit(
                    id: "cursor-demo-included",
                    label: "Composer + Grok",
                    usedPercent: 14,
                    resetsAt: now.addingTimeInterval(14 * 86_400 + 12 * 3_600 + 59 * 60),
                    displayMode: .remaining
                ),
            ],
            updatedAt: now,
            sourceDescription: "Live Cursor first-party pool"
        )
        codexError = nil
        claudeError = nil
        cursorError = nil
        lastRefresh = now
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
