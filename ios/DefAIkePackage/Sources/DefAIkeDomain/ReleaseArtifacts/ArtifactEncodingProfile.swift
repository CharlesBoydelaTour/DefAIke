// The bounded encoding profile every encoded artifact is checked against before it
// is decoded.
//
// Task 1.3 gave every artifact a validating initializer, so an artifact *value*
// cannot hold a placeholder, an incomplete map, or an inconsistent reference. That
// leaves the layer below it: the bytes. A general-purpose decoder will happily
// accept a payload of any size, resolve a duplicate key by keeping one of the two
// silently, and recurse as deeply as the input asks. None of those is acceptable for
// a signed release artifact:
//
//   * an unbounded payload is an allocation the caller never approved;
//   * a duplicate key means two readers of the same signed bytes can disagree about
//     a budget, a deadline, or a trusted key, so the signature stops pinning
//     behavior; and
//   * unbounded nesting is a decode-time resource fault before any field is read.
//
// So the profile is validated in one pass over the bytes *before* decoding, and the
// pass reports the first violation with its byte offset or artifact position.
//
// What this file deliberately does not do: choose the canonicalization profile a
// release *signature* covers. That is an approved artifact reference
// (``BundleVerificationPolicy/canonicalizationProfile``), and inventing a
// canonical-form rule here would be exactly the kind of source-code default the
// requirements forbid. This profile is structural decode safety only.
//
// No Foundation import: the scan is over bytes.

/// The bounds one artifact payload is decoded under.
///
/// ``maximumByteCount`` has no default. It is a numeric release value and it is
/// supplied by an approved artifact, which is why there is no
/// `ArtifactEncodingLimits()` and no `.default` (Requirements 10.8, 11.1, and 14.1).
///
/// The remaining bounds are structural safety ceilings in the same sense as
/// ``CanonicalIdentifierSyntax/defaultMaximumCharacterCount`` and
/// ``ValidatedDuration/maximumMilliseconds``: they keep a decode bounded and express
/// no policy, budget, deadline, or gate decision. They are still overridable, so a
/// caller with an approved bound can supply it.
public struct ArtifactEncodingLimits: Hashable, Sendable {
    /// Structural ceiling on nesting depth. The top-level object is depth 1.
    public static let defaultMaximumNestingDepth = 24

    /// Structural ceiling on keys in one object.
    public static let defaultMaximumObjectEntryCount = 512

    /// Structural ceiling on elements in one array.
    public static let defaultMaximumArrayElementCount = 4096

    /// Structural ceiling on the Unicode scalars in one string.
    public static let defaultMaximumStringScalarCount = 4096

    /// Structural ceiling on the characters in one number token.
    public static let defaultMaximumNumberTokenLength = 40

    /// The approved payload ceiling in bytes.
    public let maximumByteCount: PositiveByteCount

    public let maximumNestingDepth: Int
    public let maximumObjectEntryCount: Int
    public let maximumArrayElementCount: Int
    public let maximumStringScalarCount: Int
    public let maximumNumberTokenLength: Int

    /// Creates limits from an approved byte ceiling plus structural safety bounds.
    ///
    /// The structural bounds are clamped to at least 1, because a ceiling of zero would
    /// make every payload unreadable rather than bounded. They are in-process arguments,
    /// not artifact fields, so a nonsensical one is a caller mistake; the approved byte
    /// ceiling is a validated ``PositiveByteCount`` and is never adjusted.
    public init(
        maximumByteCount: PositiveByteCount,
        maximumNestingDepth: Int = defaultMaximumNestingDepth,
        maximumObjectEntryCount: Int = defaultMaximumObjectEntryCount,
        maximumArrayElementCount: Int = defaultMaximumArrayElementCount,
        maximumStringScalarCount: Int = defaultMaximumStringScalarCount,
        maximumNumberTokenLength: Int = defaultMaximumNumberTokenLength
    ) {
        self.maximumByteCount = maximumByteCount
        self.maximumNestingDepth = max(1, maximumNestingDepth)
        self.maximumObjectEntryCount = max(1, maximumObjectEntryCount)
        self.maximumArrayElementCount = max(1, maximumArrayElementCount)
        self.maximumStringScalarCount = max(1, maximumStringScalarCount)
        self.maximumNumberTokenLength = max(1, maximumNumberTokenLength)
    }
}

