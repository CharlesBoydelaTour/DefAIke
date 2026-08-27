import DefAIkeDomain

// Applying an approved correction, verifying uniqueness, and regenerating the affected
// evidence (Requirements 14.7 and 14.8).
//
// What this runner does is narrow, and the narrowness is the design. It reconciles two
// approved records against the inventory in hand, relabels, checks that the relabelling
// actually achieved uniqueness, and emits the result bound to the provenance of everything it
// read. What it never does:
//
//   | Decision | Where it comes from |
//   |---|---|
//   | which corrected identifier an entry gets | ``CorpusIdentifierCorrection/corrections`` |
//   | how a corrected identifier is formed | named by ``CorpusIdentifierCorrection/correctedIdentifierRule``, never executed |
//   | what a duplicate content hash is | ``DuplicateHashDisposition/classification`` |
//   | which copies reach the archival manifest | ``DuplicateHashDisposition/retainedOrigins`` |
//   | which entry an ambiguous comparison measured | digest agreement, or ``CorpusComparisonReattribution`` |
//   | whether any of it may be distributed | nowhere in this module |
//
// There is no `correctedIdentifier(for:)` that computes, no `classify(_:)`, no
// `preferredCopy`, and no parameter anywhere in this file's public surface that lets a caller
// hand in a classification or a retention set outside an approved record. A run either has
// both records or produces a finding.
//
// **Uniqueness is verified, not assumed.** An approved mapping can be wrong: it can rename an
// entry onto an identifier another entry already holds, or leave two members of a collision
// group sharing a name. Both produce
// ``CorpusRemediationError/correctedIdentifiersNotUnique(identifier:origins:)``, and neither is
// repaired here. So the existence of a ``CorpusRemediation`` value *is* the uniqueness result,
// the same way the existence of a `VerifiedBundleArtifactTree` is the integrity result.
//
// **Regeneration is relabelling.** A comparison's recorded outcome travels through as an
// opaque digest. Nothing in this module reads it, recomputes it, or adjusts it, so a corrected
// identifier can never arrive attached to a measurement that changed on the way.

// MARK: - Immutable provenance

/// The immutable provenance every regenerated artifact carries (Requirements 14.7 and 14.12).
///
/// Every field is an ``EvidenceSource``: an artifact identifier, its exact version, and a
/// digest binding the reference to fixed bytes. All of them are copied from the inputs, never
/// derived, so provenance cannot describe a read that did not happen. There is no field a
/// caller supplies and no field this module computes.
public struct RemediationProvenance: Hashable, Codable, Sendable {
    /// The corpus that was remediated.
    public let corpus: ArtifactID

    /// The pre-correction inventory the regeneration started from.
    public let subjectManifest: EvidenceSource

    /// The approved correction mapping that was applied.
    public let identifierCorrection: EvidenceSource

    /// The approved statement of how a corrected identifier is formed.
    public let correctedIdentifierRule: EvidenceSource

    /// The approved duplicate content-hash disposition record.
    public let duplicateHashDisposition: EvidenceSource

    /// Every comparison artifact this run regenerated, ordered by artifact identifier.
    ///
    /// One entry per artifact, so a regenerated comparison set cannot silently span two
    /// versions of the same artifact.
    public let regeneratedComparisons: [EvidenceSource]

    init(
        corpus: ArtifactID,
        subjectManifest: EvidenceSource,
        identifierCorrection: EvidenceSource,
        correctedIdentifierRule: EvidenceSource,
        duplicateHashDisposition: EvidenceSource,
        regeneratedComparisons: [EvidenceSource]
    ) {
        self.corpus = corpus
        self.subjectManifest = subjectManifest
        self.identifierCorrection = identifierCorrection
        self.correctedIdentifierRule = correctedIdentifierRule
        self.duplicateHashDisposition = duplicateHashDisposition
        self.regeneratedComparisons = regeneratedComparisons
    }
}

// MARK: - Regenerated evidence

/// One corpus entry under the identifier it carries after correction.
public struct CorrectedCorpusEntry: Hashable, Codable, Sendable {
    /// The entry's immutable location inside its source archive, unchanged.
    public let origin: CanonicalRelativePath

