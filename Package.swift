// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ForgeDeck",
    platforms: [.macOS(.v26)],
    dependencies: [
        // The in-app terminal: a VT100/xterm emulator and PTY host. MIT license. Pinned.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3"),
    ],
    targets: [
        // Domain, persistence, services, connectors, security and the CLI logic. No SwiftUI.
        .target(name: "ForgeDeckKit"),
        // The app. The same binary is the `forgedeck` CLI (see Main.swift), so the CLI
        // shares the app's code signature and therefore its Keychain access.
        .executableTarget(
            name: "ForgeDeck",
            dependencies: ["ForgeDeckKit", .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ForgeDeckKitTests", dependencies: ["ForgeDeckKit"]),
    ]
)
