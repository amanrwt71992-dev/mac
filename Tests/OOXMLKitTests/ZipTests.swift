import XCTest
import OOXMLKit

/// ZIP and DEFLATE conformance, checked against archives produced by Python.
///
/// The value of these tests is that nothing in them was produced by the code
/// under test. The bytes come from `zipfile` and `zlib`, and the entry sizes and
/// CRC-32 values recorded in `Fixtures` come from that same independent
/// implementation. Agreement therefore means the decoder agrees with a second
/// opinion, not with itself.
final class ZipTests: XCTestCase {

    // MARK: CRC-32

    /// The published check values. If these pass, the reflected polynomial, the
    /// pre-inversion and the post-inversion are all right — three things that are
    /// each individually easy to get wrong and that produce plausible-looking
    /// but incorrect digests.
    func testCRC32AgainstPublishedCheckValues() {
        XCTAssertEqual(CRC32.compute([UInt8]()), 0x0000_0000)
        XCTAssertEqual(
            CRC32.compute([UInt8]("123456789".utf8)),
            0xCBF4_3926,
            "0xCBF43926 is the standard CRC-32 check value"
        )
        XCTAssertEqual(
            CRC32.compute([UInt8]("The quick brown fox jumps over the lazy dog".utf8)),
            0x414F_A339
        )
    }

    // MARK: DEFLATE, unit level

    func testInflateDecodesEmptyStream() throws {
        // zlib's raw DEFLATE of empty input: one final fixed block with nothing
        // in it.
        XCTAssertEqual(try Inflate.decode([0x03, 0x00]), [])
    }

    func testInflateDecodesStoredBlock() throws {
        // BFINAL=1, BTYPE=00, LEN=3, NLEN=~3, then "ABC".
        XCTAssertEqual(
            try Inflate.decode([0x01, 0x03, 0x00, 0xFC, 0xFF, 0x41, 0x42, 0x43]),
            [0x41, 0x42, 0x43]
        )
    }

    func testInflateRejectsReservedBlockType() {
        // 0x07 read least-significant-bit-first is BFINAL=1, BTYPE=11, which the
        // specification reserves.
        XCTAssertThrowsError(try Inflate.decode([0x07])) { error in
            guard let inflateError = error as? Inflate.Error else {
                return XCTFail("expected an Inflate.Error, got \(error)")
            }
            XCTAssertEqual(inflateError, .invalidBlockType)
        }
    }

    func testInflateRejectsStoredLengthThatDisagreesWithItsComplement() {
        // LEN=5 but NLEN=0, and 5 != ~0.
        XCTAssertThrowsError(try Inflate.decode([0x01, 0x05, 0x00, 0x00, 0x00])) { error in
            XCTAssertEqual(error as? Inflate.Error, .storedLengthMismatch)
        }
    }

    func testInflateRejectsTruncatedStoredBlock() {
        // A well-formed stored header promising five bytes, with none present.
        XCTAssertThrowsError(try Inflate.decode([0x01, 0x05, 0x00, 0xFA, 0xFF])) { error in
            XCTAssertEqual(error as? Inflate.Error, .truncatedInput)
        }
    }

    // MARK: Archive structure

    func testSyntheticArchiveListsEveryEntryInOrder() throws {
        let archive = try ZipArchive(bytes: Fixtures.synthetic)
        XCTAssertEqual(
            archive.entryNames,
            Fixtures.syntheticEntries.map(\.name),
            "entry order matters: a byte-preserving save has to reproduce it"
        )
    }

    func testSyntheticArchiveReportsPythonMetadata() throws {
        let archive = try ZipArchive(bytes: Fixtures.synthetic)
        XCTAssertEqual(archive.entries.count, Fixtures.syntheticEntries.count)
        for (actual, expected) in zip(archive.entries, Fixtures.syntheticEntries) {
            XCTAssertEqual(actual.name, expected.name)
            XCTAssertEqual(Int(actual.compressionMethod), expected.method, "\(actual.name) method")
            XCTAssertEqual(actual.uncompressedSize, expected.uncompressedSize, "\(actual.name) size")
            XCTAssertEqual(actual.crc32, expected.crc32, "\(actual.name) CRC")
        }
    }

