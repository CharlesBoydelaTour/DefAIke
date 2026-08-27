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
        // No value in this module conforms to `ProvenanceAnalyzing`, because the port
        // cannot express a Provenance Feasibility Gate finding and no approved artifact
        // says which state one becomes. A `nil` analyzer is the pixel-only lane whatever
        // the signed manifest enables, so a build that links this module still reports the
        // unavailable state (Requirements 6.3, 6.4, 6.19, and 6.20).
        let provider = ProvenanceLaneProvider.resolve(
            analyzer: nil,
            policy: PolicySample.policy(),
            manifest: ManifestSample.provenanceEnabled(for: PolicySample.policy())
        )

        #expect(!provider.isEnabled)
        #expect(provider.unavailableReason == .validatorNotCompiledIntoRelease)
        #expect(!provider.canProduceCombinedSummary)
        #expect(provider.boundPolicyID == nil)
    }
}
