import HeatPumpKit
import SwiftUI

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
                .padding(Theme.Space.m)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.hairline))
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
