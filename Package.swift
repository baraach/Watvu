// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Watvu",
    defaultLocalization: .init("en"),
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Watvu",
            path: "Sources/Watvu",
            resources: [.process("Resources")]
        )
    ]
)
