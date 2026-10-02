import Foundation

/// A stable identity for a node in the document tree.
///
/// Everything that needs to point *at* content rather than *contain* it uses a
/// `NodeID`: comment anchors, bookmarks, cross-reference fields, revision
/// ranges, AI tool calls, and the `OriginRef` map that drives byte-preserving
/// save.
///
/// Stability across a save-and-reopen cycle is a hard requirement — the
/// identifier is persisted in our own custom XML part inside the package, so
/// that an AI mutation proposed against a node remains valid after the document
/// has been closed and reopened.
public struct NodeID: Hashable, Sendable, Comparable, CustomStringConvertible {

    /// The opaque value. We use a monotonically increasing 64-bit counter
    /// rather than a UUID because node ids appear in the persisted map and in
    /// every AI tool call, and short deterministic ids are far easier to debug.
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    public var description: String { "n\(rawValue)" }
}

/// Hands out `NodeID`s for a single document.
///
/// Not thread-safe by design; it lives inside the document's editing actor.
public final class NodeIDGenerator {

    private var next: UInt64

    public init(startingAt next: UInt64 = 1) {
        self.next = next
    }

    public func makeID() -> NodeID {
        let id = NodeID(next)
        next = next + 1
        return id
    }

    /// Raises the floor so that ids restored from disk are never reissued.
    public func reserve(upTo observed: UInt64) {
        if observed >= next {
            next = observed + 1
        }
    }

    /// The value to persist so a reopened document continues from the right place.
    public var highWaterMark: UInt64 {
        return next == 0 ? 0 : next - 1
    }
}
