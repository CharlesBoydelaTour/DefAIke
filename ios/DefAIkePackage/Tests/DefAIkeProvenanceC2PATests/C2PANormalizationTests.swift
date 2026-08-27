import Testing

@testable import DefAIkeDomain
@testable import DefAIkeProvenanceAPI
@testable import DefAIkeProvenanceC2PA

/// The normalization half: library findings in, one bounded vendor-independent outcome
/// out, with no repaired or substituted value anywhere.
@Suite("C2PA outcome normalization")
struct C2PAOutcomeNormalizerTests {

    // MARK: - The emitted status key space

    @Test("Every reader condition produces a distinct canonical status key")
    func readerConditionKeysAreDistinctAndCanonical() {
        let keys = C2PAStatusVocabulary.readerConditionKeys
        #expect(keys.count == C2PAReaderCondition.allCases.count)
        #expect(Set(keys).count == keys.count)
        for key in keys {
            #expect(key.rawValue.hasPrefix("c2pa.reader."))
        }
    }

    @Test("A library status code is namespaced and otherwise passed through verbatim")
    func libraryStatusKeysArePassedThrough() {
        let key = C2PAStatusVocabulary.statusID(forLibraryCode: "assertion.dataHash.mismatch")
        #expect(key?.rawValue == "c2pa.status.assertion.dataHash.mismatch")
        // The two families cannot collide, so a policy entry is unambiguously scoped.
        #expect(key != C2PAStatusVocabulary.statusID(for: .allChecksPassed))
    }

