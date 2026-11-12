import AppKit
import SwiftUI
import UsageMeterCore

struct StatusLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Group {
            if store.visibleEntries.isEmpty {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .frame(width: 18, height: 18)
            } else {
                Image(nsImage: MenuBarArtwork.image(groups: store.menuGroups, style: store.menuBarStyle))
                    .renderingMode(.template)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityLabel(store.menuSummary)
    }
}

@MainActor
enum MenuBarArtwork {
    private static let height: CGFloat = 18
    private static let iconSize: CGFloat = 14
    private static let barSize = NSSize(width: 22, height: 5)
    private static let innerSpacing: CGFloat = 3
    private static let meterSpacing: CGFloat = 5
    private static let providerSpacing: CGFloat = 10
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    static func image(
        groups: [(provider: UsageProvider, percents: [Int?])],
        style: MenuBarStyle
    ) -> NSImage {
        let showsBar = style != .percentOnly
        let showsPercent = style != .barsOnly

        let labels = groups.map { $0.percents.map(label(for:)) }
        let widths = labels.map { $0.map { ceil($0.size().width) } }
        let groupWidths = groups.indices.map { index -> CGFloat in
            let meterWidths = widths[index].reduce(CGFloat(0)) { partial, labelWidth in
                var itemWidth: CGFloat = 0
                if showsBar { itemWidth += barSize.width }
                if showsBar && showsPercent { itemWidth += innerSpacing }
                if showsPercent { itemWidth += labelWidth }
                return partial + itemWidth
            }
            return iconSize + innerSpacing + meterWidths
                + meterSpacing * CGFloat(max(0, groups[index].percents.count - 1))
        }
        let totalWidth = max(
            18,
            ceil(groupWidths.reduce(0, +) + providerSpacing * CGFloat(max(0, groups.count - 1)))
        )

        let image = NSImage(
            size: NSSize(width: totalWidth, height: height),
            flipped: false
        ) { _ in
            var x: CGFloat = 0
            for index in groups.indices {
                let group = groups[index]
                if let icon = ProviderArtwork.image(for: group.provider, size: iconSize) {
                    icon.draw(
                        in: NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1
                    )
                }
                x += iconSize + innerSpacing

                for meter in group.percents.indices {
                    if showsBar {
                        drawBar(percent: group.percents[meter], at: NSPoint(x: x, y: (height - barSize.height) / 2))
                        x += barSize.width
                        if showsPercent { x += innerSpacing }
                    }

                    if showsPercent {
                        let label = labels[index][meter]
                        label.draw(at: NSPoint(x: x, y: floor((height - label.size().height) / 2)))
                        x += widths[index][meter]
                    }

                    if meter < group.percents.index(before: group.percents.endIndex) {
                        x += meterSpacing
                    }
                }

                if index < groups.index(before: groups.endIndex) {
                    x += providerSpacing
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func label(for percent: Int?) -> NSAttributedString {
        NSAttributedString(
            string: percent.map { "\($0)%" } ?? "–",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
        )
    }

    private static func drawBar(percent: Int?, at origin: NSPoint) {
        let rect = NSRect(origin: origin, size: barSize)
        let radius = rect.height / 2
        NSColor.white.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        guard let percent else { return }
        let fraction = CGFloat(min(max(percent, 0), 100)) / 100
        let fillWidth = rect.width * fraction
        guard fillWidth > 0 else { return }

        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
        let fillRadius = min(radius, fillWidth / 2)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: fillRadius, yRadius: fillRadius).fill()
    }
}

struct UsagePopover: View {
    @ObservedObject var store: UsageStore

    static let maximumListHeight: CGFloat = 620

    var body: some View {
        VStack(spacing: 11) {
            header

            CappedVerticalLayout(maxHeight: Self.maximumListHeight) {
                ScrollView {
                    cardsList
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            footer
        }
        .padding(14)
        .frame(width: 364)
        .fixedSize(horizontal: false, vertical: true)
        .background(PopoverWindowSizer())
    }

    private var cardsList: some View {
        VStack(spacing: 8) {
            ForEach(store.visibleEntries) { entry in
                ProviderCard(
                    entry: entry,
                    onConnectCursor: { store.connectCursor(entry.account) },
                    onCancelCursor: { store.cancelCursorConnect(entry.account) }
                )
            }
            if store.visibleEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("All meters are hidden.")
                        .font(.callout.weight(.medium))
                    Text("Enable local accounts from Providers below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Reset Meter")
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitleText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                AccountWindow.show(store: store)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Providers & local accounts")

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 26, height: 26)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Refresh usage")
            }
        }
    }

    private var subtitleText: String {
        let count = store.visibleEntries.count
        return count == 1 ? "Remaining capacity · 1 local meter" : "Remaining capacity · \(count) local meters"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let refreshed = store.lastRefresh {
                Text("Updated \(refreshed, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Local read-only mode")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Providers…") { AccountWindow.show(store: store) }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Measures the `ScrollView` at its natural content height synchronously on the first pass,
/// clamping only when cards exceed `maxHeight` so 1–4 providers size tightly without blank space.
private struct CappedVerticalLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let limit = min(proposal.height ?? maxHeight, maxHeight)
        return CGSize(width: ideal.width, height: min(ideal.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// Keeps the backing borderless `MenuBarExtra(.window)` panel height synchronized with
/// SwiftUI's intrinsic height (both growing and shrinking) while anchoring `maxY` under the menu bar.
private struct PopoverWindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> PopoverWindowObserverView {
        PopoverWindowObserverView()
    }

    func updateNSView(_ nsView: PopoverWindowObserverView, context: Context) {
        nsView.scheduleSync()
    }
}

@MainActor
final class PopoverWindowObserverView: NSView {
    private var lastHeight: CGFloat = 0
    private var syncScheduled = false
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()

        guard let window else { return }
        let notifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didExposeNotification,
        ]
        for name in notifications {
            windowObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.syncWindowHeight()
                    }
                }
            )
        }
        scheduleSync()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.height - lastHeight) > 0.5 {
            lastHeight = newSize.height
            scheduleSync()
        }
    }

    func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncWindowHeight()
        }
    }

    func syncWindowHeight() {
        guard let window,
              !window.styleMask.contains(.titled),
              let contentView = window.contentView else { return }
        let anchorMaxY = window.frame.maxY
        let anchorX = window.frame.origin.x
        let anchorWidth = window.frame.width

        contentView.layoutSubtreeIfNeeded()
        let fitting = contentView.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        let targetFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: fitting)).size

        if window.contentMinSize.height > fitting.height {
            window.contentMinSize.height = 0
        }
        if window.minSize.height > targetFrameSize.height {
            window.minSize.height = 0
        }

        let current = window.frame
        guard abs(current.height - targetFrameSize.height) > 0.5
            || abs(current.maxY - anchorMaxY) > 0.5 else { return }

        let anchored = NSRect(
            x: anchorX,
            y: anchorMaxY - targetFrameSize.height,
            width: anchorWidth,
            height: targetFrameSize.height
        )
        window.setFrame(anchored, display: window.isVisible)
        if window.isVisible {
            window.invalidateShadow()
        }
    }
}

