import Foundation

// MARK: - ZipArchive

/// A reader for the ZIP container that a `.docx` file is.
///
/// Reading only, and deliberately so. Writing is a separate problem with a much
/// harder requirement attached to it: saving an unedited document must leave every
/// original entry byte-identical, which is not what a general-purpose ZIP writer
/// does — most recompress, re-order, or rewrite the local headers they were handed.
/// That belongs in its own type so the requirement is visible in the file name
/// rather than buried in a flag.
///
/// The central directory is the source of truth for sizes and CRCs, not the local
/// headers. This matters rather than being a preference: an archive written in
/// streaming mode sets bit 3 of the general-purpose flag and stores zeroes in the
/// local header, putting the real values in a data descriptor *after* the payload.
/// A reader that trusts the local header sees a zero-length entry and silently
/// produces an empty document.
public struct ZipArchive {

    // MARK: Errors

    public enum ZipError: Error, Equatable, CustomStringConvertible {
        case endOfCentralDirectoryNotFound
        case truncatedCentralDirectory
        case corruptEntryHeader(String)
        case corruptLocalHeader(String)
        case unsupportedCompression(String, UInt16)
        case encrypted(String)
        case crcMismatch(String, expected: UInt32, actual: UInt32)
        case sizeMismatch(String, expected: Int, actual: Int)
        case entryNotFound(String)

        public var description: String {
            switch self {
            case .endOfCentralDirectoryNotFound:
                return "no ZIP end-of-central-directory record; this is not a ZIP archive"
            case .truncatedCentralDirectory:
                return "the central directory ends before all its entries are present"
            case .corruptEntryHeader(let name):
                return "the central directory entry for \(name) is malformed"
            case .corruptLocalHeader(let name):
                return "the local header for \(name) is malformed or does not match the central directory"
            case .unsupportedCompression(let name, let method):
                return "\(name) uses compression method \(method) (\(ZipArchive.methodName(method))), which is not supported"
            case .encrypted(let name):
                return "\(name) is encrypted; password-protected documents are not supported"
            case .crcMismatch(let name, let expected, let actual):
                return String(format: "%@ is corrupt: CRC-32 should be %08x but decompressed to %08x", name, expected, actual)
            case .sizeMismatch(let name, let expected, let actual):
                return "\(name) should decompress to \(expected) bytes but produced \(actual)"
            case .entryNotFound(let name):
                return "the archive has no entry named \(name)"
            }
        }
    }

    // MARK: Entry

    public struct Entry: Hashable, Sendable {
        /// Archive-relative path with forward slashes, per the ZIP specification.
        /// Note that OPC part names in `[Content_Types].xml` are written with a
        /// *leading* slash and these are not; the two have to be normalised before
        /// they are compared or every lookup fails.
        public let name: String
        public let compressionMethod: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let crc32: UInt32
        public let generalPurposeFlag: UInt16

        /// Offset of this entry's local file header.
        let localHeaderOffset: Int

        /// Bit 0 of the general-purpose flag. Encrypted entries cannot be read,
        /// and saying so is better than producing garbage.
        public var isEncrypted: Bool { generalPurposeFlag & 0x0001 != 0 }

        /// Bit 3: sizes live in a trailing data descriptor, so the local header's
        /// copies are zeroes. The central directory still has the real values.
        public var usesDataDescriptor: Bool { generalPurposeFlag & 0x0008 != 0 }

        public var isSupported: Bool {
            compressionMethod == ZipArchive.methodStored || compressionMethod == ZipArchive.methodDeflate
        }
    }

    public static let methodStored: UInt16 = 0
    public static let methodDeflate: UInt16 = 8

    public static func methodName(_ method: UInt16) -> String {
        switch method {
        case 0: return "stored"
        case 1: return "shrunk"
        case 2, 3, 4, 5: return "reduced"
        case 6: return "imploded"
        case 8: return "deflate"
        case 9: return "deflate64"
        case 10: return "PKWARE imploding"
        case 12: return "bzip2"
        case 14: return "LZMA"
        case 95: return "xz"
        case 99: return "AE-x encrypted"
        case 93: return "Zstandard"
        default: return "unknown"
        }
    }

    // MARK: State

    public let entries: [Entry]
    private let bytes: [UInt8]
    private let index: [String: Int]

    /// True when the archive needed its ZIP64 end-of-central-directory record.
    /// A `.docx` with a large embedded image can cross the 4 GB and 65 535-entry
    /// limits that plain ZIP imposes, and silently mis-reading one is worse than
    /// refusing it.
    public let isZip64: Bool

    // MARK: Construction

