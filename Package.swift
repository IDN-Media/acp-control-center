// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ACPControlCenter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ACPControlCenter",
            targets: ["ACPControlCenter"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ACPControlCenter",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "ACPControlCenterTests",
            dependencies: ["ACPControlCenter"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
