import Testing

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

    @Test("The library settings left on their own defaults are named, not silently taken")
    func unreviewedDefaultsAreEnumerated() {
        // The list is the dependency and security review's surface. It is asserted to be
        // nonempty rather than exhaustive: shrinking it means an approved artifact now
        // answers one of those settings, which is a spec change, not a code change.
        #expect(!C2PALibraryReader.unreviewedLibraryDefaults.isEmpty)
        #expect(
            Set(C2PALibraryReader.unreviewedLibraryDefaults).count
                == C2PALibraryReader.unreviewedLibraryDefaults.count
        )
    }

    @Test("Compiling the adapter does not by itself produce an enabled provenance lane")
    func linkingIsNotApproval() {
        // The shipped application composition's exact shape, asserted from the one test
        // target that actually links this module: the adapter is present, the signed
        // manifest enables the capability and binds the policy, and there is still no
        // analyzer — because no value here conforms to `ProvenanceAnalyzing`, the port
        // cannot express a Provenance Feasibility Gate finding, and no approved artifact
        // says which state one becomes.
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
