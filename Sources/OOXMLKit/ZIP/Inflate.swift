import Foundation

// MARK: - Inflate

/// A raw DEFLATE decoder (RFC 1951).
///
/// Written here rather than pulled from a dependency, and written for the
/// platform-free targets rather than Apple's `Compression` framework, for three
/// reasons that all come back to the same thing — this project has no way to
/// look at its own output:
///
/// 1. `Compression` is Apple-only. Guarding the ZIP layer behind
///    `canImport(Compression)` would mean it never gets type-checked or tested on
///    the Linux CI job, which is the only job that reports back in two minutes
///    instead of five. Every unguarded line here is a line the fast job covers.
/// 2. A word processor has to round-trip other people's archives, including
///    damaged and merely unusual ones. When one fails we need to know *where* it
///    failed — which block, which code, which distance — and a system call
///    answers "the data was bad."
/// 3. Byte-preserving save is a stated, CI-enforced requirement. Controlling the
///    codec is a prerequisite for controlling the bytes.
///
/// The structure follows Mark Adler's `puff` closely, including its tolerance
/// rules: over-subscribed code lengths are an error, an incomplete code is an
/// error *unless* exactly one symbol is missing, and a distance code set with a
/// single symbol is accepted. Those tolerances are not leniency for its own sake
/// — real-world archives produced by real-world encoders rely on them, and a
/// decoder that rejects them rejects files the user can open in Word.
public enum Inflate {

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case truncatedInput
        case invalidBlockType
        case storedLengthMismatch
        case overSubscribedCode
        case incompleteCode
        case invalidLengthCode(Int)
        case invalidDistance(Int)
        case missingEndOfBlockCode
        case outputLimitExceeded