    public init(bytes: [UInt8]) throws {
        self.bytes = bytes

        let directory = try ZipArchive.findEndOfCentralDirectory(bytes)
        self.isZip64 = directory.isZip64

        var parsed: [Entry] = []
        var lookup: [String: Int] = [:]
        parsed.reserveCapacity(directory.entryCount)

        var cursor = directory.directoryOffset
        for _ in 0 ..< directory.entryCount {
            guard cursor + 46 <= bytes.count else { throw ZipError.truncatedCentralDirectory }
            guard ZipArchive.u32(bytes, cursor) == 0x0201_4b50 else {
                throw ZipError.truncatedCentralDirectory
            }

            let flag = ZipArchive.u16(bytes, cursor + 8)
            let method = ZipArchive.u16(bytes, cursor + 10)
            let crc = ZipArchive.u32(bytes, cursor + 16)
            var compressed = Int(ZipArchive.u32(bytes, cursor + 20))
            var uncompressed = Int(ZipArchive.u32(bytes, cursor + 24))
            let nameLength = Int(ZipArchive.u16(bytes, cursor + 28))
            let extraLength = Int(ZipArchive.u16(bytes, cursor + 30))
            let commentLength = Int(ZipArchive.u16(bytes, cursor + 32))
            var localOffset = Int(ZipArchive.u32(bytes, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { throw ZipError.truncatedCentralDirectory }
            let name = String(decoding: bytes[nameStart ..< nameStart + nameLength], as: UTF8.self)

            // ZIP64 extra field. The 4-byte sizes above are sentinels, and the
            // real values are in field 0x0001 — in a fixed order, and only for
            // those values that were actually sentinelled. Reading them in the
            // wrong order, or reading one that is not present, shifts every
            // later offset in the archive.
            if extraLength > 0 {
                let extraStart = nameStart + nameLength
                guard extraStart + extraLength <= bytes.count else { throw ZipError.corruptEntryHeader(name) }
                let needsUncompressed = uncompressed == 0xFFFF_FFFF
                let needsCompressed = compressed == 0xFFFF_FFFF
                let needsOffset = localOffset == 0xFFFF_FFFF
                if needsUncompressed || needsCompressed || needsOffset {
                    var walk = extraStart
                    let extraEnd = extraStart + extraLength
                    while walk + 4 <= extraEnd {
                        let fieldID = ZipArchive.u16(bytes, walk)
                        let fieldSize = Int(ZipArchive.u16(bytes, walk + 2))
                        let fieldStart = walk + 4
                        guard fieldStart + fieldSize <= extraEnd else { break }
                        if fieldID == 0x0001 {
                            var at = fieldStart
                            if needsUncompressed, at + 8 <= extraEnd {
                                uncompressed = ZipArchive.u64(bytes, at); at += 8
                            }
                            if needsCompressed, at + 8 <= extraEnd {
                                compressed = ZipArchive.u64(bytes, at); at += 8
                            }
                            if needsOffset, at + 8 <= extraEnd {
                                localOffset = ZipArchive.u64(bytes, at); at += 8
                            }
                            break
                        }
                        walk = fieldStart + fieldSize
                    }
                }
            }

            let entry = Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                crc32: crc,
                generalPurposeFlag: flag,
                localHeaderOffset: localOffset
            )
            // A later entry with the same name wins, which is what every other
            // reader does and what makes a repaired archive behave predictably.
            lookup[name] = parsed.count
            parsed.append(entry)

            cursor = nameStart + nameLength + extraLength + commentLength
        }

        self.entries = parsed
        self.index = lookup
    }

    public init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    // MARK: End of central directory

    private struct DirectoryLocation {
        let entryCount: Int
        let directoryOffset: Int
        let isZip64: Bool
    }

    /// Finds the EOCD record.
    ///
    /// Scanned for backwards, because the record is followed by a comment of
    /// arbitrary length — up to 65 535 bytes — so its position cannot be computed
    /// from the file size. Scanning forwards would find the first occurrence of
    /// the signature anywhere in the payload, which for a `.docx` containing an
    /// image is a coin toss.
    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) throws -> DirectoryLocation {
        let signature: UInt32 = 0x0605_4b50
        let minimum = 22
        guard bytes.count >= minimum else { throw ZipError.endOfCentralDirectoryNotFound }

        let lowest = max(0, bytes.count - minimum - 0xFFFF)
        var eocd = -1
        var cursor = bytes.count - minimum
        while cursor >= lowest {
            if u32(bytes, cursor) == signature {
                eocd = cursor
                break
            }
            cursor -= 1
        }
        guard eocd >= 0 else { throw ZipError.endOfCentralDirectoryNotFound }
        guard eocd + 22 <= bytes.count else { throw ZipError.endOfCentralDirectoryNotFound }

        var entryCount = Int(u16(bytes, eocd + 10))
        var directoryOffset = Int(u32(bytes, eocd + 16))
        var isZip64 = false

        // ZIP64. The locator sits immediately before the EOCD and points at the
        // real record; the EOCD's own fields are then set to their sentinels.
        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF {
            isZip64 = true
            if eocd >= 20, u32(bytes, eocd - 20) == 0x0706_4b50 {
                let zip64Offset = u64(bytes, eocd - 20 + 8)
                if zip64Offset + 56 <= bytes.count, u32(bytes, zip64Offset) == 0x0606_4b50 {
                    entryCount = u64(bytes, zip64Offset + 32)
                    directoryOffset = u64(bytes, zip64Offset + 48)
                }
            }
        }

        return DirectoryLocation(
            entryCount: entryCount,
            directoryOffset: directoryOffset,
            isZip64: isZip64
        )
    }

