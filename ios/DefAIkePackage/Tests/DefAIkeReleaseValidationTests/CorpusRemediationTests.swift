import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Corpus identifier remediation and evidence regeneration (Requirements 14.7 and 14.8).
//
// Each test builds the structurally complete synthetic remediation and changes exactly one
// thing: an absent record, a rejected approval, a miscounted defect, a correction that does not
// achieve uniqueness, a duplicate nobody classified, or an ambiguous comparison nobody
// attributed. The run has to refuse every one of them, because the alternative to refusing is a
// tool authoring the decision the requirement reserves for a release owner.
//
// Two whole families of test are deliberately absent, and their absence is the point: there is
// no test that a correction can be derived from the corrected identifier rule, and none that a
// duplicate can be classified from the data. Neither is reachable — no member exists to call.

@Suite("Corpus identifier remediation")
struct CorpusRemediationTests {
    // MARK: - A complete remediation

    @Test("A complete remediation corrects every collision and proves uniqueness")
    func completeRemediation() throws {
        let manifest = try CorpusSample.manifest()
        let remediation = try CorpusSample.remediation(manifest: manifest)

        // The corpus the requirements describe: 13 collisions, 4 duplicate hashes.
        #expect(manifest.collidingIdentifiers.count == CorpusRemediator.requiredCollisionCount)
        #expect(
            manifest.duplicatedContentDigests.count == CorpusRemediator.requiredDuplicateHashCount
        )

        // Uniqueness is what the value carries: one corrected identifier per entry.
        #expect(remediation.evidence.correctedEntries.count == manifest.entries.count)
        #expect(remediation.correctedIdentifiers.count == manifest.entries.count)

