import Foundation

#if canImport(AppKit)
import AppKit

// Zenith's entry point.
//
// A SwiftPM executable target runs `main.swift` as top-level code, so there is no
// `@main` attribute here — and there must not be one, because `@main` and
// top-level code in the same file are a compile error.
//
// The whole file is inside `canImport(AppKit)` so that the Linux CI job can still
// type-check the rest of the target's sources (which are themselves guarded) and
// catch a syntax error in two minutes instead of waiting three for a Mac runner.
// On Linux this build is not an application and does not pretend to be.

import CoreKit
import EditorKit
import LayoutKit

// Headless mode, for CI.
//
// A continuous-integration runner can compile this target but cannot look at a
// window, so "it builds" proves very little about an app. Setting
// ZENITH_HEADLESS makes the *same binary* construct the real welcome document,
// run the real layout engine with the real CoreText measurer, and report what it
// produced. That catches the failures a compile cannot: a font that resolves to
// nothing, a snapshot with no lines, a text index whose offsets disagree with the
// model. If this exits non-zero, the app a user downloads would open onto a blank
// grey window.
if ProcessInfo.processInfo.environment["ZENITH_HEADLESS"] != nil {
    var failures: [String] = []
    func expect(_ condition: Bool, _ description: String) {
        if condition {
            print("  ok    \(description)")
        } else {
            failures.append(description)
            print("  FAIL  \(description)")
        }
    }

    print("Zenith headless smoke test")

    let document = WelcomeDocument.make()
    let controller = DocumentController(document: document, authorName: "Zenith CI")
    let snapshot = controller.snapshot
    let index = controller.textIndex

    expect(!snapshot.pages.isEmpty, "layout produced at least one page")
    expect(snapshot.pages.count >= 1, "page count is \(snapshot.pageCount)")

    // Spelled with named parameters: the implicit $0/$1/$2 shorthand does not
    // nest, and the inner closure silently binds to the outer one's arguments.
    let lineCount = snapshot.pages.reduce(0) { pageTotal, page in
        pageTotal + page.paragraphs.reduce(0) { paragraphTotal, paragraph in
            paragraphTotal + paragraph.lines.count
        }
    }
    expect(lineCount > 10, "layout produced \(lineCount) lines")

    expect(index.entries.count == document.paragraphIDsInOrder.count,
           "text index covers all \(document.paragraphIDsInOrder.count) paragraphs (\(index.entries.count))")
    expect(index.totalUTF16 > 0, "flat text length is \(index.totalUTF16) UTF-16 units")

    // Round-trip every paragraph boundary through the flat index. A mismatch here
    // is what puts an input method's composition in the wrong place.
    var roundTrips = 0
    for entry in index.entries {
        let start = TextPosition(paragraphID: entry.paragraphID, characterOffset: 0)
        let flat = index.utf16Offset(of: start)
        let back = index.position(utf16Offset: flat)
        if back.paragraphID == entry.paragraphID, back.characterOffset == 0 { roundTrips += 1 }
    }
    expect(roundTrips == index.entries.count,
           "flat-offset round trip is exact for \(roundTrips)/\(index.entries.count) paragraphs")

    // Fonts must resolve to something real, not to a nil that silently falls back.
    var resolved = 0
    var sampled = 0
    for page in snapshot.pages {
        for paragraph in page.paragraphs {
            for line in paragraph.lines {
                for segment in line.segments {
                    guard sampled < 200 else { break }
                    sampled += 1
                    // `postScriptName` takes the resolved `FontSpec`, not the whole
                    // run style: colour, highlight and language do not affect which
                    // face CoreText picks.
                    let name = controller.measurer.postScriptName(for: segment.style.font)
                    if !name.isEmpty { resolved += 1 }
                }
            }
        }
    }
    expect(sampled > 0 && resolved == sampled,
           "resolved a real font for \(resolved)/\(sampled) sampled runs")

    // Typing must work without a window: this is the same call path the view uses.
    let before = controller.textIndex.totalUTF16
    controller.mutate { state in
        state.insertText("Zenith", timestamp: Date())
    }
    let after = controller.textIndex.totalUTF16
    expect(after == before + 6, "inserting text grew the document by 6 units (\(before) -> \(after))")

    controller.mutate { $0.undo(timestamp: Date()) }
    expect(controller.textIndex.totalUTF16 == before, "undo restored the previous length")

    if failures.isEmpty {
        print("\nZenith headless smoke test: all checks passed")
        exit(0)
    }
    print("\nZenith headless smoke test: \(failures.count) failure(s)")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
// `activate(ignoringOtherApps:)` is deprecated as of macOS 14 and would emit a
// warning on the Xcode 27 SDK; the deployment floor is macOS 27, so the
// replacement is unconditional.
application.activate()
application.run()

#else

// Reached only when the target is compiled on a platform without AppKit. The
// `AppDelegate` reference above is inside the same conditional, so nothing here
// depends on it.
print(
    """
    Zenith is a macOS application and needs AppKit to run.

    This binary was built on a platform without it, so there is no window to show.
    The headless harness — the layout engine's self-test and the command-line
    layout report — lives in the `Galley` executable instead (that target is
    renamed in the same pass that renames the rest of the project):

        swift run Galley selftest
        swift run Galley layout
    """
)

#endif
