---
name: add-integration
description: Add a new integration to Varmepumpe — another heat pump brand or cloud, or another kind of equipment (energy meter, water heater, EV charger, …) — with scripts/new-integration.py, the Integration contract, driver protocols, HeatPumpError mapping, StubTransport fixtures, a demo variant and, for a new kind, DeviceKind, DeviceService, screens, device model and MCP tools. Use for "add support for <brand/device>", "integrate <service>", "new heat pump", "water heater", "EV charger", "energy meter", "connect <vendor> API".
---

# Add an integration

An integration is one Swift target in `Packages/HeatPumpKit/Sources/<Name>Integration`. It knows
how to talk to one vendor and owns that vendor's rules (sign-in fields, rate limits, error texts,
health rules, knowledge documents). The core (`HeatPumpKit`) names no vendor (`BoundaryTests`);
the hub (`DeviceHub`) and the services do caching, spacing, blocks, the change budget, approval
and logging. References: `TibberIntegration` (a new kind: energy meter), `AirthingsIntegration`
(a new kind: air quality sensor; OAuth client credentials, rate limit headers, one request for
all devices) and `MELCloudIntegration` (a heat pump). Read `docs/architecture.md` ("What an integration
supplies", "Adding a device kind") first.

## 1. Decide: new brand or new kind?

- The equipment is a kind that already exists (`DeviceKind` in
  `Sources/HeatPumpKit/Devices/DeviceKind.swift`: `airToAirHeatPump`, `energyMeter`,
  `airQualitySensor`) → a new
  **brand**: a new target and its connection. No app or MCP changes; screens and tools follow
  from the capabilities its connection conforms to.
- Something else (water heater, EV charger, air-to-water heat pump, …) → a new **kind** first
  (section 7), then the integration. Do the kind in its own commit.
- A feature for devices that already exist → the `add-feature` skill, not this one.

## 2. Research the vendor API first

Before writing code, delegate a research agent (`doc-researcher`) for facts only: endpoints,
auth (token, OAuth, session cookie, expiry), documented rate limits and what happens when they
are exceeded (status, `Retry-After`, lockouts), error format (HTTP status vs. error codes in a
200 body), listing and per-device ids, data resolution and delay, write semantics, socket or
push limits, terms that forbid polling. Ask for sources. Save the notes next to the work
(session scratchpad `handoffs/<vendor>-research.md`, as `tibber-research.md` was) and put the
facts that shape the code in the API type's `///` comment, as `TibberAPI.swift` does. Unknown
limits get conservative values and a comment saying they are unverified.

## 3. Scaffold

```sh
python3 scripts/new-integration.py <TypeName> --id <id> --kind <DeviceKind rawValue> [--display "Name"]
# e.g. python3 scripts/new-integration.py Daikin --id daikin-onecta --kind airToAirHeatPump --display "Daikin Onecta"
cd Packages/HeatPumpKit && swift test --filter <TypeName>IntegrationTests
grep -rn "TODO(integration)" Packages/HeatPumpKit
```

It needs a template for the kind (`KIND_TEMPLATES` in the script: drivers, capabilities, rate
defaults, stub members and the "not implemented" test); a new kind adds one first (section 7).
It creates `Sources/<TypeName>Integration/{<TypeName>Integration,<TypeName>Connection}.swift`,
`Tests/HeatPumpKitTests/<TypeName>IntegrationTests.swift` and a placeholder fixture
`Fixtures/<id, dashes as _>_devices.json`, and registers the target in `Package.swift` (product, target,
`Integrations` and test target dependencies), in `IntegrationCatalog.all` and in the expected ids
of `IntegrationTests.catalogListsEachIntegrationOnce`. It refuses when anything already exists.
The stubs list no devices and throw `HeatPumpError.notSupported`; the generated tests pin that
state and must be replaced as the connection grows.

Every catalog integration is offered under Settings → Account → Add Integration… (except the
simulated ones), so do not ship the catalog entry before the connection works.

## 4. The `Integration` contract (`Sources/HeatPumpKit/Integration/Integration.swift`)

- `id`: persisted forever. It is the `DeviceKey` prefix (`<id>:<native id>`), the
  `fetch_state` namespace (`<id>/state`, `<id>/report.X@<native id>`) and the default keychain
  account prefix. Never rename it. Do not use `house` (`HistoryStore.pendingMeterKey`), `mock`
  or the demo ids.
- `displayName`: the service name in every text (`HeatPumpService.serviceName`, errors via
  `describe(_:)`). Texts never contain a vendor literal; they take it as `%@`.
- `vendorName`, `brandName` ("the … app"), `modelName` (`get_device_info`), `unitDescription`
  (first line of the MCP instructions and `list_devices`), `sourceTag` (stored with error-log and
  away rows; defaults to `id`, persisted).
- `credentialFields`: drive the generic sign-in form (`LoginForm` in `SettingsView.swift`).
  `.email`/`.password`/`.token`/`.clientId`/`.clientSecret` (OAuth client credentials), `isSecret`,
  `helpURL` for where a token is created and `help` for how (an `L10n` text, shown under the field;
  put both on the last field when they are about all of them). Another kind of field needs a case
  in `CredentialField.Kind` and in `LoginForm.fieldView` (the compiler points at it).
- `credentialMapping`: defaults to one keychain item per field (`<id>/<field>`) and a session
  item. Map to an existing item only to share it (Tibber's `token` is the price token's
  `tibber-token`, `isShared: true` so removing the integration keeps it). Once released, items
  never move. Secrets only in the keychain: never in files, logs, fixtures or URLs.
- `rateLimitPolicy` (`RateLimitPolicy.swift`): `maxAge`, `minRefreshInterval` (state fetch
  spacing per integration, across app and helper), `reportInterval`, `defaultLoginBlock`,
  `unauthorizedBlock`, `maxWriteWait`, `writeBaseMaxAge` and `changeBudget`. Set them from the
  research, with margin. Read-only equipment: a zero change budget (as Tibber). Add the limits to
  the "Rate limits are sacred" invariant in `CLAUDE.md`.
- `errorCodes`: an `ErrorCodeExplaining` (see `MELCloudIntegration/ErrorCatalog.swift`), or
  `NoErrorCodes()`.
- `healthChecks` (`HealthCheckProviding`, e.g. `MELCloudHealthChecks`) and `maintenanceTasks`:
  rules and intervals that only make sense for this vendor's units. Default none.
- `knowledge`: `KnowledgeSource(names:documents: KnowledgeContent.documents)` from
  `Sources/<Target>/Knowledge/{en,nb}/*.md`. Give the target `exclude: ["Knowledge"]` in
  `Package.swift` (the scaffold leaves a TODO there), run
  `python3 Packages/HeatPumpKit/scripts/generate-knowledge.py`, and
  add the target to `CompiledKnowledgeTests.compiled` in `Tests/HeatPumpKitTests/ServiceTests.swift`
  (with `@testable import <Target>` at the top).
- `makeConnection(_:)`: returns `any DeviceConnection`; its conformances decide what the hub
  serves. Read credentials lazily from `context.credentials` (a closure, as Tibber does), throw
  `missingCredentials` when there is no store.

Local network access (like MELCloud's Wi-Fi adapter) is chosen per integration id in
`IntegrationCatalog.makeHub` (`local:`); everything else gets `.unavailable`.

## 5. The connection: driver protocols

All in `Sources/HeatPumpKit/Backend/DeviceDrivers.swift`. Conform to what the equipment can do;
`Capability.derived(from:)` (`Devices/Capability.swift`) turns conformances into capabilities,
and screens and MCP tools appear only where a capability exists.

| Protocol | Capability | Requires |
|---|---|---|
| `DeviceConnection` | – | `identifier`, `login()`, `listDevices()`; optional `resetSession()`, `capabilities(of:)` (per device, e.g. live power only with a reader), `recentListing()` (reuse a listing for daily discovery) |
| `ThermostatDriver` | thermostat, fanSpeed, airflow | `fetchState(device:)`, `apply(_:)`; optional `requiresFreshStateForWrites`, `writeBaseFetchedAt`, `localWriteProblem`, `unknownModeProblem` |
| `ErrorLogReporting` | errorLog | `fetchErrorLog(device:range:)` |
| `TemperatureLogReporting` | temperatureLog | `fetchTemperatureLog(device:range:)`, `maxTemperatureLogDays` |
| `EnergyReporting` | energyLog | `fetchEnergy(device:range:)`, `maxEnergyReportDays` |
| `SignalStrengthReporting` | signalStrength | `fetchSignalStrength(device:)` |
| `AwayModesDriver` | awayModes | `fetchAwaySettings`, `applyAway`, optional `awaySettings(fromStoredListing:)` |
| `WeeklyScheduleDriver` | weeklySchedule | `fetchWeeklyTimer`, `saveWeeklyTimer`, `weeklyTimerFormat` |
| `FirmwareDriver` | firmwareUpdates | `firmwareUpdates`, `approveFirmwareUpdate`, `cancelFirmwareUpdate` |
| `DeviceLocationReporting` | location | `location(fromStoredListing:)` |
| `HardwareAddressReporting` | – | `hardwareAddress(fromStoredListing:)` (find the unit on the LAN) |
| `EnergyMeterDriver` | energyLog | refines `DeviceConnection`; `fetchHours(device:lastHours:)` |
| `LivePowerDriver` | livePower | `liveReadings(device:) -> AsyncStream<LivePowerEvent>` |
| `AirQualityDriver` | airQuality | refines `DeviceConnection`; `fetchLatest(devices:)` (several devices in one request), optional `maxDevicesPerRequest`, `fetchThresholds(device:)` |
| `AirQualityLogReporting` | airQualityLog | `fetchHourly(device:range:)`, `maxAirQualityLogDays` |
| `RequestBudgetReporting` | – | `requestBudget()`: the vendor's rate limit headers, so the service stops before the budget runs out |

Minimum per kind: heat pump `DeviceConnection & ThermostatDriver` (the hub builds a
`HeatPumpService`), energy meter `EnergyMeterDriver` (an `EnergyMeterService`), air quality sensor
`AirQualityDriver` (an `AirQualityService`).

Rules for drivers:
- `listDevices` returns `DeviceSummary(key: DeviceKey(integration: id, nativeId:), name:, kind:, metadata:)`.
  Above the driver every device is a `DeviceKey`; the driver maps it to its native ids. Vendor
  enums and wire numbers stay in the integration module (see `MELCloudWireValues.swift`).
- **No rate limiting, caching or retries in drivers.** The service reserves every call through
  `HistoryStore.reserveFetch`/`reserveChange`. A driver sends exactly one data request per call and
  throws. The exceptions: a live socket's own reconnect rules, inside its limits
  (`TibberLiveClient`), and session upkeep kept in memory (an OAuth token requested when missing or
  expired and once more after a 401, an account id looked up once per process; see
  `AirthingsConnection`). Say so in the connection's `///` comment and count them in the budget.
- Optional protocol requirements with a default in an extension (`recentListing()`,
  `resetSession()`) must match the requirement's signature exactly in an actor (`async` where the
  requirement is): a sync actor method is shadowed by the extension when called on the concrete
  type.
- **Map every failure to `HeatPumpError`** (`Backend/HeatPumpError.swift`): refused login or token
  → `invalidCredentials`, login throttle → `loginThrottled(until:)`, 429 → `rateLimited(until:)`
  (from `Retry-After` when given, as `MELCloudClassicParser.retryAfter`), unknown device →
  `deviceNotFound`, bad body → `decoding`, other status → `http(status:)`, vendor error text →
  `server`, an optional endpoint refusing the account → `endpointRefused(status:)`, missing
  capability → `HeatPumpError.notSupported`. Check error codes inside 200 answers too
  (`TibberAPI.checkErrors`). The service turns these into blocks and texts naming the service.
- Network through an injected `HTTPTransport` (`URLSessionTransport()` by default); sockets
  through an injected connector (Tibber: `WebSocketConnecting`, today in `TibberIntegration`).
- Writes (`apply`, `applyAway`, …) send only what changed and return what the vendor reports back.

## 6. Tests and fixtures

- Fixtures in `Tests/HeatPumpKitTests/Fixtures/<id>_*.json`, shaped as the vendor documents
  them, redacted: no real token, e-mail, serial, MAC, address or home id. Load with
  `Fixture.data("…")`/`Fixture.json("…")`.
- HTTP through `StubTransport` (`TestSupport.swift`): `enqueue("<path suffix>", status:, body:)`,
  then assert `transport.requests` (headers, body, nothing sent without credentials). Sockets
  through a fake connector (`FakeSockets` in `TibberTests.swift`). Time through `TestClock`.
- Cover: listing → keys, names, kinds, per-device capabilities; each read's parsing (including
  nulls and unfinished data); every error mapping; no credentials → nothing sent.
