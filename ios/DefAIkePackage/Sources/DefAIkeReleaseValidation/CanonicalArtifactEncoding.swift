import Foundation

// Producing the exact bytes a release signs, reproducibly.
//
// This is a *writer*, and it is the only one in the project. `DefAIkeModelBundle` reads a
// manifest and deliberately never re-encodes one: the signature covers the bytes that were
// read, so re-serializing them would answer a different question. Nothing here duplicates
// a verification rule — `CanonicalJSONScan` refuses a document, this file emits one — and
// nothing here decides whether the emitted bytes are acceptable. The runtime verifier is
// the only arbiter of that, and it runs over these bytes unchanged.
//
// Why a rewriting pass exists at all, rather than `JSONEncoder` alone: JSON has no
// unordered array, and a Model Bundle manifest carries two `Set`-valued fields
// (`compatibility.compatibleAppBuilds` and `compatibility.requiredCapabilities`). `Set`
// iteration order depends on Swift's per-process hash seed, so `JSONEncoder` alone produces
// bytes that agree within one process and can disagree between two. For a signed,
// reproducible artifact that is not a cosmetic difference: the manifest digest, the
// signature, and the reproducible-build claim all change with it.
//
// So the encoded bytes are rewritten once, deterministically:
//
//   * object members are ordered by the raw bytes of their encoded key;
//   * an array whose every element is a string is ordered by the raw bytes of its elements;
//   * every other array keeps its order exactly; and
//   * numbers, `true`, `false`, `null`, and string contents are copied verbatim, never
//     reparsed, so no numeric value is reformatted on the way through.
//
// Sorting string-only arrays is semantics-preserving for this schema and is not a guess.
// Every order-significant array a Model Bundle artifact declares holds objects — declared
// artifacts, self-test cases, fixture records, notice entries — while the only arrays of
// bare strings are the two set-valued fields above, which decode back into sets. A future
// schema that adds an order-significant `[String]` would have to revisit this, and
// ``CanonicalArtifactEncodingTests`` pins the behavior so that revisit is a failing test
// rather than a silent reordering.

/// Why canonical bytes could not be produced for one artifact.
public enum CanonicalEncodingFault: Error, Equatable, Sendable {
    /// The value could not be encoded to JSON at all.
    case notEncodable

    /// The encoded bytes are not well-formed JSON at this byte offset. Unreachable for
    /// `JSONEncoder` output; a refusal rather than a trap so a malformed intermediate
    /// cannot become a signed artifact.
    case notWellFormed(byteOffset: Int)

    /// The encoded value nests deeper than the rewriter walks.
    case tooDeep(maximumDepth: Int)
}

/// Encodes release artifacts to reproducible canonical bytes.
enum CanonicalArtifactEncoding {
    /// Nesting ceiling. A structural bound that keeps the rewriter's recursion depth fixed
    /// regardless of input; not an approved value, and deliberately the same bound the
    /// runtime's manifest scan walks so a document this writer emits cannot be one the
    /// runtime refuses for depth.
    static let maximumDepth = 32

    /// The canonical bytes for one encodable release artifact.
    static func canonicalBytes(
        of value: some Encodable
    ) throws(CanonicalEncodingFault) -> [UInt8] {
        let encoder = JSONEncoder()
        // `sortedKeys` is not relied on for determinism — the rewriter orders keys itself —
        // but keeping it makes the intermediate legible when a test dumps it.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded: Data
        do {
            encoded = try encoder.encode(value)
        } catch {
            throw CanonicalEncodingFault.notEncodable
        }
        return try canonicalized(Array(encoded))
    }

    /// Rewrites well-formed JSON bytes into their canonical form.
    static func canonicalized(_ bytes: [UInt8]) throws(CanonicalEncodingFault) -> [UInt8] {
        var parser = Parser(bytes: bytes)
        let document = try parser.parseDocument()
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        Emitter(source: bytes).emit(document, into: &output)
        return output
    }
}

// MARK: - Parsed shape

/// One JSON value, with every scalar kept as a range into the source bytes.
///
/// Ranges rather than decoded values: a number that is copied verbatim cannot be
/// reformatted, and a string that is copied verbatim cannot be re-escaped.
private enum CanonicalNode {
    /// A string, number, `true`, `false`, or `null`, as raw source bytes.
    case scalar(Range<Int>)
    /// An object's members, each a raw key range and a value.
    case object([(key: Range<Int>, value: CanonicalNode)])
    case array([CanonicalNode])

    /// Whether this node is a string scalar, which is what makes an array sortable.
    func isStringScalar(in source: [UInt8]) -> Bool {
        guard case let .scalar(range) = self else { return false }
        return source[range.lowerBound] == UInt8(ascii: "\"")
    }
}

// MARK: - Parsing

