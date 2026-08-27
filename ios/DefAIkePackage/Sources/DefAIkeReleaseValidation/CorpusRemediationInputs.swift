import DefAIkeDomain

// The approved inputs corpus remediation is assembled from (Requirements 14.7 and 14.8).
//
// Requirement 14.7 asks a release to correct 13 known identifier collisions in the ReWIND
// evaluation corpus, verify uniqueness under the corrected identifier rule, and regenerate
// every affected evidence artifact. Requirement 14.8 asks it to classify four known duplicate
// content hashes and record the disposition of each before publishing an archival evaluation
// manifest.
//
// Neither of those is a computation, and this file is where that is made structural. Two
// substantive decisions belong to a release owner, and nothing here can supply either:
//
//   * **Which corrected identifier a colliding entry gets.** The mapping arrives whole, in
//     ``CorpusIdentifierCorrection``, alongside the approved statement of how a corrected
//     identifier is formed. That statement is *named*, never executed: this module verifies
//     that the supplied identifiers are unique and never derives one from a rule, because
//     deriving one would make the tool the author of the correction.
//   * **What a duplicate content hash is, and what happens to it.** The classification is an
//     opaque ``DuplicateClassificationID`` with no declared constant, for the same reason
//     `ProvenanceValidatorStatusID` declares none: a classification this module could name is
//     a classification it could choose. Which copies survive into the archival manifest
//     arrives as data in ``DuplicateHashDisposition/retainedOrigins``.
//
// Deliberately absent from every type below: any field that states a distribution right, a
// licence conclusion, a data-rights conclusion, or a publication permission. Those are
// Requirement 14.2 through 14.4 conclusions carried by `DistributionRightsRecord`, and a
// corpus record that could imply one would let a relabelling tool answer a legal question.
//
// The primary key throughout is ``CorpusEntryRecord/origin``, the entry's immutable location
// inside its source archive. An identifier cannot be the key: the whole defect is that 13
// identifiers name more than one entry. An origin is unique by construction, so it stays
// addressable while the identifiers around it are ambiguous.

// MARK: - Identifiers

/// Identity of one entry in an evaluation corpus.
///
/// Declared here rather than in the domain because no session, policy, or shipping surface
/// ever names a corpus entry: the corpus is evaluation input, and it is excluded from the
/// application and the Model Bundle entirely (Requirement 14.6).
public struct CorpusEntryID: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// How an approved record classified one duplicate content hash.
///
/// Opaque, and no constant is declared. Requirement 14.8 reserves the classification for a
/// release owner, so the vocabulary belongs to the approved record: a case this module could
/// spell is a case it could select. A classification the record does not carry is a gap in
/// the record rather than something code fills in.
public struct DuplicateClassificationID: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

// MARK: - The corpus inventory as it stands

/// One entry of an evaluation corpus, as the pre-correction inventory records it.
public struct CorpusEntryRecord: Hashable, Codable, Sendable {
    /// The entry's immutable location inside its source archive. Unique across the corpus,
    /// and the only field that is: this is the key the remediation addresses entries by.
    public let origin: CanonicalRelativePath

    /// The identifier the inventory recorded for this entry.
    ///
    /// Not unique. Thirteen values of this field name more than one entry, which is the
    /// defect Requirement 14.7 corrects.
    public let recordedIdentifier: CorpusEntryID

    /// Digest of the entry's bytes.
    ///
    /// Also not unique: four values are shared by more than one entry, which is the defect
    /// Requirement 14.8 dispositions.
    public let contentDigest: SHA256Digest

    public init(
        origin: CanonicalRelativePath,
        recordedIdentifier: CorpusEntryID,
        contentDigest: SHA256Digest
    ) {
        self.origin = origin
        self.recordedIdentifier = recordedIdentifier
        self.contentDigest = contentDigest
    }
}