- The request budget: build the hub with several devices on one account, poll as the app does
  (every 60 s: state, then details) for two simulated hours with `TestClock`, and assert the
  requests per hour by path (`AirthingsIntegrationTests.fiveSensorsStayWellBelowTheHourlyBudget`).
  Document the result in the integration's `rateLimitPolicy` comment.
- Service-level behaviour (spacing, blocks) with `DeviceHub(store:catalog:…)` and
  `temporaryDatabasePath()`, as in `DeviceHubTests` and `EnergyMeterTests`.
- `BoundaryTests` must stay green: no vendor name in the core or in app/MCP string literals.

## 7. A new device kind

Do this before the integration; the compiler then points at each switch that needs a case.

1. **Kit**: `DeviceKind` case; a driver protocol (and `Capability` + `Capability.derived`) in
   `DeviceDrivers.swift`/`Capability.swift`; models in `Models/<Kind>Models.swift`; a service
   actor in `Service/` that owns spacing, caching and logging (patterns: `EnergyMeterService`,
   `AirQualityService`; a sign-in that only lists devices reuses `DeviceListing`); storage in
   `Storage/HistoryStore+<Kind>.swift` with a new migration registered after the last one in
   `HistoryStore.migrator` and a backup before it (`backUpBefore…IfNeeded`, called in
   `HistoryStore.init`; pattern: `airQualityMigration`); rules on the kind's own values in
   `Health/` (pattern: `AirQualityHealth`). A scaffold template for the kind in
   `scripts/new-integration.py` (`KIND_TEMPLATES`) and its demo id in `RESERVED_IDS`.
