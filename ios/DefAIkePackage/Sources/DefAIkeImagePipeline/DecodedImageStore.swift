import DefAIkeDomain
import CoreGraphics

// Where a decoded image lives.
//
// ``ValidatedImage`` names its decoded image with a ``DecodedImageToken`` and never
// carries the pixels: the domain must be able to refer to a decoded image without
// importing Core Graphics and without copying image-derived bytes into a value the
// privacy rules want deleted (Requirement 9.1). This actor is the other half of that
// arrangement — the only place a token can be dereferenced.
//
// Ownership is by Analysis Session, so cleanup can release everything one session
// decoded without knowing how many images that was, and a token belonging to a session
// that has ended resolves to nothing rather than to stale pixels.

/// One completely decoded image, with what was measured about it.
public struct DecodedImage: Sendable {
    /// The session that owns the pixels.
    public let sessionID: AnalysisSessionID

    /// Actual decoded dimensions, before orientation metadata is applied.
    public let dimensions: PixelDimensions

    /// Bytes the decoded image actually occupies: `bytesPerRow * height`.
    public let decodedByteCount: UInt64

    /// The decoded pixels.
    ///
    /// A `CGImage` is immutable once created, which is what makes handing it across
    /// an isolation boundary safe. The box states that explicitly rather than relying
    /// on whichever SDK-declared conformance happens to be visible.
    public var image: CGImage { box.image }

    let box: ImmutableCGImageBox

    init(sessionID: AnalysisSessionID, dimensions: PixelDimensions, decodedByteCount: UInt64, image: CGImage) {
        self.sessionID = sessionID
        self.dimensions = dimensions
        self.decodedByteCount = decodedByteCount
        self.box = ImmutableCGImageBox(image)
    }
}

/// A `CGImage` carried across isolation boundaries.
///
/// `CGImage` is documented as immutable after creation: nothing in this package
/// mutates one, and the only writers are Image I/O and Core Graphics during creation.
/// The unchecked conformance is that fact written down, and it is deliberately scoped
/// to this one wrapper so no other type in the module can claim it accidentally.
struct ImmutableCGImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) { self.image = image }
}

/// Holds the images one process has decoded, keyed by opaque token.
///
/// An actor because the tokens are handed out to whatever isolation the coordinator
/// runs in, and because the release path runs from cleanup rather than from the
/// validating call.
public actor DecodedImageStore {
    private var entries: [DecodedImageToken: DecodedImage] = [:]

    /// Next token discriminator. Monotonic and process-local: a token is only ever
    /// compared, and it carries no user content, no dimension, and no path, so it is
    /// not a session-correlatable identifier (Requirement 9.11).
    private var nextRawValue: UInt64 = 1

    public init() {}

    /// Stores a decoded image and returns the token that names it.
    func store(_ image: DecodedImage) -> DecodedImageToken {
        let token = DecodedImageToken(rawValue: nextRawValue)
        nextRawValue += 1
        entries[token] = image
        return token
    }

    /// The image a token names, or `nil` when it was never stored or has been
    /// released.
    public func image(for token: DecodedImageToken) -> DecodedImage? {
        entries[token]
    }

    /// Releases one decoded image. Idempotent.
    public func release(_ token: DecodedImageToken) {
        entries.removeValue(forKey: token)
    }

    /// Releases everything one session decoded and reports how many images went.
    ///
    /// Idempotent, like every other cleanup path: a second call reports zero rather
    /// than failing, so terminal cleanup and interrupted-session cleanup behave
    /// identically (Requirement 9.8).
    @discardableResult
    public func releaseAll(for sessionID: AnalysisSessionID) -> Int {
        let owned = entries.filter { $0.value.sessionID == sessionID }.map(\.key)
        for token in owned {
            entries.removeValue(forKey: token)
        }
        return owned.count
    }

    /// How many decoded images are currently held. Test and cleanup assertion only.
    public var retainedImageCount: Int { entries.count }
}
