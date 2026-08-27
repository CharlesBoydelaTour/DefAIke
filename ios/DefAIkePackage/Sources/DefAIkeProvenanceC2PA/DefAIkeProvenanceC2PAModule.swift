/// Boundary marker for the conditional C2PA provenance adapter.
///
/// Responsibility: offline Content Credential validation over the exact retained
/// encoded bytes under bounded resource controls, and mapping normalized library
/// outcomes through the signed Provenance Policy into exactly one enabled state
/// with bounded display-safe details.
///
/// Ships only in the pixel-plus-provenance composition. The pixel-only
/// composition neither links nor instantiates this module.
///
/// Dependency rule: `DefAIkeDomain`, `DefAIkeProvenanceAPI`, and the
/// exact-pinned reviewed `c2pa-swift` 0.0.12 release. The library is reached from
/// exactly one file, ``C2PALibraryReader``, behind the ``C2PAManifestReading``
/// seam, so every other decision in this module is a pure function that runs
/// without a native binary, without trust anchors, and without a device.
///
/// Linking the library is not approval to enable the capability. The Provenance
/// Feasibility Gate (implementation feasibility, correctness fixtures, resource
/// limits, security and dependency review, and physical-device validation) is a
/// separate gate, and ``ProvenanceLaneProvider`` additionally requires an exact
/// match against the signed Release Capability Manifest before a lane is enabled.
///
/// Nothing in this module chooses a trust store, a revocation answer, a signer
/// policy, an assertion policy, or a feasibility conclusion. Every one of those
/// arrives from a signed artifact, and any condition no artifact answers leaves as
/// a ``ProvenanceFeasibilityFinding`` rather than as a state.
public enum DefAIkeProvenanceC2PAModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkeProvenanceC2PA"

    /// The exact reviewed validator release this adapter is written against.
    ///
    /// Mirrored from ``C2PALibraryReader/reviewedImplementationVersion`` so an archive
    /// audit can read it without linking the library.
    public static let reviewedValidatorVersion = C2PALibraryReader.reviewedImplementationVersion
}
