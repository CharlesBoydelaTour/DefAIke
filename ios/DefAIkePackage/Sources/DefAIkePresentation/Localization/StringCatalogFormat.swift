// A minimal scanner over the format constructs inside one catalog value.
//
// It exists to answer three questions about a value, and deliberately nothing else:
//
//   1. how many arguments does it consume, and are they positional? Non-positional
//      arguments pin argument order to English word order, so a translation cannot
//      reorder a sentence (Requirements 12.15 and 12.16);
//   2. does any specifier carry a width or precision field? That pads or truncates the
//      substituted value to a fixed size, which is a fixed-width assumption; and
//   3. which named substitutions (`%#@name@`) does it reference, and what literal text
//      surrounds them? Cross-checking the references against the entry's declared
//      substitutions is what keeps a pluralized part inside the catalog instead of
//      being appended by the caller, and the literal text is what distinguishes a
//      sentence from a bare concatenation slot.
//
// It does not render, format, or check argument *types*: a value's arguments come from
// the view layer, and this module holds no view. Anything it cannot classify it reports
// as an unclassified specifier rather than guessing, so an exotic value fails the
// positional check instead of silently passing it.

/// One piece of a scanned catalog value.
enum StringCatalogFormatSegment: Hashable, Sendable {
    /// Text outside any format construct. An escaped `%%` contributes a literal `%`.
    case literal(String)

    /// A format specifier that consumes one argument.
    case specifier(StringCatalogFormatSpecifier)

    /// A `%#@name@` reference to a declared substitution.
    case substitutionReference(String)
}

/// One parsed format specifier.
struct StringCatalogFormatSpecifier: Hashable, Sendable {
    /// The one-based argument index, when the specifier is positional (`%2$@`).
    let argumentNumber: Int?

    /// Whether the specifier pads or truncates to a fixed size (`%-12s`, `%.4f`).
    let hasFieldWidthOrPrecision: Bool

    /// A specifier the scanner could not classify.
    ///
    /// It carries no argument number, so it fails the positional check rather than
    /// passing unexamined. A construct the checker does not understand is not a
    /// construct it has cleared.
    static let unclassified = StringCatalogFormatSpecifier(
        argumentNumber: nil,
        hasFieldWidthOrPrecision: false
    )
}

enum StringCatalogFormat {
    /// Characters that may follow the argument number as flags.
    private static let flags: Set<Character> = ["-", "+", " ", "0", "#", "'"]

    /// Flags that pad the substituted value to a width.
    private static let paddingFlags: Set<Character> = ["-", "0"]

    /// Length modifiers, longest first so `ll` is preferred over `l`.
    private static let lengthModifiers = ["hh", "ll", "h", "l", "q", "L", "z", "j", "t"]

    /// Conversion letters Foundation's formatting accepts.
    private static let conversions: Set<Character> = [
        "d", "i", "u", "o", "x", "X", "e", "E", "f", "F", "g", "G", "a", "A",
        "c", "C", "s", "S", "p", "n", "@", "b", "B",
    ]

    /// Scans `value` into literal text and format constructs, in order.
    static func scan(_ value: String) -> [StringCatalogFormatSegment] {
        var segments: [StringCatalogFormatSegment] = []
        var literal = ""
        var index = value.startIndex

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            segments.append(.literal(literal))
            literal = ""
        }

        while index < value.endIndex {
            let character = value[index]
            guard character == "%" else {
                literal.append(character)
                index = value.index(after: index)
                continue
            }

            var cursor = value.index(after: index)
            guard cursor < value.endIndex else {
                flushLiteral()
                segments.append(.specifier(.unclassified))
                index = value.endIndex
                continue
            }

            // `%%` is a literal percent, not an argument.
            if value[cursor] == "%" {
                literal.append("%")
                index = value.index(after: cursor)
                continue
            }

            // `%#@name@` names a declared substitution.
            if value[cursor] == "#",
                value.index(after: cursor) < value.endIndex,
                value[value.index(after: cursor)] == "@"
            {
                let nameStart = value.index(cursor, offsetBy: 2)
                flushLiteral()
                if let nameEnd = value[nameStart...].firstIndex(of: "@") {
                    segments.append(.substitutionReference(String(value[nameStart..<nameEnd])))
                    index = value.index(after: nameEnd)
                } else {
                    segments.append(.specifier(.unclassified))
                    index = value.endIndex
                }
                continue
            }

            // An argument number, but only when followed by `$`; otherwise the digits
            // were a field width.
            var argumentNumber: Int?
            let afterPercent = cursor
            var digits = ""
            while cursor < value.endIndex, value[cursor].isNumber {
                digits.append(value[cursor])
                cursor = value.index(after: cursor)
            }
            if !digits.isEmpty, cursor < value.endIndex, value[cursor] == "$" {
                argumentNumber = Int(digits)
                cursor = value.index(after: cursor)
            } else {
                cursor = afterPercent
            }

            var padded = false
            while cursor < value.endIndex, flags.contains(value[cursor]) {
                if paddingFlags.contains(value[cursor]) { padded = true }
                cursor = value.index(after: cursor)
            }
            while cursor < value.endIndex, value[cursor].isNumber {
                padded = true
                cursor = value.index(after: cursor)
            }
            if cursor < value.endIndex, value[cursor] == "." {
                padded = true
                cursor = value.index(after: cursor)
                while cursor < value.endIndex, value[cursor].isNumber {
                    cursor = value.index(after: cursor)
                }
            }
            for modifier in lengthModifiers where value[cursor...].hasPrefix(modifier) {
                cursor = value.index(cursor, offsetBy: modifier.count)
                break
            }

            flushLiteral()
            guard cursor < value.endIndex, conversions.contains(value[cursor]) else {
                segments.append(.specifier(.unclassified))
                index = cursor < value.endIndex ? value.index(after: cursor) : value.endIndex
                continue
            }
            segments.append(
                .specifier(
                    StringCatalogFormatSpecifier(
                        argumentNumber: argumentNumber,
                        hasFieldWidthOrPrecision: padded
                    )
                )
            )
            index = value.index(after: cursor)
        }

        flushLiteral()
        return segments
    }

    /// Every argument-consuming construct in `value`, in order.
    ///
    /// A substitution reference consumes an argument too, and is addressed by name
    /// rather than by position, so it is reported as already reorderable.
    static func argumentSpecifiers(in value: String) -> [StringCatalogFormatSpecifier] {
        scan(value).compactMap { segment in
            switch segment {
            case .literal: nil
            case let .specifier(specifier): specifier
            case .substitutionReference:
                StringCatalogFormatSpecifier(argumentNumber: 0, hasFieldWidthOrPrecision: false)
            }
        }
    }

    /// The names every `%#@name@` in `value` references.
    static func substitutionReferences(in value: String) -> Set<String> {
        Set(
            scan(value).compactMap { segment in
                guard case let .substitutionReference(name) = segment else { return nil }
                return name
            }
        )
    }

    /// The literal text of `value`, with every argument construct removed.
    ///
    /// A value whose literal text is blank while it consumes an argument is a
    /// concatenation slot rather than a sentence.
    static func literalText(in value: String) -> String {
        scan(value)
            .compactMap { segment in
                guard case let .literal(text) = segment else { return nil }
                return text
            }
            .joined()
    }
}
