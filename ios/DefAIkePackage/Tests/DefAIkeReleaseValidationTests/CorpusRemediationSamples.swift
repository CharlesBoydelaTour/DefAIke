import DefAIkeDomain
import Foundation

@testable import DefAIkeReleaseValidation

// Synthetic corpus-remediation samples.
//
// Every value here is invented. None of these is a real corpus, a real identifier collision, a
// real duplicate classification, a real retention decision, or a real approval: the tests build
// a structurally complete remediation and then change exactly one thing to check that the run
// refuses it. Nothing in this file encodes a legal, data-rights, governance, device, or fusion
// conclusion, and the classification identifiers are deliberately shaped like placeholders for
// a decision rather than like a taxonomy anyone should adopt.
//
// The synthetic corpus is laid out to make the one genuinely hard case reachable. Requirements
// 14.7 and 14.8 intersect where a colliding identifier sits over a shared content digest: there
// the recorded data cannot say which copy a comparison measured, and only an approved
// attribution can. So collision group 00 is also duplicate group 0, and two comparison
// artifacts each hold one record that lands on it.
//
//   * 13 collision groups, two origins each (26 entries). Group 00's two entries share a digest;
//     the other twelve groups' entries do not.
//   * 3 further duplicate-hash pairs whose identifiers do not collide, so digest agreement alone
//     resolves any comparison against them.
//   * 4 entries with a unique identifier and a unique digest.
//
// That is exactly 13 colliding identifiers and exactly 4 duplicated digests, which is what the
// requirements fix and what the remediator reconciles against.

enum CorpusSample {
    // MARK: Identity

    static let corpusIdentifier = "corpus.rewind"
    static let manifestIdentifier = "manifest.rewind.pre-correction"
    static let correctionIdentifier = "correction.rewind.identifiers"
    static let dispositionIdentifier = "disposition.rewind.duplicate-hashes"
    static let ruleIdentifier = "rule.rewind.corrected-identifier"
    static let regeneratedIdentifier = "evidence.rewind.regenerated"
    static let parityComparisonIdentifier = "comparison.rewind.parity"
    static let sliceComparisonIdentifier = "comparison.rewind.slice"

    static var corpus: ArtifactID { Sample.artifact(corpusIdentifier) }
    static var parityComparison: ArtifactID { Sample.artifact(parityComparisonIdentifier) }
    static var sliceComparison: ArtifactID { Sample.artifact(sliceComparisonIdentifier) }

    static func entryID(_ value: String) -> CorpusEntryID {
        CorpusEntryID(value)!
    }

    static func classification(_ value: String) -> DuplicateClassificationID {
        DuplicateClassificationID(value)!
    }

    // MARK: The synthetic corpus layout

    static let collisionGroupCount = 13

    /// The digest both copies in collision group 00 share.
    static var sharedCollisionDigest: DefAIkeDomain.SHA256Digest { Sample.digest(0x1000) }

    static func group(_ index: Int) -> String { String(format: "%02d", index) }

    static func collidingIdentifier(_ index: Int) -> CorpusEntryID {
        entryID("collide.\(group(index))")
    }

    static func collisionOriginA(_ index: Int) -> CanonicalRelativePath {
        Sample.path("archive/a\(group(index))/src.jpg")
    }

    static func collisionOriginB(_ index: Int) -> CanonicalRelativePath {
        Sample.path("archive/b\(group(index))/src.jpg")
    }

    static func collisionDigestA(_ index: Int) -> DefAIkeDomain.SHA256Digest {
        index == 0 ? sharedCollisionDigest : Sample.digest(0x1100 + index * 2)
    }

    static func collisionDigestB(_ index: Int) -> DefAIkeDomain.SHA256Digest {
        index == 0 ? sharedCollisionDigest : Sample.digest(0x1100 + index * 2 + 1)
    }

    /// The digest shared by one of the three non-colliding duplicate pairs.
    static func pairDigest(_ index: Int) -> DefAIkeDomain.SHA256Digest {
        Sample.digest(0x2000 + index)
    }

