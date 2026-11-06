---
name: localization
description: Add or change user-facing text in Varmepumpe with English as source and Norwegian bokmål as the required translation — L10n.tr/L10n.format in the package and MCP helper, SwiftUI literals and String(localized:) in the app, plurals, the string catalogs, scripts/l10n.py and the terminology glossary. Use whenever you add, change or review any text a user or Claude sees.
---

# Localization (English source, Norwegian bokmål translation)

The language follows macOS or the choice in Settings → General → Language (after restart). The
MCP helper follows the app. CI (`python3 scripts/l10n.py check`) and the unit test
`L10nTests.kitCatalogIsCompleteAndTranslated` fail when a key has no Norwegian translation or
when format specifiers differ between key and translation.

## Where text goes

**Package (`Packages/HeatPumpKit/Sources/**`, including `varmepumpe-mcp`)**
- `L10n.tr("English text")` and `L10n.format("Filter cleaned %lld days ago", days)`.
- The key must be one plain string literal passed directly. No `\(…)` interpolation (the script
  exits), no concatenation, no variables. Specifiers: `%@` String, `%lld` Int, `%.0f`/`%.1f` Double;
  positional `%1$@` only when Norwegian needs another order.
- Strings live in `App/Resources/HeatPumpKit.xcstrings`, maintained by the script
  (`extractionState: manual`).
- Under `swift test` there is no app bundle, so `L10n.tr` returns the English key: tests assert English.
- Numbers and dates: `Display.format("%.1f °C", x)`, `Display.date/time/dateTime` (locale-aware, not translated).
- MCP tool `description`s stay plain English (they are for Claude); `note`/`message` texts that reach
  the user go through `L10n`.

**App (`App/Sources`)**
- SwiftUI literals are extracted by the compiler: `Text("…")`, `Button("…")`, `Label("…", systemImage:)`,
  `Toggle`, `Picker`, `Section("…")`, `LabeledContent`, `.help("…")`, `.accessibilityLabel("…")`,
  and component parameters typed `LocalizedStringKey` (`SectionHeader`, `KPITile`, `InsightCard`,
  `TrendCard`, `LegendDot`, `EmptyChart`, `SettingChip`, `ChartTooltip` rows). Interpolation is fine:
  `Text("Lowest: \(Format.temperature(x))")`.
- Code that builds a `String` (enum titles, helpers, `AppModel` messages, notifications):
  `String(localized: "Sent \(name): \(value)")`. A plain `String` literal is not localized.
- Text that is already localized or is data (kit output, device names, user input):
  `Text(string)` or `.verbatim(string)` for `LocalizedStringKey` parameters. Never put a
  translatable literal inside `.verbatim`. Non-translatable literals: `Text(verbatim: "°C")`.
- `Info.plist` strings: `App/Resources/InfoPlist.xcstrings`.

**Rules for both**
- One key per sentence. Never build sentences from fragments (`"a" + x`, `Text("a") + Text(x)`,
  `displayName.lowercased()` inside a sentence).
- Plurals: one key with the count; give `one`/`other` variants in the translations file (below).
  No `n == 1 ? … : …` branching.
- Never localize identifiers: enum raw values, finding `code`s, DB tables/columns/settings keys,
  UserDefaults keys, MCP tool and argument names, prompt name `helsesjekk`, resource URIs,
  settings-tab tags (`generelt`, `konto`, `strompris`, `lokal`, `vaer`, `claude`, `data`),
  keychain names, `VARMEPUMPE_*` variables, log lines, text passed through from MELCloud/Tibber.
- Do not compare display text in logic (filter on enums or keys instead).
- The service, vendor and unit are never literals in core, app or MCP texts: pass
  `serviceName` (or `integration.brandName`, `modelName`) as `%@`, e.g.
  `L10n.format("%@ did not accept the login.", serviceName)` or
  `Text("Sent to \(model.serviceName)")`. `BoundaryTests` fails otherwise.

## Workflow

```sh
make l10n                                   # make debug + sync catalogs + list missing nb
# write translations to a JSON file (scratchpad), then:
make l10n TRANSLATIONS="/path/to/nb.json"
python3 scripts/l10n.py missing --source App/Sources/MyView.swift   # per file
python3 scripts/l10n.py missing --table HeatPumpKit                 # package keys
python3 scripts/l10n.py check                                       # what CI runs
```

