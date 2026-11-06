// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HeatPumpKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HeatPumpKit", targets: ["HeatPumpKit"]),
        .library(name: "MELCloudIntegration", targets: ["MELCloudIntegration"]),
        .library(name: "DemoIntegration", targets: ["DemoIntegration"]),
        .library(name: "Integrations", targets: ["Integrations"]),
        .executable(name: "varmepumpe-mcp", targets: ["varmepumpe-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "HeatPumpKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            // Knowledge/*.md is compiled in (KnowledgeContent.generated.swift) so the
            // embedded helper needs no resource bundle.
            exclude: ["Knowledge"]
        ),
        // One target per integration; the core above names no vendor.
        .target(name: "MELCloudIntegration", dependencies: ["HeatPumpKit"]),
        // The demo simulates a MELCloud unit, so it reuses that integration's wire formats.
        .target(name: "DemoIntegration", dependencies: ["HeatPumpKit", "MELCloudIntegration"]),
        // The only list of integrations, and the factory the app and the helper start from.
        .target(name: "Integrations", dependencies: ["HeatPumpKit", "MELCloudIntegration", "DemoIntegration"]),
        .executableTarget(
            name: "varmepumpe-mcp",
            dependencies: [
                "HeatPumpKit",
                "Integrations",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "HeatPumpKitTests",
            dependencies: ["HeatPumpKit", "MELCloudIntegration", "DemoIntegration", "Integrations"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
