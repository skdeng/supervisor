// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DynamicLake",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "DynamicLake",
            path: "Sources/DynamicLake",
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
        )
    ]
)
