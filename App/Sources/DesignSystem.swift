import HeatPumpKit
import SwiftUI

/// Neutral container for one self-contained item.
struct CardSurface<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Section title with an optional secondary hint on the right.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(title).font(.title3.weight(.semibold))
            Spacer(minLength: Theme.Space.s)
            if let hint { Text(hint).font(.callout).foregroundStyle(.secondary) }
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, hint: String? = nil) {
        self.init(title: title, hint: hint) { EmptyView() }
    }
}

/// Change vs. previous period with arrow and semantic colour.
struct Delta: Equatable {
    var percent: Double
    /// Whether an increase is good (green) or bad (amber/red).
    var higherIsGood: Bool

    var color: Color {
        if abs(percent) < 1 { return Theme.Status.neutral }
        let good = (percent > 0) == higherIsGood
        return good ? Theme.Status.good : (abs(percent) > 20 ? Theme.Status.bad : Theme.Status.caution)
    }

    var arrow: String {
        if abs(percent) < 1 { return "arrow.right" }
        return percent > 0 ? "arrow.up.right" : "arrow.down.right"
    }

    static func between(_ current: Double?, _ previous: Double?, higherIsGood: Bool) -> Delta? {
        guard let current, let previous, abs(previous) > 0.0001 else { return nil }
        return Delta(percent: (current - previous) / abs(previous) * 100, higherIsGood: higherIsGood)
    }
}

/// KPI tile: secondary label, large value, delta vs previous period.
struct KPITile: View {
    let label: String
    let value: String
    var detail: String?
    var delta: Delta?
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xs) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(tint) }
                Text(label).foregroundStyle(.secondary)
            }
            .font(.callout)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let delta {
                Label(Format.percent(delta.percent) + " mot forrige periode", systemImage: delta.arrow)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(delta.color)
            } else if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Small coloured dot + label for chart legends.
struct LegendDot: View {
    let label: String
    let color: Color
    var dashed = false

    var body: some View {
        HStack(spacing: 6) {
            if dashed {
                Capsule().stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 14, height: 2)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(label).font(.caption).foregroundStyle(.secondary).fixedSize()
        }
    }
}

/// Status conveyed by a leading glyph in semantic colour, on a neutral surface.
struct InsightCard: View {
    let title: String
    var detail: String?
    let systemImage: String
    let tint: Color
    var action: (() -> Void)?

    var body: some View {
        let content = HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(.body.weight(.semibold))
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if action != nil { Image(systemName: "chevron.right").foregroundStyle(.tertiary).padding(.top, 2) }
        }
        CardSurface { content }
            .contentShape(Rectangle())
            .onTapGesture { action?() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

/// Trend card: title, current value, change vs previous period, legend, chart.
struct TrendCard<Chart: View, Legend: View>: View {
    let title: String
    var value: String?
    var delta: Delta?
    @ViewBuilder var legend: Legend
    @ViewBuilder var chart: Chart

    var body: some View {
        CardSurface {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        heading
                        Spacer()
                        legend
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        heading
                        legend
                    }
                }
                chart
            }
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title).font(.headline)
            if let value { Text(value).font(.headline).foregroundStyle(.secondary).monospacedDigit() }
            if let delta {
                Text(Format.percent(delta.percent) + " mot forrige periode")
                    .font(.caption.weight(.medium)).foregroundStyle(delta.color)
            }
        }
        .fixedSize()
    }
}

/// Auto-send status chip for the Kontroll screen and the dial.
struct StatusChip: View {
    let status: AutoSendStatus
    var remaining: Int?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if status != .idle {
                HStack(spacing: 6) {
                    icon
                    Text(status.text).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: 340, alignment: .leading)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .help(status.text)
                .transition(.opacity)
            }
            if let remaining, remaining < 4 {
                Text("\(remaining) endringer igjen denne timen")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(remaining == 0 ? Theme.Status.bad : Theme.Status.caution)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: status)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .idle: EmptyView()
        case .edited: Image(systemName: "pencil").foregroundStyle(.secondary)
        case .waiting: Image(systemName: "hourglass").foregroundStyle(Theme.Status.caution)
        case .sending: ProgressView().controlSize(.mini)
        case .sent: Image(systemName: "paperplane.fill").foregroundStyle(Theme.Status.info)
        case .confirmed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Status.good)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.bad)
        }
    }
}

/// Rounded-square coloured icon like System Settings.
struct IconBadge: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// Tappable chip showing one setting (mode, power, fan, connection).
struct SettingChip: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .font(.callout.weight(.medium))
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .help("Åpne Kontroll")
    }
}

struct SeverityBadge: View {
    let severity: HealthSeverity

    var body: some View {
        Label(severity.displayName, systemImage: severity.systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(severity.color)
    }
}

/// Empty state with a short explanation.
struct EmptyChart: View {
    let title: String
    let message: String
    var systemImage = "chart.line.uptrend.xyaxis"

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, minHeight: 180)
    }
}

/// KPI tiles in a grid that wraps on narrow windows.
struct KPIRow<Content: View>: View {
    var minimum: CGFloat = 170
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: Theme.Space.l, alignment: .topLeading)], alignment: .leading, spacing: Theme.Space.l) {
            content
        }
    }
}
