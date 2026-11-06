---
name: design-system
description: Build or change SwiftUI views in the Varmepumpe app so they match its design system — tokens in Theme.swift, components in DesignSystem.swift/Components.swift/ChartKit.swift, the screen skeleton, cards, KPI tiles, charts, settings forms, sheets, empty and error states, accessibility. Use for any new screen, section, card, chart, settings tab or sheet, and when reviewing UI code.
---

# Varmepumpe design system

The look is calm and native: grouping by whitespace, neutral card surfaces, status shown by a
leading glyph in a semantic colour (never by tinting a surface), four categorical data colours,
system colours that adapt to light and dark mode. Reuse what exists; a new component is the last
resort and goes into `App/Sources/DesignSystem.swift` with a `///` comment.

Before writing a view, open the closest existing screen and copy its structure:
`AwayView.swift` (cards + confirmation sheet), `HealthView.swift` (KPIs + lists),
`HistoryView.swift` (charts), `LocalSettingsView.swift` (settings form).

## Tokens (`App/Sources/Theme.swift`)

| Token | Values | Use |
|---|---|---|
| `Theme.Space` | xs 4, s 8, m 12, l 16, xl 24, xxl 32 | all spacing and padding; no magic numbers |
| `Theme.Radius` | small 8, card 14, large 20 | small: tooltips, banners; card: cards |
| `Theme.Data` | blue, green, orange, purple; `inside` (orange), `outside` (blue), `setpoint` (secondary), `energy` (teal), `gridTariff` (purple), `electricity` (blue), `support` (green), `previous` (gray 0.7) | chart series and KPI glyphs; keep the meaning (indoor is always orange) |
| `Theme.Status` | good green, caution orange, bad red, info blue, neutral secondary | status glyphs and status text only |
| `Theme.surface`, `Theme.hairline` | control background, primary 8 % | card fill and 1 pt border |

Domain colours live next to the tokens as extensions: `OperationMode.systemImage/tint/gradient`,
`LocalPhase.tint`, `PriceLevel.color`, `HealthSeverity.color/systemImage`. Add new domain colours
the same way, in `Theme.swift`. Each sidebar screen has a badge colour in `Screen.color`.

Formatting: `Format.temperature/degrees/kWh/kroner/ore/watts/percent/percentShare/relative/countdown/hour/weekdayHour/dayMonth`
(app) and `Display.format/date/time/dateTime` (kit, locale-aware). Never format numbers with
`String(format:)` or hard-coded separators; numbers in UI get `.monospacedDigit()`.

## Screen skeleton

```swift
struct ExampleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                StatusBanner()            // always first: stale, blocked, error
                summarySection
                detailSection
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1000, alignment: .leading)   // 900 forms, 1000 lists, 1100 charts/dashboards
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Summary
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Title", hint: "Short secondary context")
            CardSurface {
                VStack(alignment: .leading, spacing: Theme.Space.m) { … }
            }
        }
    }
}
```

- Sections: `VStack(spacing: Theme.Space.m) { SectionHeader; CardSurface { … } }`.
- Narrow windows (min 620 pt): wrap side-by-side content in `ViewThatFits(in: .horizontal) { HStack {…}; VStack {…} }`;
  chip rows and legends use `FlowLayout`.
- Rows inside a card are separated with `Divider()`.
- Footnotes: `.font(.caption).foregroundStyle(.secondary)`.
- For dev screenshots, give sections `.id("name")` and wrap the ScrollView in a
  `ScrollViewReader` with `.devScrollTarget(proxy)` (see `OverviewView`).
- Register a new screen in `Screen` (`AppModel.swift`: `title`, `systemImage`, `color`) and in the
  `detail` switch in `RootView.swift`.

## Components

| Component | Use for |
|---|---|
| `CardSurface(padding:) { }` | any self-contained group; the only card container |
| `SectionHeader(_ title, hint:)` / `SectionHeader(title:hint:) { trailing }` | every section title (`title3.semibold`) |
| `KPITile(label:value:detail:delta:systemImage:tint:)` in `KPIRow(minimum:) { }` | key numbers at the top of a screen; `Delta.between(cur, prev, higherIsGood:)` for period change |
| `InsightCard(title:detail:systemImage:tint:action:)` | explanations, results of an action, a finding; tappable with `action` |
| `TrendCard(title:value:delta:) { legend } chart: { }` | a chart with heading and legend |
| `LegendDot(label:color:dashed:)` | chart legends (dashed = previous period/target) |
| `EmptyChart(title:message:systemImage:)` | no data yet for a chart or list |
| `ContentUnavailableView` | whole screen without data |
| `StatusBanner()` | first child of every scrolling screen |
| `StatusChip(status:remaining:)` | auto-send state in Control/Overview |
| `SettingChip(title:systemImage:tint:action:)` | tappable current-setting chips |
| `IconBadge(systemImage:color:size:)` | sidebar, Settings rows, list leading icons |
| `ThermostatDial(...)` | the setpoint dial (Overview) |
| `DemoBadge`, `UpdateReadyBadge` | sidebar footer |
| `FlowLayout(spacing:lineSpacing:alignment:)` | wrapping rows of chips or legends |

