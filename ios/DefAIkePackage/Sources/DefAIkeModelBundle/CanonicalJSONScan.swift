import Foundation

// A strict structural scan of the manifest bytes, run before decoding.
//
// `JSONDecoder` accepts a document whose object declares the same key twice and
// silently keeps one of the values. For a signed manifest that is not a nuisance, it
// is a verification hole: `{"signingKey":"trusted","signingKey":"attacker"}` would
// decode to whichever the decoder happened to keep. So the bytes are scanned first
// and the document is refused outright when any object repeats a key.
//
// The scan is structural only. It does not reorder, reformat, or re-encode anything:
// the signature is verified over the exact bytes that were read, and no canonical
// re-serialization is ever produced from the decoded value.

/// Why a strict structural scan refused a document.
enum JSONScanFault: Error, Equatable, Sendable {
    /// The bytes are not valid UTF-8.
    case notUTF8
    /// The document is not well-formed JSON at this byte offset.
    case malformed(byteOffset: Int)
    /// One object declares the same key twice, after unescaping.
    case duplicateKey(String)
    /// The document nests deeper than the scan walks.
    case tooDeep(maximumDepth: Int)
}

/// A bounded, duplicate-key-rejecting JSON structural scan.
enum CanonicalJSONScan {
    /// Nesting ceiling. A structural bound that keeps the scan's recursion depth
    /// fixed regardless of input; not an approved value.
    static let maximumDepth = 32

    /// Refuses a document that is not valid UTF-8, not well-formed JSON, deeper than
    /// ``maximumDepth``, or that repeats a key in any object.
    static func validate(_ bytes: [UInt8]) throws(JSONScanFault) {
        guard String(data: Data(bytes), encoding: .utf8) != nil else {
            throw JSONScanFault.notUTF8
        }
        var scanner = Scanner(bytes: bytes)
        try scanner.scanDocument()
    }
}

/// A single-pass recursive-descent scanner over UTF-8 JSON bytes.
private struct Scanner {
    let bytes: [UInt8]
    var index = 0
    var depth = 0

