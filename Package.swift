// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AgenticAccounting",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "AgenticAccounting",
            targets: ["AgenticAccounting"]
        ),
        .executable(
            name: "t_agentic_accounting",
            targets: ["AgenticAccountingTesting"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Agentic.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Accounting.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Math.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Schema.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Macros.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Testing.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "AgenticAccounting",
            dependencies: [
                .product(name: "Agentic", package: "Agentic"),
                .product(name: "Accounting", package: "Accounting"),
                .product(name: "AccountingCompiler", package: "Accounting"),
                .product(name: "Math", package: "Math"),
                .product(name: "Schema", package: "Schema"),
                .product(name: "Macros", package: "Macros"),
            ]
        ),
        .executableTarget(
            name: "AgenticAccountingTesting",
            dependencies: [
                "AgenticAccounting",
                .product(name: "Testing", package: "Testing"),
            ],
            path: "Testing/AgenticAccountingTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
