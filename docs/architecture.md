# Architecture

This describes how Varmepumpe is built today and where it is heading. The short version for
agents is in [CLAUDE.md](../CLAUDE.md).

## Today

```
┌──────────────── Varmepumpe.app ────────────────┐      ┌──── Claude Desktop / Code ────┐
│ SwiftUI views ── AppModel (@MainActor)         │      │                               │
│                     │                          │      │   MCP (stdio)                 │
│                     ▼                          │      │      │                        │
│            HeatPumpService (actor) ◄───────────┼──────┼── varmepumpe-mcp (Helpers/)   │
│    │        │         │          │             │      └───────────────────────────────┘
│    ▼        ▼         ▼          ▼             │
│ Backend   HistoryStore  Pricing/   LocalAccess │
│ (MELCloud  (SQLite,     Weather    (Wi-Fi      │
│  or Mock)   GRDB)       providers   adapter,   │
│                                     read-only) │
└────────────────────────────────────────────────┘
```

- **One entry point.** `DeviceHub` (`Packages/HeatPumpKit/Sources/HeatPumpKit/Hub`) holds one
  `HeatPumpService` per enabled heat pump, one `EnergyMeterService` per enabled energy meter and
  one `AirQualityService` per enabled air quality sensor (`Service/`), one connection per active
  integration and one
  `EnergyContextService` (prices, weather, house consumption, price outlook) shared by all devices.
  The services are the only thing that talks to the network. The app and the MCP helper each build
  a hub (`IntegrationCatalog.makeHub`) and share the SQLite database and keychain, so rate limits,
  blocks and the change budget hold across both processes. Active integrations are stored in
  `app_settings.integrations` (MELCloud until changed; demo mode: the demo only). The app keeps
  a model per enabled device (see "The app" below); the MCP helper chooses per call (`ToolRouter`).
- **Cache first.** Reads return the stored snapshot unless it is older than the allowed age;
  `HistoryStore.reserveFetch` decides whether a network call may happen.
- **Writes** go through validation → safety checks → change budget (`reserveChange`) → optional
  approval (Claude) → backend → change log → read back. They return a `ChangeOutcome`.
- **Backends** implement the capability protocols in `Backend/DeviceDrivers.swift`
  (`DeviceConnection & ThermostatDriver`, plus optional drivers such as `AwayModesDriver`):
  `MELCloudClassicBackend` for real use and `MockBackend` for demo mode and tests
  (`VARMEPUMPE_BACKEND=mock`).
- **Devices** are named by `DeviceKey` (`"<integration id>:<native id>"`, e.g.
  `melcloud-classic:12345`, `demo:100001`) everywhere above the drivers; a driver maps the key to
  its own ids. The store's `devices` table registers every device it holds data for (with the
  user's own name in `customName`); the hub gives every enabled one a service fixed to it. Device enums (`OperationMode`, vanes) are stored by their keys;
  each integration maps its wire numbers in its own module.
