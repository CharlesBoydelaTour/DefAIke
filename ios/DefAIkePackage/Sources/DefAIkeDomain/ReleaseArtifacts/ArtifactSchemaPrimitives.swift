import Foundation

// Bounded scalar building blocks shared by every policy and release artifact.
//
// Identifiers, digests, canonical artifact paths, digest records, and model
// identity are core domain values declared in `Sources/DefAIkeDomain/Core/`.
// This file adds only the artifact-layer scalars those core values do not cover:
// schema versions, semantic and platform versions, bounded text, bounded counts,
// bounded ratios, and validated deadlines.
//
// Nothing here chooses an approved value. Every type either rejects a value the
// requirements forbid or rejects a value that is structurally unusable, such as a
// zero deadline standing in for "not measured yet".

// MARK: - Schema version

/// The schema version of one encoded release artifact.
///
/// Every artifact carries its own schema version so a build rejects an artifact
/// it cannot fully interpret instead of ignoring fields it does not understand.
public struct ArtifactSchemaVersion: ValidatedScalarSchemaValue, Comparable, CustomStringConvertible {
    /// Highest schema version this source revision can represent.
    public static let maximumSupported = 1

    public let value: Int

    public var rawSchemaValue: Int { value }

    public init(validating raw: Int) throws {
        guard raw >= 1 else {
            throw ArtifactSchemaError.nonPositiveValue(field: "schemaVersion", value: "\(raw)")
        }
        guard raw <= Self.maximumSupported else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "schemaVersion",
                value: "\(raw)",
                allowed: "1...\(Self.maximumSupported)"
            )
        }
        self.value = raw
    }

    /// The only schema version defined by this source revision.
    public static let v1 = ArtifactSchemaVersion(unchecked: 1)

    private init(unchecked value: Int) { self.value = value }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    public var description: String { "\(value)" }
}

// MARK: - Bounded text

/// Bounded, display-safe artifact text, for example a device model name.
///
/// Text fields are not identifiers: they may contain spaces and mixed case. They
/// are still bounded, control-character free, and rejected when they hold a
/// placeholder token.
public struct ArtifactText: ValidatedScalarSchemaValue, CustomStringConvertible {
    public let value: String

    public var rawSchemaValue: String { value }

    public init(validating raw: String) throws {
        self.value = try ArtifactSchemaValidation.boundedText(raw, field: "text")
    }

    public var description: String { value }
}

// MARK: - Versions

/// A three-component version in canonical `major.minor.patch` form.
///
/// `0.0.0` is the repository's local development stand-in and is rejected: an
/// approved artifact records a real version.
public struct SchemaSemanticVersion: ValidatedScalarSchemaValue, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public var rawSchemaValue: String { "\(major).\(minor).\(patch)" }

    public init(validating raw: String) throws {
        let components = try Self.parse(raw, field: "version")
        guard components.contains(where: { $0 > 0 }) else {
            throw ArtifactSchemaError.placeholderValue(field: "version", value: raw)
        }
        self.major = components[0]
        self.minor = components[1]
        self.patch = components[2]
    }

    fileprivate init(components: [Int]) {
        self.major = components[0]
        self.minor = components[1]
        self.patch = components[2]
    }

    fileprivate static func parse(_ raw: String, field: String) throws -> [Int] {
        try ArtifactSchemaValidation.requireDecidedValue(raw, field: field)
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else {
            throw ArtifactSchemaError.noncanonicalValue(field: field, value: raw)
        }
        var parsed: [Int] = []
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  component == "0" || component.first != "0",
                  let number = Int(component),
                  number <= 9999
            else {
                throw ArtifactSchemaError.noncanonicalValue(field: field, value: raw)
            }
            parsed.append(number)
        }
        return parsed
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { rawSchemaValue }
}

/// Version of one compiled capability implementation.
///
/// An allowlist entry binds every enabled capability to the exact implementation
/// version that produced its gate evidence (Requirements 13.17 and 13.20).
public typealias CapabilityImplementationVersion = SchemaSemanticVersion

/// An operating-system version in canonical `major.minor.patch` form.
///
/// Foundation's `OperatingSystemVersion` is not `Codable`, so artifacts carry this
/// comparable schema type and adapters convert at the platform boundary.
public struct PlatformVersion: ValidatedScalarSchemaValue, Comparable, CustomStringConvertible {
    /// The Version 1 minimum supported release (Requirements 1.2, 4.2, and 10.3).
    public static let iOS17 = PlatformVersion(components: [17, 0, 0])

    public let major: Int
    public let minor: Int
    public let patch: Int

    public var rawSchemaValue: String { "\(major).\(minor).\(patch)" }