    /// The identifier this entry carries after correction.
    public let identifier: CorpusEntryID

    /// The identifier the pre-correction inventory recorded, retained so the change is
    /// auditable from the regenerated artifact alone.
    public let previousIdentifier: CorpusEntryID

    /// The entry's content digest, unchanged. Correction relabels; it never re-measures.
    public let contentDigest: SHA256Digest

    init(
        origin: CanonicalRelativePath,
        identifier: CorpusEntryID,
        previousIdentifier: CorpusEntryID,
        contentDigest: SHA256Digest
    ) {
        self.origin = origin
        self.identifier = identifier
        self.previousIdentifier = previousIdentifier
        self.contentDigest = contentDigest
    }

    /// Whether the approved correction changed this entry's identifier.
    public var wasCorrected: Bool { identifier != previousIdentifier }
}

/// One comparison relabelled onto the corrected identifiers.
public struct RegeneratedComparison: Hashable, Codable, Sendable {
    /// The comparison artifact this record belongs to.
    public let comparison: ArtifactID

    /// The identifier the comparison recorded before correction.
    public let recordedIdentifier: CorpusEntryID

    /// The corrected identifier it now names.
    public let correctedIdentifier: CorpusEntryID

    /// The entry it resolved to.
    public let origin: CanonicalRelativePath

    /// The corpus content digest the comparison measured, copied unchanged.
    public let measuredContentDigest: SHA256Digest

    /// The recorded outcome digest, copied unchanged. This module never reads a measurement,
    /// so it cannot alter one.
    public let outcomeDigest: SHA256Digest

    /// Whether resolving this record needed an approved attribution rather than digest
    /// agreement. An audit fact: it marks the comparisons whose identity is a decision.
    public let requiredApprovedAttribution: Bool

    init(
        comparison: ArtifactID,
        recordedIdentifier: CorpusEntryID,
        correctedIdentifier: CorpusEntryID,
        origin: CanonicalRelativePath,
        measuredContentDigest: SHA256Digest,
        outcomeDigest: SHA256Digest,
        requiredApprovedAttribution: Bool
    ) {
        self.comparison = comparison
        self.recordedIdentifier = recordedIdentifier
        self.correctedIdentifier = correctedIdentifier
        self.origin = origin
        self.measuredContentDigest = measuredContentDigest
        self.outcomeDigest = outcomeDigest
        self.requiredApprovedAttribution = requiredApprovedAttribution
    }
}

/// The archival evaluation manifest (Requirement 14.8).
///
/// Holds the retained entries *and* every recorded disposition, so a copy the approved decision
/// excluded is auditable from the manifest rather than simply absent from it. An entry that
/// shares its digest with nothing is retained without a disposition, because Requirement 14.8
/// asks for a disposition per duplicate content hash and a non-duplicate raises no question to
/// decide.
public struct ArchivalEvaluationManifest: Hashable, Codable, Sendable {
    public let corpus: ArtifactID

    /// Retained entries, ordered by the UTF-8 bytes of their corrected identifier.
    public let entries: [CorrectedCorpusEntry]

    /// Every duplicate content hash and its recorded classification and disposition, ordered
    /// by canonical digest.
    public let duplicateDispositions: [DuplicateHashDisposition]

    init(
        corpus: ArtifactID,
        entries: [CorrectedCorpusEntry],
        duplicateDispositions: [DuplicateHashDisposition]
    ) {
        self.corpus = corpus
        self.entries = entries
        self.duplicateDispositions = duplicateDispositions
    }

    /// Origins the recorded dispositions kept out of this manifest.
    public var excludedOrigins: Set<CanonicalRelativePath> {
        duplicateDispositions.reduce(into: Set<CanonicalRelativePath>()) {
            $0.formUnion($1.excludedOrigins)
        }
    }
}

