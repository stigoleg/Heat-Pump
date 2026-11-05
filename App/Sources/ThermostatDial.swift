import AppKit
import HeatPumpKit
import SwiftUI

/// Round thermostat: a 270° arc over the current mode's allowed range with a draggable knob
/// for the set point (0.5 °C steps). The centre shows the room temperature and the set point.
/// Arrow keys and VoiceOver adjust in steps; −/+ buttons do the same.
struct ThermostatDial: View {
    let room: Double?
    let setpoint: Double
    let range: ClosedRange<Double>
    let step: Double
    let mode: OperationMode
    let isOn: Bool
    /// `commit` false while dragging; true on release, key press or button.
    let onChange: (Double, _ commit: Bool) -> Void

    @State private var dragValue: Double?
    @FocusState private var focused: Bool

    private let sweep = 270.0
    private let startAngle = 135.0  // degrees, 0 = east, clockwise

    private var shown: Double { dragValue ?? setpoint }
    private var tint: Color { isOn ? mode.tint : .gray }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let lineWidth = size * 0.07
            let radius = (size - lineWidth) / 2 - 6
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                arc(from: 0, to: 1)
                    .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .padding(lineWidth / 2 + 6)
                arc(from: 0, to: fraction(shown))
                    .stroke(
                        AngularGradient(
                            colors: isOn ? mode.gradient : [.gray.opacity(0.4), .gray.opacity(0.6)],
                            center: .center, startAngle: .degrees(startAngle), endAngle: .degrees(startAngle + sweep)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .padding(lineWidth / 2 + 6)
                ticks(radius: radius, lineWidth: lineWidth)
                knob(size: lineWidth * 1.35)
                    .position(point(for: fraction(shown), radius: radius, center: center))
                    .gesture(drag(center: center))
                centre(size: size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .opacity(isOn ? 1 : 0.55)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { nudge(+1); return .handled }
        .onKeyPress(.rightArrow) { nudge(+1); return .handled }
        .onKeyPress(.downArrow) { nudge(-1); return .handled }
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ønsket temperatur")
        .accessibilityValue(Format.temperature(setpoint))
        .accessibilityHint(room.map { "Inne er det \(Format.temperature($0))." } ?? "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(+1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    // MARK: Parts

    private func arc(from: Double, to: Double) -> some Shape {
        DialArc(startAngle: startAngle + sweep * from, endAngle: startAngle + sweep * max(from, to))
    }

    private func ticks(radius: CGFloat, lineWidth: CGFloat) -> some View {
        let count = Int(((range.upperBound - range.lowerBound) / 1).rounded())
        return ZStack {
            ForEach(0...max(count, 1), id: \.self) { i in
                let f = Double(i) / Double(max(count, 1))
                let angle = Angle.degrees(startAngle + sweep * f)
                Capsule()
                    .fill(Color.primary.opacity(i % 5 == 0 ? 0.25 : 0.1))
                    .frame(width: 1.5, height: i % 5 == 0 ? lineWidth * 0.45 : lineWidth * 0.25)
                    .offset(y: -(radius - lineWidth * 0.95))
                    .rotationEffect(angle + .degrees(90))
            }
        }
    }

    private func knob(size: CGFloat) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(tint, lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .frame(width: size, height: size)
            .contentShape(Circle().inset(by: -10))
            .help("Dra for å endre ønsket temperatur")
    }

    private func centre(size: CGFloat) -> some View {
        VStack(spacing: size * 0.02) {
            Text("Inne").font(.callout).foregroundStyle(.secondary)
            Text(Format.degrees(room))
                .font(.system(size: size * 0.2, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("Ønsket \(Format.temperature(shown))")
                .font(.system(size: max(13, size * 0.055), weight: .medium, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
            HStack(spacing: size * 0.08) {
                stepButton("minus", delta: -1)
                stepButton("plus", delta: +1)
            }
            .padding(.top, size * 0.03)
            if !isOn {
                Text("Av").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func stepButton(_ symbol: String, delta: Int) -> some View {
        Button {
            nudge(delta)
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(delta > 0 ? "Varmere" : "Kaldere")
        .disabled(delta > 0 ? setpoint >= range.upperBound : setpoint <= range.lowerBound)
    }

    // MARK: Geometry and input

    private func fraction(_ value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func point(for fraction: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = (startAngle + sweep * fraction) * .pi / 180
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private func snapped(_ value: Double) -> Double {
        let s = step > 0 ? step : 0.5
        return min(max((value / s).rounded() * s, range.lowerBound), range.upperBound)
    }

    private func drag(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                var angle = atan2(gesture.location.y - center.y, gesture.location.x - center.x) * 180 / .pi
                if angle < 0 { angle += 360 }
                var relative = angle - startAngle
                if relative < 0 { relative += 360 }
                // In the gap at the bottom: stick to the nearest end.
                if relative > sweep { relative = relative - sweep < (360 - sweep) / 2 ? sweep : 0 }
                let value = snapped(range.lowerBound + (range.upperBound - range.lowerBound) * relative / sweep)
                if value != dragValue {
                    if dragValue != nil {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    dragValue = value
                    onChange(value, false)
                }
            }
            .onEnded { _ in
                if let value = dragValue { onChange(value, true) }
                dragValue = nil
            }
    }

    private func nudge(_ steps: Int) {
        let value = snapped(setpoint + Double(steps) * (step > 0 ? step : 0.5))
        guard value != setpoint else { return }
        onChange(value, true)
    }
}

private struct DialArc: Shape {
    var startAngle: Double
    var endAngle: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle), clockwise: false)
        return path
    }
}