/// What one validated payload was observed to contain.
///
/// The report describes the encoding, never the artifact's meaning: it is audit
/// material for "these are the bytes that were read", not a substitute for schema
/// validation.
public struct ArtifactEncodingReport: Hashable, Sendable {
    /// Exact payload size.
    public let byteCount: UInt64

    /// Deepest nesting observed. The top-level object counts as 1.
    public let observedNestingDepth: Int

    /// Top-level keys in document order, each appearing exactly once.
    public let topLevelKeys: [String]

    public init(byteCount: UInt64, observedNestingDepth: Int, topLevelKeys: [String]) {
        self.byteCount = byteCount
        self.observedNestingDepth = observedNestingDepth
        self.topLevelKeys = topLevelKeys
    }
}

/// The one-pass validator for the bounded artifact encoding profile.
public enum ArtifactEncodingProfile {
    /// Validates `bytes` against `limits` and reports what was observed.
    ///
    /// Returns on the first complete valid document; throws on the first violation.
    /// Nothing is repaired, normalized, or defaulted.
    public static func validate(
        _ bytes: [UInt8],
        limits: ArtifactEncodingLimits
    ) throws(ArtifactDecodingError) -> ArtifactEncodingReport {
        let actual = UInt64(bytes.count)
        guard actual <= limits.maximumByteCount.value else {
            throw .payloadTooLarge(limitBytes: limits.maximumByteCount.value, actualBytes: actual)
        }
        guard !bytes.isEmpty else { throw .emptyPayload }

        var scanner = PayloadScanner(bytes: bytes, limits: limits)
        return try scanner.scanDocument()
    }
}

// MARK: - Scanner

/// A bounded recursive-descent scanner over one artifact payload.
///
/// Recursion is safe because descent is refused past
/// ``ArtifactEncodingLimits/maximumNestingDepth`` before the frame is entered.
private struct PayloadScanner {
    let bytes: [UInt8]
    let limits: ArtifactEncodingLimits
    var index = 0
    var observedDepth = 0

    private enum Byte {
        static let tab: UInt8 = 0x09
        static let newline: UInt8 = 0x0A
        static let carriageReturn: UInt8 = 0x0D
        static let space: UInt8 = 0x20
        static let quote: UInt8 = 0x22
        static let plus: UInt8 = 0x2B
        static let comma: UInt8 = 0x2C
        static let minus: UInt8 = 0x2D
        static let period: UInt8 = 0x2E
        static let solidus: UInt8 = 0x2F
        static let zero: UInt8 = 0x30
        static let nine: UInt8 = 0x39
        static let colon: UInt8 = 0x3A
        static let openBracket: UInt8 = 0x5B
        static let backslash: UInt8 = 0x5C
        static let closeBracket: UInt8 = 0x5D
        static let openBrace: UInt8 = 0x7B
        static let closeBrace: UInt8 = 0x7D
    }

    // MARK: Document

    mutating func scanDocument() throws(ArtifactDecodingError) -> ArtifactEncodingReport {
        try rejectByteOrderMark()
        skipWhitespace()
        guard let first = peek() else {
            throw .malformedEncoding(byteOffset: index, reason: "no value")
        }
        guard first == Byte.openBrace else {
            throw .topLevelValueNotAnObject(byteOffset: index)
        }
        try requireDepth(1)
        let keys = try scanObject(path: "", depth: 1)
        skipWhitespace()
        guard index == bytes.count else {
            throw .trailingContentError(byteOffset: index)
        }
        return ArtifactEncodingReport(
            byteCount: UInt64(bytes.count),
            observedNestingDepth: observedDepth,
            topLevelKeys: keys
        )
    }

    private mutating func rejectByteOrderMark() throws(ArtifactDecodingError) {
        guard bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF else {
            return
        }
        throw .malformedEncoding(byteOffset: 0, reason: "leading byte order mark")
    }