    static func pairOrigin(_ index: Int, first: Bool) -> CanonicalRelativePath {
        Sample.path("archive/dup\(index)/\(first ? "first" : "second").jpg")
    }

    static func pairIdentifier(_ index: Int, first: Bool) -> CorpusEntryID {
        entryID("unique.dup\(index).\(first ? "first" : "second")")
    }

    static func plainOrigin(_ index: Int) -> CanonicalRelativePath {
        Sample.path("archive/plain\(index)/src.jpg")
    }

    static func plainIdentifier(_ index: Int) -> CorpusEntryID {
        entryID("unique.plain\(index)")
    }

    static func plainDigest(_ index: Int) -> DefAIkeDomain.SHA256Digest {
        Sample.digest(0x3000 + index)
    }

    /// Every entry of the structurally complete synthetic corpus.
    static func entries() -> [CorpusEntryRecord] {
        var records: [CorpusEntryRecord] = []
        for index in 0..<collisionGroupCount {
            records.append(
                CorpusEntryRecord(
                    origin: collisionOriginA(index),
                    recordedIdentifier: collidingIdentifier(index),
                    contentDigest: collisionDigestA(index)
                )
            )
            records.append(
                CorpusEntryRecord(
                    origin: collisionOriginB(index),
                    recordedIdentifier: collidingIdentifier(index),
                    contentDigest: collisionDigestB(index)
                )
            )
        }
        for index in 1...3 {
            for first in [true, false] {
                records.append(
                    CorpusEntryRecord(
                        origin: pairOrigin(index, first: first),
                        recordedIdentifier: pairIdentifier(index, first: first),
                        contentDigest: pairDigest(index)
                    )
                )
            }
        }
        for index in 1...4 {
            records.append(
                CorpusEntryRecord(
                    origin: plainOrigin(index),
                    recordedIdentifier: plainIdentifier(index),
                    contentDigest: plainDigest(index)
                )
            )
        }
        return records
    }

    // MARK: The pre-correction inventory

    static func manifest(
        identifier: String = manifestIdentifier,
        entries replacement: [CorpusEntryRecord]? = nil,
        source: EvidenceSource? = nil,
        corpus corpusOverride: ArtifactID? = nil
    ) throws -> EvaluationCorpusManifest {
        try EvaluationCorpusManifest(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            corpus: corpusOverride ?? corpus,
            source: source ?? Sample.evidence(identifier),
            entries: replacement ?? entries()
        )
    }

    // MARK: The approved correction (Requirement 14.7)

    static func correctedIdentifier(_ index: Int, first: Bool) -> CorpusEntryID {
        entryID("collide.\(group(index)).\(first ? "a" : "b")")
    }

    /// One correction entry per origin in every collision group.
    static func corrections() -> [CorpusIdentifierCorrectionEntry] {
        (0..<collisionGroupCount).flatMap { index in
            [
                CorpusIdentifierCorrectionEntry(
                    origin: collisionOriginA(index),
                    collidingIdentifier: collidingIdentifier(index),
                    correctedIdentifier: correctedIdentifier(index, first: true)
                ),
                CorpusIdentifierCorrectionEntry(
                    origin: collisionOriginB(index),
                    collidingIdentifier: collidingIdentifier(index),
                    correctedIdentifier: correctedIdentifier(index, first: false)
                ),
            ]
        }
    }

    /// The two attributions the ambiguous comparisons need.
    static func reattributions() -> [CorpusComparisonReattribution] {
        [
            CorpusComparisonReattribution(
                comparison: parityComparison,
                recordedIdentifier: collidingIdentifier(0),
                measuredContentDigest: sharedCollisionDigest,
                origin: collisionOriginA(0)
            ),
            CorpusComparisonReattribution(
                comparison: sliceComparison,
                recordedIdentifier: collidingIdentifier(0),
                measuredContentDigest: sharedCollisionDigest,
                origin: collisionOriginB(0)
            ),
        ]
    }