Translations file:

```json
{
  "Localizable": { "Sent %@: %@": "Sendt %1$@: %2$@" },
  "HeatPumpKit": {
    "Not sent: %@": "Ikke sendt: %@",
    "%lld defrosts": {
      "en": { "one": "%lld defrost", "other": "%lld defrosts" },
      "nb": { "one": "%lld avriming", "other": "%lld avriminger" }
    }
  }
}
```

App keys are the compiler's form: interpolations become `%@` (String and most types), `%lld` (Int),
`%lf` (Double without format). Do not guess keys: run `make l10n` and copy them from `missing`.
`sync` drops keys no longer in the sources (use `--keep-unused` to keep them) and never hand-edit
the `.xcstrings` files.

Knowledge documents (`Packages/HeatPumpKit/Sources/<Target>/Knowledge/{en,nb}/*.md`, today
`MELCloudIntegration`) are separate: edit both languages, then
`python3 Packages/HeatPumpKit/scripts/generate-knowledge.py`.

## Style

- Plain, calm, precise US English for people who know nothing about heat pumps; about as short as
  the Norwegian (narrow layouts). Sentence case; title case for menu items and short command
  buttons. Use "…" and curly quotes “…”.
- Norwegian bokmål, natural and idiomatic, not a word-for-word translation. «…» quotes in Norwegian.
- Units unchanged (°C, kWh, W, Hz, øre); "kr" is "NOK" in English.

## Glossary (use exactly)

| English | Norwegian |
|---|---|
| Heat Pump (the app) / the heat pump (device) | Varmepumpe / varmepumpen |
| Overview, Control, Weekly schedule, History, Forecast, Away, Health, Claude activity | Oversikt, Kontroll, Ukeplan, Historikk, Prognose, Borte hjemmefra, Helse, Claude-aktivitet |
| Settings: General, Account, Electricity price, Local connection, Weather, Claude, Data | Generelt, Konto, Strømpris, Lokal tilkobling, Vær, Claude, Data |
| Price control | Prisstyring |
| Norgespris (fixed price) | Norgespris |
| spot price, electricity contract, price area | spotpris, strømavtale, prisområde |
| grid tariff, energy charge, capacity charge | nettleie, energiledd, kapasitetsledd |
| electricity subsidy | strømstøtte |
| estimate / estimated | anslag |
| target temperature, indoor temperature, outdoor | ønsket temperatur, innetemperatur, ute |
| Heat, Cool, Dry, Fan, Auto | Varme, Kjøling, Tørking, Vifte, Auto |
| fan speed, airflow direction, vertical, horizontal, swing | viftehastighet, luftretning, vertikal, horisontal, sving |
| power, consumption | effekt, forbruk |
| defrosting / a defrost | avriming |
| short cycling, compressor starts, resting | korte sykluser, kompressorstarter, hvile |
| frost protection, holiday mode | frostsikring, feriemodus |
| firmware, Wi-Fi adapter, local connection, home network | fastvare, Wi-Fi-modul, lokal tilkobling, hjemmenettet |
| error log, error code, dealer | feillogg, feilkode, forhandler |
| filter cleaning, air filter | filterrengjøring, luftfilter |
| health check, finding | helsesjekk, funn |
| Approve, Reject, reason | Godkjenn, Avvis, begrunnelse |
| change log; Sent, Confirmed, Rejected, Failed | endringslogg; Sendt, Bekreftet, Avvist, Feilet |
| event, template, season (weekly schedule) | hendelse, mal, sesong |
| weather forecast, degree days | værvarsel, graddager |
| household electricity use | husets strømforbruk |
| block (temporarily blocked by MELCloud) | sperre |
| cache | hurtigbuffer |
| Refresh Now, Check for Updates…, Install and Restart, Restart Now | Oppdater nå, Se etter oppdateringer …, Installer og start på nytt, Start på nytt nå |
| integration, device, energy meter, water heater | integrasjon, enhet, strømmåler, varmtvannsbereder |
| live power (meter), real-time meter reader, token (Tibber) | effekt nå, sanntidsmåler, nøkkel |
| Home (sidebar group with two or more devices), Devices, Add Integration…, Refresh Device List | Hjem, Enheter, Legg til integrasjon …, Oppdater enhetslisten |

Add new terms here when you introduce them.