    // MARK: Values

    /// Scans one value. `depth` is the depth of the value's own container frame.
    private mutating func scanValue(path: String, depth: Int) throws(ArtifactDecodingError) {
        guard let byte = peek() else {
            throw .malformedEncoding(byteOffset: index, reason: "value expected")
        }
        switch byte {
        case Byte.openBrace:
            try requireDepth(depth)
            _ = try scanObject(path: path, depth: depth)
        case Byte.openBracket:
            try requireDepth(depth)
            try scanArray(path: path, depth: depth)
        case Byte.quote:
            _ = try scanString(path: path)
        case UInt8(ascii: "t"):
            try expect(literal: "true")
        case UInt8(ascii: "f"):
            try expect(literal: "false")
        case UInt8(ascii: "n"):
            try expect(literal: "null")
        case Byte.minus, Byte.zero...Byte.nine:
            try scanNumber(path: path)
        default:
            throw .malformedEncoding(
                byteOffset: index,
                reason: "\(describe(byte)) cannot begin a value"
            )
        }
    }

    private mutating func requireDepth(_ depth: Int) throws(ArtifactDecodingError) {
        guard depth <= limits.maximumNestingDepth else {
            throw .nestingTooDeep(limit: limits.maximumNestingDepth, byteOffset: index)
        }
        observedDepth = max(observedDepth, depth)
    }

    /// Scans an object and returns its keys in document order.
    private mutating func scanObject(
        path: String,
        depth: Int
    ) throws(ArtifactDecodingError) -> [String] {
        advance()  // '{'
        var keys: [String] = []
        var seen = Set<String>()
        skipWhitespace()
        if peek() == Byte.closeBrace {
            advance()
            return keys
        }
        while true {
            skipWhitespace()
            guard peek() == Byte.quote else {
                throw .malformedEncoding(byteOffset: index, reason: "object key expected")
            }
            let key = try scanString(path: display(path))
            guard seen.insert(key).inserted else {
                throw .duplicateKey(path: display(path), key: key)
            }
            keys.append(key)
            guard keys.count <= limits.maximumObjectEntryCount else {
                throw .structuralBoundExceeded(
                    path: display(path),
                    bound: .objectEntries,
                    limit: limits.maximumObjectEntryCount
                )
            }
            skipWhitespace()
            guard peek() == Byte.colon else {
                throw .malformedEncoding(byteOffset: index, reason: "\":\" expected after a key")
            }
            advance()
            skipWhitespace()
            try scanValue(path: child(path, key: key), depth: depth + 1)
            skipWhitespace()
            switch peek() {
            case Byte.comma:
                advance()
            case Byte.closeBrace:
                advance()
                return keys
            default:
                throw .malformedEncoding(
                    byteOffset: index,
                    reason: "\",\" or \"}\" expected after an object member"
                )
            }
        }
    }

    private mutating func scanArray(path: String, depth: Int) throws(ArtifactDecodingError) {
        advance()  // '['
        var count = 0
        skipWhitespace()
        if peek() == Byte.closeBracket {
            advance()
            return
        }
        while true {
            skipWhitespace()
            try scanValue(path: "\(display(path))[\(count)]", depth: depth + 1)
            count += 1
            guard count <= limits.maximumArrayElementCount else {
                throw .structuralBoundExceeded(
                    path: display(path),
                    bound: .arrayElements,
                    limit: limits.maximumArrayElementCount
                )
            }
            skipWhitespace()
            switch peek() {
            case Byte.comma:
                advance()
            case Byte.closeBracket:
                advance()
                return
            default:
                throw .malformedEncoding(
                    byteOffset: index,
                    reason: "\",\" or \"]\" expected after an array element"
                )
            }
        }
    }

    // MARK: Strings

