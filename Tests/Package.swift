// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AgenticAccountingTests",
    platforms: [.macOS(.v13)],
    products: [
        .executable(
            name: "t_agentic_accounting",
            targets: ["AgenticAccountingTesting"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Agentic.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/AgenticPDF.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Workspace.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Path.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/IO.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Accounting.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Testing.git", branch: "master"),
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "AgenticAccountingTesting",
            dependencies: [
                .product(name: "AgenticAccounting", package: "AgenticAccounting"),
                .product(name: "AgenticPDF", package: "AgenticPDF"),
                .product(name: "Accounting", package: "Accounting"),
                .product(name: "Testing", package: "Testing"),
                .product(name: "Agentic", package: "Agentic"),
                .product(name: "Workspace", package: "Workspace"),
                .product(name: "Path", package: "Path"),
                .product(name: "IO", package: "IO"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