    @Test("A library status the identifier syntax rejects is a finding, not a repaired key")
    func noncanonicalLibraryStatusIsAFinding() {
        let normalizer = C2PAOutcomeNormalizer(policy: PolicySample.policy())
        let outcome = C2PAReadOutcome(
            status: .libraryStatus("assertion dataHash mismatch"),
            binding: .notDetermined
        )

        #expect(throws: ProvenanceFeasibilityFinding
            .validatorStatusNotCanonical(rawStatus: "assertion dataHash mismatch")
        ) {
            try normalizer.normalize(outcome)
        }
    }

    // MARK: - The invalidity category is applicable only to invalid

    @Test("A failing check is carried only where the policy maps the status to invalid")
    func categoryIsWithheldFromNonInvalidStates() throws {
        let normalizer = C2PAOutcomeNormalizer(policy: PolicySample.policy())

        // `algorithm.unsupported` maps to unsupported in this policy. A category riding
        // along would contradict Requirement 6.13's separation, so it is withheld rather
        // than passed on for the mapper to reject.
        let unsupported = try normalizer.normalize(
            C2PAReadOutcome(
                status: .libraryStatus(PolicySample.unsupportedAlgorithm),
                binding: .notDetermined,
                failedCheck: .cryptographic
            )
        )
        #expect(unsupported.failedCheck == nil)

        let invalid = try normalizer.normalize(
            C2PAReadOutcome(
                status: .libraryStatus(PolicySample.cryptographicFailure),
                binding: .notDetermined,
                failedCheck: .cryptographic
            )
        )
        #expect(invalid.failedCheck == .cryptographic)
    }

    // MARK: - Bounded display-safe projection

    @Test("A detail for a field the policy does not permit displaying is dropped")
    func nondisplayableFieldIsDropped() throws {
        let policy = PolicySample.policy(displayableFields: [.signerIdentity])
        let normalizer = C2PAOutcomeNormalizer(policy: policy)

        let outcome = try normalizer.normalize(
            C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes,
                signerDetails: [
                    C2PARawDetail(field: .signerIdentity, rawValue: "CN=Example Signer"),
                    C2PARawDetail(field: .claimGenerator, rawValue: "Example Generator/1.0"),
                    C2PARawDetail(field: .validationTime, rawValue: "2026-01-01T00:00:00Z"),
                ],
                assertionLabels: ["c2pa.actions"]
            )
        )

        #expect(outcome.signerDetails.map(\.field) == [.signerIdentity])
        #expect(outcome.assertionLabels.isEmpty, "assertion labels are not displayable here")
    }

    @Test(
        "A permitted detail that is not display-safe is a finding, not a dropped field",
        arguments: [
            "",
            "   ",
            "CN=Example\nSigner",
            "CN=Example\u{202E}Signer",
        ]
    )
    func unsafeDetailIsAFinding(rawValue: String) {
        let normalizer = C2PAOutcomeNormalizer(policy: PolicySample.policy())
        let outcome = C2PAReadOutcome(
            status: .readerCondition(.allChecksPassed),
            binding: .boundToInspectedBytes,
            signerDetails: [C2PARawDetail(field: .signerIdentity, rawValue: rawValue)]
        )

        #expect(throws: ProvenanceFeasibilityFinding
            .validatorDetailNotDisplaySafe(field: .signerIdentity)
        ) {
            try normalizer.normalize(outcome)
        }
    }

    @Test("Overlong detail text is refused rather than truncated")
    func overlongDetailIsRefused() {
        let normalizer = C2PAOutcomeNormalizer(policy: PolicySample.policy())
        let overlong = String(
            repeating: "a",
            count: DisplaySafeText.maximumCharacterCount + 1
        )
        let outcome = C2PAReadOutcome(
            status: .readerCondition(.allChecksPassed),
            binding: .boundToInspectedBytes,
            signerDetails: [C2PARawDetail(field: .claimGenerator, rawValue: overlong)]
        )

        #expect(throws: ProvenanceFeasibilityFinding
            .validatorDetailNotDisplaySafe(field: .claimGenerator)
        ) {
            try normalizer.normalize(outcome)
        }
    }

    @Test("A repeated signer field keeps the first reading and stays unambiguous")
    func repeatedSignerFieldIsDeduplicated() throws {
        let normalizer = C2PAOutcomeNormalizer(policy: PolicySample.policy())

        let outcome = try normalizer.normalize(
            C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes,
                signerDetails: [
                    C2PARawDetail(field: .signerIdentity, rawValue: "CN=First"),
                    C2PARawDetail(field: .signerIdentity, rawValue: "CN=Second"),
                ]
            )
        )

        #expect(outcome.signerDetails.count == 1)
        #expect(outcome.signerDetails.first?.value.rawValue == "CN=First")
    }

    @Test("The assertion limit applies even where assertion labels are not displayable")
    func assertionLimitAppliesWithoutDisplay() {
        // The ceiling is a resource control, so hiding the labels does not exempt an
        // unbounded list from it.
        let policy = PolicySample.policy(
            displayableFields: [.signerIdentity],
            maximumAssertionCount: 2
        )
        let normalizer = C2PAOutcomeNormalizer(policy: policy)
        let outcome = C2PAReadOutcome(
            status: .readerCondition(.allChecksPassed),
            binding: .boundToInspectedBytes,
            assertionLabels: ["a", "b", "c"]
        )

        #expect(throws: ProvenanceFeasibilityFinding
            .processingLimitExceeded(.assertionCount(observed: 3, limit: 2))
        ) {
            try normalizer.normalize(outcome)
        }
    }

    @Test("Repeated assertion labels collapse while preserving first-read order")
    func repeatedAssertionLabelsAreDeduplicated() throws {
        let normalizer = C2PAOutcomeNormalizer(policy: PolicySample.policy())

        let outcome = try normalizer.normalize(
            C2PAReadOutcome(
                status: .readerCondition(.allChecksPassed),
                binding: .boundToInspectedBytes,
                assertionLabels: ["c2pa.actions", "c2pa.hash.data", "c2pa.actions"]
            )
        )

        #expect(outcome.assertionLabels.map(\.rawValue) == ["c2pa.actions", "c2pa.hash.data"])
    }

    // MARK: - Failure classification

    @Test("The three classification families are disjoint")
    func classificationFamiliesAreDisjoint() {
        let byteBinding = C2PAFailureClassification.byteBinding
        let cryptographic = C2PAFailureClassification.cryptographic
        let structural = C2PAFailureClassification.structural

        #expect(byteBinding.isDisjoint(with: cryptographic))
        #expect(byteBinding.isDisjoint(with: structural))
        #expect(cryptographic.isDisjoint(with: structural))
    }

    @Test(
        "Representative specification failure codes classify by the check they name",
        arguments: [
            ("assertion.dataHash.mismatch", InvalidityCategory.byteBinding),
            ("assertion.boxesHash.mismatch", InvalidityCategory.byteBinding),
            ("claim.hardBindings.missing", InvalidityCategory.byteBinding),
            ("claimSignature.mismatch", InvalidityCategory.cryptographic),
            ("signingCredential.untrusted", InvalidityCategory.cryptographic),
            ("signingCredential.ocsp.revoked", InvalidityCategory.cryptographic),
            ("claim.malformed", InvalidityCategory.structural),
            ("assertion.json.invalid", InvalidityCategory.structural),
        ]
    )
    func classifiesSpecificationCodes(code: String, expected: InvalidityCategory) {
        #expect(C2PAFailureClassification.category(forLibraryCode: code) == expected)
    }

    @Test(
        "An unrecognized or catch-all code does not classify",
        arguments: ["general.error", "some.future.code", ""]
    )
    func unclassifiedCodes(code: String) {
        #expect(C2PAFailureClassification.category(forLibraryCode: code) == nil)
    }
}

