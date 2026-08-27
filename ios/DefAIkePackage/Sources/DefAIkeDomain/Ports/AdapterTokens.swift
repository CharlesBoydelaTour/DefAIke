// Opaque references to adapter-owned resources.
//
// Several ports hand back something the domain must be able to name but must never
// hold: a provider representation whose access window belongs to PhotosUI, a decoded
// CGImage, a 384x384 pixel buffer, a loaded `MLModel`. Carrying those values in a
// domain type would either drag a framework into the pure core or copy hundreds of
// kilobytes of image-derived data into a value the privacy rules want gone
// (Requirement 9.1).
//
// A token is therefore an adapter-scoped name and nothing else. The domain compares,
// stores, and passes tokens; only the issuing adapter can dereference one. A token
// carries no user content, no file path, and no image-derived value, so it is not a
// session-correlatable identifier in a log (Requirement 9.11).

/// An opaque, adapter-scoped reference to a resource the adapter owns.
///
/// Tokens are not interchangeable: each concrete type names one kind of resource, so
/// a decoded image cannot be passed where a loaded model is expected. They are not
/// `Codable`, because a token is meaningful only inside the process and adapter
/// instance that issued it and must not cross the App Group boundary.
public protocol OpaqueAdapterToken: Hashable, Sendable, CustomStringConvertible {
    /// Adapter-assigned discriminator. Unique within the issuing adapter only.
    var rawValue: UInt64 { get }

    init(rawValue: UInt64)
}

extension OpaqueAdapterToken {
    /// Deliberately omits the raw value so a token cannot be logged as a
    /// session-correlatable identifier.
    public var description: String { "\(Self.self)(opaque)" }
}

/// Names one item representation held by a system provider.
///
/// The provider's access window is short-lived and owned by the framework: a token
/// is valid only until the provider's callback returns, which is why ingest copies
/// the bytes before the window closes (Requirement 2.9 and the design's byte
/// lifecycle).
public struct ProviderToken: OpaqueAdapterToken {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Names one completely decoded image held by the image pipeline adapter.
public struct DecodedImageToken: OpaqueAdapterToken {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Names one 384x384 unsigned 8-bit RGB model input buffer.
public struct ModelInputToken: OpaqueAdapterToken {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Names one loaded Core ML model instance.
public struct LoadedModelToken: OpaqueAdapterToken {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Names one outstanding resource reservation.
public struct ResourceReservationToken: OpaqueAdapterToken {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}
