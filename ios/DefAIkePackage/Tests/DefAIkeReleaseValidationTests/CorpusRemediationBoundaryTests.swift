import Foundation
import Testing

@testable import DefAIkeReleaseValidation

/// What the corpus tooling cannot do, asserted against its sources.
///
/// Requirements 14.7 and 14.8 reserve two decisions for a release owner, and Requirement 14.4
/// reserves a third. "Chooses no duplicate classification" and "reaches no distribution-rights
/// conclusion" cannot be demonstrated by calling something and observing that it did not happen,
/// because the interesting failure is a *future* change that adds the capability. So they are
/// checked the way ``BundleToolingBoundaryTests`` checks the absence of a key store: by scanning
/// the tooling's own sources for the vocabulary the capability would need.
///
/// Comments are stripped before every scan. The sources discuss the absence of these things by
/// name, and a naive substring match would flag that prose.
@Suite("Corpus remediation boundary")
struct CorpusRemediationBoundaryTests {
    /// The sources this task added.
    static let corpusSources = [
        "CorpusRemediationInputs.swift",
        "CorpusRemediationError.swift",
        "CorpusRemediationSeams.swift",
        "CorpusRemediation.swift",
    ]

    // MARK: - No decision the requirements reserve

    @Test("Nothing in the corpus tooling can reach a distribution-rights conclusion")
    func toolingReachesNoRightsConclusion() throws {
        // Requirement 14.4 blocks a distribution while code rights or data-distribution rights
        // are unresolved, and Requirement 14.15 decides what a missing entry means. Both live in
        // the release-readiness record. A relabelling tool that named a licence, a set of terms,
        // or a publication permission would be answering a legal question it cannot see the
        // inputs to, so a change that reaches for one fails here rather than in review.
        for name in Self.corpusSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "licen", "Licen", "DistributionRights", "distributionRights",
                "dataRights", "DataRights", "copyright", "Copyright", "termsOfUse",
                "publishable", "Publishable", "mayPublish", "mayDistribute",
                "isDistributable", "blocksDistribution", "redistribut", "isReleaseReady",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    @Test("Nothing in the corpus tooling can choose a duplicate classification")
    func toolingChoosesNoClassification() throws {
        // The classification vocabulary belongs to the approved record. A case this module could
        // spell is a case it could select, so no source may hold a classification literal, a
        // comparison against one, or a member that produces one.
        for name in Self.corpusSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "DuplicateClassificationID(", "static let classification",
                "func classify", "classification ==", "classification !=",
                "exactDuplicate", "nearDuplicate", "benign", "harmful",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    @Test("The classification identifier declares no constant, the way a status key declares none")
    func classificationTypeDeclaresNoConstant() throws {
        // `ProvenanceValidatorStatusID` declares no constant so that a status the approved policy
        // does not map is a policy gap rather than something code interprets. The same reasoning
        // applies here, and it is only true while the type's first member is its stored value.
        let code = Self.strippingComments(
            try Self.moduleSource(named: "CorpusRemediationInputs.swift")
        )
        #expect(
            code.contains(
                "public struct DuplicateClassificationID: CanonicalIdentifier {\n"
                    + "    public let rawValue: String"
            ),
            "the classification identifier must declare its stored value and nothing before it"
        )
    }

    @Test("Nothing in the corpus tooling can derive a corrected identifier")
    func toolingDerivesNoIdentifier() throws {
        // The corrected identifier rule is *named* and carried into provenance; it is never
        // executed. A member that formed an identifier from a path, a stem, a digest, or a
        // counter would make the tool the author of the correction, so the vocabulary such a
        // member would need is absent. Looking one up is not deriving one, which is why
        // `CorpusRemediation.correctedIdentifier(at:)` is a lookup over values already read.
        for name in Self.corpusSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "func deriveIdentifier", "func makeIdentifier", "func nextIdentifier",
                "func stem", "func rename", "func disambiguate", "func preferred",
                "CorpusEntryID(\"", "appending(\"", "suffix:", "+ suffix",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    @Test("Nothing in the corpus tooling can read or alter a recorded measurement")
    func toolingNeverTouchesAMeasurement() throws {
        // Regeneration is relabelling. A comparison's outcome travels through as an opaque
        // digest, and a module that cannot read a measurement cannot adjust one. Any digest
        // computation counts: a recomputed outcome digest would be a new measurement.
        for name in Self.corpusSources {
            let code = Self.strippingComments(try Self.moduleSource(named: name))
            for token in [
                "CryptoKit", "SHA256.hash", "Insecure.", ".finalize()", "Hasher(",
                "func measure", "func remeasure", "func recompute", "func score",
                "logit", "tolerance", "threshold", "Decimal",
            ] {
                #expect(!code.contains(token), "\(name) must not reference \(token)")
            }
        }
    }

    // MARK: - The seam has nothing to choose among

    @Test("The approved-record seam offers no default, no draft, and no alternatives")
    func seamOffersNothingToChooseFrom() throws {
        // The port-level form of the fail-closed requirement: a member that listed, drafted,
        // defaulted, or partially supplied a record would be visible here as a declaration.
        let code = Self.strippingComments(
            try Self.moduleSource(named: "CorpusRemediationSeams.swift")
        )
        for token in [
            "func availableCorrections", "func allCorrections", "func candidateCorrection",
            "func draftCorrection", "func defaultCorrection", "func provisional",
            "func classification", "func retainedOrigins", "func excluded",
            "func write", "func create", "func record", "func amend", "func approve",
            "-> [CorpusIdentifierCorrection]", "-> CorpusIdentifierCorrection?",
            "-> [DuplicateHashDispositionRecord]", "-> DuplicateHashDispositionRecord?",
            "= nil", "default", "extension ApprovedCorpusRemediationReading",
        ] {
            #expect(!code.contains(token), "the approved-record seam must not declare \(token)")
        }
        // Exactly two members, each returning one whole record for one corpus.
        #expect(code.components(separatedBy: "    func ").count - 1 == 2)
        #expect(code.contains("func identifierCorrection("))
        #expect(code.contains("func duplicateHashDisposition("))
        #expect(
            code.components(
                separatedBy: ") throws(ApprovedCorpusRecordFault) -> "
            ).count - 1 == 2
        )
    }

    @Test("No default reader exists anywhere in the module")
    func moduleShipsNoReaderImplementation() throws {
        // A remediator cannot be constructed without a reader, and this is the other half of
        // that: nothing in the shipping sources conforms to the seam, so there is no
        // implementation a caller could fall back to. The only conformer is in the tests.
        for file in try Self.moduleSourceFiles() {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            #expect(
                !code.contains(": ApprovedCorpusRemediationReading {"),
                "\(file.lastPathComponent) must not implement the approved-record seam"
            )
        }
    }

