import Foundation
import CoreKit
import LayoutKit
import EditorKit
import IntelligenceKit

// MARK: - ZenithTool command-line entry point

// The shipped product is a Mac app, and `EditorKit` grows its AppKit surface in
// M1. What lives here in M0 is the layout harness: a way to run the whole
// pipeline — model, style cascade, line breaking, pagination — headlessly and
// assert on the result.
//
// That is deliberate. The M0 exit test is "the engine lays out a document
// correctly", not "a window opens", and a harness that runs identically on a
// Linux CI runner and on an `xcode-27` macOS runner is what makes that testable
// on every push rather than once a week by hand.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> String {
    """
    Zenith Workspace \(ToolVersion.current) — layout and editing harness

    Usage:
      ZenithTool selftest                 run every applicable check; exit 1 on failure
      ZenithTool layout [--pages N]       lay out a sample document and report pages/lines
      ZenithTool providers                list the AI providers compiled into this build
      ZenithTool version                  print the version
      ZenithTool help                     this text

    Options:
      --measurer coretext|fixed       measurement backend (default: fixed, for
                                      determinism; coretext is macOS-only)
      --width POINTS                  text-area width override (default 468)
      --verbose                       print per-page detail
    """
}

/// Right-aligned two-decimal formatting for the layout report.
///
/// A free function rather than a `Self` member: `main.swift` is a top-level
/// script, where `Self` has no meaning.
func fixed(_ value: Double) -> String {
    let text = String(format: "%.2f", value)
    return String(repeating: " ", count: max(0, 7 - text.count)) + text
}

var verbose = false
var requestedWidth = 468.0
var measurerName = "fixed"

var positional: [String] = []
var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--verbose", "-v": verbose = true
    case "--width":
        guard let value = iterator.next(), let parsed = Double(value) else {
            FileHandle.standardError.write(Data("--width requires a number\n".utf8))
            exit(2)
        }
        requestedWidth = parsed
    case "--measurer":
        guard let value = iterator.next() else {
            FileHandle.standardError.write(Data("--measurer requires coretext or fixed\n".utf8))
            exit(2)
        }
        measurerName = value
    case "--pages":
        // Accepted and ignored: the sample document's length is fixed.
        _ = iterator.next()
    case let flag where flag.hasPrefix("-"):
        FileHandle.standardError.write(Data("unknown option \(flag)\n".utf8))
        exit(2)
    default:
        positional.append(argument)
    }
}

func makeMeasurer() -> any TextMeasurer {
    switch measurerName {
    case "coretext":
        guard let measurer = LayoutEngine.defaultMeasurer() else {
            FileHandle.standardError.write(Data("the CoreText measurer is only available on Apple platforms\n".utf8))
            exit(2)
        }
        return measurer
    default:
        return FixedWidthMeasurer.tenPoint
    }
}

let command = positional.first ?? "help"

switch command {
case "version", "--version":
    print("Zenith Workspace \(ToolVersion.current)")
    print("build date: \(ToolVersion.buildDate)")
    print("layout backend: \(measurerName)")

case "help", "--help", "-h":
    print(usage())

case "providers":
    for provider in ProviderCatalogue.builtIn {
        let availability = provider.availability()
        let onDevice = provider.runsOnDevice ? "on-device" : "sends text off this Mac"
        print("\(provider.id) — \(provider.displayName) (\(onDevice))")
        print("  status: \(availability.userMessage)")
        print("  tasks:  \(provider.supportedTasks.map { $0.rawValue }.sorted().joined(separator: ", "))")
    }

case "layout":
    let document = SampleDocument.make(widthPoints: requestedWidth)
    let engine = LayoutEngine(measurer: makeMeasurer())
    let snapshot = engine.layout(document: document, generation: 1)

    print("text area width: \(requestedWidth) pt")
    print("paragraphs:      \(document.paragraphIDsInOrder.count)")
    print("pages:           \(snapshot.pageCount)")
    print("lines:           \(snapshot.pages.reduce(0) { $0 + $1.lines.count })")
    if verbose {
        for page in snapshot.pages {
            print("")
            print("page \(page.displayedPageNumber) (index \(page.index), \(page.breakReason))")
            for paragraph in page.paragraphs {
                for line in paragraph.lines {
                    let text = line.segments.map { $0.text }.joined()
                    let trimmed = text.count > 60 ? String(text.prefix(57)) + "..." : text
                    // No `%@` here: `String(format:)` with an object conversion
                    // specifier depends on NSString bridging, which is not
                    // reliable in swift-corelibs-foundation. The harness has to
                    // run on Linux, so only numeric conversions are used.
                    print("  y=\(fixed(line.frame.y))"
                          + " h=\(fixed(line.frame.height))"
                          + " w=\(fixed(line.contentWidth))  \(trimmed)")
                }
            }
        }
    }

case "selftest":
    let measurer = makeMeasurer()
    let fixedMetrics = measurerName == "fixed"
    let applicable = fixedMetrics
        ? SelfTest.all
        : SelfTest.all.filter { !$0.requiresFixedMetrics }
    let skipped = SelfTest.all.count - applicable.count

    var failures: [String] = []
    for check in applicable {
        do {
            try check.run(width: requestedWidth, measurer: measurer, verbose: verbose)
            if verbose { print("ok   \(check.name)") }
        } catch {
            failures.append("\(check.name): \(error)")
            print("FAIL \(check.name): \(error)")
        }
    }
    print("")
    print("\(applicable.count - failures.count)/\(applicable.count) checks passed"
        + (skipped > 0 ? " (\(skipped) skipped: they assert synthetic-metric arithmetic)" : ""))
    if failures.isEmpty {
        print("Zenith Workspace \(ToolVersion.current) selftest: PASS")
    } else {
        print("Zenith Workspace \(ToolVersion.current) selftest: FAIL")
        exit(1)
    }

default:
    FileHandle.standardError.write(Data("unknown command '\(command)'\n\n".utf8))
    print(usage())
    exit(2)
}
