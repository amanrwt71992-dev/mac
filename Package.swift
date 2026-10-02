// swift-tools-version:6.0
//
//  Galley — a native Mac word processor.
//
//  Target layering is load-bearing, not cosmetic. The dependency flow is strictly
//  downward and CI enforces it (see .github/workflows/ci.yml):
//
//      CoreKit            pure Swift + Foundation. No AppKit, no CoreText, no UIKit.
//                         Compiles and unit-tests on Linux, which is what lets us
//                         type-check most of the codebase in ~3 minutes.
//      OOXMLKit           (M1) adds ZIPFoundation. Still cross-platform.
//      IntelligenceKit    Foundation + FoundationModels behind `canImport`.
//      LayoutKit          CoreText. macOS only; guarded so Linux still builds.
//      EditorKit          CoreKit only. Editing, selection and undo; no layout,
//                         no AppKit in M0 (the AppKit surface arrives in M1).
//      GalleyApp          the executable.
//
//  Nothing may import EditorKit or GalleyApp.

import PackageDescription

let package = Package(
    name: "Galley",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "CoreKit", targets: ["CoreKit"]),
        .library(name: "IntelligenceKit", targets: ["IntelligenceKit"]),
        .library(name: "LayoutKit", targets: ["LayoutKit"]),
        .library(name: "EditorKit", targets: ["EditorKit"]),
        .executable(name: "Galley", targets: ["GalleyApp"]),
    ],
    targets: [
        .target(name: "CoreKit"),

        .target(
            name: "IntelligenceKit",
            dependencies: ["CoreKit"]
        ),

        .target(
            name: "LayoutKit",
            dependencies: ["CoreKit"]
        ),

        // EditorKit depends on CoreKit alone. It may not import LayoutKit: the
        // layout is derived state owned by the document controller, and the CI
        // job `checks` fails the build if that boundary is crossed.
        .target(
            name: "EditorKit",
            dependencies: ["CoreKit"]
        ),

        .executableTarget(
            name: "GalleyApp",
            dependencies: ["CoreKit", "LayoutKit", "EditorKit", "IntelligenceKit"],
            path: "Sources/GalleyApp"
        ),

        .testTarget(
            name: "CoreKitTests",
            dependencies: ["CoreKit"]
        ),

        .testTarget(
            name: "LayoutKitTests",
            dependencies: ["CoreKit", "LayoutKit"]
        ),

        .testTarget(
            name: "EditorKitTests",
            dependencies: ["CoreKit", "EditorKit", "IntelligenceKit"]
        ),
    ],
    // Swift 5 language mode for now. Swift 6 strict concurrency is the right
    // destination — the layout engine is actor-based — but we cannot type-check
    // locally (the dev sandbox is Linux with no Swift toolchain), so we adopt it
    // deliberately once CI is reliably green rather than fighting two problems at once.
    swiftLanguageModes: [.v5]
)
