// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voicely",
    platforms: [
        .macOS(.v14)  // Requires macOS 14+ (WhisperKit minimum)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.17.0")),
        // FluidAudio — on-device speaker diarization (Pyannote segmentation +
        // WeSpeaker embeddings, CoreML/ANE). Models download at runtime on
        // first use, not at build time. Platform requirement .macOS(.v14)
        // matches Voicely's deployment target.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.0"),
        // swift-argument-parser — declarative subcommand parsing for the headless
        // `voicely` CLI (VoicelyCLI target). Apple-maintained, no runtime deps.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // MARK: - Reusable core (no AppKit / UI)
        //
        // Pure transcription + diarization + I/O engine shared by the menu-bar
        // app (Voicely) and the headless CLI (VoicelyCLI). Anything that links
        // AppKit / NSStatusBar / overlays stays in the Voicely app target; this
        // library is UI-free so it can be driven headless by an agent.
        .target(
            name: "VoicelyCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/VoicelyCore",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
            ]
        ),
        // MARK: - Menu-bar app
        .executableTarget(
            name: "Voicely",
            dependencies: [
                "VoicelyCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Voicely",
            resources: [
                .copy("Resources"),
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Carbon"),
            ]
        ),
        // MARK: - Headless CLI (`voicely`)
        //
        // Standalone binary an agent (Claude Code, Codex, any harness) drives to
        // transcribe files and read transcripts without the menu-bar UI. Loads
        // the WhisperKit model itself (no daemon). Subcommands register through
        // `Voicely.subcommands` (Sources/VoicelyCLI/Voicely.swift) — N3b adds the
        // `mcp` subcommand there with a one-line edit.
        .executableTarget(
            name: "VoicelyCLI",
            dependencies: [
                "VoicelyCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/VoicelyCLI",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(
            name: "VoicelyTests",
            dependencies: ["Voicely", "VoicelyCore"],
            path: "Tests/VoicelyTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
