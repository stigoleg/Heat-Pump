import Charts
import SwiftUI

/// Shared chart styling: horizontal grid lines only, no axis or tick lines, gradient areas,
/// and a small tooltip card for the hovered value.
enum ChartKit {
    static func areaGradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.3), color.opacity(0.04)], startPoint: .top, endPoint: .bottom)
    }

    static let previousStroke = StrokeStyle(lineWidth: 1.2, dash: [4, 3])
    static let setpointStroke = StrokeStyle(lineWidth: 1.2, dash: [5, 3])
}

extension View {
    /// Y axis: horizontal grid lines and labels only.
    func calmYAxis(_ format: @escaping (Double) -> String = { Display.format("%.0f", $0) }) -> some View {
        chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(format(v)).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }

    /// X axis: labels only, no grid, ticks or axis line. A little room after the plot keeps a
    /// label on the last tick from being clipped. Labels that would overlap in a narrow chart
    /// are skipped.
    func calmXAxis(_ format: Date.FormatStyle, count: Int = 6) -> some View {
        chartPlotStyle { plot in plot.padding(.trailing, 14) }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: count)) { value in
                AxisValueLabel(collisionResolution: .greedy(minimumSpacing: 6)) {
                    if let d = value.as(Date.self) {
                        Text(d.formatted(format.locale(Display.locale))).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Small card shown at the hovered position.
struct ChartTooltip: View {
    let title: String
    let rows: [(label: LocalizedStringKey, value: String, color: Color)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 6, height: 6)
                    Text(row.label).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(row.value).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 140)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.hairline))
    }
}

/// Nearest element to a selected x value.
func nearest<T>(_ items: [T], to date: Date?, by key: (T) -> Date) -> T? {
    guard let date else { return nil }
    return items.min { abs(key($0).timeIntervalSince(date)) < abs(key($1).timeIntervalSince(date)) }
}

import HeatPumpKit