    // MARK: - Only a completed run can produce a remediation

    @Test("A remediation carries its uniqueness proof and cannot be assembled from outside")
    func remediationIsNotClientConstructible() throws {
        // Uniqueness is carried by the existence of the value, so a caller that could build its
        // own `CorpusRemediation` could present unverified evidence as verified. Every produced
        // type keeps a module-internal initializer, the only public one in the file is the
        // remediator's, and the result type is deliberately not `Codable`: a decodable result
        // would be a second way in.
        let code = Self.strippingComments(
            try Self.moduleSource(named: "CorpusRemediation.swift")
        )
        for declaration in [
            "public struct CorpusRemediation: Hashable, Sendable {",
            "public struct RegeneratedCorpusEvidence",
            "public struct ArchivalEvaluationManifest",
            "public struct RegeneratedComparison",
            "public struct CorrectedCorpusEntry",
            "public struct RemediationProvenance",
        ] {
            #expect(code.contains(declaration))
        }
        let publicInitializers = code.components(separatedBy: "public init").count - 1
        #expect(publicInitializers == 1, "only the remediator may be client-constructible")
        #expect(code.contains("public init(records: any ApprovedCorpusRemediationReading)"))
        #expect(!code.contains("public struct CorpusRemediation: Hashable, Codable"))
    }

    @Test("The remediator exposes one entry point and no way to waive a check")
    func remediatorTakesNoOverrides() throws {
        // Every parameter of the one entry point is an approved input or the identity the
        // regenerated evidence publishes under. A `skip`, `force`, `allow`, or `assume`
        // parameter would let a caller past the reconciliation that makes the result mean
        // anything, and a `GateOutcome` parameter would let one hand in a result.
        let code = Self.strippingComments(
            try Self.moduleSource(named: "CorpusRemediation.swift")
        )
        for token in [
            "skip", "force", "allowMissing", "assume", "waive", "override",
            "GateOutcome", "isApproved =", "ApprovalDecision",
        ] {
            #expect(!code.contains(token), "the remediator must not reference \(token)")
        }
        #expect(code.components(separatedBy: "public func remediate").count - 1 == 1)
    }

    // MARK: - Helpers

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