/// Every evidence artifact one remediation run regenerates, as one immutable value.
///
/// Encoded as a whole rather than per artifact, so the corrected inventory, the regenerated
/// comparisons, and the archival manifest cannot be published with provenance that disagrees:
/// they carry one ``RemediationProvenance``, and it covers all three.
public struct RegeneratedCorpusEvidence: Hashable, Codable, Sendable {
    /// The identifier the regenerated evidence publishes under.
    ///
    /// Supplied by the caller. Which artifact identifier a release publishes regenerated
    /// evidence as is a release decision with no build-side counterpart, and inventing one
    /// would make this module the author of the artifact rather than of its content.
    public let id: ArtifactID

    public let schemaVersion: ArtifactSchemaVersion

    /// Every corpus entry under its corrected identifier, ordered by that identifier.
    ///
    /// Complete: the corrected counterpart of the whole pre-correction inventory, including the
    /// copies the dispositions exclude from the archival manifest. A regenerated comparison can
    /// therefore name an entry the archival manifest omits, which is a fact a release claim has
    /// to reckon with rather than one this module hides.
    public let correctedEntries: [CorrectedCorpusEntry]

    /// Every affected comparison, relabelled.
    public let regeneratedComparisons: [RegeneratedComparison]

    /// The archival evaluation manifest.
    public let archivalManifest: ArchivalEvaluationManifest

    /// Immutable provenance covering every artifact above.
    public let provenance: RemediationProvenance

    init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        correctedEntries: [CorrectedCorpusEntry],
        regeneratedComparisons: [RegeneratedComparison],
        archivalManifest: ArchivalEvaluationManifest,
        provenance: RemediationProvenance
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.correctedEntries = correctedEntries
        self.regeneratedComparisons = regeneratedComparisons
        self.archivalManifest = archivalManifest
        self.provenance = provenance
    }
}

/// One completed corpus remediation.
///
/// Constructible only inside this module, and only by a run that reconciled both approved
/// records against the inventory and proved the corrected identifiers unique. So the value
/// carries the uniqueness result rather than asserting it next to itself, and there is no
/// initializer a caller could use to produce a remediation that skipped a check.
///
/// What it does **not** claim: that the regenerated evidence may back a release claim. That is
/// Requirement 14.15's decision, recorded in the release-readiness record. Nothing here
/// exposes a `isPublishable`, a `blocksDistribution`, or any rights conclusion.
public struct CorpusRemediation: Hashable, Sendable {
    public let evidence: RegeneratedCorpusEvidence

    /// The reproducible canonical bytes of ``evidence``.
    ///
    /// Produced by the module's one writer, so two runs over the same approved inputs are
    /// byte-identical and a regenerated artifact is comparable as bytes rather than by
    /// inspection.
    public let canonicalBytes: [UInt8]

    init(evidence: RegeneratedCorpusEvidence, canonicalBytes: [UInt8]) {
        self.evidence = evidence
        self.canonicalBytes = canonicalBytes
    }

    public var provenance: RemediationProvenance { evidence.provenance }

    /// The corrected identifier at one origin, or `nil` when the corpus has no such entry.
    public func correctedIdentifier(at origin: CanonicalRelativePath) -> CorpusEntryID? {
        evidence.correctedEntries.first { $0.origin == origin }?.identifier
    }

    /// Every corrected identifier. Unique by construction: a run that could not prove this
    /// produced a finding instead of a value.
    public var correctedIdentifiers: Set<CorpusEntryID> {
        Set(evidence.correctedEntries.map(\.identifier))
    }

    /// Entries whose identifier the approved correction changed, in identifier order.
    public var correctedEntries: [CorrectedCorpusEntry] {
        evidence.correctedEntries.filter(\.wasCorrected)
    }

    /// Comparisons whose identity rested on an approved attribution rather than on digest
    /// agreement.
    public var comparisonsResolvedByApprovedAttribution: [RegeneratedComparison] {
        evidence.regeneratedComparisons.filter(\.requiredApprovedAttribution)
    }

    /// Regenerated comparisons naming an entry the recorded dispositions excluded from the
    /// archival manifest.
    ///
    /// A projection, not a verdict. Whether such a comparison may support a published claim is
    /// the release-readiness record's decision; this reports which ones an auditor has to look
    /// at.
    public var comparisonsNamingExcludedEntries: [RegeneratedComparison] {
        let excluded = evidence.archivalManifest.excludedOrigins
        return evidence.regeneratedComparisons.filter { excluded.contains($0.origin) }
    }
}