/// The manifest-store projection: selection over an already-bounded document.
@Suite("C2PA manifest store projection")
struct C2PAManifestStoreProjectionTests {

    private func projection(_ json: String) throws -> C2PAManifestStoreProjection {
        try #require(C2PAManifestStoreProjection(json: json))
    }

    @Test("Something that is not a manifest-store object projects to nothing")
    func rejectsNonObjectDocuments() {
        #expect(C2PAManifestStoreProjection(json: "[]") == nil)
        #expect(C2PAManifestStoreProjection(json: "not json") == nil)
    }

    @Test("A clean pass with a matched hard binding reports a pass and an established binding")
    func cleanPass() throws {
        let store = try projection(
            """
            {
              "active_manifest": {
                "claim_generator_info": [{ "name": "Example Generator" }],
                "signature_info": { "issuer": "CN=Example", "time": "2026-01-01T00:00:00Z" },
                "assertions": [{ "label": "c2pa.actions" }]
              },
              "validation_results": {
                "activeManifest": {
                  "success": [{ "code": "assertion.dataHash.match" },
                              { "code": "claimSignature.validated" }],
                  "informational": [],
                  "failure": []
                }
              }
            }
            """
        )

        #expect(store.statusFinding == .readerCondition(.allChecksPassed))
        #expect(store.bindingFinding == .boundToInspectedBytes)
        #expect(store.assertionLabels == ["c2pa.actions"])
        #expect(store.signerDetails.map(\.field) == [
            .signerIdentity, .claimGenerator, .validationTime,
        ])
        #expect(store.unsupportedFeatures.isEmpty)
    }

    @Test("A clean pass with no hard-binding success leaves the binding undetermined")
    func passWithoutHardBinding() throws {
        let store = try projection(
            """
            {
              "active_manifest": {},
              "validation_results": {
                "activeManifest": {
                  "success": [{ "code": "claimSignature.validated" }],
                  "informational": [], "failure": []
                }
              }
            }
            """
        )

        #expect(store.statusFinding == .readerCondition(.allChecksPassed))
        #expect(store.bindingFinding == .notDetermined)
    }

    @Test("A byte-binding failure outranks a signature failure, whatever the report order")
    func failureSelectionIsOrderIndependent() throws {
        let ascending = try projection(
            """
            {
              "active_manifest": {},
              "validation_results": {
                "activeManifest": {
                  "failure": [{ "code": "claimSignature.mismatch" },
                              { "code": "assertion.dataHash.mismatch" }],
                  "informational": [], "success": []
                }
              }
            }
            """
        )
        let descending = try projection(
            """
            {
              "active_manifest": {},
              "validation_results": {
                "activeManifest": {
                  "failure": [{ "code": "assertion.dataHash.mismatch" },
                              { "code": "claimSignature.mismatch" }],
                  "informational": [], "success": []
                }
              }
            }
            """
        )

        #expect(ascending.statusFinding == .libraryStatus("assertion.dataHash.mismatch"))
        #expect(ascending.statusFinding == descending.statusFinding)
        #expect(ascending.bindingFinding == .notBound)
        #expect(descending.bindingFinding == .notBound)
    }

    @Test("An unresolved revocation answer outranks an otherwise clean pass")
    func revocationGapOutranksPass() throws {
        let store = try projection(
            """
            {
              "active_manifest": {},
              "validation_results": {
                "activeManifest": {
                  "success": [{ "code": "assertion.dataHash.match" },
                              { "code": "claimSignature.validated" }],
                  "informational": [{ "code": "signingCredential.ocsp.inaccessible" }],
                  "failure": []
                }
              }
            }
            """
        )

        #expect(store.statusFinding == .readerCondition(.revocationAnswerUnavailable))
    }

    @Test("A parsed manifest with no reported result is neither a pass nor absence")
    func noValidationResult() throws {
        let store = try projection(#"{ "active_manifest": {} }"#)

        #expect(store.statusFinding == .readerCondition(.validationResultAbsent))
        #expect(store.bindingFinding == .notDetermined)
    }

    @Test("A legacy status array is read as failures")
    func legacyValidationStatus() throws {
        let store = try projection(
            """
            {
              "active_manifest": {},
              "validation_status": [{ "code": "assertion.dataHash.mismatch" }]
            }
            """
        )

        #expect(store.statusFinding == .libraryStatus("assertion.dataHash.mismatch"))
        #expect(store.bindingFinding == .notBound)
    }

    @Test("An active manifest named by label resolves through the manifest map")
    func activeManifestByLabel() throws {
        let store = try projection(
            """
            {
              "active_manifest": "urn:uuid:example",
              "manifests": {
                "urn:uuid:example": {
                  "claim_generator": "Legacy Generator/1.0",
                  "signature_info": { "issuer": "CN=Example" }
                }
              },
              "validation_results": {
                "activeManifest": { "success": [], "informational": [], "failure": [] }
              }
            }
            """
        )

        #expect(store.signerDetails.contains {
            $0.field == .claimGenerator && $0.rawValue == "Legacy Generator/1.0"
        })
    }
}

