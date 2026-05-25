// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ModelStatus",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ModelStatus",
            path: "ModelStatus",
            exclude: [
                "Info.plist",
                "ModelStatus.entitlements"
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "ModelStatusTests",
            dependencies: ["ModelStatus"],
            path: "Tests/ModelStatusTests"
        )
    ]
)