- **Storage** (`Storage/HistoryStore*.swift`): device-scoped tables carry `deviceKey`;
  `fetch_state` keys of an integration are namespaced (`melcloud-classic/state`,
  `melcloud-classic/global`, …), so blocks, the state spacing, endpoint refusals and the change
  budget are per integration (the account's) and still shared across processes. Requests about one
  unit are spaced per device (`<integration>/<name>@<native id>`: reports, away, timer, firmware,
  local adapter), and the device caches in `app_settings` are per device
  (`<name>@<device key>`: away, weekly timer, firmware status, local connection). Migration v13
  moved the old global copies to the then current device. Migration v14 made the house's
  consumption per meter (`meter_hourly`, keyed by the meter; hours fetched with the price token
  alone wait under the placeholder `house:meter` until the first meter adopts them, so the
  numbers never change) and added `meter_live` (live power per minute, 48 hours), after copying
  the file to `<name>-pre-v14.sqlite`. Migration v16 added `air_quality_latest` (newest value per
  sensor and metric) and `air_quality_hourly` (hourly averages, two years) after copying the file
  to `<name>-pre-v16.sqlite`. Migration v12 converted older files (rows keyed by the
  integration that opened the store, `IntegrationCatalog.makeService`) after copying the file to
  `<name>-pre-v12.sqlite` with SQLite's backup API. When the app and the helper open an
  unmigrated file at the same moment, the one that loses the race runs the migrator again once
  the other has applied its migrations (`HistoryStore.migrate(with:)`).
- **Spacing per device and per integration.** Reports, away, timer and firmware are spaced per
  device, so N units on one MELCloud account make N times those calls per hour. The state fetch
  spacing, blocks (429, login throttle), the "credentials rejected" stop and the change budget
  are per integration: they are the account's, however many units it has.
- **A 1.x helper across the update** (transition, remove after 2.1). Claude Desktop can keep an
  old `varmepumpe-mcp` running after the app is updated; it reads and writes the plain
  `fetch_state` keys (`global`, `credentials`, `state`, `write`, `report.*`). For MELCloud
  (`HistoryStore.legacyKeyMirror`, set by `IntegrationCatalog.makeHub` outside demo mode) the
  store writes blocks, refused credentials and the reservations of `state`, `write` and the
  first device's reports to both keys, and every check honours the more restrictive row. v12
  copies these rows instead of moving them; migration v15 restores them in files an earlier
  build migrated (`Storage/HistoryStore+Legacy.swift`).
- **Demo mode** (`VARMEPUMPE_BACKEND=mock`) without `VARMEPUMPE_DB_PATH` uses `demo.sqlite` next
  to the real database, never the real one (v12 would take its rows for the demo's).
- **Credentials** (`CredentialStore`) are `CredentialValues` addressed through each integration's
  `CredentialMapping`. MELCloud keeps its original keychain items (`melcloud-credentials`,
  `melcloud-context-key`) so the access shared by app and helper survives; new integrations get
  `<integration id>/<field>` items. Tibber maps its `token` field to the price token's item
  (`tibber-token`, `isShared`): prices and the meter use one token, and removing the integration
  keeps it.
- **Providers** for electricity prices (Tibber, hvakosterstrommen.no), weather (MET Norway) and
  house consumption (Tibber's token-only `TibberConsumptionProvider`) are injected as closures,
  which is also how tests and demo mode swap them. With an enabled energy meter the house's
  hours come from the meter's own driver instead (`EnergyContextService.houseMeter`), spaced per
  meter (`<integration>/meter.hours@<native id>`) and shared with the meter's service.
- **Local connection** (`Local/`) reads the Mitsubishi Wi-Fi adapter over the home network,
  read-only, for power, compressor and defrost data.
- **Localization**: `L10n` resolves the language from the app's `AppleLanguages` (shared with the
  helper, which reads the strings from the app bundle around it).
- **Knowledge documents** (`Sources/<Target>/Knowledge/{en,nb}/*.md`: `MELCloudIntegration`,
  `TibberIntegration`, `AirthingsIntegration`) are compiled into each target's `KnowledgeContent.generated.swift` by
  `scripts/generate-knowledge.py` so the helper needs no resource bundle; `Knowledge` combines the
  core's (none yet) with the active integration's, and the MCP server exposes them as resources.

### Module map (`Packages/HeatPumpKit/Sources`)

| Target | What |
|---|---|
| `HeatPumpKit` | The vendor-neutral core: service, store, models, health engine, pricing, weather, L10n. Names no vendor outside comments (`BoundaryTests`). |
| `MELCloudIntegration` | `MELCloudIntegration: Integration`, the MELCloud Classic backend and parsers, the local adapter client (CN105), `ErrorCatalog`, `MELCloudHealthChecks` and the knowledge documents. |
| `TibberIntegration` | Tibber homes as energy meters: `TibberConnection` (`EnergyMeterDriver`, `LivePowerDriver`), the GraphQL API (`TibberAPI`), the live socket client (`TibberLiveClient`, `graphql-transport-ws`, one socket for the app, never in the helper), the token-only house provider and the `energy-meter` knowledge document. The reference example for a new integration. |
| `AirthingsIntegration` | Airthings sensors as air quality sensors over the Consumer API: `AirthingsConnection` (`AirQualityDriver`, `AirQualityLogReporting`, `RequestBudgetReporting`; OAuth client credentials, token and account id in memory), `AirthingsAPI` (endpoints, parsing, error mapping, rate limit headers) and the `air-quality` knowledge document. Read-only. |
| `DemoIntegration` | Simulated data (`MockBackend`, mock providers). Simulates a MELCloud unit, so it reuses MELCloud's wire formats, texts, error codes, health rules and documents; `DemoMeterIntegration` (`demo-meter`, `MockMeter`) simulates a Tibber home for `VARMEPUMPE_DEMO_DEVICES=…,meter`, `DemoAirQualityIntegration` (`demo-airquality`, `MockAirQualitySensor`) an Airthings Wave Plus for `…,airthings`. |
| `Integrations` | `IntegrationCatalog`: the list of integrations, `current(environment:)` and `makeHub` (`makeService` is its primary service). |
| `varmepumpe-mcp` | The MCP helper. |

### What an integration supplies (`Integration`)

- **Texts**: `displayName` is the service name in every text (`HeatPumpService.serviceName`,
  `AppModel.serviceName`; keys carry it as `%@`), `brandName` ("the … app"), `modelName`
  (`get_device_info`) and `unitDescription` (first line of the MCP instructions). Error texts
  (`HeatPumpError`) are created far from the service; texts a service builds name its own
  integration (`HeatPumpService.describe(_:)`, `HeatPumpError.description(serviceName:)`), and
  `errorDescription` falls back to the process-wide `HeatPumpError.serviceName` (the primary
  device's integration, set by the hub).
- **Error codes**: `errorCodes: ErrorCodeExplaining` (lookup, `hasExplanation`, caveat, the
  codes that mean "no error").
- **Health**: `healthChecks: HealthCheckProviding` for rules on the integration's own signals
  (including maintenance reminders), and `maintenanceTasks` for the maintenance tasks the unit has
  and their intervals.
- **Connection**: `makeConnection` returns `any DeviceConnection`; its conformances decide what
  the hub serves (`ThermostatDriver`: a `HeatPumpService` per heat pump; `EnergyMeterDriver`: an
  `EnergyMeterService` per meter, `LivePowerDriver` for live power; `AirQualityDriver`: an
  `AirQualityService` per sensor, `AirQualityLogReporting` for its history, `RequestBudgetReporting`
  when the vendor reports its request budget). `capabilities(of:)` gives a
  device's own capabilities (live power only where Tibber reports a real-time reader), and
  `recentListing()` lets the hub's daily discovery reuse a listing the connection fetched anyway.
- **Credentials**: `credentialFields` (`.email`, `.password`, `.token`, `.clientId`,
  `.clientSecret`; a field may carry a `helpURL` and a `help` text) and `credentialMapping`
  (keychain items, session item, dev environment variables, `isShared`). `HealthEngine` runs the generic
  rules and asks the integration at fixed points, so findings keep their order.
- **Knowledge**: `knowledge: KnowledgeSource`.
- **Persisted identifiers**: `sourceTag` is stored with error-log entries and away settings.

### The app (`App/Sources`)

- **`AppModel`** holds what is app-wide: the hub, the route, appearance, language, updates, the
  shared energy context (prices, weather, outlook; read through the primary device's service),
  price control (`PriceControlRunner` on `DeviceHub.priceControlService()`), notifications and
  `devices: [any DeviceModel]`, one model per enabled device in registry order
  (`syncDevices()`, no network, at every poll). Before any device is known it holds the primary
  service's model, which keeps its model when the first sign-in finds the device.
- **Device models** (`DeviceModels.swift`): `HeatPumpDeviceModel` (`@MainActor @Observable`) holds
  one heat pump's state, history, health, away modes, weekly timer, firmware, local connection,
  debouncer and actions; `EnergyMeterDeviceModel` one meter's status, today, the last hour's live
  minutes and its live stream (started while the app polls, stopped when the Mac sleeps or the
  meter is turned off); `AirQualityDeviceModel` one sensor's status (values, levels, findings), its
  history for the charts and its radon notification switch. Device screens read their model from the environment
  (`@Environment(HeatPumpDeviceModel.self)`, `@Environment(EnergyMeterDeviceModel.self)`) and
  app-wide data from `AppModel`. The meter's screens are `MeterOverviewView` and
  `MeterHistoryView`, its Home card `MeterHomeCard`; a sensor's `AirQualityOverviewView`,
  `AirQualityHistoryView` and `AirQualityHomeCard`.
- **Polling**: one loop, every 60 s. Devices are polled stalest first (`pollState`), then the
  shared syncs, then each device's slower reads (`pollDetails`), price control, the reloads and
  notifications (per device; with two or more the title names the device). An integration allows
  one state fetch a minute for its account, so devices sharing one take turns. After each poll
  the hub's `discoverDevices()` checks each integration's device list at most daily (from a
  listing the connection fetched anyway when it has one): new devices are registered and
  enabled, devices the account no longer lists are disabled.
- **Routing** (`DeviceNavigation` in the kit, tested): `AppRoute.home(HomeScreen)` or
  `.device(DeviceKey?, DeviceScreen)` (nil: the primary device). With one device the sidebar is
  the flat list it always was; with two or more it has Home (overview of all devices, Forecast,
  Claude activity) and a group per device. `VARMEPUMPE_SCREEN` takes today's values, `home`,
  `home/<screen>` and `<device key>/<screen>`.
- **`DeviceUIRegistry`** maps a device to its screens (kind and capabilities), the views behind
  them (with the model injected), its Home card and its Settings (today the local connection).
- **Settings**: the sign-in form comes from the integration's `credentialFields`. With two or more
  integrations Account has a section per integration; with two or more devices a device list
  (rename, turn on/off, refresh the list). "Add Integration…" (a quiet button at the bottom of
  Account) appears when the catalog has an integration that is not active (the simulated ones
  are never offered); for Tibber the token saved for prices is filled in. Turning off (or
  removing the integration of) price control's device first turns price control off, which sets
  its temperature back (`DeviceHub.setEnabled`).

**Adding a device kind** (done for the energy meter, phase 5, and the air quality sensor, phase 9): a driver protocol and a service in
the kit (`EnergyMeterDriver`, `EnergyMeterService`) and a `DeviceService` case the hub builds from
the connection's conformance; its screens in `DeviceNavigation.screens(kind:capabilities:)`; a
`final class …DeviceModel: DeviceModel` in the app, created in `AppModel.syncDevices()` from its
`DeviceService` case; its screen views and Home card in `DeviceUIRegistry`; its MCP tools in the
helper (`MeterTools`, `AirQualityTools`: one entry each in `ToolCatalog.kindTools`, which maps
every tool to its kind; `ToolCatalog.canAnswer` checks kind and capability, and `ToolRouter`
hands a kind's tools to its handler). Services whose sign-in is a listing share
`DeviceListing`. The compiler points at each switch over `DeviceService`, `DeviceKind` and
`DeviceScreen` that needs a case.

### Extending

- **A new integration** (another heat pump brand, or equipment such as an energy meter, water
  heater or EV charger): the `add-integration` skill
  ([.claude/skills/add-integration/SKILL.md](../.claude/skills/add-integration/SKILL.md)).
  `python3 scripts/new-integration.py <TypeName> --id <id> --kind <DeviceKind>` creates the
  target, a connection with the kind's minimum drivers, tests on `StubTransport` and a fixture,
  and registers it in `Package.swift` and `IntegrationCatalog.all`.
- **A new feature, screen, setting or MCP tool**: the `add-feature` skill
  ([.claude/skills/add-feature/SKILL.md](../.claude/skills/add-feature/SKILL.md)), which traces
  Away from model to MCP tool and lists the write rules and the final checklist.
- Views follow the `design-system` skill, texts the `localization` skill, screenshots and parity
  the `screenshots` skill.

### Known couplings (what the platform work removes)

Device models have air-to-air fields; the generic error text fallback (`errorDescription`) still
names the primary device's service; prices, weather and price control's settings are shared, and
price control steers one heat pump at a time. Price control's settings are shared, but its
memory (what it last sent) and the comfort temperature are kept per device
(`priceControlRuntime@<device key>`, moved there by v15), so they never reach another unit; when
the device it steers loses its service (turned off, no longer listed, another account), the hub
turns price control off first and sets that device back.

## Direction: an integration platform

Work in progress (branch series `platform/*`). The goal is that a new heat pump brand, another
kind of equipment (water heater, energy meter, EV charger) or a new feature can be added by
following one pattern, with the compiler and tests guarding the boundaries. **For a user with
one heat pump the app looks and behaves exactly as before.**

- **Integrations are Swift modules** in the package, one target each (`MELCloudIntegration`,
  `TibberIntegration`, `DemoIntegration`), registered in one place (`IntegrationCatalog`). The core
  (`HeatPumpKit`) names no vendor; a test enforces it.
- **Devices** have a stable `DeviceKey` (`"<integration>:<native id>"`), a `DeviceKind` and a set of
  **capabilities** (thermostat, fan, airflow, energy reporting, live power, error log, away modes,
  weekly schedule, firmware, local telemetry). Each capability is a Swift protocol a driver conforms
  to; screens and MCP tools appear only for devices that have the capability.
- **Each integration owns its rules**: credential fields (drive a generic sign-in form), rate-limit
  policy, error texts, health checks and knowledge documents.
- **`DeviceHub`** is the entry point; per-device services do the work (phase 4a); the app has a
  model per device (phase 4b).
- **Several devices at once.** With two or more, the sidebar gets a Home group (overview of all
  devices, Forecast, Claude activity) and a group per device.

## Feature parity checklist

Every item must work and look the same after each platform phase (one heat pump, MELCloud or
demo). Check with `scripts/parity.sh` plus a manual pass.

**Screens**
- [ ] Overview: thermostat dial, setting chips, power, today's consumption and cost, price now, health, forecast
- [ ] Control: power, mode, temperature (slider and stepper), fan, vanes; auto-send with status chip and change budget
- [ ] Weekly schedule: read/edit MELCloud timer, templates, copy days, confirmation sheet
- [ ] History: temperature, energy, energy cost, operation, power tabs; 24 h / 7 d / 30 d / year
- [ ] Forecast: weather, prices (known and estimated), expected consumption and cost; price control section
- [ ] Away: frost protection and holiday mode with confirmation
- [ ] Health: findings, error log with explanations, maintenance, firmware section, knowledge sheet
- [ ] Claude activity: change log list
- [ ] Onboarding / sign-in when no credentials; status banner for stale, blocked and failed data; demo badge

**Settings tabs**: General (language, appearance, updates, background), Account (MELCloud sign-in,
heat pump, security), Electricity price (agreement, area, grid tariff, subsidy, Tibber token),
Local connection, Weather (location search, map, contact), Claude (connection instructions),
Data (database, fetch status, blocks)
- [ ] all tabs and every option in them

**App shell**
- [ ] Menu: Check for Updates…, Refresh Now (⌘R), Appearance picker and Toggle Appearance (⌘⇧L)
- [ ] Menu bar extra while price control is on; temperature restored on quit and sleep
- [ ] Notifications: new errors, filter reminders
- [ ] Auto-update (download, verify, install on quit or restart)
- [ ] Language switch with Restart Now

**MCP helper** (names, arguments and output unchanged)
- [ ] Read tools: `get_status`, `get_live_status`, `get_device_info`, `get_history`, `get_energy`,
  `get_error_log`, `get_health_report`, `get_maintenance_status`, `get_change_log`, `get_prices`,
  `get_forecast`, `get_house_consumption`, `get_away_settings`, `get_weekly_timer`,
  `get_firmware_status`, `refresh`
- [ ] Change tools (approval each): `set_power`, `set_mode`, `set_temperature`, `set_fan_speed`,
  `set_vanes`, `set_frost_protection`, `set_holiday_mode`, `start_firmware_update`, `record_maintenance`
- [ ] Prompt `helsesjekk`; resources `varmepumpe://knowledge/…` in the chosen language
- [ ] With one device no `device` argument and no `list_devices` (catalog golden test); with two
  or more, both, and an error listing the choices when `device` is needed
- [ ] `get_meter_status` only with an enabled energy meter, `get_air_quality`/`get_air_quality_history` only with an enabled air quality sensor; heat pump tools never ask to choose the meter or a sensor

**Developer hooks**
- [ ] `VARMEPUMPE_BACKEND`, `VARMEPUMPE_DB_PATH`, `MELCLOUD_EMAIL`/`MELCLOUD_PASSWORD`,
  `VARMEPUMPE_APPROVAL`, `VARMEPUMPE_SCREEN`, `VARMEPUMPE_HISTORY_TAB`, `VARMEPUMPE_HISTORY_RANGE`,
  `VARMEPUMPE_SCROLL_TO`, `VARMEPUMPE_APPEARANCE`, `VARMEPUMPE_LANGUAGE`, `VARMEPUMPE_SETTINGS_TAB`,
  `VARMEPUMPE_MOCK_CYCLING`, `VARMEPUMPE_DEMO_DEVICES`, `VARMEPUMPE_SETTINGS_SHEET`
- [ ] `make demo`, `make l10n`, `make release`; CI and release workflows