// MARK: - The runner

/// Remediates one evaluation corpus from its two approved records.
///
/// Holds nothing but the injected reader, so it carries no approved value of its own and no
/// state two runs could share. It cannot be constructed without a reader, which is the
/// structural form of "a run without the approved records does not happen".
public struct CorpusRemediator: Sendable {
    /// Identifier collisions the known evaluation corpus exhibits (Requirement 14.7).
    ///
    /// A count the requirement fixes, reconciled against rather than trusted: an inventory that
    /// exhibits a different number is not the corpus the approved correction was written for,
    /// and remediating it would apply a decision to something nobody examined.
    public static let requiredCollisionCount = 13

    /// Duplicate content hashes it exhibits (Requirement 14.8).
    public static let requiredDuplicateHashCount = 4

    private let records: any ApprovedCorpusRemediationReading

    /// Creates a remediator over the approved-record reader.
    ///
    /// Required, with no default. There is no convenience initializer, no in-module reader, and
    /// no test double in the shipping sources: a remediator without approved records cannot
    /// exist rather than running against something this module chose.
    public init(records: any ApprovedCorpusRemediationReading) {
        self.records = records
    }

    /// Corrects, verifies uniqueness, and regenerates the affected evidence.
    ///
    /// `comparisons` is the complete affected set. It is reconciled in both directions against
    /// the approved record's attributions, so a run cannot regenerate half the comparisons a
    /// correction was written for and present the result as the regenerated evidence.
    public func remediate(
        _ manifest: EvaluationCorpusManifest,
        comparisons: [CorpusComparisonRecord],
        publishingAs id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion
    ) throws(CorpusRemediationError) -> CorpusRemediation {
        let correction = try readCorrection(for: manifest)
        let disposition = try readDisposition(for: manifest)

        try Self.reconcileCollisions(manifest, correction: correction)
        let correctedEntries = try Self.applyCorrection(manifest, correction: correction)
        try Self.reconcileDuplicates(manifest, disposition: disposition)

        let regenerated = try Self.regenerateComparisons(
            comparisons,
            manifest: manifest,
            correction: correction,
            correctedEntries: correctedEntries
        )
        let comparisonSources = try Self.provenanceSources(of: comparisons)

        let excluded = disposition.excludedOrigins
        let archival = ArchivalEvaluationManifest(
            corpus: manifest.corpus,
            entries: correctedEntries.filter { !excluded.contains($0.origin) },
            duplicateDispositions: disposition.dispositions.sorted {
                $0.contentDigest.hexadecimalString < $1.contentDigest.hexadecimalString
            }
        )
        let evidence = RegeneratedCorpusEvidence(
            id: id,
            schemaVersion: schemaVersion,
            correctedEntries: correctedEntries,
            regeneratedComparisons: regenerated,
            archivalManifest: archival,
            provenance: RemediationProvenance(
                corpus: manifest.corpus,
                subjectManifest: manifest.source,
                identifierCorrection: correction.source,
                correctedIdentifierRule: correction.correctedIdentifierRule,
                duplicateHashDisposition: disposition.source,
                regeneratedComparisons: comparisonSources
            )
        )
        do {
            return CorpusRemediation(
                evidence: evidence,
                canonicalBytes: try CanonicalArtifactEncoding.canonicalBytes(of: evidence)
            )
        } catch {
            throw CorpusRemediationError.regeneratedEvidenceNotEncodable(error)
        }
    }

    // MARK: Reading the approved records

    /// Reads the approved correction, or reports that there is none.
    ///
    /// The only place a missing correction is handled, and it has one outcome. Nothing below
    /// this line runs without a record.
    private func readCorrection(
        for manifest: EvaluationCorpusManifest
    ) throws(CorpusRemediationError) -> CorpusIdentifierCorrection {
        let correction: CorpusIdentifierCorrection
        do {
            correction = try records.identifierCorrection(forCorpus: manifest.corpus)
        } catch {
            throw CorpusRemediationError.identifierCorrectionMissing(
                corpus: manifest.corpus,
                fault: error
            )
        }
        try Self.reconcileSubject(
            record: correction.id,
            corpus: correction.corpus,
            subject: correction.subject,
            against: manifest
        )
        return correction
    }

