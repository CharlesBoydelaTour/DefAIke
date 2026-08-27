// Pixel-model identity carried by a session binding.

/// The identity of the pixel model a session was bound to.
///
/// Which checkpoint and weight digest are compatible is fixed by the release
/// requirements and verified by the Model Bundle layer against the signed
/// manifest. This type only carries the identity; it declares no constant and
/// therefore cannot become a source of a second, drifting copy of the required
/// checkpoint identity or weight digest.
public struct ModelIdentity: Hashable, Codable, Sendable {
    /// The checkpoint this model was converted from.
    public let checkpointIdentifier: ModelCheckpointIdentifier

    /// The weight-blob digest the manifest declares for that checkpoint.
    public let requiredWeightDigest: SHA256Digest

    public init(
        checkpointIdentifier: ModelCheckpointIdentifier,
        requiredWeightDigest: SHA256Digest
    ) {
        self.checkpointIdentifier = checkpointIdentifier
        self.requiredWeightDigest = requiredWeightDigest
    }
}
