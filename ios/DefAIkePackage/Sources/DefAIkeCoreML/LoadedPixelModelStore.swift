import DefAIkeDomain

// Where a loaded model lives.
//
// ``BoundCoreMLModel`` names its model with a ``LoadedModelToken`` and never carries
// the instance: the domain has to be able to refer to a loaded model without importing
// Core ML. This actor is the other half of that arrangement, and the only place a
// token can be dereferenced.
//
// Ownership is by activation rather than by Analysis Session. One verified bundle is
// active at a time and a session binds the value snapshot, so a loaded model outlives
// any single session and is released when its activation is replaced. That is why
// there is no per-session release member here: a session ending must not unload the
// model a concurrent session is bound to.

/// Holds the models this process has loaded, keyed by opaque token.
///
/// An actor because the tokens are handed to whatever isolation the coordinator runs
/// in, while registration happens on the load path.
public actor LoadedPixelModelStore {
    private var runtimes: [LoadedModelToken: any PixelModelRuntime] = [:]

    /// Next token discriminator. Monotonic and process-local. A token is only ever
    /// compared, and it carries no user content, no path, and no image-derived value,
    /// so it is not a session-correlatable identifier (Requirement 9.11).
    private var nextRawValue: UInt64 = 1

    public init() {}

    /// Registers a loaded model and returns the token that names it.
    public func register(_ runtime: any PixelModelRuntime) -> LoadedModelToken {
        let token = LoadedModelToken(rawValue: nextRawValue)
        nextRawValue += 1
        runtimes[token] = runtime
        return token
    }

    /// The model a token names, or `nil` when it was never registered or has been
    /// released.
    ///
    /// `nil` is a fail-closed refusal rather than a reason to load something: the
    /// analyzer reports that there is no loaded model instead of loading one itself,
    /// so inference can never run against a model no verified activation produced.
    public func runtime(for token: LoadedModelToken) -> (any PixelModelRuntime)? {
        runtimes[token]
    }

    /// Releases one loaded model. Idempotent, like every other cleanup path here.
    public func release(_ token: LoadedModelToken) {
        runtimes.removeValue(forKey: token)
    }

    /// How many models are currently loaded. Test and cleanup assertion only.
    public var loadedModelCount: Int { runtimes.count }
}
