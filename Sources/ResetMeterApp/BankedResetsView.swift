import SwiftUI
import UsageMeterCore

/// One caption-sized line by default. Per-reset expiries expand on demand, so
/// an account without banked resets costs a single row instead of a section.
struct BankedResetsView: View {
    let resets: BankedResets?
    @State private var isExpanded = false

    private var credits: [BankedReset] { resets?.credits ?? [] }
    private var missingDetailCount: Int { resets?.missingDetailCount ?? 0 }
    private var hasDetail: Bool { !credits.isEmpty || missingDetailCount > 0 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 5) {
                summary(now: context.date)
                if isExpanded {
                    detail(now: context.date)
                }
            }
            .font(.caption2)
        }
    }

    @ViewBuilder private func summary(now: Date) -> some View {
        let row = HStack(spacing: 5) {
            Image(systemName: "arrow.counterclockwise.circle")
            Text("Banked resets")
            Spacer()
            Text(summaryValue(now: now))
                .monospacedDigit()
            if hasDetail {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())

        if hasDetail {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                row
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide each reset's expiry" : "Show each reset's expiry")
        } else {
            row
        }
    }

    @ViewBuilder private func detail(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                HStack(spacing: 6) {
                    Text("Reset \(index + 1)")
                    Spacer()
                    expiration(credit.expiration, now: now)
                }
            }
            if missingDetailCount > 0 {
                Text(missingDetailCount == resets?.availableCount
                     ? "Expiry details unavailable"
                     : "Expiry details unavailable for \(missingDetailCount) more")
            }
        }
        .foregroundStyle(.tertiary)
    }

    private func summaryValue(now: Date) -> String {
        guard let resets else { return "Unavailable" }
        guard resets.availableCount > 0 else { return "None" }
        guard let next = nextExpiry, next > now else { return "\(resets.availableCount)" }
        return "\(resets.availableCount) · next in \(UsageCountdown.duration(next.timeIntervalSince(now)))"
    }

    private var nextExpiry: Date? {
        credits.compactMap { credit -> Date? in
            if case .date(let date) = credit.expiration { return date }
            return nil
        }.min()
    }

    @ViewBuilder private func expiration(_ expiration: ResetExpiration, now: Date) -> some View {
        switch expiration {
        case .date(let date):
            Text(date > now
                 ? "in \(UsageCountdown.duration(date.timeIntervalSince(now))) · \(date.formatted(date: .abbreviated, time: .omitted))"
                 : "expired · refresh to update")
                .monospacedDigit()
                .help(date.formatted(date: .complete, time: .complete))
        case .never:
            Text("no expiry")
        case .unknown:
            Text("expiry unavailable")
        }
    }
}
