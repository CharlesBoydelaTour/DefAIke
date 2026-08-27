import DefAIkeDomain
import DefAIkeProvenanceAPI

/// Pixel-only composition.
///
/// Compiled into `DefAIkeApp-PixelOnly` only. No Content Credential validator is linked, so
/// `DefAIkeProvenanceC2PA` is unreachable and every Evidence Report from this build uses the
/// unavailable provenance source-lane state and omits any Combined Summary (Requirements 6.19,
/// 6.20, and 7.10).
///
/// This is the composition that remains distributable when the Provenance Feasibility Gate does
/// not pass.
enum CompiledCapabilityComposition: CapabilityComposition {
    static let identifier = "pixel-only"
    static let linksProvenanceValidator = false

    /// Pixel analysis alone. Content Credential validation is not compiled, so the manifest
    /// this build is admitted under must not enable it.
    static let capabilities: Set<CapabilityID> = [.pixelAnalysis]

    /// Always `nil`, and not by choice: `DefAIkeProvenanceC2PA` is absent from this target's
    /// module closure, so there is no validator type to name here. `ProvenanceLaneProvider`
    /// turns that into `UnavailableReason.validatorNotCompiledIntoRelease` without awaiting or
    /// invoking anything, which is Requirement 6.19's "remains inactive" as the absence of a
    /// callee rather than as a check.
    static func provenanceAnalyzer(
        store: any EphemeralFileStoring,
        policy: ProvenancePolicy?
    ) -> (any ProvenanceAnalyzing)? {
        nil
    }

    /// Empty, and structurally so.
    ///
    /// An entry here has to be read from a constant inside a linked adapter module. This
    /// composition links one evidence module, `DefAIkeCoreML`, and that module carries no
    /// self-reported implementation version to read: the pixel analyzer's version is the
    /// application's own, recorded in the signed manifest and the allowlist entry, not a
    /// third-party release this repository pins.
    ///
    /// So this composition attests nothing, and cannot. That is not a weaker guarantee than the
    /// provenance composition's: an adapter-version pin exists to keep a build from claiming to
    /// be a *different* reviewed third-party release than the one it links, and the only third-
    /// party release either composition links is `c2pa-swift`, which is absent here. What keeps
    /// this build free of a validator is non-linkage — enforced in the declared module graph by
    /// `check-module-boundaries.py` and in the shipped bytes by
    /// `check-capability-composition.py` — and separately the emptiness of the capability set
    /// below, which makes a provisioned `content-credential-validation` version a refusal rather
    /// than an unchecked entry (`CompiledCapabilityComposition.init?` requires exact coverage).
    static let linkedImplementationVersions: [CapabilityID: String] = [:]
}