    // MARK: Access

    public var entryNames: [String] { entries.map(\.name) }

    public func entry(named name: String) -> Entry? {
        guard let position = index[name] else { return nil }
        return entries[position]
    }

    /// Reads and verifies an entry.
    ///
    /// Verification is on by default and is not optional theatre: a `.docx` that
    /// has been truncated by an interrupted download, or that has a single flipped
    /// bit in `document.xml`, will otherwise produce a document that opens with a
    /// paragraph silently missing. Failing loudly at the CRC is the difference
    /// between "this file is damaged" and "this file lost some of your text."
    public func contents(of entry: Entry, verify: Bool = true) throws -> [UInt8] {
        guard !entry.isEncrypted else { throw ZipError.encrypted(entry.name) }
        guard entry.isSupported else {
            throw ZipError.unsupportedCompression(entry.name, entry.compressionMethod)
        }

        let offset = entry.localHeaderOffset
        guard offset + 30 <= bytes.count else { throw ZipError.corruptLocalHeader(entry.name) }
        guard ZipArchive.u32(bytes, offset) == 0x0403_4b50 else {
            throw ZipError.corruptLocalHeader(entry.name)
        }

        // The local header's own name and extra-field lengths, not the central
        // directory's. They are allowed to differ — archivers routinely write a
        // longer extra field locally — and using the central directory's numbers
        // here shifts the payload and reads the wrong bytes.
        let localNameLength = Int(ZipArchive.u16(bytes, offset + 26))
        let localExtraLength = Int(ZipArchive.u16(bytes, offset + 28))
        let dataStart = offset + 30 + localNameLength + localExtraLength
        let dataEnd = dataStart + entry.compressedSize
        guard dataStart <= dataEnd, dataEnd <= bytes.count else {
            throw ZipError.corruptLocalHeader(entry.name)
        }

        let payload = Array(bytes[dataStart ..< dataEnd])
        let decompressed: [UInt8]
        switch entry.compressionMethod {
        case ZipArchive.methodStored:
            decompressed = payload
        case ZipArchive.methodDeflate:
            decompressed = try Inflate.decode(payload, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupportedCompression(entry.name, entry.compressionMethod)
        }

        if verify {
            guard decompressed.count == entry.uncompressedSize else {
                throw ZipError.sizeMismatch(
                    entry.name,
                    expected: entry.uncompressedSize,
                    actual: decompressed.count
                )
            }
            let actual = CRC32.compute(decompressed)
            guard actual == entry.crc32 else {
                throw ZipError.crcMismatch(entry.name, expected: entry.crc32, actual: actual)
            }
        }
        return decompressed
    }

    public func contents(named name: String, verify: Bool = true) throws -> [UInt8] {
        guard let entry = entry(named: name) else { throw ZipError.entryNotFound(name) }
        return try contents(of: entry, verify: verify)
    }

    public func string(named name: String) throws -> String {
        String(decoding: try contents(named: name), as: UTF8.self)
    }

    // MARK: Little-endian reads

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at])
            | (UInt32(bytes[at + 1]) << 8)
            | (UInt32(bytes[at + 2]) << 16)
            | (UInt32(bytes[at + 3]) << 24)
    }

    private static func u64(_ bytes: [UInt8], _ at: Int) -> Int {
        guard at >= 0, at + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for offset in stride(from: 7, through: 0, by: -1) {
            value = (value << 8) | UInt64(bytes[at + offset])
        }
        return Int(value & 0x7FFF_FFFF_FFFF_FFFF)
    }
}