    static func correction(
        identifier: String = correctionIdentifier,
        corrections replacement: [CorpusIdentifierCorrectionEntry]? = nil,
        reattributions attributionsOverride: [CorpusComparisonReattribution]? = nil,
        subject: EvidenceSource? = nil,
        source: EvidenceSource? = nil,
        corpus corpusOverride: ArtifactID? = nil,
        approval decision: ApprovalDecision = .approved
    ) throws -> CorpusIdentifierCorrection {
        try CorpusIdentifierCorrection(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            corpus: corpusOverride ?? corpus,
            source: source ?? Sample.evidence(identifier),
            subject: subject ?? Sample.evidence(manifestIdentifier),
            correctedIdentifierRule: Sample.evidence(ruleIdentifier),
            corrections: replacement ?? corrections(),
            comparisonReattributions: attributionsOverride ?? reattributions(),
            approval: Sample.approval(decision, identifier: "approval.corpus.correction")
        )
    }

    // MARK: The approved duplicate-hash disposition (Requirement 14.8)

    /// The four dispositions, deliberately exercising all three retention shapes: keep one
    /// copy, keep both, keep neither. All three are decisions a release owner can record, and
    /// the tooling narrows none of them.
    static func dispositions() throws -> [DuplicateHashDisposition] {
        [
            try DuplicateHashDisposition(
                contentDigest: sharedCollisionDigest,
                origins: [collisionOriginA(0), collisionOriginB(0)],
                classification: classification("classification.sample.alpha"),
                retainedOrigins: [collisionOriginA(0)],
                source: Sample.evidence(dispositionIdentifier)
            ),
            try DuplicateHashDisposition(
                contentDigest: pairDigest(1),
                origins: [pairOrigin(1, first: true), pairOrigin(1, first: false)],
                classification: classification("classification.sample.beta"),
                retainedOrigins: [pairOrigin(1, first: true)],
                source: Sample.evidence(dispositionIdentifier)
            ),
            try DuplicateHashDisposition(
                contentDigest: pairDigest(2),
                origins: [pairOrigin(2, first: true), pairOrigin(2, first: false)],
                classification: classification("classification.sample.gamma"),
                retainedOrigins: [pairOrigin(2, first: true), pairOrigin(2, first: false)],
                source: Sample.evidence(dispositionIdentifier)
            ),
            try DuplicateHashDisposition(
                contentDigest: pairDigest(3),
                origins: [pairOrigin(3, first: true), pairOrigin(3, first: false)],
                classification: classification("classification.sample.delta"),
                retainedOrigins: [],
                source: Sample.evidence(dispositionIdentifier)
            ),
        ]
    }

    static func disposition(
        identifier: String = dispositionIdentifier,
        dispositions replacement: [DuplicateHashDisposition]? = nil,
        subject: EvidenceSource? = nil,
        source: EvidenceSource? = nil,
        corpus corpusOverride: ArtifactID? = nil,
        approval decision: ApprovalDecision = .approved
    ) throws -> DuplicateHashDispositionRecord {
        try DuplicateHashDispositionRecord(
            id: Sample.artifact(identifier),
            schemaVersion: .v1,
            corpus: corpusOverride ?? corpus,
            source: source ?? Sample.evidence(identifier),
            subject: subject ?? Sample.evidence(manifestIdentifier),
            dispositions: replacement ?? (try dispositions()),
            approval: Sample.approval(decision, identifier: "approval.corpus.disposition")
        )
    }

    // MARK: The affected comparisons

    static func outcomeDigest(_ index: Int) -> DefAIkeDomain.SHA256Digest {
        Sample.digest(0x4000 + index)
    }

    static func comparison(
        _ artifact: ArtifactID,
        identifier: CorpusEntryID,
        measured: DefAIkeDomain.SHA256Digest,
        outcome: Int,
        source: EvidenceSource? = nil
    ) -> CorpusComparisonRecord {
        CorpusComparisonRecord(
            comparison: artifact,
            recordedIdentifier: identifier,
            measuredContentDigest: measured,
            outcomeDigest: outcomeDigest(outcome),
            source: source ?? Sample.evidence(artifact.rawValue)
        )
    }

