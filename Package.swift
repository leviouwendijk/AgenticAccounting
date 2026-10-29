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
        .package(url: "https://github.com/leviouwendijk/AgenticIO.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Workspace.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Path.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/IO.git", branch: "master"),
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
                .product(name: "AgenticStandard", package: "Agentic"),
                .product(name: "AgenticIO", package: "AgenticIO"),
                .product(name: "Workspace", package: "Workspace"),
                .product(name: "Accounting", package: "Accounting"),
                .product(name: "AccountingCompiler", package: "Accounting"),
                .product(name: "Math", package: "Math"),
                .product(name: "AgenticMath", package: "Agentic"),
                .product(name: "Schema", package: "Schema"),
                .product(name: "Macros", package: "Macros"),
            ]
        ),
        .executableTarget(
            name: "AgenticAccountingTesting",
            dependencies: [
                "AgenticAccounting",
                .product(name: "Testing", package: "Testing"),
                .product(name: "Agentic", package: "Agentic"),
                .product(name: "Workspace", package: "Workspace"),
                .product(name: "Path", package: "Path"),
                .product(name: "IO", package: "IO"),
            ],
            path: "Testing/AgenticAccountingTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