    public init(validating raw: String) throws {
        let components = try SchemaSemanticVersion.parse(raw, field: "osVersion")
        guard components[0] >= 1 else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "osVersion",
                value: raw,
                allowed: "major version 1 or greater"
            )
        }
        self.init(components: components)
    }

    private init(components: [Int]) {
        self.major = components[0]
        self.minor = components[1]
        self.patch = components[2]
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Major version used to index the accessibility and localization gate
    /// matrices (Requirements 12.13 and 12.17).
    public var majorVersion: Int { major }

    public var description: String { rawSchemaValue }
}

// MARK: - Bounded numbers

/// A strictly positive byte count.
public struct PositiveByteCount: ValidatedScalarSchemaValue, Comparable, CustomStringConvertible {
    public let value: UInt64

    public var rawSchemaValue: UInt64 { value }

    public init(validating raw: UInt64) throws {
        guard raw > 0 else {
            throw ArtifactSchemaError.nonPositiveValue(field: "byteCount", value: "\(raw)")
        }
        self.value = raw
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    public var description: String { "\(value)" }
}

/// A strictly positive item count, for example a declared sample count.
public struct PositiveCount: ValidatedScalarSchemaValue, Comparable, CustomStringConvertible {
    public let value: Int

    public var rawSchemaValue: Int { value }

    public init(validating raw: Int) throws {
        guard raw > 0 else {
            throw ArtifactSchemaError.nonPositiveValue(field: "count", value: "\(raw)")
        }
        self.value = raw
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    public var description: String { "\(value)" }
}

/// A non-negative count that may legitimately be zero, for example an error count.
public struct NonNegativeCount: ValidatedScalarSchemaValue, Comparable, CustomStringConvertible {
    public let value: Int

    public var rawSchemaValue: Int { value }

    public init(validating raw: Int) throws {
        guard raw >= 0 else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "count",
                value: "\(raw)",
                allowed: "0 or greater"
            )
        }
        self.value = raw
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    public var description: String { "\(value)" }
}

/// A strictly positive decimal magnitude, for example a measured resource limit.
public struct PositiveDecimal: ValidatedScalarSchemaValue, Comparable, CustomStringConvertible {
    public let value: Decimal

    public var rawSchemaValue: Decimal { value }

    public init(validating raw: Decimal) throws {
        try ArtifactSchemaValidation.requirePositive(raw, field: "value")
        self.value = raw
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    public var description: String { "\(value)" }
}

/// A non-negative decimal magnitude, for example a numeric tolerance.
public struct NonNegativeDecimal: ValidatedScalarSchemaValue, Comparable, CustomStringConvertible {
    public let value: Decimal

    public var rawSchemaValue: Decimal { value }

    public init(validating raw: Decimal) throws {
        guard raw >= 0 else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "value",
                value: "\(raw)",
                allowed: "0 or greater"
            )
        }
        self.value = raw
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    public var description: String { "\(value)" }
}

/// A ratio in the closed interval `0...1`, for example a rate or coverage value.
public struct UnitInterval: ValidatedScalarSchemaValue, Comparable, CustomStringConvertible {
    /// Exactly zero.
    public static let zero = UnitInterval(unchecked: 0)

    /// Exactly one, used where a requirement fixes total agreement.
    public static let one = UnitInterval(unchecked: 1)

    public let value: Decimal

    public var rawSchemaValue: Decimal { value }

    public init(validating raw: Decimal) throws {
        guard raw >= 0, raw <= 1 else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "ratio",
                value: "\(raw)",
                allowed: "0...1"
            )
        }
        self.value = raw
    }

    private init(unchecked value: Decimal) { self.value = value }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    public var description: String { "\(value)" }
}

/// A strictly positive deadline, encoded canonically in whole milliseconds.
///
/// Cleanup deadlines and latency limits are release-controlled numeric values.
/// Zero is neither "immediately" nor "not measured yet": it is rejected, because a
/// distributable artifact states a decided deadline (Requirements 9.7 and 11.1).
public struct ValidatedDuration: ValidatedScalarSchemaValue, Comparable, CustomStringConvertible {
    /// Ceiling that keeps an encoded deadline inside any plausible session
    /// lifecycle window (30 days). A safety bound, not an approved value.
    public static let maximumMilliseconds: UInt64 = 30 * 24 * 60 * 60 * 1000

    public let milliseconds: UInt64

    public var rawSchemaValue: UInt64 { milliseconds }

    public init(validating raw: UInt64) throws {
        guard raw > 0 else {
            throw ArtifactSchemaError.nonPositiveValue(field: "duration", value: "\(raw)ms")
        }
        guard raw <= Self.maximumMilliseconds else {
            throw ArtifactSchemaError.valueOutOfRange(
                field: "duration",
                value: "\(raw)ms",
                allowed: "1...\(Self.maximumMilliseconds)ms"
            )
        }
        self.milliseconds = raw
    }

    /// Exact `Duration` for clock comparisons, with no floating-point conversion.
    public var duration: Duration { .milliseconds(Int64(milliseconds)) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.milliseconds < rhs.milliseconds }

    public var description: String { "\(milliseconds)ms" }
}
