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
    ],
    dependencies: [
        .package(url: "https://github.com/leviouwendijk/Agentic.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/AgenticIO.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/AgenticPDF.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Workspace.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Path.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Accounting.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Search.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Math.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Schema.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Macros.git", branch: "master"),
        .package(url: "https://github.com/leviouwendijk/Primitives.git", branch: "master"),
    ],
    targets: [
        .target(
            name: "AgenticAccounting",
            dependencies: [
                .product(name: "Agentic", package: "Agentic"),
                .product(name: "AgenticStandard", package: "Agentic"),
                .product(name: "AgenticIO", package: "AgenticIO"),
                .product(name: "AgenticPDF", package: "AgenticPDF"),
                .product(name: "Path", package: "Path"),
                .product(name: "Workspace", package: "Workspace"),
                .product(name: "Accounting", package: "Accounting"),
                .product(name: "AccountingCompiler", package: "Accounting"),
                .product(name: "Search", package: "Search"),
                .product(name: "Math", package: "Math"),
                .product(name: "AgenticMath", package: "Agentic"),
                .product(name: "Schema", package: "Schema"),
                .product(name: "Macros", package: "Macros"),
                .product(name: "Primitives", package: "Primitives"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
