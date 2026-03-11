// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "voice",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "voice", targets: ["voice"])
    ],
    targets: [
        .executableTarget(
            name: "voice",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Speech")
            ]
        ),
    ]
)