2. **Hub** (`Hub/DeviceHub.swift`): a `DeviceService` case and accessor, and the kind in
   `DeviceService.isHeatPump`. The compiler does **not** point at the rest, because they are
   casts, not switches: a dictionary of the kind's services and one of account services without a
   device, filled in `init` and `reconcile()` where the hub checks `runtime.connection as? any
   <Driver>`; `service(for:)` and a `<kind>Service(for:)` accessor; `accounts(of:)`,
   `anyService(of:)` (sign-in, sign-out, discovery) and `seedDemoHistoryIfNeeded()`.
3. **Navigation**: its screens in `DeviceNavigation.screens(kind:capabilities:)`, new
   `DeviceScreen` cases only if needed; tests in `DeviceNavigationTests`.
4. **App**: `final class <Kind>DeviceModel: DeviceModel` (`@MainActor @Observable`) in
   `App/Sources/DeviceModels.swift`, created in `AppModel.syncDevices()` from its
   `DeviceService` case; its views (`<Kind>OverviewView.swift`, …, `design-system` skill); in
   `App/Sources/DeviceUIRegistry.swift` its `screen(_:of:)` branch with the model injected and its
   `homeCard`; its `DeviceKind.title`/`systemImage` (`IntegrationSettings.swift`) and domain
   colours (`Theme.swift`). Price control uses `heatPumps` only; a kind with notifications adds a
   pure planner in the kit (`NotificationPlanner.planAirQuality`) and a loop in
   `AppModel.deliverNotifications`, off until the user turns it on.
