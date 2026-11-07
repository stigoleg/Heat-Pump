#!/usr/bin/env python3
"""Scaffold a new integration target in Packages/HeatPumpKit.

  python3 scripts/new-integration.py <TypeName> --id <id> --kind <DeviceKind rawValue> [--display "Name"]

Example:
  python3 scripts/new-integration.py Daikin --id daikin-onecta --kind airToAirHeatPump --display "Daikin Onecta"

Creates
  Sources/<TypeName>Integration/<TypeName>Integration.swift   the `Integration` (id, texts, fields, limits)
  Sources/<TypeName>Integration/<TypeName>Connection.swift    the connection with the kind's minimum drivers
  Tests/HeatPumpKitTests/<TypeName>IntegrationTests.swift      tests of the scaffold state (StubTransport)
  Tests/HeatPumpKitTests/Fixtures/<id_with_underscores>_devices.json  a placeholder listing fixture
and registers the target in Package.swift (product, target, `Integrations` and test target
dependencies), in `IntegrationCatalog.all` and in the catalog test's list of ids.

Everything the developer still has to decide is marked `TODO(integration):`. The generated code
compiles and its tests pass; the stubs list no devices and throw `HeatPumpError.notSupported`.
Refuses (and changes nothing) when any of the files or registrations already exist.
The procedure around it is in .claude/skills/add-integration/SKILL.md.
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/HeatPumpKit"
SOURCES = PACKAGE / "Sources"
TESTS = PACKAGE / "Tests/HeatPumpKitTests"
PACKAGE_SWIFT = PACKAGE / "Package.swift"
CATALOG = SOURCES / "Integrations/IntegrationCatalog.swift"
CATALOG_TEST = TESTS / "IntegrationTests.swift"
DEVICE_KIND = SOURCES / "HeatPumpKit/Devices/DeviceKind.swift"

# Ids the store or the demo already use for something else.
RESERVED_IDS = {"house", "mock", "demo", "demo-meter", "demo-airquality"}


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def device_kinds():
    text = DEVICE_KIND.read_text()
    body = re.search(r"enum DeviceKind[^{]*\{(.*?)\n\}", text, re.S)
    return re.findall(r"^\s*case (\w+)", body.group(1), re.M) if body else []


def existing_ids():
    ids = set()
    for path in SOURCES.rglob("*.swift"):
        ids.update(re.findall(r'static let id = "([^"]+)"', path.read_text()))
    return ids


def lower_camel(name):
    head = re.match(r"[A-Z]+(?=[A-Z][a-z]|\d|$)|[A-Z]", name).group(0)
    if len(head) > 1 and len(head) < len(name):
        return head.lower() + name[len(head):]
    return name[0].lower() + name[1:]


# MARK: Templates

KIND_TEMPLATES = {
    "airToAirHeatPump": {
        "drivers": "DeviceConnection, ThermostatDriver",
        "noun": "heat pump",
        "capabilities": "[.thermostat, .fanSpeed, .airflow]",
        "rate_comment": """    // TODO(integration): the vendor's documented limits (research them first; see the
    // add-integration skill). Until then the app's standard ones: cached state up to 10 minutes,
    // one state fetch a minute across app and helper, reports hourly, 12 writes an hour 5 s apart.""",
        "rate_policy": """RateLimitPolicy(
            maxAge: 10 * 60, minRefreshInterval: 60, reportInterval: 3600, defaultLoginBlock: 30 * 60, unauthorizedBlock: 3600,
            maxWriteWait: 10, writeBaseMaxAge: 60, changeBudget: ChangeBudgetPolicy(maxChangesPerHour: 12, window: 3600, minSpacing: 5))""",
        "members": """    public func fetchState(device: DeviceKey) async throws -> DeviceState {
        // TODO(integration): read the unit and map it to `DeviceState` (modes and vanes by their
        // keys; the vendor's wire numbers stay in this module).
        throw HeatPumpError.notSupported
    }

    public func apply(_ changes: ChangeSet) async throws -> DeviceState? {
        // TODO(integration): send only the non-nil fields of `changes`; return the state the
        // vendor reports back, or nil when it reports none. Never retry here.
        throw HeatPumpError.notSupported
    }""",
        "test_unimplemented": """    @Test func stateAndWritesAreNotImplementedYet() async throws {
        let unit = DeviceKey(integration: {T}Integration.id, nativeId: "1")
        let client = connection(StubTransport())
        await #expect(throws: HeatPumpError.notSupported) { try await client.fetchState(device: unit) }
        await #expect(throws: HeatPumpError.notSupported) { try await client.apply(ChangeSet(device: unit, power: true)) }
    }""",
    },
    "energyMeter": {
        "drivers": "EnergyMeterDriver",
        "noun": "energy meter",
        "capabilities": "[.energyLog]",
        "rate_comment": """    // TODO(integration): the vendor's documented limits (research them first; see the
    // add-integration skill). Until then Tibber's shape: listings at most every 5 minutes, hours
    // hourly, no writes.""",
        "rate_policy": """RateLimitPolicy(
            maxAge: 3600, minRefreshInterval: 300, reportInterval: 3600, defaultLoginBlock: 30 * 60, unauthorizedBlock: 3600,
            maxWriteWait: 0, writeBaseMaxAge: 0, changeBudget: ChangeBudgetPolicy(maxChangesPerHour: 0, window: 3600, minSpacing: 0))""",
        "members": """    public func fetchHours(device: DeviceKey, lastHours: Int) async throws -> [HouseHour] {
        // TODO(integration): the last `lastHours` finished hours; leave out hours the vendor has
        // not finished yet.
        throw HeatPumpError.notSupported
    }""",
        "test_unimplemented": """    @Test func hoursAreNotImplementedYet() async throws {
        let meter = DeviceKey(integration: {T}Integration.id, nativeId: "1")
        await #expect(throws: HeatPumpError.notSupported) { try await connection(StubTransport()).fetchHours(device: meter, lastHours: 24) }
    }""",
    },
    "airQualitySensor": {
        "drivers": "AirQualityDriver, AirQualityLogReporting",
        "noun": "air quality sensor",
        "capabilities": "[.airQuality, .airQualityLog]",
        "rate_comment": """    // TODO(integration): the vendor's documented limits (research them first; see the
    // add-integration skill). Until then: newest values of every sensor at most every 5 minutes,
    // history and listings hourly, no writes.""",
        "rate_policy": """RateLimitPolicy(
            maxAge: 300, minRefreshInterval: 300, reportInterval: 3600, defaultLoginBlock: 30 * 60, unauthorizedBlock: 3600,
            maxWriteWait: 0, writeBaseMaxAge: 0, changeBudget: ChangeBudgetPolicy(maxChangesPerHour: 0, window: 3600, minSpacing: 0))""",
        "members": """    public func fetchLatest(devices: [DeviceKey]) async throws -> [AirQualityReading] {
        // TODO(integration): the newest values of `devices` in one request, metric units, mapped to
        // `AirQualityMetric` (unknown sensor types are left out).
        throw HeatPumpError.notSupported
    }

    public func fetchHourly(device: DeviceKey, range: DateInterval) async throws -> [AirQualityHour] {
        // TODO(integration): hourly averages for the hours that start in `range`, one request.
        throw HeatPumpError.notSupported
    }""",
        "test_unimplemented": """    @Test func readingsAreNotImplementedYet() async throws {
        let sensor = DeviceKey(integration: {T}Integration.id, nativeId: "1")
        let client = connection(StubTransport())
        await #expect(throws: HeatPumpError.notSupported) { try await client.fetchLatest(devices: [sensor]) }
        await #expect(throws: HeatPumpError.notSupported) {
            try await client.fetchHourly(device: sensor, range: DateInterval(start: clock.now.addingTimeInterval(-3600), end: clock.now))
        }
    }""",
    },
}

