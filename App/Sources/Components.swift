import HeatPumpKit
import SwiftUI

/// Calm card: caption, one primary value, optional detail.
struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension HealthSeverity {
    var color: Color {
        switch self {
        case .ok: .green
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }

    var systemImage: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

struct SeverityBadge: View {
    let severity: HealthSeverity

    var body: some View {
        Label(severity.displayName, systemImage: severity.systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(severity.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(severity.color.opacity(0.12), in: Capsule())
    }
}

extension OperationMode {
    var systemImage: String {
        switch self {
        case .heat: "flame"
        case .cool: "snowflake"
        case .dry: "drop"
        case .fan: "fan"
        case .auto: "arrow.triangle.2.circlepath"
        }
    }
}

enum Format {
    static func temperature(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Norwegian.format("%.1f °C", value)
    }

    static func kWh(_ value: Double) -> String { Norwegian.format("%.1f kWh", value) }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "ukjent" }
        if abs(now.timeIntervalSince(date)) < 45 { return "akkurat nå" }
        return date.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide).locale(Norwegian.locale))
    }

    static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds >= 3600 { return "\(seconds / 3600) t \(seconds % 3600 / 60) min" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Banner for stale, blocked or failed data, from `StateResult`.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    /// Outer padding, applied only when there is something to show.
    var inset: CGFloat = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let message = message(now: context.date) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: message.icon).foregroundStyle(message.color)
                    // No vertical fixedSize here: inside a non-scrolling layout it loops.
                    Text(message.text)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(message.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .padding(inset)
            }
        }
    }

    private struct Message {
        var text: String
        var icon: String
        var color: Color
    }

    private func message(now: Date) -> Message? {
        if let error = model.startupError { return Message(text: error, icon: "xmark.octagon", color: .red) }
        guard let result = model.stateResult else { return nil }
        if result.needsLogin {
            return Message(
                text: result.blockMessage ?? result.error ?? "Logg inn på MELCloud i Innstillinger.",
                icon: "person.crop.circle.badge.exclamationmark", color: .orange)
        }
        if let until = result.blockedUntil, until > now {
            // The text comes from the block reason (traffic, login attempts, refused access).
            let reason = result.blockMessage ?? BlockReason.rateLimited.message(until: until)
            return Message(
                text: "\(reason) (om \(Format.countdown(to: until, now: now))). Viser lagrede data.",
                icon: "hourglass", color: .orange)
        }
        if let error = result.error {
            return Message(text: "Kunne ikke hente ny status: \(error) Viser lagrede data.", icon: "wifi.exclamationmark", color: .orange)
        }
        if result.stale, let age = result.dataAgeSeconds, age > 15 * 60 {
            return Message(
                text: "Dataene er \(age / 60) minutter gamle.", icon: "clock.arrow.circlepath", color: .secondary)
        }
        return nil
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("Demo-data")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.purple.opacity(0.15), in: Capsule())
            .foregroundStyle(.purple)
            .help("Appen kjører med simulerte data (VARMEPUMPE_BACKEND=mock).")
    }
}
