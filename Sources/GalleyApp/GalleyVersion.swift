import Foundation

/// Version metadata for the harness and, later, for the app's About panel.
public enum GalleyVersion {

    /// Milestone 0. The numbering follows docs/05-ROADMAP.md: v1.0 is M0–M3.
    public static let current = "0.0.1-m0"

    /// The commit the binary was built from, when the build system supplies it.
    ///
    /// Injected rather than hard-coded: a hard-coded revision goes stale the
    /// moment anyone commits, and a stale revision in a bug report is worse than
    /// no revision at all.
    public static var revision: String {
        ProcessInfo.processInfo.environment["GALLEY_REVISION"] ?? "unknown"
    }

    public static var buildDate: String {
        ProcessInfo.processInfo.environment["SOURCE_DATE_EPOCH"]
            .flatMap { Double($0) }
            .map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
            ?? "development build"
    }

    /// A one-line banner suitable for a crash report or a support email.
    public static var banner: String {
        "Galley \(current) (\(revision))"
    }
}