        public var description: String {
            switch self {
            case .truncatedInput:
                return "the DEFLATE stream ended in the middle of a value"
            case .invalidBlockType:
                return "block type 3 is reserved and must never appear"
            case .storedLengthMismatch:
                return "a stored block's length and its one's complement do not agree"
            case .overSubscribedCode:
                return "a Huffman code has more symbols than its lengths allow"
            case .incompleteCode:
                return "a Huffman code is incomplete and not the single-symbol case"
            case .invalidLengthCode(let symbol):
                return "length code \(symbol) is outside the 0..<29 range RFC 1951 defines"
            case .invalidDistance(let distance):
                return "a back-reference reached \(distance) bytes before the output start"
            case .missingEndOfBlockCode:
                return "the literal/length code has no end-of-block symbol, or repeats past its alphabet"
            case .outputLimitExceeded:
                return "decompression passed the caller's size limit"
            }
        }
    }

    /// Maximum Huffman code length in DEFLATE.
    private static let maxBits = 15

    /// Length codes 257...285: base length and extra-bit count.
    private static let lengthBase = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtra = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]

    /// Distance codes 0...29: base distance and extra-bit count.
    private static let distanceBase = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577,
    ]
    private static let distanceExtra = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]

    /// The order in which code-length code lengths appear in the stream. Not
    /// ascending: the most common lengths come first so the alphabet itself
    /// compresses.
    private static let codeLengthOrder = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    /// Decompresses a raw DEFLATE stream.
    ///
    /// `expectedSize` is a hint used to preallocate, not a promise: the output
    /// grows past it if the stream says so. `limit` is a hard ceiling that
    /// protects against a corrupt or hostile archive declaring a plausible size
    /// and then expanding without end.
    public static func decode(
        _ input: [UInt8],
        expectedSize: Int = 0,
        limit: Int = 1 << 30
    ) throws -> [UInt8] {
        var state = State(input: input, expectedSize: expectedSize, limit: limit)
        try state.run()
        return state.output
    }

    public static func decode(_ data: Data, expectedSize: Int = 0, limit: Int = 1 << 30) throws -> Data {
        Data(try decode([UInt8](data), expectedSize: expectedSize, limit: limit))
    }

    // MARK: Canonical Huffman code

    /// A canonical Huffman code, stored the way `puff` stores it: how many
    /// symbols have each length, and the symbols in canonical order. The codes
    /// themselves are never materialised — they are implied by the lengths, which
    /// is what makes a canonical code worth using at all.
    private struct Code {
        /// `count[length]` = number of symbols with that code length. Index 0 is
        /// the number of symbols that are not in the code.
        var count: [Int]
        /// Symbols sorted by code length, then by symbol value.
        var symbol: [Int]

        init() {
            count = [Int](repeating: 0, count: Inflate.maxBits + 1)
            symbol = []
        }

        /// Builds the code from a length per symbol.
        ///
        /// Returns the number of unused codes, matching `puff`'s convention:
        /// negative would mean over-subscribed, positive means incomplete, zero
        /// means exactly complete.
        ///
        /// Only over-subscription is thrown here. **Incompleteness is reported,
        /// never rejected**, because whether it is acceptable depends entirely on
        /// which table is being built and only the caller knows that:
        ///
        /// - the fixed distance table assigns 5 bits to 30 of the 32 possible
        ///   codes and is *always* incomplete — rejecting it means no fixed block
        ///   can ever decode, which is most small files;
        /// - the fixed literal/length table is complete;
        /// - a dynamic code-length table must be complete;
        /// - a dynamic literal/length or distance table may be incomplete only in
        ///   the degenerate single-symbol case, which zlib emits constantly for
        ///   data with no long back-references.
        ///
        /// A builder that decided this itself would have to pick one rule and be
        /// wrong for the other three.
        mutating func build(lengths: [Int]) throws -> Int {
            count = [Int](repeating: 0, count: Inflate.maxBits + 1)
            for length in lengths { count[length] += 1 }

            // A code with no symbols at all is legal and simply never matches.
            if count[0] == lengths.count {
                symbol = []
                return 0
            }

            var left = 1
            for length in 1 ... Inflate.maxBits {
                left <<= 1
                left -= count[length]
                if left < 0 { throw Error.overSubscribedCode }
            }
            var offsets = [Int](repeating: 0, count: Inflate.maxBits + 2)
            offsets[1] = 0
            for length in 1 ..< Inflate.maxBits {
                offsets[length + 1] = offsets[length] + count[length]
            }
            symbol = [Int](repeating: 0, count: lengths.count)
            var filled = 0
            for (symbolValue, length) in lengths.enumerated() where length != 0 {
                symbol[offsets[length]] = symbolValue
                offsets[length] += 1
                filled += 1
            }
            symbol.removeSubrange(filled ..< symbol.count)
            return left
        }
    }

    // MARK: Decoder state

    private struct State {
        let input: [UInt8]
        var position = 0
        var bitBuffer = 0
        var bitCount = 0
        var output: [UInt8]
        let limit: Int

        init(input: [UInt8], expectedSize: Int, limit: Int) {
            self.input = input
            self.limit = limit
            output = []
            output.reserveCapacity(min(max(expectedSize, 0), limit))
        }

        // MARK: Bit input

        /// Reads `need` bits, least-significant bit first.
        mutating func bits(_ need: Int) throws -> Int {
            var value = bitBuffer
            while bitCount < need {
                guard position < input.count else { throw Error.truncatedInput }
                value |= Int(input[position]) << bitCount
                position += 1
                bitCount += 8
            }
            bitBuffer = value >> need
            bitCount -= need
            return value & ((1 << need) - 1)
        }

        /// Discards any partial byte. A stored block begins on a byte boundary.
        mutating func alignToByte() {
            bitBuffer = 0
            bitCount = 0
        }

        mutating func emit(_ byte: UInt8) throws {
            guard output.count < limit else { throw Error.outputLimitExceeded }
            output.append(byte)
        }

        // MARK: Huffman decoding

        /// Walks the canonical code one bit at a time.
        ///
        /// Materialising the codes would need a table per length; walking them
        /// needs only the length histogram and the canonical symbol order, which
        /// is what `Code` stores. Fifteen iterations of one-bit reads is the whole
        /// cost, and it is the same approach `puff` takes.
        mutating func decodeSymbol(from code: Code) throws -> Int {
            var codeValue = 0
            var first = 0
            var index = 0
            for length in 1 ... Inflate.maxBits {
                codeValue |= try bits(1)
                let count = code.count[length]
                if codeValue - count < first {
                    return code.symbol[index + (codeValue - first)]
                }
                index += count
                first += count
                first <<= 1
                codeValue <<= 1
            }
            throw Error.incompleteCode
        }

        // MARK: Blocks

        mutating func run() throws {
            var isLast = false
            while !isLast {
                isLast = try bits(1) != 0
                switch try bits(2) {
                case 0: try storedBlock()
                case 1: try fixedBlock()
                case 2: try dynamicBlock()
                default: throw Error.invalidBlockType
                }
            }
        }

        mutating func storedBlock() throws {
            alignToByte()
            let length = try bits(16)
            let complement = try bits(16)
            guard length == (complement ^ 0xFFFF) else { throw Error.storedLengthMismatch }
            guard position + length <= input.count else { throw Error.truncatedInput }
            for _ in 0 ..< length {
                try emit(input[position])
                position += 1
            }
        }

        mutating func fixedBlock() throws {
            var lengths = [Int](repeating: 0, count: 288)
            for symbol in 0 ..< 144 { lengths[symbol] = 8 }
            for symbol in 144 ..< 256 { lengths[symbol] = 9 }
            for symbol in 256 ..< 280 { lengths[symbol] = 7 }
            for symbol in 280 ..< 288 { lengths[symbol] = 8 }
            // Both return values are deliberately discarded. The fixed
            // literal/length table is complete; the fixed distance table is not —
            // 30 codes of 5 bits leaves two unused — and that is specified
            // behaviour, not corruption.
            var literalLength = Code()
            _ = try literalLength.build(lengths: lengths)

            let distanceLengths = [Int](repeating: 5, count: 30)
            var distance = Code()
            _ = try distance.build(lengths: distanceLengths)

            try inflateCodes(literalLength: literalLength, distance: distance)
        }

        mutating func dynamicBlock() throws {
            let literalCount = try bits(5) + 257
            let distanceCount = try bits(5) + 1
            let codeLengthCount = try bits(4) + 4
            guard literalCount <= 286, distanceCount <= 30 else { throw Error.invalidLengthCode(literalCount) }

            var codeLengths = [Int](repeating: 0, count: 19)
            for index in 0 ..< codeLengthCount {
                codeLengths[Inflate.codeLengthOrder[index]] = try bits(3)
            }
            var codeLengthCode = Code()
            // The code-length alphabet is the one dynamic table that must be
            // exactly complete: it describes the other two, so a gap in it is not
            // a degenerate case, it is a corrupt stream.
            if try codeLengthCode.build(lengths: codeLengths) != 0 {
                throw Error.incompleteCode
            }

            let total = literalCount + distanceCount
            var lengths = [Int](repeating: 0, count: total)
            var index = 0
            while index < total {
                let symbol = try decodeSymbol(from: codeLengthCode)
                if symbol < 16 {
                    lengths[index] = symbol
                    index += 1
                    continue
                }

                var repeatLength = 0
                var repeated: Int
                switch symbol {
                case 16:
                    // Repeat the previous length 3 to 6 times. Needs a previous
                    // length to repeat, so position 0 is malformed.
                    guard index > 0 else { throw Error.missingEndOfBlockCode }
                    repeated = lengths[index - 1]
                    repeatLength = try bits(2) + 3
                case 17:
                    repeated = 0
                    repeatLength = try bits(3) + 3
                default:
                    repeated = 0
                    repeatLength = try bits(7) + 11
                }
                guard index + repeatLength <= total else { throw Error.missingEndOfBlockCode }
                for _ in 0 ..< repeatLength {
                    lengths[index] = repeated
                    index += 1
                }
            }

            guard lengths[256] != 0 else { throw Error.missingEndOfBlockCode }

            var literalLength = Code()
            let literalLeftover = try literalLength.build(lengths: Array(lengths[0 ..< literalCount]))
            // An incomplete literal/length code is tolerated only when exactly
            // one symbol is missing; anything else means the stream is corrupt.
            if literalLeftover > 0 && literalCount - literalLength.count[0] != 1 {
                throw Error.incompleteCode
            }

            var distanceCode = Code()
            let distanceLeftover = try distanceCode.build(lengths: Array(lengths[literalCount ..< total]))
            if distanceLeftover > 0 && distanceCount - distanceCode.count[0] != 1 {
                throw Error.incompleteCode
            }

            try inflateCodes(literalLength: literalLength, distance: distanceCode)
        }

        mutating func inflateCodes(literalLength: Code, distance: Code) throws {
            while true {
                let symbol = try decodeSymbol(from: literalLength)
                guard symbol < 256 else {
                    if symbol == 256 { return }

                    let lengthIndex = symbol - 257
                    guard lengthIndex < Inflate.lengthBase.count else {
                        throw Error.invalidLengthCode(symbol)
                    }
                    // `try` has to cover the whole expression or be split out;
                    // Swift rejects it to the right of a binary operator.
                    let lengthExtraBits = try bits(Inflate.lengthExtra[lengthIndex])
                    let length = Inflate.lengthBase[lengthIndex] + lengthExtraBits

                    let distanceSymbol = try decodeSymbol(from: distance)
                    guard distanceSymbol < Inflate.distanceBase.count else {
                        throw Error.invalidDistance(distanceSymbol)
                    }
                    let distanceExtraBits = try bits(Inflate.distanceExtra[distanceSymbol])
                    let back = Inflate.distanceBase[distanceSymbol] + distanceExtraBits
                    guard back <= output.count else { throw Error.invalidDistance(back) }

                    // Copied one byte at a time on purpose. DEFLATE allows
                    // `back` to be smaller than `length`, which means the copy
                    // overlaps itself and expands a run — `run.bin` in the test
                    // fixture is 20 000 bytes of one value compressed to 37, and
                    // only self-overlapping copies can produce that.
                    for _ in 0 ..< length {
                        try emit(output[output.count - back])
                    }
                    continue
                }
                try emit(UInt8(symbol))
            }
        }
    }
}

// MARK: - CRC-32

/// CRC-32 as ZIP defines it: the IEEE 802.3 polynomial, reflected, with a
/// pre- and post-inversion. Every ZIP entry carries one and readers are expected
/// to check it, so a decoder that skips the check silently accepts corruption.
public enum CRC32 {

    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0 ..< 256 {
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        return table
    }()

    public static func compute(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    public static func compute(_ data: Data) -> UInt32 { compute([UInt8](data)) }
}