    mutating func scanDocument() throws(JSONScanFault) {
        skipWhitespace()
        try scanValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw JSONScanFault.malformed(byteOffset: index)
        }
    }

    // MARK: Values

    mutating func scanValue() throws(JSONScanFault) {
        guard let byte = peek() else {
            throw JSONScanFault.malformed(byteOffset: index)
        }
        switch byte {
        case UInt8(ascii: "{"):
            try scanObject()
        case UInt8(ascii: "["):
            try scanArray()
        case UInt8(ascii: "\""):
            _ = try scanString()
        case UInt8(ascii: "t"):
            try expect("true")
        case UInt8(ascii: "f"):
            try expect("false")
        case UInt8(ascii: "n"):
            try expect("null")
        default:
            try scanNumber()
        }
    }

    mutating func scanObject() throws(JSONScanFault) {
        try enter()
        index += 1
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            leave()
            return
        }
        var keys = Set<String>()
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else {
                throw JSONScanFault.malformed(byteOffset: index)
            }
            let key = try scanString()
            guard keys.insert(key).inserted else {
                throw JSONScanFault.duplicateKey(key)
            }
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else {
                throw JSONScanFault.malformed(byteOffset: index)
            }
            index += 1
            skipWhitespace()
            try scanValue()
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "}"):
                index += 1
                leave()
                return
            default:
                throw JSONScanFault.malformed(byteOffset: index)
            }
        }
    }

    mutating func scanArray() throws(JSONScanFault) {
        try enter()
        index += 1
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            leave()
            return
        }
        while true {
            skipWhitespace()
            try scanValue()
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                leave()
                return
            default:
                throw JSONScanFault.malformed(byteOffset: index)
            }
        }
    }

    // MARK: Scalars

    /// Scans a string and returns its unescaped value.
    ///
    /// Unescaping matters for the duplicate-key check: `"a"` and `"\u0061"` are the
    /// same key, and comparing raw bytes would treat them as two.
    mutating func scanString() throws(JSONScanFault) -> String {
        index += 1
        var decoded: [UInt8] = []
        while true {
            guard index < bytes.count else {
                throw JSONScanFault.malformed(byteOffset: index)
            }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: decoded, as: UTF8.self)
            case UInt8(ascii: "\\"):
                try scanEscape(into: &decoded)
            case 0x00...0x1F:
                throw JSONScanFault.malformed(byteOffset: index)
            default:
                decoded.append(byte)
                index += 1
            }
        }
    }

    private mutating func scanEscape(into decoded: inout [UInt8]) throws(JSONScanFault) {
        let escapeOffset = index
        index += 1
        guard let marker = peek() else {
            throw JSONScanFault.malformed(byteOffset: escapeOffset)
        }
        index += 1
        switch marker {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
            decoded.append(marker)
        case UInt8(ascii: "b"):
            decoded.append(0x08)
        case UInt8(ascii: "f"):
            decoded.append(0x0C)
        case UInt8(ascii: "n"):
            decoded.append(0x0A)
        case UInt8(ascii: "r"):
            decoded.append(0x0D)
        case UInt8(ascii: "t"):
            decoded.append(0x09)
        case UInt8(ascii: "u"):
            let scalar = try scanUnicodeEscape(startingAt: escapeOffset)
            decoded.append(contentsOf: Array(String(scalar).utf8))
        default:
            throw JSONScanFault.malformed(byteOffset: escapeOffset)
        }
    }

    /// Scans the four hexadecimal digits of a `\u` escape, pairing surrogates.
    private mutating func scanUnicodeEscape(
        startingAt escapeOffset: Int
    ) throws(JSONScanFault) -> Unicode.Scalar {
        let first = try scanHexadecimalQuad(startingAt: escapeOffset)
        if let scalar = Unicode.Scalar(first) {
            return scalar
        }
        // Not a scalar on its own: only a surrogate half can reach here.
        guard (0xD800...0xDBFF).contains(first) else {
            throw JSONScanFault.malformed(byteOffset: escapeOffset)
        }
        guard peek() == UInt8(ascii: "\\"), peekAhead(1) == UInt8(ascii: "u") else {
            throw JSONScanFault.malformed(byteOffset: escapeOffset)
        }
        index += 2
        let second = try scanHexadecimalQuad(startingAt: escapeOffset)
        guard (0xDC00...0xDFFF).contains(second) else {
            throw JSONScanFault.malformed(byteOffset: escapeOffset)
        }
        let combined = 0x1_0000 + ((first - 0xD800) << 10) + (second - 0xDC00)
        guard let scalar = Unicode.Scalar(combined) else {
            throw JSONScanFault.malformed(byteOffset: escapeOffset)
        }
        return scalar
    }

    private mutating func scanHexadecimalQuad(
        startingAt escapeOffset: Int
    ) throws(JSONScanFault) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = peek(), let nibble = Scanner.hexadecimalNibble(byte) else {
                throw JSONScanFault.malformed(byteOffset: escapeOffset)
            }
            value = value << 4 | nibble
            index += 1
        }
        return value
    }

    /// Scans a JSON number, rejecting leading zeros, a bare sign, and `1.` forms.
    mutating func scanNumber() throws(JSONScanFault) {
        let start = index
        if peek() == UInt8(ascii: "-") {
            index += 1
        }
        guard let leading = peek(), Scanner.isDigit(leading) else {
            throw JSONScanFault.malformed(byteOffset: start)
        }
        if leading == UInt8(ascii: "0") {
            index += 1
            if let next = peek(), Scanner.isDigit(next) {
                throw JSONScanFault.malformed(byteOffset: start)
            }
        } else {
            try scanDigits(startingAt: start)
        }
        if peek() == UInt8(ascii: ".") {
            index += 1
            try scanDigits(startingAt: start)
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            index += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") {
                index += 1
            }
            try scanDigits(startingAt: start)
        }
    }

    private mutating func scanDigits(startingAt start: Int) throws(JSONScanFault) {
        var consumed = 0
        while let byte = peek(), Scanner.isDigit(byte) {
            index += 1
            consumed += 1
        }
        guard consumed > 0 else {
            throw JSONScanFault.malformed(byteOffset: start)
        }
    }

    mutating func expect(_ literal: String) throws(JSONScanFault) {
        let expected = Array(literal.utf8)
        let end = index + expected.count
        guard end <= bytes.count, Array(bytes[index..<end]) == expected else {
            throw JSONScanFault.malformed(byteOffset: index)
        }
        index = end
    }

    // MARK: Cursor

    private mutating func enter() throws(JSONScanFault) {
        depth += 1
        guard depth <= CanonicalJSONScan.maximumDepth else {
            throw JSONScanFault.tooDeep(maximumDepth: CanonicalJSONScan.maximumDepth)
        }
    }

    private mutating func leave() {
        depth -= 1
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func peekAhead(_ offset: Int) -> UInt8? {
        let position = index + offset
        return position < bytes.count ? bytes[position] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func hexadecimalNibble(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return UInt32(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return UInt32(byte - UInt8(ascii: "A")) + 10
        default:
            return nil
        }
    }
}