5. **MCP**: a tools file like `varmepumpe-mcp/AirQualityTools.swift` (tools and a handler); each
   tool in `ToolCatalog.requiredCapability` (`Tools.swift`); one entry in `ToolCatalog.kindTools`
   (that maps every tool to its kind, so heat pump tools never pick the new kind and its tools pick
   only it); a case in `ToolRouter.handle(_:kind:devices:)`; a sentence in `instructions(for:)`
   (`main.swift`) when such a device is enabled. Tools appear only when such a device is enabled;
   the one-device golden catalog (`MCPCatalogTests`, `Fixtures/mcp_catalog_one_device.json`) must
   not change. Tests that assert the whole `Capability.allCases` (`IntegrationTests.
   capabilitiesFollowConformances`, `MCPCatalogTests.oneDeviceKeepsTheCatalogAndInstructions`)
   must leave out the new kind's capabilities.
6. **Demo** (below) and docs: `docs/architecture.md` ("Adding a device kind", module map).

## 8. Demo variant

Demo mode (`VARMEPUMPE_BACKEND=mock`, `make demo`) never touches the network.
- A new heat pump brand: the simulated units (`DemoIntegration`, `MockBackend`) already cover the
  heat pump screens; add nothing unless the brand brings a capability the mock lacks.
- A new kind: a simulated integration in `Sources/DemoIntegration/` (patterns: `MockMeter.swift`
  with `DemoMeterIntegration`, `MockAirQuality.swift` with `DemoAirQualityIntegration`; texts
  borrowed from the real integration, so `DemoIntegration` depends on its target in
  `Package.swift`), a token for `VARMEPUMPE_DEMO_DEVICES` (`DemoUnit.wants(_:environment:)` in
  `MockBackend.swift`), registration in `IntegrationCatalog` (`all`, `simulated`, the demo branch
  of `makeHub`, disabled when not asked for) and seeding (`MeterDemoSeeding`,
  `AirQualityDemoSeeding`). The default demo (`heatpump`) must look exactly as before:
  `scripts/parity.sh` proves it.
