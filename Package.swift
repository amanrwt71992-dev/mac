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
//      OOXMLKit           CoreKit only. The ZIP container and the OOXML
//                         reader/writer. No dependencies, no platform guards, so
//                         the Linux job covers it too.
//      IntelligenceKit    Foundation + FoundationModels behind `canImport`.
//      LayoutKit          CoreText. macOS only; guarded so Linux still builds.
//      EditorKit          CoreKit only. Editing, selection and undo. It may not
//                         import LayoutKit: the snapshot is derived state owned
//                         by the controller, not by the editor.
//      ZenithApp          the application. AppKit lives here and nowhere else.
//      GalleyApp          the headless harness: self-test, layout report,
//                         providers. Named for the old product name; renamed in
//                         the same pass that renames the rest of the project.
//
//  Nothing may import EditorKit or GalleyApp.

import PackageDescription

let package = Package(
    name: "Zenith",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "CoreKit", targets: ["CoreKit"]),
        .library(name: "OOXMLKit", targets: ["OOXMLKit"]),
        .library(name: "IntelligenceKit", targets: ["IntelligenceKit"]),
        .library(name: "LayoutKit", targets: ["LayoutKit"]),
        .library(name: "EditorKit", targets: ["EditorKit"]),
        .executable(name: "Galley", targets: ["GalleyApp"]),
        .executable(name: "Zenith", targets: ["ZenithApp"]),
    ],
    targets: [
        .target(name: "CoreKit"),

        // The file format. ZIP container and OOXML reader/writer.
        //
        // Deliberately free of platform conditionals and of external dependencies.
        // `Compression` is Apple-only, and guarding the codec behind it would mean
        // the Linux job never type-checks a line of it — which is the only job that
        // reports back in two minutes instead of five. Writing the DEFLATE decoder
        // here instead buys that feedback loop, plus error messages that say which
        // block failed, plus the control a byte-preserving save needs.
        //
        // Depends on CoreKit and nothing else: reading a file must not require the
        // layout engine, and laying out a document must not require a file.
        .target(
            name: "OOXMLKit",
            dependencies: ["CoreKit"]
        ),

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

        // The application. This is the only target allowed to import AppKit: it
        // is the only one that draws anything. Everything below it stays
        // headless, which is what keeps the layout engine testable on a machine
        // with no window server and lets CI type-check most of the codebase in
        // two minutes on Linux instead of three on a Mac.
        //
        // Every source file here is wrapped in `#if canImport(AppKit)`, so the
        // Linux job still builds the target — it just produces an executable that
        // says so, rather than failing to compile.
        .executableTarget(
            name: "ZenithApp",
            dependencies: ["CoreKit", "LayoutKit", "EditorKit", "IntelligenceKit"],
            path: "Sources/ZenithApp"
        ),

        .testTarget(
            name: "CoreKitTests",
            dependencies: ["CoreKit"]
        ),

        .testTarget(
            name: "OOXMLKitTests",
            dependencies: ["CoreKit", "OOXMLKit"]
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