    /// The complete affected comparison set.
    ///
    /// Nineteen records resolve by digest agreement alone; two — one per comparison artifact —
    /// land on collision group 00 over the shared digest and cannot.
    static func comparisons() -> [CorpusComparisonRecord] {
        var records: [CorpusComparisonRecord] = []
        for index in 1..<collisionGroupCount {
            records.append(
                comparison(
                    parityComparison,
                    identifier: collidingIdentifier(index),
                    measured: collisionDigestA(index),
                    outcome: index
                )
            )
        }
        records.append(
            comparison(
                parityComparison,
                identifier: collidingIdentifier(0),
                measured: sharedCollisionDigest,
                outcome: 0
            )
        )
        for first in [true, false] {
            records.append(
                comparison(
                    parityComparison,
                    identifier: pairIdentifier(1, first: first),
                    measured: pairDigest(1),
                    outcome: first ? 0x21 : 0x22
                )
            )
        }
        for index in 1...4 {
            records.append(
                comparison(
                    parityComparison,
                    identifier: plainIdentifier(index),
                    measured: plainDigest(index),
                    outcome: 0x30 + index
                )
            )
        }
        records.append(
            comparison(
                sliceComparison,
                identifier: collidingIdentifier(0),
                measured: sharedCollisionDigest,
                outcome: 0x40
            )
        )
        return records
    }
}

// MARK: - The approved-record reader

/// An in-memory reader for the two approved records.
///
/// Deliberately capable of holding *nothing*, because the absent-record path is the behavior
/// Requirements 14.7 and 14.8 turn on. It cannot draft, complete, or default a record: the only
/// thing it can do when a record is absent is report which fault made it absent.
struct FakeApprovedCorpusRecords: ApprovedCorpusRemediationReading {
    var correction: CorpusIdentifierCorrection?
    var correctionFault: ApprovedCorpusRecordFault = .recordAbsent
    var disposition: DuplicateHashDispositionRecord?
    var dispositionFault: ApprovedCorpusRecordFault = .recordAbsent

    func identifierCorrection(
        forCorpus corpus: ArtifactID
    ) throws(ApprovedCorpusRecordFault) -> CorpusIdentifierCorrection {
        guard let correction else { throw correctionFault }
        return correction
    }

    func duplicateHashDisposition(
        forCorpus corpus: ArtifactID
    ) throws(ApprovedCorpusRecordFault) -> DuplicateHashDispositionRecord {
        guard let disposition else { throw dispositionFault }
        return disposition
    }

    /// A reader holding both approved records.
    static func complete(
        correction: CorpusIdentifierCorrection? = nil,
        disposition: DuplicateHashDispositionRecord? = nil
    ) throws -> FakeApprovedCorpusRecords {
        FakeApprovedCorpusRecords(
            correction: try correction ?? CorpusSample.correction(),
            disposition: try disposition ?? CorpusSample.disposition()
        )
    }
}

extension CorpusSample {
    /// A remediator over both approved records.
    static func remediator(
        correction: CorpusIdentifierCorrection? = nil,
        disposition: DuplicateHashDispositionRecord? = nil
    ) throws -> CorpusRemediator {
        CorpusRemediator(
            records: try FakeApprovedCorpusRecords.complete(
                correction: correction,
                disposition: disposition
            )
        )
    }

    /// One complete remediation of the structurally complete synthetic corpus.
    static func remediation(
        correction: CorpusIdentifierCorrection? = nil,
        disposition: DuplicateHashDispositionRecord? = nil,
        manifest manifestOverride: EvaluationCorpusManifest? = nil,
        comparisons comparisonsOverride: [CorpusComparisonRecord]? = nil,
        publishingAs identifier: String = regeneratedIdentifier
    ) throws -> CorpusRemediation {
        try remediator(correction: correction, disposition: disposition)
            .remediate(
                manifestOverride ?? (try manifest()),
                comparisons: comparisonsOverride ?? comparisons(),
                publishingAs: Sample.artifact(identifier),
                schemaVersion: .v1
            )
    }
}