INTEGRATION = """import Foundation
import HeatPumpKit

/// TODO(integration): one or two lines on what this connects ({display} {noun}s through which API)
/// and anything unusual about it. Generated by scripts/new-integration.py.
public struct {T}Integration: Integration {
    public init() {}

    /// `Integration.id`; the integration part of every device's `DeviceKey` (`{id}:<native id>`).
    /// Persisted: never change it once released.
    public static let id = "{id}"
    static let displayName = "{display}"

    public var id: String { Self.id }
    /// The service name in every text ("{display} did not accept the login.").
    public var displayName: String { Self.displayName }
    // TODO(integration): the vendor's name; `brandName` ("the … app") defaults to it.
    public var vendorName: String { "{display}" }
    // TODO(integration): what Claude is told the device is (MCP instructions, `list_devices`).
    public var unitDescription: String { "{display} {noun}" }

    // TODO(integration): the sign-in fields the vendor needs (`.email` + `.password`, or `.token`
    // with a `helpURL` to where the user creates it). Stored as `{id}/<field>` in the keychain.
    public var credentialFields: [CredentialField] {
        [CredentialField(id: "token", kind: .token, isSecret: true)]
    }

{rate_comment}
    public var rateLimitPolicy: RateLimitPolicy {
        {rate_policy}
    }

    // TODO(integration): explain the unit's error codes (`ErrorCodeExplaining`), or keep none.
    public var errorCodes: any ErrorCodeExplaining { NoErrorCodes() }

    /// Reads the credentials lazily, when a request is made.
    public func makeConnection(_ context: IntegrationContext) throws -> any DeviceConnection {
        guard let credentials = context.credentials else { throw HeatPumpError.missingCredentials }
        let mapping = credentialMapping
        return {T}Connection(credentials: {{ try? credentials.loadValues(for: mapping) }}, now: context.now)
    }
}
"""

