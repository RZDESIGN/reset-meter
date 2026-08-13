import AppKit
import SwiftUI
import UsageMeterCore

struct StatusLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Image(nsImage: MenuBarArtwork.image(
            codexPercent: store.menuRemainingPercent(for: .codex),
            claudePercent: store.menuRemainingPercent(for: .claude),
            cursorPercent: store.menuRemainingPercent(for: .cursor)
        ))
        .renderingMode(.template)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityLabel(store.menuSummary)
    }
}

@MainActor
private enum MenuBarArtwork {
    private static let height: CGFloat = 18
    private static let iconSize: CGFloat = 14
    private static let barSize = NSSize(width: 24, height: 5)
    private static let innerSpacing: CGFloat = 3
    private static let providerSpacing: CGFloat = 8
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    static func image(codexPercent: Int?, claudePercent: Int?, cursorPercent: Int?) -> NSImage {
        let entries: [(UsageProvider, Int?)] = [
            (.codex, codexPercent),
            (.claude, claudePercent),
            (.cursor, cursorPercent),
        ]
        let labels = entries.map { label(for: $0.1) }
        let widths = labels.map { ceil($0.size().width) }
        let entryWidths = widths.map {
            iconSize + innerSpacing + barSize.width + innerSpacing + $0
        }
        let totalWidth = ceil(
            entryWidths.reduce(0, +) + providerSpacing * CGFloat(max(0, entries.count - 1))
        )

        let image = NSImage(
            size: NSSize(width: totalWidth, height: height),
            flipped: false
        ) { _ in
            var x: CGFloat = 0
            for index in entries.indices {
                let entry = entries[index]
                if let icon = ProviderArtwork.image(for: entry.0, size: iconSize) {
                    icon.draw(
                        in: NSRect(x: x, y: (height - iconSize) / 2, width: iconSize, height: iconSize),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1
                    )
                }
                x += iconSize + innerSpacing

                drawBar(percent: entry.1, at: NSPoint(x: x, y: (height - barSize.height) / 2))
                x += barSize.width + innerSpacing

                let label = labels[index]
                label.draw(at: NSPoint(x: x, y: floor((height - label.size().height) / 2)))
                x += widths[index]

                if index < entries.index(before: entries.endIndex) {
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

    var body: some View {
        VStack(spacing: 12) {
            header

            ProviderCard(
                provider: .codex,
                usage: store.codex,
                error: store.codexError,
                tint: Color(red: 0.20, green: 0.48, blue: 0.98),
                iconTint: .primary
            )

            ProviderCard(
                provider: .claude,
                usage: store.claude,
                error: store.claudeError,
                tint: Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
            )

            ProviderCard(
                provider: .cursor,
                usage: store.cursor,
                error: store.cursorError,
                tint: Color(red: 0.48, green: 0.42, blue: 0.96),
                iconTint: .primary
            )

            footer
        }
        .padding(14)
        .frame(width: 348)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Reset Meter")
                    .font(.headline)
                Text("Remaining usage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.055), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let refreshed = store.lastRefresh {
                Text("Updated \(refreshed, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ProviderCard: View {
    let provider: UsageProvider
    let usage: ProviderUsage?
    let error: String?
    let tint: Color
    var iconTint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ProviderIcon(provider: provider, size: 28, tint: iconTint ?? tint)

                Text(provider.displayName)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if usage?.isStale == true {
                    Text("STALE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }

            if let usage {
                ForEach(usage.limits) { limit in
                    LimitRow(limit: limit, tint: tint)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(usage.isStale ? Color.orange : Color.green)
                        .frame(width: 5, height: 5)
                    Text(usage.sourceDescription)
                    if usage.limits.contains(where: \.resetIsEstimated) {
                        Text("· reset ≈ estimated")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            } else {
                Text(error ?? "Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct LimitRow: View {
    let limit: UsageLimit
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(limit.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(limit.displayPercent.rounded()))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(barColor)
                            .frame(width: geometry.size.width * limit.displayPercent / 100)
                    }
                }
                .frame(height: 7)

                HStack {
                    Spacer()
                    Text(resetText(now: context.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
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

    private func resetText(now: Date) -> String {
        guard let reset = limit.resetsAt else { return "Reset unavailable" }
        let prefix = limit.resetIsEstimated ? "Resets ≈ " : "Resets in "
        return prefix + Self.duration(max(0, reset.timeIntervalSince(now)))
    }

    private static func duration(_ interval: TimeInterval) -> String {
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

private struct ProviderIcon: View {
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
                    .padding(size * 0.2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: size * 0.22))
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
        case .cursor: "cursorarrow"
        }
    }
}

private enum ProviderArtwork {
    static func image(for provider: UsageProvider, size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: provider.rawValue, withExtension: "svg") else {
            return nil
        }
        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else {
            return nil
        }

        // MenuBarExtra can otherwise honor the SVG's large intrinsic canvas.
        // Render onto a native point-sized square while preserving each logo's
        // original aspect ratio (Cursor's official cube is slightly taller).
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
