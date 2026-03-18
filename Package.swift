// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OllamaStatus",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "OllamaStatus",
            path: "OllamaStatus",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