CONNECTION = """import Foundation
import HeatPumpKit

/// TODO(integration): the vendor API (base URL, auth, error format) in a few lines.
///
/// Rate limiting, caching and retries are the service's job (`HistoryStore.reserveFetch`,
/// `reserveChange`); this only sends requests, parses answers and maps errors to `HeatPumpError`.
public actor {T}Connection: {drivers} {{
    public nonisolated let identifier = {T}Integration.id
    /// TODO(integration): the vendor's API base URL.
    static let baseURL = URL(string: "https://api.example.invalid/")!  // constant literal
    /// How long to stay away after HTTP 429 when the answer does not say.
    /// TODO(integration): the vendor's documented pause, or its `Retry-After`.
    static let rateLimitPause: TimeInterval = 15 * 60

    private let credentials: @Sendable () -> CredentialValues?
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        credentials: @escaping @Sendable () -> CredentialValues?, transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = {{ Date() }}
    ) {{
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }}

    public func login() async throws {{
        // TODO(integration): sign in, or nothing when every request carries a token. A refused
        // login is `invalidCredentials`, a login throttle `loginThrottled(until:)`.
        guard credentials() != nil else {{ throw HeatPumpError.missingCredentials }}
    }}

    public func listDevices() async throws -> [DeviceSummary] {{
        // TODO(integration): `Self.devices(from: try JSONValue.parse(try await get("<listing path>")))`.
        // Until then the account has no devices, so the hub serves none.
        []
    }}

    /// The devices in a listing answer.
    static func devices(from json: JSONValue) -> [DeviceSummary] {{
        // TODO(integration): one `DeviceSummary(key: DeviceKey(integration: {T}Integration.id,
        // nativeId: …), name: …, kind: .{kind}, metadata: […])` per unit.
        []
    }}

{members}

    // MARK: HTTP

    /// Sends a GET to `path` and returns the body, or throws the mapped error.
    func get(_ path: String) async throws -> Data {{
        guard let values = credentials() else {{ throw HeatPumpError.missingCredentials }}
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.timeoutInterval = 20
        // TODO(integration): authenticate as the vendor documents (header, session, …).
        if let token = values["token"] {{ request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization") }}
        let (data, response) = try await transport.send(request)
        if let error = Self.error(status: response.statusCode, now: now()) {{ throw error }}
        return data
    }}

    /// The error an HTTP status means, or nil for success.
    /// TODO(integration): the vendor's own error bodies (codes in a 200 answer, throttle texts).
    static func error(status: Int, now: Date) -> HeatPumpError? {{
        switch status {{
        case 200..<300: nil
        case 401, 403: .invalidCredentials(nil)
        case 429: .rateLimited(until: now.addingTimeInterval(rateLimitPause))
        default: .http(status: status)
        }}
    }}
}}
"""

