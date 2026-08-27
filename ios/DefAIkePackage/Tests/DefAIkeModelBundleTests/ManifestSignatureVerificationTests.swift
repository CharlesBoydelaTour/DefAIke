import Testing

@testable import DefAIkeDomain
@testable import DefAIkeModelBundle

/// Signature verification, and the fact that every trust answer in it comes from the
/// injected Bundle Verification Policy.
///
/// The module under test contains no algorithm, no key, no rotation rule, and no
/// revocation rule. These tests exercise that from both sides: changing a policy field
/// changes the outcome, and removing an approval or a key makes verification fail rather
/// than proceed on something the module picked.
@Suite("Model Bundle signature verification")
struct ManifestSignatureVerificationTests {
    // MARK: The algorithm comes from the policy

    @Test("The verifier is asked for exactly the algorithm the policy approves")
    func policyAlgorithmIsTheOneExecuted() throws {
        for algorithm in SignatureAlgorithm.allCases {
            let assembled = try BundleAssembler.standard(
                policyAlgorithm: algorithm,
                supportedAlgorithms: [algorithm]
            )
            #expect(assembled.verificationFinding() == nil, "\(algorithm) should verify")

            let others = Set(SignatureAlgorithm.allCases).subtracting([algorithm])
            let mismatched = try BundleAssembler.standard(
                policyAlgorithm: algorithm,
                supportedAlgorithms: others
            )
            #expect(
                mismatched.verificationFinding() == .signatureAlgorithmUnsupported(algorithm),
                "a build without \(algorithm) must refuse rather than substitute one"
            )
        }
    }

    @Test("A policy whose key records a different algorithm cannot be constructed")
    func policyKeepsOneAlgorithm() {
        // There is only one algorithm field to read, because the approved artifact
        // refuses to hold two answers. Verification therefore has no second opinion to
        // reconcile and no reason to prefer one.
        #expect(throws: ArtifactSchemaError.self) {
            _ = try BundleVerificationPolicy(
                id: Sample.artifact("policy.bundle-verification"),
                schemaVersion: .v1,
                algorithm: .ed25519,
                canonicalizationProfile: Sample.evidence("evidence.canonicalization"),
                trustedKeys: [
                    TrustedSigningKey(
                        key: Sample.signingKey(),
                        algorithm: .ecdsaP256SHA256,
                        publicKeyDigest: Sample.digest(),
                        status: .active,
                        governanceApproval: Sample.approval()
                    )
                ],
                rotationBehavior: .activeKeysOnly,
                revocationBehavior: .rejectBundle,
                maximumManifestByteCount: Sample.byteCount(1024),
                reproducibilityEvidence: Sample.evidence("evidence.reproducibility")
            )
        }
    }

    // MARK: Trusted keys come from the policy

    @Test("A key the policy does not list is refused")
    func untrustedKeyRefused() throws {
        let assembled = try BundleAssembler.standard(
            trustedKeyID: Sample.signingKey("key.other")
        )
        #expect(
            assembled.verificationFinding() == .signingKeyNotTrusted(Sample.signingKey())
        )
    }

    @Test("A listed key whose governance record is a rejection is refused")
    func rejectedGovernanceRefused() throws {
        let assembled = try BundleAssembler.standard(governance: .rejected)
        #expect(
            assembled.verificationFinding()
                == .signingKeyGovernanceNotApproved(Sample.signingKey())
        )
    }

    @Test("A revoked key is refused")
    func revokedKeyRefused() throws {
        let assembled = try BundleAssembler.standard(keyStatus: .revoked)
        #expect(assembled.verificationFinding() == .signingKeyRevoked(Sample.signingKey()))
    }

    @Test("A retired key is refused under both rotation rules, for different reasons")
    func retiredKeyRefusedUnderEitherRotationRule() throws {
        let activeOnly = try BundleAssembler.standard(
            keyStatus: .retired,
            rotationBehavior: .activeKeysOnly
        )
        #expect(
            activeOnly.verificationFinding()
                == .retiredSigningKeyRejectedByRotationRule(Sample.signingKey())
        )

        // The rule needs a retirement instant and a signing instant. Neither the policy
        // nor the manifest carries one, so the window is not establishable and
        // verification fails closed instead of admitting any retired key.
        let historical = try BundleAssembler.standard(
            keyStatus: .retired,
            rotationBehavior: .retiredKeysVerifyHistoricalBundles
        )
        #expect(
            historical.verificationFinding()
                == .retiredSigningKeyWindowNotEstablishable(Sample.signingKey())
        )
    }

    @Test("A policy cannot treat an unresolved revocation status as trust")
    func revocationBehaviorCannotBePermissive() {
        #expect(throws: ArtifactSchemaError.self) {
            _ = try BundleVerificationPolicy(
                id: Sample.artifact("policy.bundle-verification"),
                schemaVersion: .v1,
                algorithm: .ed25519,
                canonicalizationProfile: Sample.evidence("evidence.canonicalization"),
                trustedKeys: [
                    TrustedSigningKey(
                        key: Sample.signingKey(),
                        algorithm: .ed25519,
                        publicKeyDigest: Sample.digest(),
                        status: .active,
                        governanceApproval: Sample.approval()
                    )
                ],
                rotationBehavior: .activeKeysOnly,
                revocationBehavior: .treatAsTrusted,
                maximumManifestByteCount: Sample.byteCount(1024),
                reproducibilityEvidence: Sample.evidence("evidence.reproducibility")
            )
        }
    }

    // MARK: Key material

    @Test("A build with no key material for a trusted key refuses rather than skipping")
    func absentKeyMaterialRefused() throws {
        let assembled = try BundleAssembler.standard(omitKeyMaterial: true)
        #expect(
            assembled.verificationFinding()
                == .signingKeyMaterialUnavailable(Sample.signingKey())
        )
    }

    @Test("Key material that is not the key the policy records is refused")
    func substitutedKeyMaterialRefused() throws {
        let assembled = try BundleAssembler.standard(
            declaredKeyMaterialDigest: Sample.digest("7")
        )
        #expect(
            assembled.verificationFinding()
                == .signingKeyMaterialDigestMismatch(Sample.signingKey())
        )
    }

    // MARK: The signature covers the exact manifest bytes

    @Test("A signature over different bytes does not verify")
    func alteredSignatureRefused() throws {
        var assembled = try BundleAssembler.standard()
        var signature = assembled.tree.fileBytes[ModelBundleManifest.signatureFileName]!
        signature[0] ^= 0xFF
        assembled.tree.overwriteContent(
            ModelBundleManifest.signatureFileName,
            bytes: signature
        )
        #expect(
            assembled.verificationFinding()
                == .manifestSignatureDidNotVerify(key: Sample.signingKey())
        )
    }

    @Test("Rewriting a signed manifest field breaks the signature")
    func rewrittenManifestBreaksSignature() throws {
        var assembled = try BundleAssembler.standard()
        // A rewritten compatibility field: schema-valid on its own, but not what was
        // signed (Requirement 10.6).
        let rewritten = String(decoding: assembled.manifestBytes, as: UTF8.self)
            .replacingOccurrences(of: "\"build.sample\"", with: "\"build.forged\"")
        let bytes = Array(rewritten.utf8)
        #expect(bytes.count == assembled.manifestBytes.count)
        assembled.tree.overwriteContent(ModelBundleManifest.manifestFileName, bytes: bytes)

        #expect(
            assembled.verificationFinding()
                == .manifestSignatureDidNotVerify(key: Sample.signingKey())
        )
    }

    @Test("The signature is checked before any artifact is hashed")
    func signaturePrecedesArtifactHashing() throws {
        // Both the signature and an artifact digest are wrong. The reported finding is
        // the signature, which pins the design's verification order.
        var assembled = try BundleAssembler.standard()
        assembled.tree.overwriteContent(
            BundleAssembler.preprocessingPath,
            text: "preprocessing-CONTRACT"
        )
        var signature = assembled.tree.fileBytes[ModelBundleManifest.signatureFileName]!
        signature[3] ^= 0x01
        assembled.tree.overwriteContent(
            ModelBundleManifest.signatureFileName,
            bytes: signature
        )
        #expect(
            assembled.verificationFinding()
                == .manifestSignatureDidNotVerify(key: Sample.signingKey())
        )
    }

    // MARK: Canonicalization profile

    @Test("An unapproved canonicalization correspondence is refused")
    func unapprovedCanonicalizationRefused() throws {
        let assembled = try BundleAssembler.standard(canonicalizationApproval: .rejected)
        #expect(
            assembled.verificationFinding()
                == .canonicalizationProfileNotApproved(
                    Sample.artifact("evidence.canonicalization")
                )
        )
    }

    @Test("A policy naming a profile this build does not implement is refused")
    func profileMismatchRefused() throws {
        var assembled = try BundleAssembler.standard()
        assembled.canonicalization = ApprovedCanonicalizationProfile(
            profile: Sample.evidence("evidence.canonicalization-v2"),
            construction: .sortedKindTaggedRecords,
            approval: Sample.approval()
        )
        #expect(
            assembled.verificationFinding()
                == .canonicalizationProfileMismatch(
                    policyProfile: Sample.artifact("evidence.canonicalization"),
                    buildProfile: Sample.artifact("evidence.canonicalization-v2")
                )
        )
    }

    @Test("A profile reference matching by name but not by content digest is refused")
    func profileContentDigestMustMatch() throws {
        var assembled = try BundleAssembler.standard()
        assembled.canonicalization = ApprovedCanonicalizationProfile(
            profile: Sample.evidence(
                "evidence.canonicalization",
                contentDigest: Sample.digest("4")
            ),
            construction: .sortedKindTaggedRecords,
            approval: Sample.approval()
        )
        guard case .canonicalizationProfileMismatch = assembled.verificationFinding() else {
            Issue.record("expected a canonicalization mismatch")
            return
        }
    }

    @Test("The canonicalization check runs before the manifest is read")
    func canonicalizationPrecedesReading() throws {
        var assembled = try BundleAssembler.standard(canonicalizationApproval: .rejected)
        assembled.tree.enumerationFault = .storeUnavailable
        #expect(
            assembled.verificationFinding()
                == .canonicalizationProfileNotApproved(
                    Sample.artifact("evidence.canonicalization")
                )
        )
    }
}