/// A single-pass recursive-descent parser over UTF-8 JSON bytes.
private struct Parser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0

    mutating func parseDocument() throws(CanonicalEncodingFault) -> CanonicalNode {
        skipWhitespace()
        let node = try parseValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw CanonicalEncodingFault.notWellFormed(byteOffset: index)
        }
        return node
    }

    mutating func parseValue() throws(CanonicalEncodingFault) -> CanonicalNode {
        guard let byte = peek() else {
            throw CanonicalEncodingFault.notWellFormed(byteOffset: index)
        }
        switch byte {
        case UInt8(ascii: "{"):
            return try parseObject()
        case UInt8(ascii: "["):
            return try parseArray()
        case UInt8(ascii: "\""):
            return .scalar(try scanString())
        case UInt8(ascii: "t"):
            return .scalar(try scanLiteral("true"))
        case UInt8(ascii: "f"):
            return .scalar(try scanLiteral("false"))
        case UInt8(ascii: "n"):
            return .scalar(try scanLiteral("null"))
        default:
            return .scalar(try scanNumber())
        }
    }

    mutating func parseObject() throws(CanonicalEncodingFault) -> CanonicalNode {
        try enter()
        index += 1
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            depth -= 1
            return .object([])
        }
        var members: [(key: Range<Int>, value: CanonicalNode)] = []
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else {
                throw CanonicalEncodingFault.notWellFormed(byteOffset: index)
            }
            let key = try scanString()
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else {
                throw CanonicalEncodingFault.notWellFormed(byteOffset: index)
            }
            index += 1
            skipWhitespace()
            members.append((key: key, value: try parseValue()))
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "}"):
                index += 1
                depth -= 1
                return .object(members)
            default:
                throw CanonicalEncodingFault.notWellFormed(byteOffset: index)
            }
        }
    }

    mutating func parseArray() throws(CanonicalEncodingFault) -> CanonicalNode {
        try enter()
        index += 1
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            depth -= 1
            return .array([])
        }
        var elements: [CanonicalNode] = []
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                depth -= 1
                return .array(elements)
            default:
                throw CanonicalEncodingFault.notWellFormed(byteOffset: index)
            }
        }
    }

    /// Scans a string and returns the range of its bytes, quotes included.
    ///
    /// Escapes are stepped over rather than decoded: the bytes are copied verbatim, so the
    /// escaping `JSONEncoder` chose is preserved exactly and nothing here can change what a
    /// decoder reads back.
    mutating func scanString() throws(CanonicalEncodingFault) -> Range<Int> {
        let start = index
        index += 1
        while true {
            guard index < bytes.count else {
                throw CanonicalEncodingFault.notWellFormed(byteOffset: index)
            }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return start..<index
            }
            if byte == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if byte <= 0x1F {
                throw CanonicalEncodingFault.notWellFormed(byteOffset: index)
            }
            index += 1
        }
    }

    mutating func scanNumber() throws(CanonicalEncodingFault) -> Range<Int> {
        let start = index
        if peek() == UInt8(ascii: "-") { index += 1 }
        try scanDigits(startingAt: start)
        if peek() == UInt8(ascii: ".") {
            index += 1
            try scanDigits(startingAt: start)
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            index += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { index += 1 }
            try scanDigits(startingAt: start)
        }
        return start..<index
    }

    private mutating func scanDigits(startingAt start: Int) throws(CanonicalEncodingFault) {
        var consumed = 0
        while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            index += 1
            consumed += 1
        }
        guard consumed > 0 else {
            throw CanonicalEncodingFault.notWellFormed(byteOffset: start)
        }
    }

    mutating func scanLiteral(_ literal: String) throws(CanonicalEncodingFault) -> Range<Int> {
        let expected = Array(literal.utf8)
        let start = index
        let end = index + expected.count
        guard end <= bytes.count, Array(bytes[start..<end]) == expected else {
            throw CanonicalEncodingFault.notWellFormed(byteOffset: index)
        }
        index = end
        return start..<end
    }

    private mutating func enter() throws(CanonicalEncodingFault) {
        depth += 1
        guard depth <= CanonicalArtifactEncoding.maximumDepth else {
            throw CanonicalEncodingFault.tooDeep(
                maximumDepth: CanonicalArtifactEncoding.maximumDepth
            )
        }
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }
}

// MARK: - Emitting

/// Writes a parsed document back out in canonical form.
private struct Emitter {
    let source: [UInt8]

    func emit(_ node: CanonicalNode, into output: inout [UInt8]) {
        switch node {
        case let .scalar(range):
            output.append(contentsOf: source[range])
        case let .object(members):
            output.append(UInt8(ascii: "{"))
            let ordered = members.sorted {
                source[$0.key].lexicographicallyPrecedes(source[$1.key])
            }
            for (offset, member) in ordered.enumerated() {
                if offset > 0 { output.append(UInt8(ascii: ",")) }
                output.append(contentsOf: source[member.key])
                output.append(UInt8(ascii: ":"))
                emit(member.value, into: &output)
            }
            output.append(UInt8(ascii: "}"))
        case let .array(elements):
            output.append(UInt8(ascii: "["))
            for (offset, element) in ordered(elements).enumerated() {
                if offset > 0 { output.append(UInt8(ascii: ",")) }
                emit(element, into: &output)
            }
            output.append(UInt8(ascii: "]"))
        }
    }

    /// Orders an array's elements when, and only when, every one of them is a string.
    private func ordered(_ elements: [CanonicalNode]) -> [CanonicalNode] {
        guard elements.allSatisfy({ $0.isStringScalar(in: source) }) else { return elements }
        return elements.sorted { lhs, rhs in
            guard case let .scalar(left) = lhs, case let .scalar(right) = rhs else {
                return false
            }
            return source[left].lexicographicallyPrecedes(source[right])
        }
    }
}
