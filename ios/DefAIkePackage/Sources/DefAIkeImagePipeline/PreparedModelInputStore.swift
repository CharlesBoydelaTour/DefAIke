import DefAIkeDomain

// Where the prepared model input lives.
//
// The same arrangement as ``DecodedImageStore``, for the same reason: ``ModelImageInput``
// names its buffer with a ``ModelInputToken`` and never carries the pixels, so the domain
// can refer to a prepared input without holding hundreds of kilobytes of image-derived
// bytes in a value the privacy rules want deleted (Requirement 9.1). This actor is the
// only place a token can be dereferenced.
//
// Ownership is by Analysis Session, so cleanup releases everything one session prepared
// without knowing how many buffers that was, and a token belonging to a session that has
// ended resolves to nothing rather than to stale pixels.
//
// The Core ML adapter reads a prepared input through its own ``PreparedPixelResolving``
// seam, which this module cannot conform to: `DefAIkeImagePipeline` must not depend on
// `DefAIkeCoreML`. The composition root bridges the two. What this store guarantees is
// the invariant that seam states — tightly packed, row-major, three bytes per pixel, no
// app-side scaling or normalization — so the bridge copies bytes rather than reshaping
// them.

/// One prepared model input buffer, with the shape it was produced to.
public struct PreparedModelInput: Hashable, Sendable {
    /// The session that owns the bytes.
    public let sessionID: AnalysisSessionID

    /// Edge length of the square buffer. The bound contract's crop edge.
    public let edge: Int

    /// Channel order of the interleaved bytes.
    public let channelOrder: ModelChannelOrder

    /// Tightly packed, row-major, three bytes per pixel: exactly `edge * edge * 3` bytes.
    ///
    /// Unsigned 8-bit sample values exactly as the crop produced them. No `1/255`
    /// scaling, no mean subtraction, and no standard-deviation division: all three belong
    /// to the model graph (Requirements 4.6 through 4.8), and applying any of them here
    /// would double-normalize and silently invalidate every parity measurement.
    public let bytes: [UInt8]

    /// Creates a prepared input, or `nil` when `bytes` is not one tightly packed
    /// three-channel square of `edge` pixels.
    ///
    /// A short, long, or padded buffer is not representable, so a buffer that is not the
    /// shape it claims cannot reach a token and be handed to the framework.
    init?(
        sessionID: AnalysisSessionID,
        edge: Int,
        channelOrder: ModelChannelOrder,
        bytes: [UInt8]
    ) {
        guard edge > 0 else { return nil }
        guard UInt64(bytes.count) == UInt64(edge) * UInt64(edge) * 3 else { return nil }
        self.sessionID = sessionID
        self.edge = edge
        self.channelOrder = channelOrder
        self.bytes = bytes
    }
}

/// Holds the model input buffers one process has prepared, keyed by opaque token.
public actor PreparedModelInputStore {
    private var entries: [ModelInputToken: PreparedModelInput] = [:]

    /// Next token discriminator. Monotonic and process-local: a token is only ever
    /// compared, and it carries no user content, no dimension, and no path, so it is not
    /// a session-correlatable identifier (Requirement 9.11).
    private var nextRawValue: UInt64 = 1

    public init() {}

    /// Stores a prepared input and returns the token that names it.
    func store(_ input: PreparedModelInput) -> ModelInputToken {
        let token = ModelInputToken(rawValue: nextRawValue)
        nextRawValue += 1
        entries[token] = input
        return token
    }

    /// The prepared input a token names, or `nil` when it was never stored or has been
    /// released.
    public func preparedInput(for token: ModelInputToken) -> PreparedModelInput? {
        entries[token]
    }

    /// Releases one prepared input. Idempotent.
    public func release(_ token: ModelInputToken) {
        entries.removeValue(forKey: token)
    }

    /// Releases everything one session prepared and reports how many buffers went.
    ///
    /// Idempotent, like every other cleanup path: a second call reports zero rather than
    /// failing, so terminal cleanup and interrupted-session cleanup behave identically
    /// (Requirement 9.8).
    @discardableResult
    public func releaseAll(for sessionID: AnalysisSessionID) -> Int {
        let owned = entries.filter { $0.value.sessionID == sessionID }.map(\.key)
        for token in owned {
            entries.removeValue(forKey: token)
        }
        return owned.count
    }

    /// How many prepared inputs are currently held. Test and cleanup assertion only.
    public var retainedInputCount: Int { entries.count }
}