TEST = """import Foundation
import Testing
@testable import HeatPumpKit
@testable import Integrations
@testable import {T}Integration

/// Generated by scripts/new-integration.py: these pin the scaffold's state. Replace them with tests
/// of the real listing, reads and error answers, fed through `StubTransport` from redacted
/// fixtures shaped as the vendor documents them (`Fixtures/{fixture}.json`).
@Suite("{display} integration")
struct {T}IntegrationTests {{
    let clock = TestClock()

    func connection(_ transport: StubTransport, values: CredentialValues? = CredentialValues(["token": "TOKEN"])) -> {T}Connection {{
        {T}Connection(credentials: {{ values }}, transport: transport, now: clock.provider)
    }}

    @Test func isInTheCatalogOnce() {{
        #expect(IntegrationCatalog.all.filter {{ $0.id == {T}Integration.id }}.count == 1)
        #expect({T}Integration().credentialMapping.integrationId == "{id}")
    }}

    @Test func needsCredentials() throws {{
        let store = try HistoryStore(path: temporaryDatabasePath())
        #expect(throws: HeatPumpError.missingCredentials) {{
            try {T}Integration().makeConnection(IntegrationContext(environment: [:], store: store))
        }}
    }}

    @Test func servesItsKind() {{
        #expect(connection(StubTransport()).capabilities == {capabilities})
    }}

    @Test func listsNothingUntilImplemented() async throws {{
        let transport = StubTransport()
        #expect(try await connection(transport).listDevices().isEmpty)
        #expect(transport.requests.isEmpty)
        #expect({T}Connection.devices(from: try Fixture.json("{fixture}")).isEmpty)
    }}

    @Test func refusedAnswersBecomeHeatPumpErrors() async throws {{
        let transport = StubTransport()
        transport.enqueue("devices", status: 401, body: Data())
        transport.enqueue("devices", status: 429, body: Data())
        let client = connection(transport)
        await #expect(throws: HeatPumpError.invalidCredentials(nil)) {{ try await client.get("devices") }}
        await #expect(throws: HeatPumpError.rateLimited(until: clock.now.addingTimeInterval({T}Connection.rateLimitPause))) {{
            try await client.get("devices")
        }}
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
    }}

    @Test func noCredentialsSendNothing() async throws {{
        let transport = StubTransport()
        await #expect(throws: HeatPumpError.missingCredentials) {{ try await connection(transport, values: nil).get("devices") }}
        #expect(transport.requests.isEmpty)
    }}

{test_unimplemented}
}}
"""


# MARK: Registration edits (computed first, written only when every anchor is found)


