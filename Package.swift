// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kenar", defaultLocalization: "tr", platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Kenar", resources: [.process("Resources")],
                          linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "KenarTests", dependencies: ["Kenar"], path: "Tests/KenarTests")
    ]
)
