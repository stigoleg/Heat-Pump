# Varmepumpe (Heat Pump)

A macOS 26 SwiftUI app that monitors and controls home energy equipment, today a Mitsubishi
air-to-air heat pump through MELCloud, plus an embedded MCP server (`varmepumpe-mcp`) that lets
Claude read the data and propose changes the user approves on the Mac. Published on GitHub
(`stigoleg/Heat-Pump`), GPL-3.0, English UI with a full Norwegian bokmål translation.

Architecture, concepts and the feature parity checklist: [docs/architecture.md](docs/architecture.md).

## Layout

| Path | What |
|---|---|
| `App/Sources` | SwiftUI app: `AppModel` (`@MainActor @Observable`, app-wide) with a model per device (`DeviceModels.swift`) and `DeviceUIRegistry`, one `XView.swift` per screen, Settings tabs, design system (`Theme.swift`, `DesignSystem.swift`, `ChartKit.swift`, `Components.swift`) |
| `App/Resources` | String catalogs: `Localizable.xcstrings` (app), `HeatPumpKit.xcstrings` (package), `InfoPlist.xcstrings` |
| `Packages/HeatPumpKit/Sources/HeatPumpKit` | Vendor-neutral core, all rules and data: capability protocols, models, `DeviceHub` (the entry point; one `HeatPumpService` actor per device, a shared `EnergyContextService`), `EnergyMeterService` per energy meter, SQLite `HistoryStore` (GRDB), pricing, weather, health engine, local access, L10n |
| `Packages/HeatPumpKit/Sources/MELCloudIntegration`, `TibberIntegration`, `DemoIntegration`, `Integrations` | Integrations (connection, error codes, health rules, knowledge docs) and `IntegrationCatalog`; Tibber (homes as energy meters) is the reference example; see the module map in docs/architecture.md |
| `Packages/HeatPumpKit/Sources/varmepumpe-mcp` | MCP server embedded in the app bundle (`Contents/Helpers`); tools in `Tools.swift`, handlers in `ToolHandler.swift` |
| `Packages/HeatPumpKit/Tests/HeatPumpKitTests` | Swift Testing suites, JSON fixtures, `TestSupport.swift` helpers |
| `project.yml` | XcodeGen source of truth; `.xcodeproj` is generated and not checked in |
| `scripts/` | `l10n.py` (catalogs), `release.sh`, `screenshot.sh`, `parity.sh` |

The app holds no business rules: views call `AppModel` or their device's model, which call the kit. Keep it that way.

## Commands

```sh
make test        # package unit tests (swift test) — run after every kit change
make check       # tests + Debug build of the app — run before saying you are done
make demo        # app with simulated data, own DB in build/demo/ (LANGUAGE=en|nb)
make l10n        # sync string catalogs, list missing Norwegian translations
python3 scripts/l10n.py check                     # what CI runs for translations
python3 Packages/HeatPumpKit/scripts/generate-knowledge.py   # after editing Knowledge/*.md
scripts/screenshot.sh out.png VARMEPUMPE_SCREEN=…   # one demo window, fixed size
scripts/parity.sh capture|compare …                 # visual regression check
```

New Swift files in `App/Sources` are picked up by `make debug`/`make check` (they run XcodeGen).

## Invariants (do not break)

- **Rate limits are sacred.** MELCloud allows at most one fetch per 60 s across app and helper,
  reports hourly, 12 writes per rolling hour with 5 s spacing, and a block after 429/login
  throttle stops all calls. Tibber allows about 100 requests per 5 minutes and two open
  sockets: homes and hours at most hourly, one live socket for the whole app, none in the
  helper, and a refused token is never retried. All network access goes through the device's
  service (`HeatPumpService`, `EnergyMeterService`), which enforces this via
  `HistoryStore.reserveFetch`/`reserveChange`. Never call a backend directly from the app or MCP
  code, and never add a retry loop around a refused call.
- **Every write** is validated, budgeted, logged in `change_log`, and when it comes from Claude
  (`source: .claude`) approved by the user in the approval dialog. Business refusals return
  `ChangeOutcome`, they do not throw.
- **The local connection is read-only.** Only the status request is ever sent to the Wi-Fi adapter.
- **Secrets live in the keychain** (`CredentialStore`), never in files, logs, fixtures or URLs.
  Fixtures are redacted.
- **Localization:** English source text everywhere. Package strings via `L10n.tr("…")` /
  `L10n.format("…%@", x)` with a plain literal key; app strings via SwiftUI literals or
  `String(localized:)`. Every key needs a Norwegian translation (CI and a unit test fail
  otherwise). See the `localization` skill.
- **Look and features stay as they are** unless the task is explicitly a design change. Refactors
  are verified with `scripts/parity.sh`.
- Swift 6 strict concurrency (`complete`). The service is an actor; UI models are `@MainActor @Observable`.
- No push, tag, release or anything sent to third parties without the user's go-ahead.

## Conventions

- Code, comments, commit messages, docs and skills in English. `///` doc comments explain why
  and limits, not what.
- One screen per file; private subviews as computed properties grouped with `// MARK:`.
- Kit features as `HeatPumpService+Feature.swift`; models are `public struct … Codable, Sendable, Equatable`.
- Tests: Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`), `TestClock` for time,
  `CountingBackend`/`StubTransport` for network, `temporaryDatabasePath()` for the store.
- Errors in the UI are shown inline (`Label` with a status colour or `InsightCard`), never `.alert`.
- `CHANGELOG.md` entries in English; they become the release notes and the in-app "What's new".

## Skills (`.claude/skills/`)

| Skill | Use when |
|---|---|
| `design-system` | building or changing any SwiftUI view |
| `localization` | adding or changing user-facing text, plurals, translations |
| `screenshots` | README/demo screenshots or visual parity checks |
| `release` | preparing a version, CHANGELOG, tag and GitHub release |