        // Both copies of every collision group were renamed, and nothing else was.
        #expect(remediation.correctedEntries.count == CorpusRemediator.requiredCollisionCount * 2)
        for entry in remediation.correctedEntries {
            #expect(manifest.collidingIdentifiers.contains(entry.previousIdentifier))
        }
    }

    @Test("Correction relabels and never re-measures")
    func correctionOnlyRelabels() throws {
        let manifest = try CorpusSample.manifest()
        let remediation = try CorpusSample.remediation(manifest: manifest)

        for corrected in remediation.evidence.correctedEntries {
            let original = try #require(manifest.entry(at: corrected.origin))
            #expect(corrected.contentDigest == original.contentDigest)
            #expect(corrected.previousIdentifier == original.recordedIdentifier)
        }
    }

    @Test("Regeneration carries every recorded outcome through unchanged")
    func regenerationPreservesOutcomes() throws {
        let comparisons = CorpusSample.comparisons()
        let remediation = try CorpusSample.remediation(comparisons: comparisons)

        #expect(remediation.evidence.regeneratedComparisons.count == comparisons.count)
        for regenerated in remediation.evidence.regeneratedComparisons {
            let original = try #require(
                comparisons.first {
                    $0.comparison == regenerated.comparison
                        && $0.recordedIdentifier == regenerated.recordedIdentifier
                        && $0.measuredContentDigest == regenerated.measuredContentDigest
                }
            )
            #expect(regenerated.outcomeDigest == original.outcomeDigest)
            #expect(regenerated.measuredContentDigest == original.measuredContentDigest)
        }
    }

    @Test("A comparison resolves by digest agreement wherever the data can distinguish it")
    func comparisonsResolveByDigestWhereverPossible() throws {
        let remediation = try CorpusSample.remediation()

        // The two records that land on the shared digest under a colliding identifier are the
        // only ones an approved attribution had to resolve.
        let attributed = remediation.comparisonsResolvedByApprovedAttribution
        #expect(attributed.count == 2)
        #expect(Set(attributed.map(\.comparison)).count == 2)
        for regenerated in attributed {
            #expect(regenerated.recordedIdentifier == CorpusSample.collidingIdentifier(0))
            #expect(regenerated.measuredContentDigest == CorpusSample.sharedCollisionDigest)
        }
        // Including the two records against a duplicate digest whose identifiers do not collide.
        #expect(remediation.evidence.regeneratedComparisons.count - attributed.count == 18)
    }

    @Test("Approved attributions send the two ambiguous records to different copies")
    func approvedAttributionsAreHonoured() throws {
        let remediation = try CorpusSample.remediation()
        let attributed = remediation.comparisonsResolvedByApprovedAttribution

        let parity = try #require(
            attributed.first { $0.comparison == CorpusSample.parityComparison }
        )
        let slice = try #require(
            attributed.first { $0.comparison == CorpusSample.sliceComparison }
        )
        #expect(parity.origin == CorpusSample.collisionOriginA(0))
        #expect(slice.origin == CorpusSample.collisionOriginB(0))
        #expect(parity.correctedIdentifier == CorpusSample.correctedIdentifier(0, first: true))
        #expect(slice.correctedIdentifier == CorpusSample.correctedIdentifier(0, first: false))
    }

    // MARK: - Immutable provenance

    @Test("Every regenerated artifact carries the identifiers and versions it came from")
    func provenanceNamesEverySource() throws {
        let manifest = try CorpusSample.manifest()
        let remediation = try CorpusSample.remediation(manifest: manifest)
        let provenance = remediation.provenance

        #expect(provenance.corpus == CorpusSample.corpus)
        #expect(provenance.subjectManifest == manifest.source)
        #expect(
            provenance.identifierCorrection.artifact
                == Sample.artifact(CorpusSample.correctionIdentifier)
        )
        #expect(
            provenance.correctedIdentifierRule.artifact
                == Sample.artifact(CorpusSample.ruleIdentifier)
        )
        #expect(
            provenance.duplicateHashDisposition.artifact
                == Sample.artifact(CorpusSample.dispositionIdentifier)
        )
        // One entry per comparison artifact, each with a version and a content digest.
        #expect(provenance.regeneratedComparisons.count == 2)
        #expect(
            Set(provenance.regeneratedComparisons.map(\.artifact))
                == [CorpusSample.parityComparison, CorpusSample.sliceComparison]
        )
    }

    @Test("A record whose provenance names another artifact is refused")
    func recordProvenanceMustNameItself() throws {
        #expect(
            throws: CorpusRemediationError.provenanceDoesNotNameItsRecord(
                record: Sample.artifact(CorpusSample.correctionIdentifier),
                named: Sample.artifact("some.other.artifact")
            )
        ) {
            try CorpusSample.correction(source: Sample.evidence("some.other.artifact"))
        }
        #expect(
            throws: CorpusRemediationError.provenanceDoesNotNameItsRecord(
                record: Sample.artifact(CorpusSample.dispositionIdentifier),
                named: Sample.artifact("some.other.artifact")
            )
        ) {
            try CorpusSample.disposition(source: Sample.evidence("some.other.artifact"))
        }
    }

    @Test("Comparison records mixing two versions of one artifact are refused")
    func mixedComparisonVersionsRefused() throws {
        var comparisons = CorpusSample.comparisons()
        let restated = EvidenceSource(
            artifact: CorpusSample.parityComparison,
            version: Sample.version("2.0.0"),
            contentDigest: Sample.digest(0xE1)
        )
        comparisons[0] = CorpusSample.comparison(
            CorpusSample.parityComparison,
            identifier: comparisons[0].recordedIdentifier,
            measured: comparisons[0].measuredContentDigest,
            outcome: 1,
            source: restated
        )

        #expect(
            throws: CorpusRemediationError.comparisonSourceVersionsMixed(
                comparison: CorpusSample.parityComparison,
                first: Sample.version(),
                second: Sample.version("2.0.0")
            )
        ) {
            try CorpusSample.remediation(comparisons: comparisons)
        }
    }

    // MARK: - Missing approved input is a failure, not a default

    @Test("A run without an approved correction fails and derives nothing")
    func absentCorrectionFailsClosed() throws {
        for fault in ApprovedCorpusRecordFault.allCases {
            let records = FakeApprovedCorpusRecords(
                correction: nil,
                correctionFault: fault,
                disposition: try CorpusSample.disposition()
            )
            #expect(
                throws: CorpusRemediationError.identifierCorrectionMissing(
                    corpus: CorpusSample.corpus,
                    fault: fault
                )
            ) {
                try CorpusRemediator(records: records).remediate(
                    try CorpusSample.manifest(),
                    comparisons: CorpusSample.comparisons(),
                    publishingAs: Sample.artifact(CorpusSample.regeneratedIdentifier),
                    schemaVersion: .v1
                )
            }
        }
    }

    @Test("A run without an approved duplicate disposition fails and classifies nothing")
    func absentDispositionFailsClosed() throws {
        for fault in ApprovedCorpusRecordFault.allCases {
            let records = FakeApprovedCorpusRecords(
                correction: try CorpusSample.correction(),
                disposition: nil,
                dispositionFault: fault
            )
            #expect(
                throws: CorpusRemediationError.duplicateDispositionMissing(
                    corpus: CorpusSample.corpus,
                    fault: fault
                )
            ) {
                try CorpusRemediator(records: records).remediate(
                    try CorpusSample.manifest(),
                    comparisons: CorpusSample.comparisons(),
                    publishingAs: Sample.artifact(CorpusSample.regeneratedIdentifier),
                    schemaVersion: .v1
                )
            }
        }
    }

    @Test("Neither record is absent-by-default: a reader holding nothing yields nothing")
    func emptyReaderYieldsNothing() throws {
        let records = FakeApprovedCorpusRecords()
        #expect(throws: ApprovedCorpusRecordFault.recordAbsent) {
            try records.identifierCorrection(forCorpus: CorpusSample.corpus)
        }
        #expect(throws: ApprovedCorpusRecordFault.recordAbsent) {
            try records.duplicateHashDisposition(forCorpus: CorpusSample.corpus)
        }
    }

    // MARK: - Presence is not approval

    @Test("A rejected correction record is refused")
    func rejectedCorrectionRefused() throws {
        #expect(
            throws: CorpusRemediationError.identifierCorrectionNotApproved(
                Sample.artifact(CorpusSample.correctionIdentifier)
            )
        ) {
            try CorpusSample.correction(approval: .rejected)
        }
    }

    @Test("A rejected disposition record is refused")
    func rejectedDispositionRefused() throws {
        #expect(
            throws: CorpusRemediationError.duplicateDispositionNotApproved(
                Sample.artifact(CorpusSample.dispositionIdentifier)
            )
        ) {
            try CorpusSample.disposition(approval: .rejected)
        }
    }

    // MARK: - Records reconciled against the inventory

    @Test("A record written for another corpus is refused")
    func recordForAnotherCorpusRefused() throws {
        let other = Sample.artifact("corpus.somewhere-else")
        #expect(
            throws: CorpusRemediationError.recordCorpusMismatch(
                record: Sample.artifact(CorpusSample.correctionIdentifier),
                expected: CorpusSample.corpus,
                found: other
            )
        ) {
            try CorpusSample.remediation(
                correction: try CorpusSample.correction(corpus: other)
            )
        }
    }

    @Test("A record written against another inventory version is refused")
    func recordForAnotherInventoryRefused() throws {
        let restated = EvidenceSource(
            artifact: Sample.artifact(CorpusSample.manifestIdentifier),
            version: Sample.version("9.9.9"),
            contentDigest: Sample.digest(0xE1)
        )
        #expect(throws: CorpusRemediationError.self) {
            try CorpusSample.remediation(
                disposition: try CorpusSample.disposition(subject: restated)
            )
        }
    }

    @Test("An inventory exhibiting a different collision count is refused")
    func collisionCountIsReconciled() throws {
        // Drop the second copy of one collision group: 12 collisions remain.
        let entries = CorpusSample.entries().filter { $0.origin != CorpusSample.collisionOriginB(5) }
        #expect(
            throws: CorpusRemediationError.collisionCountMismatch(expected: 13, found: 12)
        ) {
            try CorpusSample.remediation(manifest: try CorpusSample.manifest(entries: entries))
        }
        #expect(CorpusRemediator.requiredCollisionCount == 13)
    }

    @Test("An inventory exhibiting a different duplicate-hash count is refused")
    func duplicateHashCountIsReconciled() throws {
        // Give one member of a duplicate pair its own digest: 3 duplicates remain.
        var entries = CorpusSample.entries()
        let index = try #require(
            entries.firstIndex { $0.origin == CorpusSample.pairOrigin(3, first: false) }
        )
        entries[index] = CorpusEntryRecord(
            origin: entries[index].origin,
            recordedIdentifier: entries[index].recordedIdentifier,
            contentDigest: Sample.digest(0x7777)
        )
        #expect(
            throws: CorpusRemediationError.duplicateHashCountMismatch(expected: 4, found: 3)
        ) {
            try CorpusSample.remediation(
                manifest: try CorpusSample.manifest(entries: entries),
                comparisons: []
            )
        }
        #expect(CorpusRemediator.requiredDuplicateHashCount == 4)
    }

    @Test("A correction naming an origin the inventory omits is refused")
    func correctionOfUnknownOriginRefused() throws {
        let absent = Sample.path("archive/nowhere/src.jpg")
        var corrections = CorpusSample.corrections()
        corrections.append(
            CorpusIdentifierCorrectionEntry(
                origin: absent,
                collidingIdentifier: CorpusSample.collidingIdentifier(0),
                correctedIdentifier: CorpusSample.entryID("collide.00.c")
            )
        )
        #expect(throws: CorpusRemediationError.correctedOriginNotInCorpus(absent)) {
            try CorpusSample.remediation(
                correction: try CorpusSample.correction(corrections: corrections)
            )
        }
    }

    @Test("A correction restating the wrong prior identifier is refused")
    func correctionSubjectMismatchRefused() throws {
        var corrections = CorpusSample.corrections()
        let wrong = CorpusSample.collidingIdentifier(7)
        corrections[0] = CorpusIdentifierCorrectionEntry(
            origin: CorpusSample.collisionOriginA(0),
            collidingIdentifier: wrong,
            correctedIdentifier: CorpusSample.correctedIdentifier(0, first: true)
        )
        #expect(
            throws: CorpusRemediationError.correctionSubjectMismatch(
                origin: CorpusSample.collisionOriginA(0),
                expected: CorpusSample.collidingIdentifier(0),
                found: wrong
            )
        ) {
            try CorpusSample.remediation(
                correction: try CorpusSample.correction(corrections: corrections)
            )
        }
    }

    @Test("A correction that rewrites a non-colliding entry is refused")
    func correctionOutsideApprovedScopeRefused() throws {
        var corrections = CorpusSample.corrections()
        corrections.append(
            CorpusIdentifierCorrectionEntry(
                origin: CorpusSample.plainOrigin(1),
                collidingIdentifier: CorpusSample.plainIdentifier(1),
                correctedIdentifier: CorpusSample.entryID("unique.plain1.renamed")
            )
        )
        #expect(
            throws: CorpusRemediationError.correctionOfNonCollidingEntry(
                origin: CorpusSample.plainOrigin(1),
                identifier: CorpusSample.plainIdentifier(1)
            )
        ) {
            try CorpusSample.remediation(
                correction: try CorpusSample.correction(corrections: corrections)
            )
        }
    }

    @Test("A partially corrected collision group is refused")
    func partialCollisionCorrectionRefused() throws {
        let uncovered = CorpusSample.collisionOriginB(4)
        let corrections = CorpusSample.corrections().filter { $0.origin != uncovered }
        #expect(
            throws: CorpusRemediationError.collisionGroupNotFullyCorrected(
                identifier: CorpusSample.collidingIdentifier(4),
                uncovered: [uncovered]
            )
        ) {
            try CorpusSample.remediation(
                correction: try CorpusSample.correction(corrections: corrections)
            )
        }
    }

    // MARK: - Uniqueness is verified, not assumed

    @Test("A correction that renames onto an existing identifier is refused")
    func correctionCollidingWithAnUntouchedEntryRefused() throws {
        var corrections = CorpusSample.corrections()
        // Rename a colliding copy onto an identifier a non-colliding entry already holds.
        corrections[0] = CorpusIdentifierCorrectionEntry(
            origin: CorpusSample.collisionOriginA(0),
            collidingIdentifier: CorpusSample.collidingIdentifier(0),
            correctedIdentifier: CorpusSample.plainIdentifier(2)
        )
        #expect(
            throws: CorpusRemediationError.correctedIdentifiersNotUnique(
                identifier: CorpusSample.plainIdentifier(2),
                origins: [CorpusSample.collisionOriginA(0), CorpusSample.plainOrigin(2)]
                    .sorted { $0.rawValue < $1.rawValue }
            )
        ) {
            try CorpusSample.remediation(
                correction: try CorpusSample.correction(corrections: corrections)
            )
        }
    }

    @Test("A correction that leaves a group sharing one name is refused")
    func correctionThatDoesNotSeparateAGroupRefused() throws {
        var corrections = CorpusSample.corrections()
        // Both copies of group 09 corrected to the same identifier: covered, and still ambiguous.
        let shared = CorpusSample.entryID("collide.09.merged")
        for (offset, correction) in corrections.enumerated()
        where correction.collidingIdentifier == CorpusSample.collidingIdentifier(9) {
            corrections[offset] = CorpusIdentifierCorrectionEntry(
                origin: correction.origin,
                collidingIdentifier: correction.collidingIdentifier,
                correctedIdentifier: shared
            )
        }
        #expect(
            throws: CorpusRemediationError.correctedIdentifiersNotUnique(
                identifier: shared,
                origins: [CorpusSample.collisionOriginA(9), CorpusSample.collisionOriginB(9)]
            )
        ) {
            try CorpusSample.remediation(
                correction: try CorpusSample.correction(corrections: corrections)
            )
        }
    }

    // MARK: - Duplicate-hash dispositions

    @Test("Every retention shape an approved decision can record is accepted")
    func everyRetentionShapeIsAccepted() throws {
        let remediation = try CorpusSample.remediation()
        let archival = remediation.evidence.archivalManifest

        #expect(archival.duplicateDispositions.count == 4)
        // Keep one copy, keep both, keep neither.
        let retained = archival.duplicateDispositions.map(\.retainedOrigins.count).sorted()
        #expect(retained == [0, 1, 1, 2])

        let excluded = archival.excludedOrigins
        #expect(excluded.contains(CorpusSample.collisionOriginB(0)))
        #expect(excluded.contains(CorpusSample.pairOrigin(1, first: false)))
        #expect(!excluded.contains(CorpusSample.pairOrigin(2, first: false)))
        #expect(excluded.contains(CorpusSample.pairOrigin(3, first: true)))
        #expect(excluded.contains(CorpusSample.pairOrigin(3, first: false)))
        // One copy from each of the two "keep one" dispositions, both from "keep neither",
        // none from "keep both".
        #expect(excluded.count == 4)
    }

    @Test("The archival manifest holds the retained entries and every recorded disposition")
    func archivalManifestIsRetainedPlusRecorded() throws {
        let manifest = try CorpusSample.manifest()
        let remediation = try CorpusSample.remediation(manifest: manifest)
        let archival = remediation.evidence.archivalManifest

        #expect(archival.corpus == CorpusSample.corpus)
        #expect(archival.entries.count == manifest.entries.count - archival.excludedOrigins.count)
        #expect(archival.entries.count == 32)
        for entry in archival.entries {
            #expect(!archival.excludedOrigins.contains(entry.origin))
        }
        // The excluded copies are auditable from the manifest rather than simply absent.
        for digest in manifest.duplicatedContentDigests {
            #expect(archival.duplicateDispositions.contains { $0.contentDigest == digest })
        }
        // The corrected inventory keeps every entry, excluded or not.
        #expect(remediation.evidence.correctedEntries.count == manifest.entries.count)
    }

    @Test("Comparisons naming an excluded entry are reported, not hidden or judged")
    func comparisonsNamingExcludedEntriesAreReported() throws {
        let remediation = try CorpusSample.remediation()
        let flagged = remediation.comparisonsNamingExcludedEntries

        // The slice record was attributed to the excluded copy of group 00, and one parity
        // record measured the excluded copy of duplicate pair 1.
        #expect(flagged.count == 2)
        #expect(Set(flagged.map(\.origin)) == [
            CorpusSample.collisionOriginB(0),
            CorpusSample.pairOrigin(1, first: false),
        ])
        // Reported as a fact. Every flagged comparison is still regenerated.
        for comparison in flagged {
            #expect(remediation.evidence.regeneratedComparisons.contains(comparison))
        }
    }

    @Test("A disposition for a digest no two entries share is refused")
    func dispositionOfANonDuplicateRefused() throws {
        var dispositions = try CorpusSample.dispositions()
        let notShared = Sample.digest(0x9999)
        dispositions.append(
            try DuplicateHashDisposition(
                contentDigest: notShared,
                origins: [CorpusSample.plainOrigin(1), CorpusSample.plainOrigin(2)],
                classification: CorpusSample.classification("classification.sample.epsilon"),
                retainedOrigins: [CorpusSample.plainOrigin(1)],
                source: Sample.evidence(CorpusSample.dispositionIdentifier)
            )
        )
        #expect(
            throws: CorpusRemediationError.dispositionSubjectNotDuplicatedInCorpus(notShared)
        ) {
            try CorpusSample.remediation(
                disposition: try CorpusSample.disposition(dispositions: dispositions)
            )
        }
    }

    @Test("A disposition naming the wrong origins for its digest is refused")
    func dispositionOriginsMustMatchTheInventory() throws {
        var dispositions = try CorpusSample.dispositions()
        dispositions[1] = try DuplicateHashDisposition(
            contentDigest: CorpusSample.pairDigest(1),
            origins: [CorpusSample.pairOrigin(1, first: true), CorpusSample.plainOrigin(3)],
            classification: CorpusSample.classification("classification.sample.beta"),
            retainedOrigins: [CorpusSample.pairOrigin(1, first: true)],
            source: Sample.evidence(CorpusSample.dispositionIdentifier)
        )
        #expect(throws: CorpusRemediationError.self) {
            try CorpusSample.remediation(
                disposition: try CorpusSample.disposition(dispositions: dispositions)
            )
        }
    }

    @Test("A duplicate content hash nobody classified blocks the run")
    func undispositionedDuplicateRefused() throws {
        let dispositions = try CorpusSample.dispositions()
            .filter { $0.contentDigest != CorpusSample.pairDigest(2) }
        #expect(
            throws: CorpusRemediationError.duplicateHashNotDispositioned([
                CorpusSample.pairDigest(2)
            ])
        ) {
            try CorpusSample.remediation(
                disposition: try CorpusSample.disposition(dispositions: dispositions)
            )
        }
    }

    @Test("A disposition retaining an origin outside its group is refused")
    func retainedOriginMustShareTheDigest() throws {
        #expect(
            throws: CorpusRemediationError.retainedOriginNotInDuplicateGroup(
                digest: CorpusSample.pairDigest(1),
                origin: CorpusSample.plainOrigin(1)
            )
        ) {
            try DuplicateHashDisposition(
                contentDigest: CorpusSample.pairDigest(1),
                origins: [CorpusSample.pairOrigin(1, first: true), CorpusSample.pairOrigin(1, first: false)],
                classification: CorpusSample.classification("classification.sample.beta"),
                retainedOrigins: [CorpusSample.plainOrigin(1)],
                source: Sample.evidence(CorpusSample.dispositionIdentifier)
            )
        }
    }

    @Test("A disposition of a single origin is refused: its subject is not a duplicate")
    func singleOriginDispositionRefused() throws {
        #expect(
            throws: CorpusRemediationError.dispositionSubjectIsNotADuplicate(
                CorpusSample.pairDigest(1)
            )
        ) {
            try DuplicateHashDisposition(
                contentDigest: CorpusSample.pairDigest(1),
                origins: [CorpusSample.pairOrigin(1, first: true)],
                classification: CorpusSample.classification("classification.sample.beta"),
                retainedOrigins: [],
                source: Sample.evidence(CorpusSample.dispositionIdentifier)
            )
        }
    }

    @Test("The same digest cannot be dispositioned twice")
    func repeatedDispositionSubjectRefused() throws {
        var dispositions = try CorpusSample.dispositions()
        dispositions.append(dispositions[0])
        #expect(
            throws: CorpusRemediationError.repeatedDispositionSubject(
                CorpusSample.sharedCollisionDigest
            )
        ) {
            try CorpusSample.disposition(dispositions: dispositions)
        }
    }

    // MARK: - Ambiguous comparisons

    @Test("An ambiguous comparison with no approved attribution blocks the run")
    func ambiguousComparisonNeedsAnApprovedAttribution() throws {
        let correction = try CorpusSample.correction(reattributions: [])
        #expect(
            throws: CorpusRemediationError.comparisonReattributionMissing(
                comparison: CorpusSample.parityComparison,
                identifier: CorpusSample.collidingIdentifier(0),
                candidates: [CorpusSample.collisionOriginA(0), CorpusSample.collisionOriginB(0)]
            )
        ) {
            try CorpusSample.remediation(correction: correction)
        }
    }

    @Test("An attribution to a copy the comparison could not have measured is refused")
    func attributionOutsideCandidatesRefused() throws {
        var attributions = CorpusSample.reattributions()
        attributions[0] = CorpusComparisonReattribution(
            comparison: CorpusSample.parityComparison,
            recordedIdentifier: CorpusSample.collidingIdentifier(0),
            measuredContentDigest: CorpusSample.sharedCollisionDigest,
            origin: CorpusSample.plainOrigin(1)
        )
        #expect(
            throws: CorpusRemediationError.comparisonReattributedOutsideCandidates(
                comparison: CorpusSample.parityComparison,
                identifier: CorpusSample.collidingIdentifier(0),
                origin: CorpusSample.plainOrigin(1)
            )
        ) {
            try CorpusSample.remediation(
                correction: try CorpusSample.correction(reattributions: attributions)
            )
        }
    }

    @Test("An attribution for a comparison the run was not handed is refused")
    func unusedAttributionRefused() throws {
        let comparisons = CorpusSample.comparisons()
            .filter { $0.comparison != CorpusSample.sliceComparison }
        #expect(
            throws: CorpusRemediationError.comparisonReattributionUnused(
                comparison: CorpusSample.sliceComparison,
                identifier: CorpusSample.collidingIdentifier(0)
            )
        ) {
            try CorpusSample.remediation(comparisons: comparisons)
        }
    }

    @Test("A comparison measured against content the inventory lacks is refused")
    func comparisonAgainstUnknownContentRefused() throws {
        var comparisons = CorpusSample.comparisons()
        comparisons.append(
            CorpusSample.comparison(
                CorpusSample.parityComparison,
                identifier: CorpusSample.plainIdentifier(1),
                measured: Sample.digest(0xABCD),
                outcome: 0x50
            )
        )
        #expect(
            throws: CorpusRemediationError.comparisonMatchesNoEntry(
                comparison: CorpusSample.parityComparison,
                identifier: CorpusSample.plainIdentifier(1)
            )
        ) {
            try CorpusSample.remediation(comparisons: comparisons)
        }
    }

    @Test("Two indistinguishable comparison records are refused")
    func indistinguishableComparisonRecordsRefused() throws {
        var comparisons = CorpusSample.comparisons()
        comparisons.append(comparisons[0])
        #expect(
            throws: CorpusRemediationError.duplicateComparisonRecord(
                comparison: comparisons[0].comparison,
                identifier: comparisons[0].recordedIdentifier
            )
        ) {
            try CorpusSample.remediation(comparisons: comparisons)
        }
    }

    @Test("The same comparison record cannot be attributed twice")
    func duplicateAttributionRefused() throws {
        var attributions = CorpusSample.reattributions()
        attributions.append(attributions[0])
        #expect(
            throws: CorpusRemediationError.duplicateComparisonReattribution(
                comparison: CorpusSample.parityComparison,
                identifier: CorpusSample.collidingIdentifier(0)
            )
        ) {
            try CorpusSample.correction(reattributions: attributions)
        }
    }

    // MARK: - Structural record faults

    @Test("An inventory with two entries at one origin is refused")
    func duplicateOriginRefused() throws {
        var entries = CorpusSample.entries()
        entries.append(entries[0])
        #expect(throws: CorpusRemediationError.duplicateCorpusOrigin(entries[0].origin)) {
            try CorpusSample.manifest(entries: entries)
        }
    }

    @Test("An empty inventory is refused")
    func emptyInventoryRefused() throws {
        #expect(
            throws: CorpusRemediationError.corpusManifestEmpty(
                Sample.artifact(CorpusSample.manifestIdentifier)
            )
        ) {
            try CorpusSample.manifest(entries: [])
        }
    }

    @Test("An empty correction record is refused")
    func emptyCorrectionRefused() throws {
        #expect(
            throws: CorpusRemediationError.identifierCorrectionEmpty(
                Sample.artifact(CorpusSample.correctionIdentifier)
            )
        ) {
            try CorpusSample.correction(corrections: [])
        }
    }

    @Test("A correction record correcting one origin twice is refused")
    func duplicateCorrectionOriginRefused() throws {
        var corrections = CorpusSample.corrections()
        corrections.append(corrections[0])
        #expect(throws: CorpusRemediationError.duplicateCorrectedOrigin(corrections[0].origin)) {
            try CorpusSample.correction(corrections: corrections)
        }
    }

    @Test("An empty disposition record is refused")
    func emptyDispositionRefused() throws {
        #expect(
            throws: CorpusRemediationError.duplicateDispositionEmpty(
                Sample.artifact(CorpusSample.dispositionIdentifier)
            )
        ) {
            try CorpusSample.disposition(dispositions: [])
        }
    }

    // MARK: - Reproducibility

    @Test("Two runs over the same approved inputs produce byte-identical evidence")
    func regenerationIsReproducible() throws {
        let first = try CorpusSample.remediation()
        let second = try CorpusSample.remediation()

        #expect(first.canonicalBytes == second.canonicalBytes)
        #expect(first.evidence == second.evidence)
        #expect(!first.canonicalBytes.isEmpty)
    }

    @Test("Changing one approved correction changes the regenerated bytes")
    func regeneratedBytesTrackTheApprovedInputs() throws {
        var corrections = CorpusSample.corrections()
        corrections[0] = CorpusIdentifierCorrectionEntry(
            origin: CorpusSample.collisionOriginA(0),
            collidingIdentifier: CorpusSample.collidingIdentifier(0),
            correctedIdentifier: CorpusSample.entryID("collide.00.alternative")
        )
        let baseline = try CorpusSample.remediation()
        let altered = try CorpusSample.remediation(
            correction: try CorpusSample.correction(corrections: corrections)
        )

        #expect(baseline.canonicalBytes != altered.canonicalBytes)
        #expect(
            altered.correctedIdentifier(at: CorpusSample.collisionOriginA(0))
                == CorpusSample.entryID("collide.00.alternative")
        )
    }

    @Test("The regenerated evidence publishes under the identifier it was given")
    func regeneratedIdentityIsSupplied() throws {
        let remediation = try CorpusSample.remediation(publishingAs: "evidence.somewhere.else")
        #expect(remediation.evidence.id == Sample.artifact("evidence.somewhere.else"))
        #expect(remediation.evidence.schemaVersion == .v1)
    }

    // MARK: - Round-trip

    @Test("Every approved record round-trips through its validating decoder")
    func approvedRecordsRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let manifest = try CorpusSample.manifest()
        #expect(
            try decoder.decode(
                EvaluationCorpusManifest.self,
                from: try encoder.encode(manifest)
            ) == manifest
        )
        let correction = try CorpusSample.correction()
        #expect(
            try decoder.decode(
                CorpusIdentifierCorrection.self,
                from: try encoder.encode(correction)
            ) == correction
        )
        let disposition = try CorpusSample.disposition()
        #expect(
            try decoder.decode(
                DuplicateHashDispositionRecord.self,
                from: try encoder.encode(disposition)
            ) == disposition
        )
    }

    @Test("A record that in-process construction would reject cannot be decoded either")
    func decodingRefusesWhatConstructionRefuses() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // A structurally valid record, re-encoded with its own provenance pointing elsewhere.
        var object = try #require(
            try JSONSerialization.jsonObject(
                with: try encoder.encode(try CorpusSample.correction())
            ) as? [String: Any]
        )
        object["source"] = ["artifact": "some.other.artifact", "version": "1.0.0",
                            "contentDigest": Sample.digest(0xE1).hexadecimalString]
        let tampered = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try decoder.decode(CorpusIdentifierCorrection.self, from: tampered)
        }
    }
}