/// The pre-correction inventory of one evaluation corpus.
///
/// Deliberately permissive about the two defects: a manifest that refused colliding
/// identifiers could not describe the corpus the requirements are about, and a remediation
/// tool that could not read the broken inventory could not fix it. What it does refuse is a
/// second entry at the same origin, because that would make the key ambiguous too and there
/// would be nothing left to address an entry by.
public struct EvaluationCorpusManifest: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The corpus this inventory describes.
    public let corpus: ArtifactID

    /// The immutable artifact this inventory was read from, whose identifier is this
    /// inventory's own. Carried forward verbatim as provenance.
    public let source: EvidenceSource

    /// Every entry, each origin exactly once.
    public let entries: [CorpusEntryRecord]

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        corpus: ArtifactID,
        source: EvidenceSource,
        entries: [CorpusEntryRecord]
    ) throws(CorpusRemediationError) {
        guard source.artifact == id else {
            throw CorpusRemediationError.provenanceDoesNotNameItsRecord(
                record: id,
                named: source.artifact
            )
        }
        guard !entries.isEmpty else {
            throw CorpusRemediationError.corpusManifestEmpty(id)
        }
        var seen = Set<CanonicalRelativePath>()
        for entry in entries where !seen.insert(entry.origin).inserted {
            throw CorpusRemediationError.duplicateCorpusOrigin(entry.origin)
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.corpus = corpus
        self.source = source
        self.entries = entries
    }

    /// The entry at one origin, or `nil` when the inventory has none.
    public func entry(at origin: CanonicalRelativePath) -> CorpusEntryRecord? {
        entries.first { $0.origin == origin }
    }

    /// Origins grouped by the identifier the inventory recorded for them.
    ///
    /// A group of more than one origin is an identifier collision.
    public var originsByRecordedIdentifier: [CorpusEntryID: [CanonicalRelativePath]] {
        var grouped: [CorpusEntryID: [CanonicalRelativePath]] = [:]
        for entry in entries {
            grouped[entry.recordedIdentifier, default: []].append(entry.origin)
        }
        return grouped.mapValues { $0.sorted { $0.rawValue < $1.rawValue } }
    }

    /// Origins grouped by content digest.
    ///
    /// A group of more than one origin is a duplicate content hash.
    public var originsByContentDigest: [SHA256Digest: [CanonicalRelativePath]] {
        var grouped: [SHA256Digest: [CanonicalRelativePath]] = [:]
        for entry in entries {
            grouped[entry.contentDigest, default: []].append(entry.origin)
        }
        return grouped.mapValues { $0.sorted { $0.rawValue < $1.rawValue } }
    }

    /// Every identifier the inventory records for more than one entry, sorted.
    public var collidingIdentifiers: [CorpusEntryID] {
        originsByRecordedIdentifier
            .filter { $0.value.count > 1 }
            .keys
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Every content digest more than one entry shares, sorted by canonical hexadecimal.
    public var duplicatedContentDigests: [SHA256Digest] {
        originsByContentDigest
            .filter { $0.value.count > 1 }
            .keys
            .sorted { $0.hexadecimalString < $1.hexadecimalString }
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, corpus, source, entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                corpus: container.decode(ArtifactID.self, forKey: .corpus),
                source: container.decode(EvidenceSource.self, forKey: .source),
                entries: container.decode([CorpusEntryRecord].self, forKey: .entries)
            )
        } catch let error as CorpusRemediationError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - The approved identifier correction (Requirement 14.7)

/// The corrected identifier an approved decision assigns to one corpus entry.
///
/// ``collidingIdentifier`` restates what the inventory recorded, so a correction written
/// against one inventory cannot be applied to a different one without the mismatch being
/// visible. It may equal ``correctedIdentifier``: a decision that one copy in a collision
/// group keeps its identifier is a decision, and recording it is what keeps the group's
/// resolution readable instead of inferred from an omission.
public struct CorpusIdentifierCorrectionEntry: Hashable, Codable, Sendable {
    public let origin: CanonicalRelativePath
    public let collidingIdentifier: CorpusEntryID
    public let correctedIdentifier: CorpusEntryID

    public init(
        origin: CanonicalRelativePath,
        collidingIdentifier: CorpusEntryID,
        correctedIdentifier: CorpusEntryID
    ) {
        self.origin = origin
        self.collidingIdentifier = collidingIdentifier
        self.correctedIdentifier = correctedIdentifier
    }
}

/// The entry an approved decision attributes one ambiguous comparison record to.
///
/// Needed for exactly one situation, and it is the intersection of the two requirements: a
/// comparison whose recorded identifier collides *and* whose measured content digest is one
/// of the shared ones. Digest agreement resolves every other ambiguous comparison on its own;
/// for these there is nothing left in the data to distinguish the candidates, so the
/// attribution is a decision and it arrives as one.
public struct CorpusComparisonReattribution: Hashable, Codable, Sendable {
    /// The comparison artifact the ambiguous record belongs to.
    public let comparison: ArtifactID

    /// The identifier that record recorded.
    public let recordedIdentifier: CorpusEntryID

    /// The content digest that record measured.
    public let measuredContentDigest: SHA256Digest

    /// The entry origin the approved decision attributes it to.
    public let origin: CanonicalRelativePath

    public init(
        comparison: ArtifactID,
        recordedIdentifier: CorpusEntryID,
        measuredContentDigest: SHA256Digest,
        origin: CanonicalRelativePath
    ) {
        self.comparison = comparison
        self.recordedIdentifier = recordedIdentifier
        self.measuredContentDigest = measuredContentDigest
        self.origin = origin
    }

    /// The key an ambiguous comparison record is looked up by.
    var lookupKey: String {
        "\(comparison.rawValue)\u{1F}\(recordedIdentifier.rawValue)\u{1F}"
            + measuredContentDigest.hexadecimalString
    }
}

/// The approved correction mapping for one corpus's identifier collisions.
///
/// Every field is supplied. The record carries the mapping, the approved statement of the
/// rule the mapping was formed under, and the decision that approved it; presence of the
/// record is not approval, so a rejected decision is refused here rather than applied.
public struct CorpusIdentifierCorrection: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The corpus this correction applies to.
    public let corpus: ArtifactID

    /// The immutable record this correction was read from, whose identifier is this
    /// record's own.
    public let source: EvidenceSource

    /// The inventory this correction was written against.
    ///
    /// Reconciled against the manifest a run is handed, so a correction cannot be applied to
    /// an inventory nobody approved it for.
    public let subject: EvidenceSource

    /// The approved statement of how a corrected identifier is formed.
    ///
    /// Named and carried into provenance, never executed. Uniqueness of the result is
    /// verified; the result itself is read from ``corrections``.
    public let correctedIdentifierRule: EvidenceSource

    /// One entry per origin in every collision group.
    public let corrections: [CorpusIdentifierCorrectionEntry]

    /// Attributions for ambiguous comparison records, possibly none.
    public let comparisonReattributions: [CorpusComparisonReattribution]

    /// The decision that approved this correction. Presence is not approval.
    public let approval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        corpus: ArtifactID,
        source: EvidenceSource,
        subject: EvidenceSource,
        correctedIdentifierRule: EvidenceSource,
        corrections: [CorpusIdentifierCorrectionEntry],
        comparisonReattributions: [CorpusComparisonReattribution],
        approval: ApprovalRecord
    ) throws(CorpusRemediationError) {
        guard source.artifact == id else {
            throw CorpusRemediationError.provenanceDoesNotNameItsRecord(
                record: id,
                named: source.artifact
            )
        }
        guard approval.isApproved else {
            throw CorpusRemediationError.identifierCorrectionNotApproved(id)
        }
        guard !corrections.isEmpty else {
            throw CorpusRemediationError.identifierCorrectionEmpty(id)
        }
        var seenOrigins = Set<CanonicalRelativePath>()
        for correction in corrections where !seenOrigins.insert(correction.origin).inserted {
            throw CorpusRemediationError.duplicateCorrectedOrigin(correction.origin)
        }
        var seenKeys = Set<String>()
        for reattribution in comparisonReattributions
        where !seenKeys.insert(reattribution.lookupKey).inserted {
            throw CorpusRemediationError.duplicateComparisonReattribution(
                comparison: reattribution.comparison,
                identifier: reattribution.recordedIdentifier
            )
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.corpus = corpus
        self.source = source
        self.subject = subject
        self.correctedIdentifierRule = correctedIdentifierRule
        self.corrections = corrections
        self.comparisonReattributions = comparisonReattributions
        self.approval = approval
    }

    /// The correction recorded for one origin, or `nil` when the record has none.
    public func correction(
        at origin: CanonicalRelativePath
    ) -> CorpusIdentifierCorrectionEntry? {
        corrections.first { $0.origin == origin }
    }

    /// Every origin this correction covers.
    public var coveredOrigins: Set<CanonicalRelativePath> {
        Set(corrections.map(\.origin))
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, corpus, source, subject, correctedIdentifierRule
        case corrections, comparisonReattributions, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                corpus: container.decode(ArtifactID.self, forKey: .corpus),
                source: container.decode(EvidenceSource.self, forKey: .source),
                subject: container.decode(EvidenceSource.self, forKey: .subject),
                correctedIdentifierRule: container.decode(
                    EvidenceSource.self,
                    forKey: .correctedIdentifierRule
                ),
                corrections: container.decode(
                    [CorpusIdentifierCorrectionEntry].self,
                    forKey: .corrections
                ),
                comparisonReattributions: container.decode(
                    [CorpusComparisonReattribution].self,
                    forKey: .comparisonReattributions
                ),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as CorpusRemediationError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - The approved duplicate-hash disposition (Requirement 14.8)

/// The approved classification and disposition of one duplicate content hash.
///
/// ``retainedOrigins`` may hold every origin, some of them, or none. All three are decisions
/// a release owner can legitimately record, and nothing here narrows the set: retaining both
/// copies of identical bytes under two corrected identifiers is as valid a disposition as
/// dropping both, and a tool that preferred one would be choosing.
public struct DuplicateHashDisposition: Hashable, Codable, Sendable {
    /// The digest more than one entry shares.
    public let contentDigest: SHA256Digest

    /// Every entry origin sharing it, as the inventory records them.
    public let origins: [CanonicalRelativePath]

    /// What the approved record classified this duplicate as.
    public let classification: DuplicateClassificationID

    /// The origins the approved decision retains in the archival manifest.
    public let retainedOrigins: [CanonicalRelativePath]

    /// The immutable record the classification and disposition were read from.
    public let source: EvidenceSource

    public init(
        contentDigest: SHA256Digest,
        origins: [CanonicalRelativePath],
        classification: DuplicateClassificationID,
        retainedOrigins: [CanonicalRelativePath],
        source: EvidenceSource
    ) throws(CorpusRemediationError) {
        guard origins.count > 1 else {
            throw CorpusRemediationError.dispositionSubjectIsNotADuplicate(contentDigest)
        }
        var seen = Set<CanonicalRelativePath>()
        for origin in origins where !seen.insert(origin).inserted {
            throw CorpusRemediationError.duplicateDispositionOrigin(
                digest: contentDigest,
                origin: origin
            )
        }
        var retained = Set<CanonicalRelativePath>()
        for origin in retainedOrigins {
            guard retained.insert(origin).inserted else {
                throw CorpusRemediationError.duplicateDispositionOrigin(
                    digest: contentDigest,
                    origin: origin
                )
            }
            guard seen.contains(origin) else {
                throw CorpusRemediationError.retainedOriginNotInDuplicateGroup(
                    digest: contentDigest,
                    origin: origin
                )
            }
        }
        self.contentDigest = contentDigest
        self.origins = origins.sorted { $0.rawValue < $1.rawValue }
        self.classification = classification
        self.retainedOrigins = retainedOrigins.sorted { $0.rawValue < $1.rawValue }
        self.source = source
    }

    /// The origins this disposition keeps out of the archival manifest.
    public var excludedOrigins: Set<CanonicalRelativePath> {
        Set(origins).subtracting(retainedOrigins)
    }

    private enum CodingKeys: String, CodingKey {
        case contentDigest, origins, classification, retainedOrigins, source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                contentDigest: container.decode(SHA256Digest.self, forKey: .contentDigest),
                origins: container.decode([CanonicalRelativePath].self, forKey: .origins),
                classification: container.decode(
                    DuplicateClassificationID.self,
                    forKey: .classification
                ),
                retainedOrigins: container.decode(
                    [CanonicalRelativePath].self,
                    forKey: .retainedOrigins
                ),
                source: container.decode(EvidenceSource.self, forKey: .source)
            )
        } catch let error as CorpusRemediationError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

/// The approved disposition record for one corpus's duplicate content hashes.
public struct DuplicateHashDispositionRecord: Hashable, Codable, Sendable {
    public let id: ArtifactID
    public let schemaVersion: ArtifactSchemaVersion

    /// The corpus these dispositions apply to.
    public let corpus: ArtifactID

    /// The immutable record these dispositions were read from, whose identifier is this
    /// record's own.
    public let source: EvidenceSource

    /// The inventory these dispositions were written against.
    public let subject: EvidenceSource

    /// One disposition per duplicate content hash, each digest exactly once.
    public let dispositions: [DuplicateHashDisposition]

    /// The decision that approved this record. Presence is not approval.
    public let approval: ApprovalRecord

    public init(
        id: ArtifactID,
        schemaVersion: ArtifactSchemaVersion,
        corpus: ArtifactID,
        source: EvidenceSource,
        subject: EvidenceSource,
        dispositions: [DuplicateHashDisposition],
        approval: ApprovalRecord
    ) throws(CorpusRemediationError) {
        guard source.artifact == id else {
            throw CorpusRemediationError.provenanceDoesNotNameItsRecord(
                record: id,
                named: source.artifact
            )
        }
        guard approval.isApproved else {
            throw CorpusRemediationError.duplicateDispositionNotApproved(id)
        }
        guard !dispositions.isEmpty else {
            throw CorpusRemediationError.duplicateDispositionEmpty(id)
        }
        var seen = Set<SHA256Digest>()
        for disposition in dispositions
        where !seen.insert(disposition.contentDigest).inserted {
            throw CorpusRemediationError.repeatedDispositionSubject(disposition.contentDigest)
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.corpus = corpus
        self.source = source
        self.subject = subject
        self.dispositions = dispositions
        self.approval = approval
    }

    /// The disposition recorded for one digest, or `nil` when the record has none.
    public func disposition(for digest: SHA256Digest) -> DuplicateHashDisposition? {
        dispositions.first { $0.contentDigest == digest }
    }

    /// Every digest this record dispositions.
    public var dispositionedDigests: Set<SHA256Digest> {
        Set(dispositions.map(\.contentDigest))
    }

    /// Every origin any disposition keeps out of the archival manifest.
    public var excludedOrigins: Set<CanonicalRelativePath> {
        dispositions.reduce(into: Set<CanonicalRelativePath>()) {
            $0.formUnion($1.excludedOrigins)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, corpus, source, subject, dispositions, approval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ArtifactID.self, forKey: .id),
                schemaVersion: container.decode(ArtifactSchemaVersion.self, forKey: .schemaVersion),
                corpus: container.decode(ArtifactID.self, forKey: .corpus),
                source: container.decode(EvidenceSource.self, forKey: .source),
                subject: container.decode(EvidenceSource.self, forKey: .subject),
                dispositions: container.decode(
                    [DuplicateHashDisposition].self,
                    forKey: .dispositions
                ),
                approval: container.decode(ApprovalRecord.self, forKey: .approval)
            )
        } catch let error as CorpusRemediationError {
            throw error.asDecodingError(codingPath: decoder.codingPath)
        }
    }
}

// MARK: - The affected comparisons

/// One recorded comparison against a corpus entry, as it stands before correction.
///
/// The measured value is a digest here, and that is not laziness: a relabelling tool has no
/// business reading a measurement, and one that cannot read a measurement cannot alter one.
/// Regeneration rewrites the corpus reference and carries ``outcomeDigest`` through
/// unchanged, so no path in this module can re-measure, recompute, or adjust a comparison.
public struct CorpusComparisonRecord: Hashable, Codable, Sendable {
    /// The comparison artifact this record belongs to.
    public let comparison: ArtifactID

    /// The corpus identifier the comparison recorded. Ambiguous when it collides.
    public let recordedIdentifier: CorpusEntryID

    /// Digest of the corpus content the comparison was measured against.
    ///
    /// The disambiguator for a colliding identifier, and the reason most ambiguous
    /// comparisons need no decision at all: bytes that were scored are bytes that can be
    /// matched back to one entry.
    public let measuredContentDigest: SHA256Digest

    /// Digest of the recorded comparison outcome, opaque to this module.
    public let outcomeDigest: SHA256Digest

    /// The immutable artifact this comparison was read from.
    public let source: EvidenceSource

    public init(
        comparison: ArtifactID,
        recordedIdentifier: CorpusEntryID,
        measuredContentDigest: SHA256Digest,
        outcomeDigest: SHA256Digest,
        source: EvidenceSource
    ) {
        self.comparison = comparison
        self.recordedIdentifier = recordedIdentifier
        self.measuredContentDigest = measuredContentDigest
        self.outcomeDigest = outcomeDigest
        self.source = source
    }

    /// The key this record is reattributed by.
    var lookupKey: String {
        "\(comparison.rawValue)\u{1F}\(recordedIdentifier.rawValue)\u{1F}"
            + measuredContentDigest.hexadecimalString
    }
}
