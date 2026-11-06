import HeatPumpKit
import SwiftUI

/// Banner for stale, blocked or failed data, from `StateResult`.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    /// Outer padding, applied only when there is something to show.
    var inset: CGFloat = 0
    /// Space below the banner, only when it is shown (so an empty banner takes no room).
    var bottomSpacing: CGFloat = 0

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
                .padding(.bottom, bottomSpacing)
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
                text: result.blockMessage ?? result.error ?? String(localized: "Log in to \(model.serviceName) in Settings."),
                icon: "person.crop.circle.badge.exclamationmark", color: .orange)
        }
        if let until = result.blockedUntil, until > now {
            // The text comes from the block reason (traffic, login attempts, refused access).
            let reason = result.blockMessage ?? BlockReason.rateLimited.message(until: until, serviceName: model.serviceName)
            return Message(
                text: String(localized: "\(reason) (in \(Format.countdown(to: until, now: now))). Showing saved data."),
                icon: "hourglass", color: .orange)
        }
        if let error = result.error {
            return Message(text: String(localized: "Could not fetch new status: \(error) Showing saved data."), icon: "wifi.exclamationmark", color: .orange)
        }
        if result.stale, let age = result.dataAgeSeconds, age > 15 * 60 {
            return Message(
                text: String(localized: "The data is \(age / 60) minutes old."), icon: "clock.arrow.circlepath", color: .secondary)
        }
        return nil
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("Demo data")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.purple.opacity(0.15), in: Capsule())
            .foregroundStyle(.purple)
            .help("The app is running with simulated data (VARMEPUMPE_BACKEND=mock).")
    }
}

/// Lets the user resize the hosting window; SwiftUI's Settings window is fixed-size otherwise.
/// The minimum size comes from the content's frame.
struct ResizableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.styleMask.insert(.resizable) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Dev only (`VARMEPUMPE_SCROLL_TO`): scrolls a screen to the section with that id once, a moment
/// after it appears, so screenshots can show sections below the fold without input events.
struct DevScrollTarget: ViewModifier {
    let proxy: ScrollViewProxy
    @State private var done = false

    func body(content: Content) -> some View {
        content.task {
            guard !done, let target = ProcessInfo.processInfo.environment["VARMEPUMPE_SCROLL_TO"] else { return }
            done = true
            try? await Task.sleep(for: .seconds(3))
            proxy.scrollTo(target, anchor: .top)
        }
    }
}

extension View {
    func devScrollTarget(_ proxy: ScrollViewProxy) -> some View { modifier(DevScrollTarget(proxy: proxy)) }
}