extension UsageProvider {
    var tint: Color {
        switch self {
        case .codex: Color(red: 0.20, green: 0.48, blue: 0.98)
        case .claude: Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
        case .antigravity: Color(red: 0.16, green: 0.58, blue: 0.98)
        case .cursor: Color(red: 0.52, green: 0.44, blue: 0.97)
        }
    }

    var iconTint: Color {
        switch self {
        case .claude, .antigravity: tint
        case .codex, .cursor: .primary
        }
    }
}

struct ProviderCard<Controls: View>: View {
    let entry: UsageEntry
    var visibility: Binding<Bool>?
    var showsAccountSubtitle = true
    var onConnectCursor: (() -> Void)? = nil
    var onCancelCursor: (() -> Void)? = nil
    @ViewBuilder let controls: Controls

    private var provider: UsageProvider { entry.provider }
    private var usage: ProviderUsage? { entry.usage }
    private var error: String? { entry.error }
    private var tint: Color { provider.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ProviderIcon(provider: provider, size: 22, tint: provider.iconTint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(provider.displayName)
                            .font(.system(size: 13.5, weight: .semibold))
                        if showsAccountSubtitle, let subtitle = entry.visibleAccountSubtitle {
                            Text("· \(subtitle)")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let usage {
                            StatusDot(usage: usage)
                        }
                    }
                }

                Spacer(minLength: 4)

                if let plan = entry.planLabel {
                    Text(plan)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.065), in: Capsule())
                        .help("Account plan: \(plan)")
                        .accessibilityLabel("Account plan: \(plan)")
                }

                if let visibility {
                    Toggle("Show", isOn: visibility)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel("Show \(entry.displayName)")
                        .help("Show in the menu bar and usage popover")
                }
            }

            controls

            if let usage {
                VStack(spacing: 8) {
                    ForEach(usage.limits) { limit in
                        LimitRow(limit: limit, tint: tint)
                    }
                }

                if provider == .codex {
                    if usage.limits.isEmpty {
                        Text("Usage windows unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let resets = usage.bankedResets, resets.availableCount > 0 {
                        BankedResetsView(resets: resets)
                    }
                }

                if let footnote = usage.footnote {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                        Text(footnote)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else if entry.isConnecting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Confirm sign-in in your browser…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let onCancelCursor {
                        Button("Cancel", action: onCancelCursor)
                            .controlSize(.small)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text(error ?? "Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.canConnectCursor, let onConnectCursor {
                        Spacer(minLength: 4)
                        Button("Connect…", action: onConnectCursor)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.042))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 1)
        }
    }
}

