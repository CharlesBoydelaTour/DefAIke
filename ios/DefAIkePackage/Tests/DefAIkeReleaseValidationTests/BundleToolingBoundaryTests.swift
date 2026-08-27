import Foundation
import Testing

@testable import DefAIkeModelBundle
@testable import DefAIkeReleaseValidation

/// What the release-tooling module cannot do, asserted against its sources.
///
/// Task 14.5 has two fail-closed constraints that are not statements about behavior at all —
/// they are statements about reachability. "Selects no signing key" and "declares no
/// governance approval" cannot be demonstrated by calling something and observing that it did
/// not happen, because the interesting failure is a *future* change that adds the capability.
/// So they are checked the way `ActivationAndRollbackTests.moduleHasNoModelUpdateChannel`
/// checks the absence of a model-update channel: by scanning the module's own sources for the
/// vocabulary the capability would need.
///
/// Comments are stripped before every scan. The module's documentation discusses the absence
/// of these things by name, and a naive substring match would flag that prose.
@Suite("Release tooling boundary")
struct BundleToolingBoundaryTests {
    // MARK: - No key store, no signing

    @Test("Nothing in the module can reach key material or produce a signature")
    func moduleCannotReachAKeyStoreOrSign() throws {
        // A signing key is an approved decision under approved custody. This module is handed
        // one *identity* and emits a request; producing a signature would need one of the
        // tokens below, so a change that reaches for key custody, a private key, or a
        // signing primitive fails here rather than in review.
        let forbidden = [
            "SecKey", "SecItem", "kSecClass", "SecRandom", "Keychain", "keychain",
            "privateKey", "PrivateKey", "secretKey", "SecretKey",
            "publicKeyMaterial", "keyMaterial", "func sign(", ".sign(", "signingIdentity",
            "Curve25519", "P256", "P384", "_RSA", "SigningKeyStore", "keyStore",
        ]
        for file in try Self.moduleSourceFiles() {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for token in forbidden {
                #expect(
                    !code.contains(token),
                    "\(file.lastPathComponent) must not reference \(token)"
                )
            }
        }
    }

    @Test("Nothing in the module can mint, amend, or assert a governance approval")
    func moduleCannotMintAnApproval() throws {
        // Presence is not approval, and this module can only ever *read* one: an approval
        // record arrives inside an approved input, `isApproved` is consulted, and a rejection
        // stops the build. Constructing an `ApprovalRecord`, naming an `ApprovalDecision`, or
        // writing an applicability decision would all be this module supplying a conclusion
        // that belongs to a release owner.
        //
        // `ApprovalDecision` is spelled out as a construction or a literal rather than bare,
        // because the bare word occurs legitimately as the payload of one refusal case:
        // `NonImportableManualEvidence.authorizationDecisionIsNotApproved(ApprovalDecision)`
        // *reports* the decision a run read on an imported authorization. Naming the decision it
        // refused is the opposite of minting one, and the narrower tokens still catch every way a
        // module could supply a decision of its own.
        let forbidden = [
            "ApprovalRecord(", "ApprovalDecision(", "ApprovalDecision.approved",
            "ApprovalDecision.rejected", "decision: .", "notApplicable(",
            "GateApplicability(", "isApproved =",
        ]
        for file in try Self.moduleSourceFiles() {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            for token in forbidden {
                #expect(
                    !code.contains(token),
                    "\(file.lastPathComponent) must not reference \(token)"
                )
            }
        }
    }

    @Test("The key-governance seam offers nothing to choose among and no key material")
    func keyGovernanceSeamHasNothingToSelectFrom() throws {
        // The port-level form of "selects no signing key": a member that listed, ranked, or
        // preferred keys would be visible here as a declaration, and so would one that
        // returned material or a signature.
        let code = Self.strippingComments(try Self.moduleSource(named: "BundleBuildSeams.swift"))
        for token in [
            "func trustedKeys", "func availableKeys", "func allKeys", "func keys",
            "func preferredKey", "func selectKey", "func chooseKey", "func publicKey",
            "func privateKey", "func sign", "func approve", "func record",
            "-> [SigningKeyID]", "-> Set<SigningKeyID>",
        ] {
            #expect(!code.contains(token), "the key-governance seam must not declare \(token)")
        }
        // And exactly one member, which returns one designation.
        #expect(
            code.contains("func designatedSigningKey(\n        forBundle bundle: ModelBundleID\n    ) throws(KeyGovernanceFault) -> DesignatedReleaseSigningKey")
        )
    }

    @Test("The measurement seam cannot write and this module holds no digest of its own")
    func measurementSeamIsReadOnlyAndTheModuleComputesNoDigest() throws {
        // Two claims in one scan. The seam is read-only, so a staged artifact the build cannot
        // measure has exactly one outcome available to it — a finding. And the deterministic
        // tree-digest construction has one implementation, in `DefAIkeModelBundle`: the
        // bundle-tooling sources name the construction they were told to use and compute
        // nothing, so there is no second authority on what a signed digest means.
        let seam = Self.strippingComments(try Self.moduleSource(named: "BundleBuildSeams.swift"))
        for token in ["func write", "func create", "func stage", "func emit", "func delete", "URL"] {
            #expect(!seam.contains(token), "the measurement seam must not declare \(token)")
        }

        // The tooling *carries* `SHA256Digest` values everywhere; what it must never do is
        // produce one. So the scan names the ways a digest gets computed rather than the type
        // that holds the result.
        for name in Self.bundleToolingSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "CryptoKit", "StreamingSHA256", "SHA256.hash", "SHA256(", "Insecure.",
                "Hasher(", "hasher", ".finalize()", "BundleTreeDigest.", "sortedKindTaggedRecords",
            ] {
                #expect(!code.contains(token), "\(name) must not compute a digest (\(token))")
            }
        }
    }

    // MARK: - No gate outcome can be handed in

    @Test("Only the recorder can construct a gate record")
    func evidenceRecordsAreNotClientConstructible() throws {
        // "Generated, not asserted" is structural: the three record types have module-internal
        // initializers, so no caller outside `DefAIkeReleaseValidation` can hand in a
        // `GateOutcome`. The only public initializer in the file is the recorder's, and it
        // takes the runtime's verifiers rather than any outcome.
        let code = Self.strippingComments(
            try Self.moduleSource(named: "BundleReleaseEvidence.swift")
        )
        let publicInitializers = code.components(separatedBy: "public init").count - 1
        #expect(publicInitializers == 1, "only the recorder may have a public initializer")
        #expect(code.contains("public init(\n        integrity: ModelBundleIntegrityVerifier,"))

        let internalInitializers = code.components(separatedBy: "\n    init(").count - 1
        #expect(internalInitializers == 3, "the three record types keep module-internal initializers")
    }

    @Test("The signing request cannot be constructed outside the module")
    func signingRequestIsNotClientConstructible() throws {
        // A client that could build its own `BundleSigningRequest` could name a key the
        // approved record did not designate. The produced values therefore keep
        // module-internal initializers too, and the request is only ever handed back by a
        // build that read the governance record.
        let code = Self.strippingComments(
            try Self.moduleSource(named: "InitialModelBundleBuild.swift")
        )
        for declaration in [
            "public struct BundleSigningRequest",
            "public struct UnsignedInitialModelBundle",
            "public struct CanonicalBundleTreePlan",
            "public struct PlannedBundleEntry",
        ] {
            #expect(code.contains(declaration))
        }
        // One public initializer in the file: the request type the caller supplies.
        let publicInitializers = code.components(separatedBy: "public init").count - 1
        #expect(publicInitializers == 1, "only the build request may be client-constructible")
        #expect(code.contains("public init(\n        bundleID: ModelBundleID,"))
    }

    // MARK: - Scope

    @Test("The bundle tooling claims no archive, dependency, privacy, or network audit")
    func moduleDoesNotReachIntoTheAdjacentAudit() throws {
        // Task 14.6 owns the Software Bill of Materials, forbidden-SDK, endpoint, and export
        // surfaces. The notice set here deliberately takes the dependency list as an approved
        // input and reconciles it against nothing, so this module cannot appear to have
        // audited an archive it never read.
        //
        // Scoped to ``bundleToolingSources`` rather than the whole module, for the same reason
        // the "computes no digest" scan above is: 14.6's archive audit now lives in this module
        // and *legitimately* declares `SoftwareBillOfMaterials` in `ArchiveAuditInputs.swift`
        // and models it in `ArchiveAudit.swift` and `ArchiveAuditError.swift`. Modelling that
        // type is 14.6's job, so a module-wide scan is the wrong instrument for a claim about
        // 14.5's files — it would report 14.6 doing its work as a boundary breach. The claim
        // this test exists to make is that the *bundle-tooling* sources do not reach into the
        // adjacent audit, and naming them keeps the claim exactly as strong as it is true.
        #expect(
            !Self.bundleToolingSources.isEmpty,
            "the bundle-tooling file list must be non-empty for this scan to mean anything"
        )
        for name in Self.bundleToolingSources {
            // `moduleSource(named:)` requires the file to exist, so a renamed or deleted
            // bundle-tooling source fails here rather than silently emptying the scan.
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "SoftwareBillOfMaterials", "sbom", "SBOM", "forbiddenSDK", "ForbiddenSDK",
                "networkEndpoint", "exportCompliance", "URLSession", "import Network",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    // MARK: - Helpers

    /// The sources this task added, for scans whose claim is about 14.5's files rather than the
    /// module as a whole.
    ///
    /// `FixtureCatalogVerifier` legitimately hashes a fixture asset with CryptoKit, so a
    /// module-wide "computes no digest" scan would be false; 14.6's `ArchiveAudit*.swift`
    /// legitimately declares and models `SoftwareBillOfMaterials`, so a module-wide "claims no
    /// archive audit" scan would be false too. Naming the bundle-tooling files keeps both
    /// claims exactly as strong as they are true.
    static let bundleToolingSources = [
        "BundleBuildSeams.swift",
        "BundleBuildError.swift",
        "ApprovedBundleNotices.swift",
        "InitialModelBundleBuild.swift",
        "InitialModelBundleBuilder.swift",
        "BundleReleaseEvidence.swift",
        "CanonicalArtifactEncoding.swift",
    ]

    private static func moduleSourceFiles() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DefAIkeReleaseValidation")
        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "the module's sources must be readable for this to mean anything")
        return files
    }

    private static func moduleSource(named name: String) throws -> String {
        let file = try #require(try moduleSourceFiles().first { $0.lastPathComponent == name })
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Removes `//` comment text so a scan reads code rather than documentation.
    ///
    /// No source in this module puts `//` inside a string literal, and the scan asserts the
    /// absence of exactly the tokens that would appear in one, so a simple split is enough and
    /// its failure mode is a false pass on a file that does not exist — which
    /// ``moduleSourceFiles()`` and ``moduleSource(named:)`` both refuse.
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let marker = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<marker.lowerBound])
            }
            .joined(separator: "\n")
    }
}
