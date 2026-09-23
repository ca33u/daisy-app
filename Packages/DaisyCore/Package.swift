// swift-tools-version: 6.2
import PackageDescription

// DaisyCore — platform-free heart of Daisy for iPhone: the session
// format contract (writer / reader / classifier), audio resampling and
// the on-device Whisper engine (backlog 6 F-1: the SAME WhisperKit model
// the Mac transcribes with, so a phone session re-transcribed on the Mac
// reads the same). No UIKit, no AppKit, no `#if os(...)`.
// Lives in daisy-app (public) and is referenced by DaisyLite (private)
// as `../Daisy/Packages/DaisyCore` — the public repository must build
// from a clone on its own.
// Same defaults as the app target: Swift 6 language mode, MainActor as
// the default isolation, strict concurrency.
//
// DaisyPalette / DaisyDesign (backlog 5 E-1) — the colour tokens and
// the button vocabulary SHARED with the Mac app (`daisy-app` links
// `DaisyDesign` from this package): `DaisyPalette` is data only (hex
// pairs, metrics numbers), `DaisyDesign` is the thin SwiftUI layer on
// top. The macOS floor is 14 because the Mac app ships for macOS 14+;
// the iOS-26-only App Intents API in `DaisyCore` is availability-gated
// instead of raising the whole package's floor.
let package = Package(
    name: "DaisyCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
        // Бэклог 14 Н-2: only `DaisyLink` is built for the watch — it
        // is Foundation-only and depends on nothing, so WhisperKit
        // never has to exist on watchOS.
        .watchOS(.v26),
    ],
    products: [
        .library(name: "DaisyCore", targets: ["DaisyCore"]),
        .library(name: "DaisyPalette", targets: ["DaisyPalette"]),
        .library(name: "DaisyDesign", targets: ["DaisyDesign"]),
        .library(name: "DaisyLink", targets: ["DaisyLink"]),
        .library(name: "DaisyDiarization", targets: ["DaisyDiarization"]),
    ],
    dependencies: [
        // WhisperKit 1.1.0 — the same pin as daisy-app
        // (Daisy.xcodeproj Package.resolved), so both sides run the
        // identical decoder on the identical model.
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift",
            revision: "1e2a163736dfa5a198e637ae44c114e1c6d5cc2d"
        ),
        // Бэклог 18: diarization on the phone, as a spike.
        //
        // The revision is pinned to the EXACT one daisy-app uses
        // (Daisy.xcodeproj Package.resolved), and that is not tidiness:
        // a voice embedding only means something inside the model that
        // produced it. A different FluidAudio would download different
        // weights, the owner's `SpeakerProfile` built on the Mac would
        // match nobody on the phone, and the spike would measure the
        // wrong thing while looking like it worked.
        .package(
            url: "https://github.com/FluidInference/FluidAudio",
            revision: "6428e29186573c6d33c598e25d460e6690bc0ee1"
        ),
    ],
    targets: [
        .target(
            name: "DaisyCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(
            name: "DaisyPalette",
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(
            name: "DaisyDesign",
            dependencies: ["DaisyPalette"],
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        // Бэклог 18: kept OUT of DaisyCore on purpose. Everything that
        // links DaisyCore — the widgets, and through them the home
        // screen — would otherwise carry FluidAudio too, and a widget
        // has about 30 MB of memory to live in. Only the app links
        // this.
        .target(
            name: "DaisyDiarization",
            dependencies: [
                "DaisyCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(
            name: "DaisyLink",
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "DaisyCoreTests",
            dependencies: ["DaisyCore", "DaisyPalette", "DaisyDesign", "DaisyLink"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
