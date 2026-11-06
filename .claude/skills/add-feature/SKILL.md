---
name: add-feature
description: Add a feature to Varmepumpe end to end — model, capability and driver, a HeatPumpService+Feature.swift in the kit, the device model, the view and its route, a setting, an MCP tool with requiredCapability, tests, translations, docs — while keeping rate limits, the write rules and the one-device look intact. Use for "add a feature", "new screen", "new setting", "new MCP tool", "let Claude …", "show … in the app", and when planning where new behaviour belongs.
---

# Add a feature

The app holds no business rules. Rules, network, storage and validation live in the kit
(`Packages/HeatPumpKit/Sources/HeatPumpKit`); the app (`App/Sources`) and the MCP helper
(`Sources/varmepumpe-mcp`) only call it. Read `CLAUDE.md` (invariants) and
`docs/architecture.md` first. For UI follow the `design-system` skill, for text the
`localization` skill, for screenshots and parity the `screenshots` skill.

## 1. Where does it live?

- **Device feature behind a capability** (the device can or cannot do it: away modes, weekly
  schedule, firmware): a driver protocol + `Capability`, a service extension, a device screen or
  section shown only when the device has the capability, and an MCP tool with
  `requiredCapability`. Most features are this.
- **App-wide feature** (prices, weather, price control, Home, Claude activity, updates): on
  `EnergyContextService` or `DeviceHub` in the kit, `AppModel` in the app, a Home screen
  (`HomeScreen`) or a Settings tab; not tied to one device.
- **Integration-specific** (only one vendor has it, e.g. MELCloud's local Wi-Fi adapter or its
  health rules): inside that integration's target, exposed through a vendor-neutral protocol
  (`HealthCheckProviding`, `LocalAccess`, a driver). The core and app texts never name the vendor.
- **A new device or vendor**: the `add-integration` skill instead.

## 2. The path, traced for Away (frost protection and holiday mode)

Follow the same files for a new device feature; read each one before writing yours.

1. **Model** — `Models/AwayModels.swift`: `AwaySettings` (`public struct … Codable, Sendable,
   Equatable`) and `AwayChange` with `validationProblem(now:)`, `safetyProblem(current:now:serviceName:)`,
   `displaySummary`, `field`. Pure and testable; no I/O.
2. **Capability protocol** — `Backend/DeviceDrivers.swift`: `AwayModesDriver`
   (`fetchAwaySettings`, `applyAway`); `Devices/Capability.swift`: `.awayModes`, set in
   `Capability.derived(from:)`. Vendor-neutral types only.
3. **Driver** — each integration that can, conforms (`MELCloudClassicBackend` in
   `MELCloudIntegration/`, `MockBackend` in `DemoIntegration/`). Wire formats stay there
   (`MELCloudAwayParser.swift`). One request per call, errors mapped to `HeatPumpError`, no retries.
4. **Service** — `Service/HeatPumpService+Away.swift`: reads cached in `app_settings` per device
   (`deviceSetting`/`saveDeviceSetting`, key `awaySettings@<device key>`), spaced
   per device with `reserveDeviceFetch(_:minInterval:now:)` under a fetch key
   (`awayFetchKey = "away"`), refusals paused (`recordKeyRefusal`); the write `applyAway(_:source:reason:approver:)`
   (rules in section 3). Name the file `HeatPumpService+<Feature>.swift`; reach the driver with
   `driver((any AwayModesDriver).self)`, which throws `notSupported` when missing.
5. **Device model** — `App/Sources/DeviceModels.swift`, `HeatPumpDeviceModel`: state `away`,
   actions `loadAway(manual:)` and `applyAway(_:)` (calls the service with `source: .app`), reads
   in `pollDetails()`, stored copy in `reloadLocal()`. App-wide state goes on `AppModel` instead.
6. **View** — `App/Sources/AwayView.swift`: `@Environment(HeatPumpDeviceModel.self) private var model`,
   cards plus a confirmation sheet, errors inline (never `.alert`). One screen per file.
7. **Route** — kit `Devices/DeviceNavigation.swift`: `DeviceScreen.away`, shown in
   `screens(kind:capabilities:)` only with `.awayModes`; app `DeviceUIRegistry.heatPumpScreen`
   maps it to `AwayView()`; `Screen.away` in `AppModel.swift` gives title, icon and badge colour.
   A section on an existing screen needs none of this: check the capability in the view
   (`model.descriptor?.capabilities`).
8. **MCP** — `varmepumpe-mcp/Tools.swift`: `get_away_settings` (read-only annotations) and
   `set_frost_protection`/`set_holiday_mode` (with `reasonProperty` and `writeWarning`);
   `ToolCatalog.requiredCapability` maps each to `.awayModes`, so the tool exists only when some
   device can answer and gets the `device` argument with two or more devices. Handler:
   `ToolHandler.writeAway` calls the service with `source: .claude` and the `approver`. Tool
   descriptions are plain English for Claude; user-facing `note`/`message` texts go through `L10n`.
9. **Tests** — `Tests/HeatPumpKitTests/AwayTests.swift` (parsing, validation, the service write):
   Swift Testing, `TestClock` for time, `CountingBackend` (counts calls, injects errors) or
   `StubTransport` for network, `temporaryDatabasePath()` for the store, `FixedApprover` for
   approval. Navigation in `DeviceNavigationTests`, tools in `MCPCatalogTests`.
