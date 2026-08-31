import Testing

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI
@testable import DefAIkeProvenanceC2PA

/// Confirms the conditional provenance-adapter test target is wired to its module, and
/// that linking the reviewed library did not by itself enable the capability.
///
/// The approved offline fixture suite — valid signed, tampered, invalid, absent,
/// unsupported, and indeterminate credentials exercised against the real binary — arrives
/// with task 9.9 and consumes the approved trust and revocation policy rather than
/// inventing trust. Nothing here runs the native validator.
@Suite("DefAIkeProvenanceC2PA module wiring")
struct ModuleWiringTests {
    @Test("Module marker identifies the conditional C2PA adapter")
    func moduleMarker() {
        #expect(DefAIkeProvenanceC2PAModule.name == "DefAIkeProvenanceC2PA")
    }

    @Test("The adapter names the exact reviewed validator release")
    func reviewedVersion() {
        #expect(DefAIkeProvenanceC2PAModule.reviewedValidatorVersion == "0.0.12")
    }

    @Test("No security-sensitive library setting is left on its vendor default")
    func securitySensitiveDefaultsAreResolved() {
        #expect(C2PALibraryReader.unreviewedLibraryDefaults.isEmpty)
    }

    @Test("The bundled official trust snapshot matches its pinned descriptor")
    func bundledTrustSnapshotIsDigestAndCountPinned() throws {
        let digest = try #require(
            DefAIkeDomain.SHA256Digest(
                hexadecimal: BundledC2PATrustStore.contentDigestHex
            )
        )
        let descriptor = try ProvenanceTrustStoreDescriptor(
            store: EvidenceSource(
                artifact: try #require(ArtifactID("c2pa.official-trust-list")),
                version: try SchemaSemanticVersion(validating: "1.0.0"),
                contentDigest: digest
            ),
            anchorCount: try PositiveCount(validating: BundledC2PATrustStore.anchorCount),
            isOfflineOnly: true
        )

        let material = try #require(BundledC2PATrustStore.material(matching: descriptor))
        #expect(material.descriptor == descriptor)
        #expect(material.anchorBytes.isEmpty == false)

        let mismatched = try ProvenanceTrustStoreDescriptor(
            store: EvidenceSource(
                artifact: descriptor.store.artifact,
                version: descriptor.store.version,
                contentDigest: try #require(
                    DefAIkeDomain.SHA256Digest(
                        hexadecimal: String(repeating: "0", count: 64)
                    )
                )
            ),
            anchorCount: descriptor.anchorCount,
            isOfflineOnly: true
        )
        #expect(BundledC2PATrustStore.material(matching: mismatched) == nil)
    }

    @Test("Compiling the adapter does not by itself produce an enabled provenance lane")
    func linkingIsNotApproval() {
        // The shipped application composition's exact shape, asserted from the one test
        // target that actually links this module: the adapter is present, the signed
        // manifest enables the capability and binds the policy, and there is still no
        // analyzer — because this call intentionally supplies none. Linking an adapter or
        // bundling public trust material cannot approve a Release composition by itself.
        //
        // So the lane is unavailable (Requirements 6.3, 6.4, 6.19, and 6.20), and the
        // reason is the one that is true of this build rather than the one that used to
        // cover every unavailable lane when a second composition linked no adapter at all.
        let provider = ProvenanceLaneProvider.resolve(
            linksValidator: true,
            analyzer: nil,
            policy: PolicySample.policy(),
            manifest: ManifestSample.provenanceEnabled(for: PolicySample.policy())
        )

        #expect(!provider.isEnabled)
        #expect(provider.unavailableReason == .validatorEnablementUnapproved)
        #expect(!provider.canProduceCombinedSummary)
        #expect(provider.boundPolicyID == nil)
    }

    @Test("A composition that links no adapter still reports the module-graph reason")
    func nonLinkageOutranksTheManifest() {
        // The other direction, kept live even though the shipping app no longer takes it.
        // `linksValidator: false` outranks a manifest that enables the capability, because
        // a signed artifact cannot enable an implementation that is absent from the binary.
        // Asserting it here is what stops `linksValidator` from being a parameter nothing
        // reads.
        let provider = ProvenanceLaneProvider.resolve(
            linksValidator: false,
            analyzer: nil,
            policy: PolicySample.policy(),
            manifest: ManifestSample.provenanceEnabled(for: PolicySample.policy())
        )

        #expect(!provider.isEnabled)
        #expect(provider.unavailableReason == .validatorNotCompiledIntoRelease)
    }
}