- Document the token in the README env tables (both languages) and the `screenshots` skill. The
  sign-in form of a new integration: `VARMEPUMPE_SETTINGS_SHEET=add-integration/<id>` with
  `VARMEPUMPE_SETTINGS_TAB=konto` and `WINDOW=settings`.

## 9. Texts, docs, changelog

- Every new text through `L10n.tr`/`L10n.format` with a Norwegian translation (`localization`
  skill); vendor and service names as `%@`. Add new terms to the glossary there.
- `README.md` and `README.nb.md`: the feature list, "Other services" under Security and privacy
  (what is contacted, when, with which credentials), the env table for any new hook.
- `CHANGELOG.md`: a user-facing bullet under the next version (`release` skill).
- `CLAUDE.md`: the layout row and the rate-limit invariant; `docs/architecture.md`: module map.

## 10. Verify

```sh
make check                                   # all tests + Debug build
python3 scripts/l10n.py check
make debug && scripts/parity.sh capture build/parity/after   # baseline captured before the change
scripts/parity.sh compare build/parity/baseline build/parity/after
```

The default demo set must stay clean. Take screenshots of the new screens (multi-device demo with
the new `VARMEPUMPE_DEMO_DEVICES` token, en and nb) with the `screenshots` skill and look at them.
Never test against a real account, database or keychain without the user's go-ahead.