## Charts (`App/Sources/ChartKit.swift`)

- Lines `.interpolationMethod(.monotone)`; setpoints `.stepEnd` with `ChartKit.setpointStroke`;
  previous period/forecast `ChartKit.previousStroke`; areas `ChartKit.areaGradient(color)`.
- Axes: `.calmYAxis { Display.format("%.0f", $0) }` and `.calmXAxis(Date.FormatStyle…, count:)`.
- Hover: `.chartXSelection(value: $selected)`, `nearest(items, to: selected, by: \.date)`, a
  `RuleMark` with `.annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) { ChartTooltip(title:rows:) }`.
- A "now" `RuleMark` in `Color.secondary.opacity(0.5)` when the chart spans past and future.
- Heights 110–300 via `.frame(height:)`. Every chart gets `.accessibilityLabel("…")`.
- Series identity uses stable keys (`series: .value("Series", "indoor")`), never localized text.

## Settings tabs

```swift
Form {
    Section {
        Toggle(isOn: $enabled) {
            Label { Text("Main switch") } icon: { IconBadge(systemImage: "wifi.router", color: .teal) }
        }
        LabeledContent("Value") {
            TextField("Value", text: $value).labelsHidden().frame(width: 120).multilineTextAlignment(.trailing)
        }
        HStack { statusLabel; Spacer(); Button("Save") { … }.buttonStyle(.borderedProminent).disabled(!changed) }
    } header: { Text("Section") } footer: { Text("What it does and its limits.") }
    Section { Label("…", systemImage: "lock.shield") } header: { Text("Good to know") }
        .font(.callout).foregroundStyle(.secondary)
}
.formStyle(.grouped)
.task { guard !loaded else { return }; loaded = true; … }
```

Tabs are listed in `SettingsView.swift`; tab tags are stable identifiers (`generelt`, `konto`, …)
used by `VARMEPUMPE_SETTINGS_TAB`, do not rename them.

## Sheets and confirmations

`VStack(alignment: .leading, spacing: Theme.Space.l)` with a `Label(…).font(.title2.bold())`
title, explanation in `.callout` secondary, buttons right-aligned: Cancel (`.cancelAction`) and a
`.borderedProminent` primary. `.padding(Theme.Space.xl)`, fixed `.frame(width: 420…580)`. Use
`.sheet(item:)` with an `Identifiable` wrapper. Destructive choices use `confirmationDialog`.
Any change sent to a device from a non-Control screen is confirmed in a sheet first.

## Errors, status, empty states

- No `.alert`. Inline: `Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.Status.caution)`
  or an `InsightCard` with a status tint. Success: `checkmark.circle.fill` in `Theme.Status.good`.
- Actions in `AppModel` return `(ok: Bool, message: String)` or `String?`; show the message where
  the action was taken.
- Loading: `ProgressView().controlSize(.small)` next to the control, not a full-screen spinner.

## Accessibility and text

- `.accessibilityElement(children: .combine)` on tiles and cards; `.isSelected` traits on choice
  buttons; `.help("…")` on icon-only buttons; adjustable actions on custom controls.
- Localize everything (see the `localization` skill): literals in `Text`/`Button`/component
  `LocalizedStringKey` parameters are extracted automatically; text that is already localized
  (from the kit, the device or the user) goes through `.verbatim(text)`; computed strings use
  `String(localized:)`. Never concatenate sentence fragments.
- Sentence case for titles and labels; title case for menu items and short command buttons
  ("Restart Now", "Find Automatically").

## Checklist before you finish

- Tokens only (no raw spacing, radii or colours outside `Theme`), components reused.
- Works at 620 pt width and in dark mode: `scripts/screenshot.sh /tmp/x.png VARMEPUMPE_SCREEN=<screen> VARMEPUMPE_APPEARANCE=dark SIZE=620x700`
  and look at the image.
- English and Norwegian both fit (`LANG_CODE=nb`).
- `make check` passes; `python3 scripts/l10n.py check` passes after `make l10n` + translations.