    /// Reads the approved disposition record, or reports that there is none.
    private func readDisposition(
        for manifest: EvaluationCorpusManifest
    ) throws(CorpusRemediationError) -> DuplicateHashDispositionRecord {
        let disposition: DuplicateHashDispositionRecord
        do {
            disposition = try records.duplicateHashDisposition(forCorpus: manifest.corpus)
        } catch {
            throw CorpusRemediationError.duplicateDispositionMissing(
                corpus: manifest.corpus,
                fault: error
            )
        }
        try Self.reconcileSubject(
            record: disposition.id,
            corpus: disposition.corpus,
            subject: disposition.subject,
            against: manifest
        )
        return disposition
    }

    /// Requires an approved record to be about this corpus and this inventory version.
    ///
    /// Both halves matter. A record for another corpus applies a decision to the wrong data; a
    /// record for another version of this inventory names collisions and duplicates that may
    /// no longer be the ones present.
    private static func reconcileSubject(
        record: ArtifactID,
        corpus: ArtifactID,
        subject: EvidenceSource,
        against manifest: EvaluationCorpusManifest
    ) throws(CorpusRemediationError) {
        guard corpus == manifest.corpus else {
            throw CorpusRemediationError.recordCorpusMismatch(
                record: record,
                expected: manifest.corpus,
                found: corpus
            )
        }
        guard subject == manifest.source else {
            throw CorpusRemediationError.recordSubjectMismatch(
                record: record,
                expected: manifest.source,
                found: subject
            )
        }
    }

    // MARK: Correcting identifiers

    /// Reconciles the approved correction against the collisions the inventory exhibits.
    ///
    /// Both directions, and both are load-bearing. A correction naming something the inventory
    /// does not collide on is outside what was approved; a collision group the correction does
    /// not fully cover would leave copies sharing a name, and the omission would look like a
    /// decision to keep it.
    private static func reconcileCollisions(
        _ manifest: EvaluationCorpusManifest,
        correction: CorpusIdentifierCorrection
    ) throws(CorpusRemediationError) {
        let groups = manifest.originsByRecordedIdentifier
        let colliding = manifest.collidingIdentifiers
        guard colliding.count == requiredCollisionCount else {
            throw CorpusRemediationError.collisionCountMismatch(
                expected: requiredCollisionCount,
                found: colliding.count
            )
        }
        for entry in correction.corrections.sorted(by: { $0.origin.rawValue < $1.origin.rawValue }) {
            guard let recorded = manifest.entry(at: entry.origin) else {
                throw CorpusRemediationError.correctedOriginNotInCorpus(entry.origin)
            }
            guard recorded.recordedIdentifier == entry.collidingIdentifier else {
                throw CorpusRemediationError.correctionSubjectMismatch(
                    origin: entry.origin,
                    expected: recorded.recordedIdentifier,
                    found: entry.collidingIdentifier
                )
            }
            guard (groups[recorded.recordedIdentifier]?.count ?? 0) > 1 else {
                throw CorpusRemediationError.correctionOfNonCollidingEntry(
                    origin: entry.origin,
                    identifier: recorded.recordedIdentifier
                )
            }
        }
        let covered = correction.coveredOrigins
        for identifier in colliding {
            let uncovered = (groups[identifier] ?? []).filter { !covered.contains($0) }
            guard uncovered.isEmpty else {
                throw CorpusRemediationError.collisionGroupNotFullyCorrected(
                    identifier: identifier,
                    uncovered: uncovered
                )
            }
        }
    }