/// The container recognition the vendor API has to be told about.
@Suite("C2PA container signature")
struct C2PAContainerSignatureTests {

    @Test("Each supported container is recognized from its leading bytes")
    func recognizesSupportedContainers() {
        #expect(C2PAContainerSignature.container(of: [0xFF, 0xD8, 0xFF, 0xE0]) == .jpeg)
        #expect(
            C2PAContainerSignature.container(
                of: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            ) == .png
        )
        #expect(C2PAContainerSignature.container(of: isoBaseMedia(brand: "heic")) == .heic)
        #expect(C2PAContainerSignature.container(of: isoBaseMedia(brand: "mif1")) == .heif)
    }

    @Test("Anything else yields no container rather than a guessed format")
    func refusesUnknownContainers() {
        #expect(C2PAContainerSignature.container(of: []) == nil)
        #expect(C2PAContainerSignature.container(of: [0xFF, 0xD8]) == nil)
        #expect(C2PAContainerSignature.container(of: isoBaseMedia(brand: "qt  ")) == nil)
        #expect(C2PAContainerSignature.container(of: Array(repeating: 0x00, count: 32)) == nil)
    }

    @Test("Every supported container has a distinct media type")
    func mediaTypesAreDistinct() {
        let types = StaticContainer.allCases.map(\.mimeType)
        #expect(Set(types).count == types.count)
    }

    private func isoBaseMedia(brand: String) -> [UInt8] {
        [0x00, 0x00, 0x00, 0x18] + Array("ftyp".utf8) + Array(brand.utf8) + Array(repeating: 0, count: 8)
    }
}