extension ProviderCard where Controls == EmptyView {
    init(
        entry: UsageEntry,
        onConnectCursor: (() -> Void)? = nil,
        onCancelCursor: (() -> Void)? = nil
    ) {
        self.entry = entry
        self.visibility = nil
        self.onConnectCursor = onConnectCursor
        self.onCancelCursor = onCancelCursor
        self.controls = EmptyView()
    }
}

private struct LimitRow: View {
    let limit: UsageLimit
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 4.5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(limit.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if let resetLabel = resetText(now: context.date) {
                        Text(resetLabel)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    Text("\(Int(limit.displayPercent.rounded()))%")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(percentColor)
                        .monospacedDigit()
                        .frame(minWidth: 32, alignment: .trailing)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(0, geometry.size.width * limit.displayPercent / 100))
                    }
                }
                .frame(height: 6)
            }
        }
    }

    private var barColor: Color {
        switch limit.usedPercent {
        case 90...: .red
        case 70...: .orange
        default: tint
        }
    }

    private var percentColor: Color {
        switch limit.usedPercent {
        case 90...: .red
        case 75...: .orange
        default: .primary
        }
    }

    private func resetText(now: Date) -> String? {
        guard let reset = limit.resetsAt else { return nil }
        let remaining = reset.timeIntervalSince(now)
        if remaining <= 0 {
            return limit.resetIsEstimated ? "≈ resetting" : "Resetting…"
        }
        let prefix = limit.resetIsEstimated ? "≈ " : "Resets in "
        return prefix + UsageCountdown.duration(remaining)
    }
}

enum UsageCountdown {
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(max(1, minutes))m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }
}

private struct StatusDot: View {
    let usage: ProviderUsage

    var body: some View {
        Circle()
            .fill(usage.isStale ? Color.orange : Color.green)
            .frame(width: 6, height: 6)
            .help(description)
            .accessibilityLabel(description)
    }

    private var description: String {
        var parts = [usage.sourceDescription]
        if usage.isStale { parts.append("cached") }
        if usage.limits.contains(where: \.resetIsEstimated) { parts.append("reset ≈ estimated") }
        return parts.joined(separator: " · ")
    }
}

struct ProviderIcon: View {
    let provider: UsageProvider
    let size: CGFloat
    var tint: Color = .primary

    var body: some View {
        Group {
            if let image = ProviderArtwork.image(for: provider, size: size) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.15)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(tint)
        .clipped()
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityHidden(true)
    }

    private var fallbackSymbol: String {
        switch provider {
        case .codex: "terminal.fill"
        case .claude: "sparkles"
        case .antigravity: "aqi.medium"
        case .cursor: "cursorarrow"
        }
    }
}

enum ProviderArtwork {
    static func image(for provider: UsageProvider, size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: provider.rawValue, withExtension: "svg"),
              let source = NSImage(contentsOf: url),
              source.size.width > 0,
              source.size.height > 0 else {
            return nil
        }

        let canvas = NSSize(width: size, height: size)
        let scale = min(canvas.width / source.size.width, canvas.height / source.size.height)
        let fitted = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        let destination = NSRect(
            x: (canvas.width - fitted.width) / 2,
            y: (canvas.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
        let image = NSImage(size: canvas, flipped: false) { _ in
            source.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }
}
