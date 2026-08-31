// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SuperVisor",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        // Pinned to the minor because make-app.sh hardcodes the artifact slice path and the
        // framework's Versions/B layout; a Sparkle minor bump is a deliberate act that
        // revisits both.
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.9.6"))
    ],
    targets: [
        .executableTarget(
            name: "SuperVisor",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/SuperVisor",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            // Embed Info.plist into the executable's __TEXT,__info_plist section so the
            // privacy usage strings (location, calendars, Bluetooth, accessibility) and the
            // LSUIElement/bundle-identifier keys are present even when the binary runs as a
            // bare SPM executable, and are honored when copied into an .app bundle.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "SuperVisorTests",
            dependencies: ["SuperVisor"],
            path: "Tests/SuperVisorTests"
        )
    ]
)
