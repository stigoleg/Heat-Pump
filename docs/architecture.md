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
  `HeatPumpService` per enabled device (`Service/`), one connection per active integration and one
  `EnergyContextService` (prices, weather, house consumption, price outlook) shared by all devices.
  The services are the only thing that talks to the network. The app and the MCP helper each build
  a hub (`IntegrationCatalog.makeHub`) and share the SQLite database and keychain, so rate limits,
  blocks and the change budget hold across both processes. Active integrations are stored in
  `app_settings.integrations` (MELCloud until changed; demo mode: the demo only). The app serves
  the primary device (`primaryService()`); the MCP helper chooses per call (`ToolRouter`).
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
  moved the old global copies to the then current device. Migration v12 converted older files (rows keyed by the
  integration that opened the store, `IntegrationCatalog.makeService`) after copying the file to
  `<name>-pre-v12.sqlite` with SQLite's backup API.
- **Credentials** (`CredentialStore`) are `CredentialValues` addressed through each integration's
  `CredentialMapping`. MELCloud keeps its original keychain items (`melcloud-credentials`,
  `melcloud-context-key`) so the access shared by app and helper survives; new integrations get
  `<integration id>/<field>` items.
- **Providers** for electricity prices (Tibber, hvakosterstrommen.no), weather (MET Norway) and
  house consumption (Tibber) are injected as closures, which is also how tests and demo mode
  swap them.
- **Local connection** (`Local/`) reads the Mitsubishi Wi-Fi adapter over the home network,
  read-only, for power, compressor and defrost data.
- **Localization**: `L10n` resolves the language from the app's `AppleLanguages` (shared with the
  helper, which reads the strings from the app bundle around it).
- **Knowledge documents** (`Sources/<Target>/Knowledge/{en,nb}/*.md`, today only
  `MELCloudIntegration`) are compiled into each target's `KnowledgeContent.generated.swift` by
  `scripts/generate-knowledge.py` so the helper needs no resource bundle; `Knowledge` combines the
  core's (none yet) with the active integration's, and the MCP server exposes them as resources.

### Module map (`Packages/HeatPumpKit/Sources`)

| Target | What |
|---|---|
| `HeatPumpKit` | The vendor-neutral core: service, store, models, health engine, pricing, weather, L10n. Names no vendor outside comments (`BoundaryTests`). |
| `MELCloudIntegration` | `MELCloudIntegration: Integration`, the MELCloud Classic backend and parsers, the local adapter client (CN105), `ErrorCatalog`, `MELCloudHealthChecks` and the knowledge documents. |
| `DemoIntegration` | Simulated data (`MockBackend`, mock providers). Simulates a MELCloud unit, so it reuses MELCloud's wire formats, texts, error codes, health rules and documents. |
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
- **Credentials**: `credentialFields` and `credentialMapping` (keychain items, session item,
  dev environment variables). `HealthEngine` runs the generic
  rules and asks the integration at fixed points, so findings keep their order.
- **Knowledge**: `knowledge: KnowledgeSource`.
- **Persisted identifiers**: `sourceTag` is stored with error-log entries and away settings.

### Known couplings (what the platform work removes)

Device models have air-to-air fields; the app serves only the hub's primary device, so every
screen assumes one heat pump; the generic error text fallback (`errorDescription`) still names the
primary device's service.

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
- **`DeviceHub`** is the entry point; per-device services do the work (done in phase 4a; the
  app UI for several devices follows).
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

**Developer hooks**
- [ ] `VARMEPUMPE_BACKEND`, `VARMEPUMPE_DB_PATH`, `MELCLOUD_EMAIL`/`MELCLOUD_PASSWORD`,
  `VARMEPUMPE_APPROVAL`, `VARMEPUMPE_SCREEN`, `VARMEPUMPE_HISTORY_TAB`, `VARMEPUMPE_HISTORY_RANGE`,
  `VARMEPUMPE_SCROLL_TO`, `VARMEPUMPE_APPEARANCE`, `VARMEPUMPE_LANGUAGE`, `VARMEPUMPE_SETTINGS_TAB`,
  `VARMEPUMPE_MOCK_CYCLING`, `VARMEPUMPE_DEMO_DEVICES`
- [ ] `make demo`, `make l10n`, `make release`; CI and release workflows
