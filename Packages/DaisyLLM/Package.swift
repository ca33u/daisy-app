// swift-tools-version: 6.2
import PackageDescription

// DaisyLLM — «Локальная модель Daisy» (plan 2026-10-28, package Л-1):
// a summary model that runs on this Mac through MLX, in its own XPC
// process (DaisyLLM.xpc inside Daisy.app) so its 4–7 GB never sit next
// to Whisper in Daisy, and an MLX crash or a memory-pressure kill takes
// the helper, not a recording.
//
// Two libraries, so MLX is linked only where it runs:
//  • DaisyLLMKit — the Codable wire protocol, the NSXPC interfaces and
//    the service core (queue, cancellation, exit on idle) behind a
//    `DaisyLLMBackend` protocol. No dependencies. Daisy.app links it for
//    the client; the tests drive the core with a scripted backend.
//  • DaisyLLMEngine — the MLX backend. Only DaisyLLM.xpc links it.
//
// Like DaisyLink these targets keep the language's own default
// isolation (nonisolated): the coordinator is `@MainActor` by name, the
// engine's heavy work is `@concurrent`, and the wire types cross XPC
// queues. The XPC target's own code is MainActor by default, as the app.
let package = Package(
    name: "DaisyLLM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DaisyLLMKit", targets: ["DaisyLLMKit"]),
        .library(name: "DaisyLLMEngine", targets: ["DaisyLLMEngine"]),
    ],
    dependencies: [
        // Pinned exactly: the spike (28.10) measured this release on this
        // Mac — Qwen 3.5 4B 4-bit, Swift as fast as Python-MLX. A new one
        // is a deliberate change with a re-measure, not a resolve.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        // The tokenizer, through mlx-swift-lm's `TokenizerLoader` protocol
        // (not the MLXHuggingFace macros, which would pull in swift-syntax).
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        .target(
            name: "DaisyLLMKit",
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .target(
            name: "DaisyLLMEngine",
            dependencies: [
                "DaisyLLMKit",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