    /// Scans a string and returns its decoded value.
    ///
    /// Validates UTF-8 sequences, rejects unescaped control characters, rejects
    /// unknown escapes, and rejects lone surrogates, so a decoded string is never a
    /// lossy reconstruction of the payload.
    private mutating func scanString(path: String) throws(ArtifactDecodingError) -> String {
        advance()  // opening quote
        var decoded: [UInt8] = []
        var scalarCount = 0
        while true {
            guard let byte = peek() else {
                throw .malformedEncoding(byteOffset: index, reason: "unterminated string")
            }
            if byte == Byte.quote {
                advance()
                // Lossless: every appended sequence was validated as UTF-8 above.
                return String(decoding: decoded, as: UTF8.self)
            }
            if byte == Byte.backslash {
                advance()
                let scalar = try scanEscape()
                decoded.append(contentsOf: Array(String(scalar).utf8))
                scalarCount += 1
            } else if byte < 0x20 {
                throw .malformedEncoding(
                    byteOffset: index,
                    reason: "unescaped control character \(describe(byte))"
                )
            } else if byte < 0x80 {
                decoded.append(byte)
                advance()
                scalarCount += 1
            } else {
                let sequence = try scanUTF8Sequence()
                decoded.append(contentsOf: sequence)
                scalarCount += 1
            }
            guard scalarCount <= limits.maximumStringScalarCount else {
                throw .structuralBoundExceeded(
                    path: path,
                    bound: .stringScalars,
                    limit: limits.maximumStringScalarCount
                )
            }
        }
    }

    private mutating func scanEscape() throws(ArtifactDecodingError) -> Unicode.Scalar {
        guard let marker = peek() else {
            throw .malformedEncoding(byteOffset: index, reason: "unterminated escape")
        }
        advance()
        switch marker {
        case Byte.quote: return "\""
        case Byte.backslash: return "\\"
        case Byte.solidus: return "/"
        case UInt8(ascii: "b"): return Unicode.Scalar(UInt8(0x08))
        case UInt8(ascii: "f"): return Unicode.Scalar(UInt8(0x0C))
        case UInt8(ascii: "n"): return "\n"
        case UInt8(ascii: "r"): return "\r"
        case UInt8(ascii: "t"): return "\t"
        case UInt8(ascii: "u"): return try scanUnicodeEscape()
        default:
            throw .malformedEncoding(
                byteOffset: index - 1,
                reason: "unknown escape \(describe(marker))"
            )
        }
    }

    private mutating func scanUnicodeEscape() throws(ArtifactDecodingError) -> Unicode.Scalar {
        let first = try scanHexQuad()
        if let scalar = Unicode.Scalar(first) {
            return scalar
        }
        // Only surrogate code points fail `Unicode.Scalar` construction here.
        guard (0xD800...0xDBFF).contains(first) else {
            throw .malformedEncoding(
                byteOffset: index - 4,
                reason: "lone low surrogate escape"
            )
        }
        guard peek() == Byte.backslash, peek(offset: 1) == UInt8(ascii: "u") else {
            throw .malformedEncoding(
                byteOffset: index,
                reason: "high surrogate escape without a low surrogate"
            )
        }
        advance()
        advance()
        let second = try scanHexQuad()
        guard (0xDC00...0xDFFF).contains(second) else {
            throw .malformedEncoding(
                byteOffset: index - 4,
                reason: "high surrogate escape followed by a non-low surrogate"
            )
        }
        let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
        guard let scalar = Unicode.Scalar(combined) else {
            throw .malformedEncoding(byteOffset: index - 4, reason: "invalid surrogate pair")
        }
        return scalar
    }