def edit_package(text, target):
    product_anchor = '        .library(name: "DemoIntegration", targets: ["DemoIntegration"]),\n'
    if product_anchor not in text:
        fail("Package.swift: the DemoIntegration product line was not found")
    text = text.replace(product_anchor, f'        .library(name: "{target}", targets: ["{target}"]),\n' + product_anchor, 1)

    lines = text.splitlines(keepends=True)
    index = next((i for i, line in enumerate(lines) if '.target(name: "DemoIntegration"' in line), None)
    if index is None:
        fail("Package.swift: the DemoIntegration target was not found")
    while index > 0 and lines[index - 1].strip().startswith("//"):
        index -= 1
    lines[index:index] = [
        "        // TODO(integration): what this integration connects. Add `exclude: [\"Knowledge\"]` with documents.\n",
        f'        .target(name: "{target}", dependencies: ["HeatPumpKit"]),\n',
    ]
    text = "".join(lines)

    integrations = re.search(r'(\.target\(name: "Integrations", dependencies: \[[^\]]*?)"DemoIntegration"', text)
    if not integrations:
        fail('Package.swift: "DemoIntegration" in the Integrations target dependencies was not found')
    text = text[: integrations.end(1)] + f'"{target}", ' + text[integrations.end(1) :]

    test_target = re.search(r'(\.testTarget\(\s*name: "HeatPumpKitTests",\s*dependencies: \[[^\]]*?)"DemoIntegration"', text)
    if not test_target:
        fail('Package.swift: "DemoIntegration" in the test target dependencies was not found')
    return text[: test_target.end(1)] + f'"{target}", ' + text[test_target.end(1) :]


def edit_catalog(text, target, static):
    imports = re.findall(r"^import \w+\n", text, re.M)
    if not imports:
        fail("IntegrationCatalog.swift: no imports found")
    block = "".join(imports)
    new_block = "".join(sorted(imports + [f"import {target}\n"]))
    text = text.replace(block, new_block, 1)

    anchor = "    public static let demo = DemoIntegration()\n"
    if anchor not in text:
        fail("IntegrationCatalog.swift: `public static let demo = DemoIntegration()` was not found")
    text = text.replace(anchor, f"    public static let {static} = {target}()\n" + anchor, 1)

    all_list = re.search(r"(public static let all: \[any Integration\] = \[[^\]]*?)\bdemo\b", text)
    if not all_list:
        fail("IntegrationCatalog.swift: `demo` in `all` was not found")
    return text[: all_list.end(1)] + f"{static}, " + text[all_list.end(1) :]