    // MARK: Decoded content

    func testStoredEntryIsReturnedVerbatim() throws {
        let archive = try ZipArchive(bytes: Fixtures.synthetic)
        let bytes = try archive.contents(named: "stored.txt")
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "Hello, stored entry - uncompressed.\n")
    }

    func testOneByteDeflatedEntry() throws {
        let archive = try ZipArchive(bytes: Fixtures.synthetic)
        XCTAssertEqual(try archive.contents(named: "tiny.txt"), [UInt8]("A".utf8))
    }

    func testHighlyRepetitiveEntryExpandsBackReferences() throws {
        let archive = try ZipArchive(bytes: Fixtures.synthetic)
        let bytes = try archive.contents(named: "repeat.txt")
        XCTAssertEqual(bytes.count, 18_000)
        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 400)
        )
    }

    /// Incompressible data makes zlib fall back to a *stored DEFLATE block*
    /// inside a deflate stream. That is block type 00, reached through a
    /// different path from ZIP's own method 0, and it is what a `.docx` full of
    /// PNG and JPEG images spends most of its bytes on.
    func testIncompressibleEntryUsesStoredDeflateBlocks() throws {
        let archive = try ZipArchive(bytes: Fixtures.synthetic)
        let entry = try XCTUnwrap(archive.entry(named: "random.bin"))
        XCTAssertEqual(entry.compressionMethod, ZipArchive.methodDeflate)
        XCTAssertGreaterThan(
            entry.compressedSize,
            entry.uncompressedSize,
            "the fixture is meant to be incompressible"
        )
        XCTAssertEqual(try archive.contents(of: entry).count, 4_000)
    }

    func testEveryLiteralCodeDecodes() throws {
        let archive = try ZipArchive(bytes: Fixtures.synthetic)
        let bytes = try archive.contents(named: "allbytes.bin")
        XCTAssertEqual(bytes.count, 3_072)
        for (position, byte) in bytes.enumerated() {
            XCTAssertEqual(byte, UInt8(position % 256), "byte at \(position)")
        }
    }

    /// 20 000 identical bytes compress to 37, which is only possible if
    /// back-references are allowed to overlap themselves: a copy whose distance
    /// is shorter than its length reads bytes it has just written. Copying with a
    /// bulk move instead of one byte at a time produces the wrong output here and
    /// is the single most common way to get LZ77 wrong.
    func testSelfOverlappingBackReference() throws {
        let archive = try ZipArchive(bytes: Fixtures.synthetic)
        let entry = try XCTUnwrap(archive.entry(named: "run.bin"))
        let bytes = try archive.contents(of: entry)
        XCTAssertEqual(bytes.count, 20_000)
        XCTAssertEqual(Set(bytes), Set([0xAA]), "every byte must be 0xAA")
    }

    // MARK: A real .docx

    func testMinimalDocxListsItsThreeParts() throws {
        let archive = try ZipArchive(bytes: Fixtures.minimalDocx)
        XCTAssertEqual(archive.entryNames, [
            "[Content_Types].xml",
            "_rels/.rels",
            "word/document.xml",
        ])
        for entry in archive.entries {
            XCTAssertEqual(entry.compressionMethod, ZipArchive.methodDeflate)
            XCTAssertFalse(entry.isEncrypted)
        }
    }

    func testMinimalDocxDocumentPartMatchesExactly() throws {
        let archive = try ZipArchive(bytes: Fixtures.minimalDocx)
        let xml = try archive.string(named: "word/document.xml")
        XCTAssertEqual(xml, Fixtures.minimalDocxDocumentXML)
    }

    func testMinimalDocxContentTypesCarriesTheECMANamespace() throws {
        let archive = try ZipArchive(bytes: Fixtures.minimalDocx)
        let xml = try archive.string(named: "[Content_Types].xml")
        XCTAssertTrue(
            xml.contains("http://schemas.openxmlformats.org/package/2006/content-types"),
            "the content-types namespace is fixed by ECMA-376 and cannot be reworded"
        )
        XCTAssertTrue(
            xml.contains("application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")
        )
    }

    // MARK: Refusing bad archives

    /// Flipping one byte of a stored payload must be caught by the CRC rather
    /// than handed back as a document that quietly says something else.
    func testCorruptedPayloadIsRejectedByItsCRC() throws {
        var corrupted = Fixtures.synthetic

        // Read the local header's own name and extra lengths from the archive
        // rather than assuming them: `stored.txt` is the first entry, so its
        // local header is at offset 0 and its payload follows at 30 plus those
        // two lengths. Computed here from the spec so the test does not borrow
        // the implementation's arithmetic.
        let nameLength = Int(corrupted[26]) | (Int(corrupted[27]) << 8)
        let extraLength = Int(corrupted[28]) | (Int(corrupted[29]) << 8)
        let payload = 30 + nameLength + extraLength
        corrupted[payload + 4] ^= 0xFF

        let archive = try ZipArchive(bytes: corrupted)
        let entry = try XCTUnwrap(archive.entry(named: "stored.txt"))
        XCTAssertThrowsError(try archive.contents(of: entry)) { error in
            guard let zipError = error as? ZipArchive.ZipError,
                  case .crcMismatch(let name, _, _) = zipError else {
                return XCTFail("expected a CRC mismatch, got \(error)")
            }
            XCTAssertEqual(name, "stored.txt")
        }
    }

    func testVerificationCanBeDisabledForSalvage() throws {
        var corrupted = Fixtures.synthetic
        let nameLength = Int(corrupted[26]) | (Int(corrupted[27]) << 8)
        let extraLength = Int(corrupted[28]) | (Int(corrupted[29]) << 8)
        corrupted[30 + nameLength + extraLength + 4] ^= 0xFF

        let archive = try ZipArchive(bytes: corrupted)
        let entry = try XCTUnwrap(archive.entry(named: "stored.txt"))
        // Reading without verification still has to return the bytes: recovering
        // a damaged document is a feature, and it cannot be built on a reader
        // that refuses to hand over anything imperfect.
        XCTAssertEqual(try archive.contents(of: entry, verify: false).count, 36)
    }

    func testArchiveWithoutAnEndOfCentralDirectoryIsRejected() {
        // Dropping the tail removes the EOCD record. Nothing else in the file
        // looks like one, so the scan must come up empty rather than finding the
        // signature somewhere inside a payload.
        let truncated = Array(Fixtures.minimalDocx.prefix(Fixtures.minimalDocx.count - 40))
        XCTAssertThrowsError(try ZipArchive(bytes: truncated)) { error in
            XCTAssertEqual(error as? ZipArchive.ZipError, .endOfCentralDirectoryNotFound)
        }
    }

    func testEmptyInputIsRejected() {
        XCTAssertThrowsError(try ZipArchive(bytes: [])) { error in
            XCTAssertEqual(error as? ZipArchive.ZipError, .endOfCentralDirectoryNotFound)
        }
    }

    /// A `.docx` without `word/styles.xml` is perfectly legal — every property
    /// then comes from the defaults — so a missing part has to be reported as
    /// "not there" rather than as a corrupt archive.
    func testMissingEntryIsReportedByName() throws {
        let archive = try ZipArchive(bytes: Fixtures.minimalDocx)
        XCTAssertNil(archive.entry(named: "word/styles.xml"))
        XCTAssertThrowsError(try archive.contents(named: "word/styles.xml")) { error in
            XCTAssertEqual(error as? ZipArchive.ZipError, .entryNotFound("word/styles.xml"))
        }
    }
}