    private mutating func scanHexQuad() throws(ArtifactDecodingError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = peek(), let digit = Self.hexadecimalValue(byte) else {
                throw .malformedEncoding(
                    byteOffset: index,
                    reason: "four hexadecimal digits expected"
                )
            }
            value = value << 4 | UInt32(digit)
            advance()
        }
        return value
    }

    /// Validates one multi-byte UTF-8 sequence and returns its bytes.
    ///
    /// Overlong encodings, surrogate encodings, and out-of-range scalars are refused
    /// so that no payload can carry two encodings of the same text.
    private mutating func scanUTF8Sequence() throws(ArtifactDecodingError) -> [UInt8] {
        let start = index
        guard let lead = peek() else { throw .invalidUTF8(byteOffset: start) }
        let continuationCount: Int
        var secondRange: ClosedRange<UInt8> = 0x80...0xBF
        switch lead {
        case 0xC2...0xDF: continuationCount = 1
        case 0xE0: continuationCount = 2; secondRange = 0xA0...0xBF
        case 0xE1...0xEC, 0xEE...0xEF: continuationCount = 2
        case 0xED: continuationCount = 2; secondRange = 0x80...0x9F
        case 0xF0: continuationCount = 3; secondRange = 0x90...0xBF
        case 0xF1...0xF3: continuationCount = 3
        case 0xF4: continuationCount = 3; secondRange = 0x80...0x8F
        default: throw .invalidUTF8(byteOffset: start)
        }
        advance()
        for position in 0..<continuationCount {
            guard let byte = peek() else { throw .invalidUTF8(byteOffset: index) }
            let permitted: ClosedRange<UInt8> = position == 0 ? secondRange : 0x80...0xBF
            guard permitted.contains(byte) else { throw .invalidUTF8(byteOffset: index) }
            advance()
        }
        return Array(bytes[start..<index])
    }

    // MARK: Numbers

    private mutating func scanNumber(path: String) throws(ArtifactDecodingError) {
        let start = index
        if peek() == Byte.minus { advance() }
        guard let leading = peek(), Self.isDigit(leading) else {
            throw .malformedEncoding(byteOffset: index, reason: "digit expected")
        }
        if leading == Byte.zero {
            advance()
            if let next = peek(), Self.isDigit(next) {
                throw .malformedEncoding(byteOffset: index, reason: "leading zero in a number")
            }
        } else {
            try scanDigits()
        }
        if peek() == Byte.period {
            advance()
            try scanDigits()
        }
        if let exponent = peek(), exponent == UInt8(ascii: "e") || exponent == UInt8(ascii: "E") {
            advance()
            if let sign = peek(), sign == Byte.plus || sign == Byte.minus { advance() }
            try scanDigits()
        }
        guard index - start <= limits.maximumNumberTokenLength else {
            throw .structuralBoundExceeded(
                path: path,
                bound: .numberTokenLength,
                limit: limits.maximumNumberTokenLength
            )
        }
    }

    private mutating func scanDigits() throws(ArtifactDecodingError) {
        guard let first = peek(), Self.isDigit(first) else {
            throw .malformedEncoding(byteOffset: index, reason: "digit expected")
        }
        while let byte = peek(), Self.isDigit(byte) { advance() }
    }

    // MARK: Primitives

    private mutating func expect(literal: String) throws(ArtifactDecodingError) {
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected
        else {
            throw .malformedEncoding(byteOffset: index, reason: "\"\(literal)\" expected")
        }
        index += expected.count
    }

    private mutating func skipWhitespace() {
        while let byte = peek() {
            switch byte {
            case Byte.space, Byte.tab, Byte.newline, Byte.carriageReturn: advance()
            default: return
            }
        }
    }

    private func peek(offset: Int = 0) -> UInt8? {
        let position = index + offset
        return position < bytes.count ? bytes[position] : nil
    }

    private mutating func advance() { index += 1 }

    private func display(_ path: String) -> String {
        path.isEmpty ? ArtifactDecodingError.rootPath : path
    }

    private func child(_ path: String, key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    private func describe(_ byte: UInt8) -> String {
        (0x20...0x7E).contains(byte)
            ? "\"\(Character(Unicode.Scalar(byte)))\""
            : "byte 0x\(String(byte, radix: 16, uppercase: true))"
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (Byte.zero...Byte.nine).contains(byte) }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case Byte.zero...Byte.nine: byte - Byte.zero
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

extension ArtifactDecodingError {
    /// Content after the one top-level value.
    ///
    /// Named separately because a second document appended to a signed artifact is a
    /// distinct authoring fault from a grammar violation inside it.
    public static func trailingContentError(byteOffset: Int) -> ArtifactDecodingError {
        .malformedEncoding(byteOffset: byteOffset, reason: "content after the top-level value")
    }
}
