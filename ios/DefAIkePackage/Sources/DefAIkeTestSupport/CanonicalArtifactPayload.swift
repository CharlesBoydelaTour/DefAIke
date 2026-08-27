import DefAIkeDomain
import Foundation

/// Encodes artifacts to payload bytes and mutates those bytes, for decode tests.
///
/// Shipping code only ever *decodes* artifacts, so encoding lives here rather than in
/// the domain. That split is deliberate: the profile
/// ``BoundedArtifactDecoder`` enforces is structural decode safety, and the
/// canonicalization profile a release *signature* covers is an approved artifact
/// reference. Nothing in this file is that profile, and nothing here is release
/// evidence.
///
/// The mutators operate on payload text rather than on typed values, because that is
/// the only way to express what a hostile or mis-authored artifact can contain and a
/// Swift value cannot: a duplicate key, an absent required field, a null where a value
/// belongs, or a member of a closed vocabulary this build does not implement.
public enum CanonicalArtifactPayload {
    /// A deterministic encoder with sorted keys and unescaped solidus.
    ///
    /// Sorted keys make a payload stable enough to mutate by position in a test. This
    /// is a test convenience, not a canonical-form decision.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Encodes one artifact to payload bytes.
    public static func bytes(_ value: some Encodable) throws -> [UInt8] {
        try Array(makeEncoder().encode(value))
    }

    /// Encodes one artifact to payload text.
    public static func text(_ value: some Encodable) throws -> String {
        String(decoding: try bytes(value), as: UTF8.self)
    }

    /// The top-level keys of an encoded artifact, sorted, which is the order
    /// ``makeEncoder()`` emits them in.
    public static func topLevelKeys(_ value: some Encodable) throws -> [String] {
        let object = try topLevelObject(value)
        return object.keys.sorted()
    }

    // MARK: - Mutations

    /// Removes one top-level key, so a test can show nothing substitutes a default.
    ///
    /// Returns `nil` when the key is absent, so a test cannot silently assert against
    /// an unmutated payload.
    public static func removingTopLevelKey(_ key: String, from value: some Encodable) throws
        -> [UInt8]?
    {
        var object = try topLevelObject(value)
        guard object.removeValue(forKey: key) != nil else { return nil }
        return try serialize(object)
    }

    /// Replaces one top-level value, for example with an unknown vocabulary member.
    public static func replacingTopLevelValue(
        _ key: String,
        with replacement: Any,
        in value: some Encodable
    ) throws -> [UInt8]? {
        var object = try topLevelObject(value)
        guard object[key] != nil else { return nil }
        object[key] = replacement
        return try serialize(object)
    }

    /// Sets one top-level key to null.
    public static func nullingTopLevelKey(_ key: String, in value: some Encodable) throws
        -> [UInt8]?
    {
        try replacingTopLevelValue(key, with: NSNull(), in: value)
    }

    /// Where a spliced duplicate key is placed relative to the original.
    ///
    /// Both placements matter, because which one a general-purpose decoder keeps is an
    /// implementation detail nobody should have to know: the same signed bytes can read
    /// as two different artifacts depending on it.
    public enum DuplicateKeyPlacement: Sendable {
        /// Ahead of every existing key.
        case first
        /// After every existing key.
        case last
    }

    /// Duplicates one top-level key by rewriting the payload text.
    ///
    /// A duplicate key cannot be produced through a serializer, because a serializer's
    /// input is a dictionary. It has to be spliced into the text, which is exactly the
    /// shape a mis-authored or tampered artifact arrives in.
    public static func duplicatingTopLevelKey(
        _ key: String,
        in value: some Encodable,
        placing placement: DuplicateKeyPlacement = .first
    ) throws -> [UInt8]? {
        let payload = try text(value)
        let quoted = "\"\(key)\":"
        guard payload.contains(quoted), payload.hasPrefix("{"), payload.hasSuffix("}") else {
            return nil
        }
        switch placement {
        case .first:
            return Array("{\(quoted)null,\(payload.dropFirst())".utf8)
        case .last:
            return Array("\(payload.dropLast()),\(quoted)null}".utf8)
        }
    }

    /// Wraps `depth` nested single-key objects, for depth-ceiling tests.
    public static func nested(depth: Int, key: String = "nested") -> [UInt8] {
        guard depth > 0 else { return Array("{}".utf8) }
        var payload = "{}"
        for _ in 1..<max(depth, 1) {
            payload = "{\"\(key)\":\(payload)}"
        }
        return Array(payload.utf8)
    }

    // MARK: - Helpers

    private static func topLevelObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try makeEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PayloadError.topLevelValueIsNotAnObject
        }
        return object
    }

    private static func serialize(_ object: [String: Any]) throws -> [UInt8] {
        try Array(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    /// Why a payload could not be prepared. Test-support only.
    public enum PayloadError: Error, Sendable, Equatable {
        case topLevelValueIsNotAnObject
    }
}