10. **Text** — `L10n.tr`/`L10n.format` in the kit and helper, SwiftUI literals or
    `String(localized:)` in the app, Norwegian for every key (`make l10n`, `localization` skill).
11. **Knowledge** — if Claude needs background (limits, safe ranges), add or extend a document in
    the integration's `Knowledge/{en,nb}/*.md` and run
    `python3 Packages/HeatPumpKit/scripts/generate-knowledge.py`.
12. **Docs** — `README.md` and `README.nb.md` (feature list, MCP tool list and count),
    `CHANGELOG.md` (user-facing bullet), `docs/architecture.md` parity checklist for anything that
    must keep working.

## 3. Write rules (every change to a device)

In the service, in this order (see `applyAway` and `HeatPumpService.applyWithApproval`):

1. **Validate** first (a pure `validationProblem`, then safety against the current state);
   invalid requests are logged as rejected and never counted or shown for approval.
2. Stop on `credentialsRejected()` and an active `blockStatus(now:)`.
3. **Approval** when an `approver` is given (Claude, `source: .claude`): the user approves on the
   Mac (`ApprovalRequest` with a short summary and the reason). The app's own writes need none.
4. **Budget**: `store.reserveChange([record], device:, budget: policy.changeBudget)` → `.reserved`,
   `.tooSoon` (wait up to `policy.maxWriteWait`), `.exceeded`. The budget is the integration's
   (`rateLimitPolicy`), shared by app and helper and every device on the account.
5. Send through the driver; `store.finishChange(ids:result:error:)`; read back when the read-back
   spacing allows.
6. Return a `ChangeOutcome` (`Service/ServiceTypes.swift`). Business refusals return an outcome
   with `result: .rejected`, they do not throw. Every attempt is in `change_log` (`logChange`)
   and shows under Claude activity.

Reads go through `reserveFetch`/`reserveDeviceFetch`: never call a driver or backend from the app
or the helper, never add a retry loop around a refused call.

## 4. Settings

- Global: `HistoryStore.setting(_:key:)`/`saveSetting(_:key:)` in `app_settings` (prices,
  weather, active integrations). Shared by app and helper.
- Per device: `HistoryStore.deviceSetting(_:name:device:)`/`saveDeviceSetting(_:name:device:)`
  (key `<name>@<device key>`). `HistoryStore.deviceSettingNames` lists only the caches migration
  v13 moved; a new name needs no entry there.
- UserDefaults only for app-only preferences (appearance, notification memory).
- UI: a section in an existing tab of `App/Sources/SettingsView.swift`, or a new
  `Tab("…", systemImage:, value: "<tag>")` with a lowercase tag (Norwegian tags like
  `strompris` are identifiers, never translated). Form pattern: `LocalSettingsView.swift`.
  Settings about one device use `selectedHeatPump`; with two or more devices add a device
  picker as Local connection does (`IntegrationSettings.swift`).
- Add the tag to `VARMEPUMPE_SETTINGS_TAB` in the `screenshots` skill and the README env tables.

## 5. One device and several

- With one device the app must look and behave exactly as before: flat sidebar, no device names,
  no new controls. Gate multi-device UI on `app.isGrouped` / `DeviceNavigation.isGrouped`.
- Device data belongs to a device model; never read "the" device from `AppModel` for new code.
  Shared data (prices, weather) is on `hub.energy`.
- MCP: with one device, tools have no `device` argument and the golden catalog
  (`MCPCatalogTests`, `Fixtures/mcp_catalog_one_device.json`) is unchanged unless you add a tool
  on purpose; then update the fixture in the same commit and say so.
- Check with `scripts/parity.sh capture`/`compare` (default demo) and `capture-multi` for the
  grouped look.

## 6. Background and menu bar

The app quits when the window closes unless `AppModel.keepsRunningInBackground` is true (today:
price control on), and then lives in the menu bar (`MenuBarExtra` in `VarmepumpeApp.swift`,
`PriceControlMenu`). A feature that must act while the window is closed extends that property,
restores anything it changed on quit and sleep (as price control does), and stops its work when
the Mac sleeps. Polling is one loop (`AppModel.refresh`); add slow reads to the device model's
`pollDetails()`, never a second timer that calls the network.

## 7. Checklist

- [ ] Kit owns the rule; app and helper only call it; no vendor name in core texts (`BoundaryTests`)
- [ ] Capability-gated: screen, section and MCP tool appear only where the device can do it
- [ ] Reads cached and spaced; writes validated, approved (Claude), budgeted, logged, `ChangeOutcome`
- [ ] Tests with `TestClock`, `CountingBackend`/`StubTransport`, `temporaryDatabasePath()`
- [ ] Every text localized with Norwegian; glossary updated for new terms
- [ ] One-device look unchanged (`scripts/parity.sh`), multi-device checked (`capture-multi`)
- [ ] New screens screenshotted in en and nb and looked at (`screenshots` skill)
- [ ] README (both languages), CHANGELOG, knowledge documents, `docs/architecture.md` checklist
- [ ] `make check` and `python3 scripts/l10n.py check` green