def edit_catalog_test(text, integration_id):
    expectation = re.search(r'(#expect\(ids == \[[^\]]*?)"demo"', text)
    if not expectation:
        return None
    return text[: expectation.end(1)] + f'"{integration_id}", ' + text[expectation.end(1) :]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("type_name", metavar="TypeName", help="UpperCamelCase, without the Integration suffix (e.g. Daikin)")
    parser.add_argument("--id", required=True, help="persisted integration id, the DeviceKey prefix (e.g. daikin-onecta)")
    parser.add_argument("--kind", required=True, help="an existing DeviceKind rawValue (e.g. airToAirHeatPump, energyMeter)")
    parser.add_argument("--display", help="service name in texts (default: TypeName)")
    args = parser.parse_args()

    name = args.type_name
    if not re.fullmatch(r"[A-Z][A-Za-z0-9]*", name) or name.endswith("Integration"):
        fail("TypeName must be UpperCamelCase letters and digits, without the Integration suffix")
    integration_id = args.id
    if not re.fullmatch(r"[a-z][a-z0-9-]*[a-z0-9]", integration_id):
        fail("--id must be lowercase letters, digits and dashes (it is persisted in every DeviceKey)")
    if integration_id in RESERVED_IDS or integration_id in existing_ids():
        fail(f"the id {integration_id!r} is already used")
    kinds = device_kinds()
    if args.kind not in kinds:
        fail(f"--kind must be one of {', '.join(kinds)} (a new kind is added by hand first; see the skill)")
    if args.kind not in KIND_TEMPLATES:
        fail(f"no template for the kind {args.kind!r}; add one to KIND_TEMPLATES in {pathlib.Path(__file__).name}")
    display = args.display or name
    if '"' in display or "\\" in display:
        fail("--display may not contain quotes or backslashes")

    target = f"{name}Integration"
    static = lower_camel(name)
    fixture = integration_id.replace("-", "_") + "_devices"
    source_dir = SOURCES / target
    test_file = TESTS / f"{target}Tests.swift"
    fixture_file = TESTS / "Fixtures" / f"{fixture}.json"

    for path in (source_dir, test_file, fixture_file):
        if path.exists():
            fail(f"{path.relative_to(ROOT)} already exists")
    package_text = PACKAGE_SWIFT.read_text()
    catalog_text = CATALOG.read_text()
    if f'"{target}"' in package_text:
        fail(f"Package.swift already mentions {target}")
    if re.search(rf"\b{target}\b|static let {static}\b", catalog_text):
        fail(f"IntegrationCatalog.swift already has {target} or a `{static}`")

    template = KIND_TEMPLATES[args.kind]
    values = {"T": name, "id": integration_id, "display": display, "kind": args.kind, "fixture": fixture, **template}
    files = {
        source_dir / f"{target}.swift": INTEGRATION.replace("{rate_comment}", template["rate_comment"])
        .replace("{rate_policy}", template["rate_policy"])
        .replace("{{", "\0")
        .replace("}}", "\1")
        .replace("{T}", name)
        .replace("{id}", integration_id)
        .replace("{display}", display)
        .replace("{noun}", template["noun"])
        .replace("\0", "{")
        .replace("\1", "}"),
        source_dir / f"{name}Connection.swift": CONNECTION.format(
            **{**values, "members": template["members"]}
        ),
        test_file: TEST.format(**{**values, "test_unimplemented": template["test_unimplemented"].replace("{T}", name)}),
        fixture_file: json.dumps(
            {
                "_note": "Placeholder from scripts/new-integration.py. Replace with a redacted answer shaped as the "
                "vendor documents it: never a real token, e-mail, serial number, address or home id.",
                "devices": [],
            },
            indent=2,
        )
        + "\n",
    }
    new_package = edit_package(package_text, target)
    new_catalog = edit_catalog(catalog_text, target, static)
    new_catalog_test = edit_catalog_test(CATALOG_TEST.read_text(), integration_id)

    source_dir.mkdir(parents=True)
    for path, content in files.items():
        path.write_text(content)
    PACKAGE_SWIFT.write_text(new_package)
    CATALOG.write_text(new_catalog)
    if new_catalog_test:
        CATALOG_TEST.write_text(new_catalog_test)

    rel = lambda p: p.relative_to(ROOT)
    print(f"Created {target} ({args.kind}, id {integration_id!r}):")
    for path in files:
        print(f"  {rel(path)}")
    print(f"Registered in {rel(PACKAGE_SWIFT)} and IntegrationCatalog.all (`IntegrationCatalog.{static}`)")
    if new_catalog_test:
        print(f"Added {integration_id!r} to the expected ids in {rel(CATALOG_TEST)}")
    else:
        print(f"Check the expected ids in {rel(CATALOG_TEST)} (catalogListsEachIntegrationOnce): the anchor was not found")
    print(
        f"""
Next steps (.claude/skills/add-integration/SKILL.md):
  1. cd Packages/HeatPumpKit && swift test --filter {target}Tests   # the scaffold builds and its tests pass
  2. Research the vendor API (endpoints, auth, limits, error format) and save the notes next to the work.
  3. Work through every TODO(integration):  grep -rn "TODO(integration)" {rel(source_dir)} {rel(test_file)} {rel(PACKAGE_SWIFT)}
  4. Replace the fixture with redacted, documented answers and the scaffold tests with real ones.
  5. Knowledge documents, a demo variant, l10n, README and CHANGELOG as the skill describes.
  6. make check && python3 scripts/l10n.py check
Until the connection works, keep the catalog entry out of a release: the app offers every
catalog integration under Settings > Account > Add Integration…"""
    )


if __name__ == "__main__":
    main()