    /// Applies the approved correction and verifies uniqueness of the result.
    ///
    /// The uniqueness check is over the whole corrected inventory, not just the corrected
    /// entries: a mapping that renames a colliding entry onto an identifier some untouched
    /// entry already holds has not fixed anything, and only comparing the full set catches it.
    private static func applyCorrection(
        _ manifest: EvaluationCorpusManifest,
        correction: CorpusIdentifierCorrection
    ) throws(CorpusRemediationError) -> [CorrectedCorpusEntry] {
        let corrected = manifest.entries.map { entry in
            CorrectedCorpusEntry(
                origin: entry.origin,
                identifier: correction.correction(at: entry.origin)?.correctedIdentifier
                    ?? entry.recordedIdentifier,
                previousIdentifier: entry.recordedIdentifier,
                contentDigest: entry.contentDigest
            )
        }
        var byIdentifier: [CorpusEntryID: [CanonicalRelativePath]] = [:]
        for entry in corrected {
            byIdentifier[entry.identifier, default: []].append(entry.origin)
        }
        for identifier in byIdentifier.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let origins = byIdentifier[identifier] ?? []
            guard origins.count == 1 else {
                throw CorpusRemediationError.correctedIdentifiersNotUnique(
                    identifier: identifier,
                    origins: origins.sorted { $0.rawValue < $1.rawValue }
                )
            }
        }
        return corrected.sorted {
            $0.identifier.rawValue.utf8.lexicographicallyPrecedes($1.identifier.rawValue.utf8)
        }
    }

    // MARK: Dispositioning duplicates

    /// Reconciles the approved dispositions against the duplicate hashes the inventory
    /// exhibits, in both directions.
    private static func reconcileDuplicates(
        _ manifest: EvaluationCorpusManifest,
        disposition: DuplicateHashDispositionRecord
    ) throws(CorpusRemediationError) {
        let groups = manifest.originsByContentDigest
        let duplicated = manifest.duplicatedContentDigests
        guard duplicated.count == requiredDuplicateHashCount else {
            throw CorpusRemediationError.duplicateHashCountMismatch(
                expected: requiredDuplicateHashCount,
                found: duplicated.count
            )
        }
        for recorded in disposition.dispositions.sorted(by: {
            $0.contentDigest.hexadecimalString < $1.contentDigest.hexadecimalString
        }) {
            guard let origins = groups[recorded.contentDigest], origins.count > 1 else {
                throw CorpusRemediationError.dispositionSubjectNotDuplicatedInCorpus(
                    recorded.contentDigest
                )
            }
            guard origins == recorded.origins else {
                throw CorpusRemediationError.dispositionOriginsMismatch(
                    digest: recorded.contentDigest,
                    expected: origins,
                    found: recorded.origins
                )
            }
        }
        let dispositioned = disposition.dispositionedDigests
        let undecided = duplicated.filter { !dispositioned.contains($0) }
        guard undecided.isEmpty else {
            throw CorpusRemediationError.duplicateHashNotDispositioned(undecided)
        }
    }

    // MARK: Regenerating comparisons

    /// Relabels every affected comparison onto the corrected identifiers.
    ///
    /// Resolution is by content agreement first: a comparison recorded the identifier it saw
    /// and the digest of the bytes it scored, and for all but the hardest case that pair names
    /// exactly one entry. The hardest case is precisely where Requirements 14.7 and 14.8 meet —
    /// a colliding identifier over a shared digest — and there the approved attribution is the
    /// only thing that can resolve it. Nothing here picks a candidate.
    private static func regenerateComparisons(
        _ comparisons: [CorpusComparisonRecord],
        manifest: EvaluationCorpusManifest,
        correction: CorpusIdentifierCorrection,
        correctedEntries: [CorrectedCorpusEntry]
    ) throws(CorpusRemediationError) -> [RegeneratedComparison] {
        var seen = Set<String>()
        for record in comparisons where !seen.insert(record.lookupKey).inserted {
            throw CorpusRemediationError.duplicateComparisonRecord(
                comparison: record.comparison,
                identifier: record.recordedIdentifier
            )
        }
        var attributions: [String: CorpusComparisonReattribution] = [:]
        for attribution in correction.comparisonReattributions {
            attributions[attribution.lookupKey] = attribution
        }
        var correctedByOrigin: [CanonicalRelativePath: CorpusEntryID] = [:]
        for entry in correctedEntries {
            correctedByOrigin[entry.origin] = entry.identifier
        }
        // Indexed once rather than scanned per comparison. A real evaluation corpus and its
        // comparison set are both large, and a nested scan would be quadratic in the corpus
        // size for no benefit: the candidate set for a record is exactly the entries agreeing
        // on both the recorded identifier and the measured digest.
        var candidatesByRecord: [String: [CanonicalRelativePath]] = [:]
        for entry in manifest.entries {
            let key = "\(entry.recordedIdentifier.rawValue)\u{1F}"
                + entry.contentDigest.hexadecimalString
            candidatesByRecord[key, default: []].append(entry.origin)
        }

        var regenerated: [RegeneratedComparison] = []
        var consumed = Set<String>()
        for record in comparisons.sorted(by: { $0.lookupKey < $1.lookupKey }) {
            let key = "\(record.recordedIdentifier.rawValue)\u{1F}"
                + record.measuredContentDigest.hexadecimalString
            let candidates = (candidatesByRecord[key] ?? []).sorted { $0.rawValue < $1.rawValue }
            guard !candidates.isEmpty else {
                throw CorpusRemediationError.comparisonMatchesNoEntry(
                    comparison: record.comparison,
                    identifier: record.recordedIdentifier
                )
            }
            let origin: CanonicalRelativePath
            let neededAttribution: Bool
            if candidates.count == 1 {
                origin = candidates[0]
                neededAttribution = false
            } else {
                guard let attribution = attributions[record.lookupKey] else {
                    throw CorpusRemediationError.comparisonReattributionMissing(
                        comparison: record.comparison,
                        identifier: record.recordedIdentifier,
                        candidates: candidates
                    )
                }
                guard candidates.contains(attribution.origin) else {
                    throw CorpusRemediationError.comparisonReattributedOutsideCandidates(
                        comparison: record.comparison,
                        identifier: record.recordedIdentifier,
                        origin: attribution.origin
                    )
                }
                origin = attribution.origin
                neededAttribution = true
                consumed.insert(record.lookupKey)
            }
            // Total: every inventory origin has a corrected entry, and `candidates` holds only
            // inventory origins.
            guard let correctedIdentifier = correctedByOrigin[origin] else {
                throw CorpusRemediationError.correctedOriginNotInCorpus(origin)
            }
            regenerated.append(
                RegeneratedComparison(
                    comparison: record.comparison,
                    recordedIdentifier: record.recordedIdentifier,
                    correctedIdentifier: correctedIdentifier,
                    origin: origin,
                    measuredContentDigest: record.measuredContentDigest,
                    outcomeDigest: record.outcomeDigest,
                    requiredApprovedAttribution: neededAttribution
                )
            )
        }
        for attribution in correction.comparisonReattributions
        where !consumed.contains(attribution.lookupKey) {
            throw CorpusRemediationError.comparisonReattributionUnused(
                comparison: attribution.comparison,
                identifier: attribution.recordedIdentifier
            )
        }
        return regenerated.sorted {
            ($0.comparison.rawValue, $0.correctedIdentifier.rawValue)
                < ($1.comparison.rawValue, $1.correctedIdentifier.rawValue)
        }
    }

    /// The distinct comparison artifacts this run regenerated, one entry each.
    ///
    /// Refuses a set that names two versions of the same artifact. Provenance has to say which
    /// version the regenerated comparisons came from, and a mixed set makes that unanswerable
    /// rather than merely untidy.
    private static func provenanceSources(
        of comparisons: [CorpusComparisonRecord]
    ) throws(CorpusRemediationError) -> [EvidenceSource] {
        var byArtifact: [ArtifactID: EvidenceSource] = [:]
        for record in comparisons.sorted(by: { $0.lookupKey < $1.lookupKey }) {
            if let existing = byArtifact[record.comparison], existing != record.source {
                throw CorpusRemediationError.comparisonSourceVersionsMixed(
                    comparison: record.comparison,
                    first: existing.version,
                    second: record.source.version
                )
            }
            byArtifact[record.comparison] = record.source
        }
        return byArtifact.keys
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { byArtifact[$0] }
    }
}
