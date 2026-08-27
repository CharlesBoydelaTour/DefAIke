import DefAIkeDomain

// Why a corpus remediation did not produce regenerated evidence.
//
// Three rules shape the set, and they are the fail-closed content of Requirements 14.7
// and 14.8:
//
//   * **No case can be resolved by inventing a value.** There is no "correction absent, will
//     be derived from the rule" and no "classification absent, will be inferred from the
//     digests". A missing approved input is a finding, because the alternative is this module
//     authoring the decision the requirement reserves for a release owner.
//   * **No case means "regenerated with a caveat".** A run either produces a
//     ``CorpusRemediation`` whose identifiers are unique and whose provenance is complete, or
//     it produces one of these findings and no artifact at all.
//   * **No case is a distribution conclusion.** Nothing here says a corpus may be published,
//     a claim may be made, or a right is resolved. Those are Requirement 14.2 through 14.4
//     and 14.15 decisions, recorded in the release-readiness record.
//
// Separate from `ArtifactSchemaError`, which says one artifact is malformed, and from
// `FixtureCatalogError`, which is about a fixture suite's completeness. A remediation finding
// names the one reconciliation that failed, so an audit can point at an origin, an identifier,
// a digest, or a comparison rather than at "bad corpus".

/// Why an evaluation corpus could not be remediated, or its regenerated evidence trusted.
public enum CorpusRemediationError: Error, Equatable, Sendable, CustomStringConvertible {
    // MARK: Missing approved input

    /// No approved identifier-correction record exists for this corpus.
    ///
    /// Requirement 14.7's fail-closed case. A run cannot proceed without the mapping and
    /// cannot derive one from the corrected identifier rule.
    case identifierCorrectionMissing(corpus: ArtifactID, fault: ApprovedCorpusRecordFault)

    /// No approved duplicate-hash disposition record exists for this corpus.
    ///
    /// Requirement 14.8's fail-closed case. A run cannot classify a duplicate itself.
    case duplicateDispositionMissing(corpus: ArtifactID, fault: ApprovedCorpusRecordFault)

    // MARK: Presence is not approval

    /// The identifier-correction record carries a rejection rather than an approval.
    case identifierCorrectionNotApproved(ArtifactID)

    /// The duplicate-hash disposition record carries a rejection rather than an approval.
    case duplicateDispositionNotApproved(ArtifactID)

    // MARK: Structural record faults

    /// A record's own provenance names a different artifact, so a regenerated artifact's
    /// provenance would point away from the record that produced it.
    case provenanceDoesNotNameItsRecord(record: ArtifactID, named: ArtifactID)

    /// The corpus inventory holds no entries.
    case corpusManifestEmpty(ArtifactID)

    /// The inventory records two entries at the same origin, so the only unique key the
    /// corpus has is ambiguous too.
    case duplicateCorpusOrigin(CanonicalRelativePath)

    /// The correction record holds no corrections.
    case identifierCorrectionEmpty(ArtifactID)

    /// The correction record corrects the same origin twice.
    case duplicateCorrectedOrigin(CanonicalRelativePath)

    /// The correction record reattributes the same comparison record twice.
    case duplicateComparisonReattribution(comparison: ArtifactID, identifier: CorpusEntryID)

    /// The disposition record holds no dispositions.
    case duplicateDispositionEmpty(ArtifactID)

    /// A disposition names fewer than two origins, so its subject is not a duplicate.
    case dispositionSubjectIsNotADuplicate(SHA256Digest)

    /// A disposition lists the same origin twice.
    case duplicateDispositionOrigin(digest: SHA256Digest, origin: CanonicalRelativePath)

    /// A disposition retains an origin that does not share the digest it dispositions.
    case retainedOriginNotInDuplicateGroup(digest: SHA256Digest, origin: CanonicalRelativePath)

    /// The disposition record dispositions the same digest twice.
    case repeatedDispositionSubject(SHA256Digest)

    // MARK: Records reconciled against the inventory

    /// An approved record was written for a different corpus.
    case recordCorpusMismatch(record: ArtifactID, expected: ArtifactID, found: ArtifactID)

    /// An approved record was written against a different inventory version, so the
    /// collisions and duplicates it names are not the ones in hand.
    case recordSubjectMismatch(record: ArtifactID, expected: EvidenceSource, found: EvidenceSource)

    /// The inventory does not exhibit the number of identifier collisions Requirement 14.7
    /// fixes, so it is not the corpus the correction is about.
    case collisionCountMismatch(expected: Int, found: Int)

    /// The inventory does not exhibit the number of duplicate content hashes
    /// Requirement 14.8 fixes.
    case duplicateHashCountMismatch(expected: Int, found: Int)

    /// The correction names an origin the inventory does not carry.
    case correctedOriginNotInCorpus(CanonicalRelativePath)

    /// The correction restates an identifier the inventory does not record at that origin.
    case correctionSubjectMismatch(
        origin: CanonicalRelativePath,
        expected: CorpusEntryID,
        found: CorpusEntryID
    )

    /// The correction corrects an entry whose identifier does not collide, which is outside
    /// what Requirement 14.7 approved it for.
    case correctionOfNonCollidingEntry(origin: CanonicalRelativePath, identifier: CorpusEntryID)

    /// A collision group has origins the correction does not cover. A partial correction is
    /// not a correction: the uncovered copies would keep an ambiguous identifier.
    case collisionGroupNotFullyCorrected(
        identifier: CorpusEntryID,
        uncovered: [CanonicalRelativePath]
    )

    /// A disposition dispositions a digest no two inventory entries share.
    case dispositionSubjectNotDuplicatedInCorpus(SHA256Digest)

    /// A disposition's origins are not exactly the inventory entries sharing that digest.
    case dispositionOriginsMismatch(
        digest: SHA256Digest,
        expected: [CanonicalRelativePath],
        found: [CanonicalRelativePath]
    )

    /// A duplicate content hash in the inventory has no recorded disposition.
    case duplicateHashNotDispositioned([SHA256Digest])

    // MARK: Uniqueness under the corrected identifier rule

    /// Applying the approved correction leaves an identifier naming more than one entry, so
    /// the corrected inventory is no more usable than the one it replaces.
    case correctedIdentifiersNotUnique(identifier: CorpusEntryID, origins: [CanonicalRelativePath])

    // MARK: Regenerating comparisons

    /// Two comparison records in the same artifact are indistinguishable, so a reattribution
    /// could not name one of them.
    case duplicateComparisonRecord(comparison: ArtifactID, identifier: CorpusEntryID)

    /// A comparison names an identifier and digest pair the inventory has no entry for, so it
    /// was not measured against this corpus.
    case comparisonMatchesNoEntry(comparison: ArtifactID, identifier: CorpusEntryID)

    /// A comparison matches more than one entry and the approved record does not attribute
    /// it. Nothing left in the data distinguishes the candidates, and this module does not
    /// pick one.
    case comparisonReattributionMissing(
        comparison: ArtifactID,
        identifier: CorpusEntryID,
        candidates: [CanonicalRelativePath]
    )

    /// An approved attribution names an origin that is not one of the candidates the
    /// comparison could have measured.
    case comparisonReattributedOutsideCandidates(
        comparison: ArtifactID,
        identifier: CorpusEntryID,
        origin: CanonicalRelativePath
    )

    /// The correction record attributes a comparison record this run did not resolve by
    /// decision: either it was not handed that record, or digest agreement already named one
    /// entry.
    ///
    /// Refused rather than ignored in both readings. An attribution the run never consulted is
    /// an approved decision that had no effect, and if it disagreed with the entry digest
    /// agreement picked, ignoring it would be code overriding the decision.
    case comparisonReattributionUnused(comparison: ArtifactID, identifier: CorpusEntryID)

    /// Two records of one comparison artifact name different versions of it, so provenance
    /// cannot say which version the regenerated comparisons came from.
    case comparisonSourceVersionsMixed(
        comparison: ArtifactID,
        first: SchemaSemanticVersion,
        second: SchemaSemanticVersion
    )

    // MARK: Emitting

    /// The regenerated evidence could not be encoded to reproducible canonical bytes.
    case regeneratedEvidenceNotEncodable(CanonicalEncodingFault)

    public var description: String {
        switch self {
        case let .identifierCorrectionMissing(corpus, fault):
            return """
                no approved identifier correction is available for corpus \
                \(corpus.rawValue): \(Self.text(for: fault))
                """
        case let .duplicateDispositionMissing(corpus, fault):
            return """
                no approved duplicate-hash disposition is available for corpus \
                \(corpus.rawValue): \(Self.text(for: fault))
                """
        case let .identifierCorrectionNotApproved(record):
            return "the identifier correction record \(record.rawValue) is not approved"
        case let .duplicateDispositionNotApproved(record):
            return "the duplicate-hash disposition record \(record.rawValue) is not approved"
        case let .provenanceDoesNotNameItsRecord(record, named):
            return """
                record \(record.rawValue) carries provenance naming \(named.rawValue); a \
                record's provenance names the record itself
                """
        case let .corpusManifestEmpty(manifest):
            return "the corpus inventory \(manifest.rawValue) holds no entries"
        case let .duplicateCorpusOrigin(origin):
            return "the corpus inventory records two entries at \"\(origin.rawValue)\""
        case let .identifierCorrectionEmpty(record):
            return "the identifier correction record \(record.rawValue) holds no corrections"
        case let .duplicateCorrectedOrigin(origin):
            return "the correction record corrects \"\(origin.rawValue)\" more than once"
        case let .duplicateComparisonReattribution(comparison, identifier):
            return """
                the correction record attributes \(comparison.rawValue) record \
                \(identifier.rawValue) more than once
                """
        case let .duplicateDispositionEmpty(record):
            return "the disposition record \(record.rawValue) holds no dispositions"
        case let .dispositionSubjectIsNotADuplicate(digest):
            return """
                the disposition for \(digest.hexadecimalString) names fewer than two origins, \
                so its subject is not a duplicate
                """
        case let .duplicateDispositionOrigin(digest, origin):
            return """
                the disposition for \(digest.hexadecimalString) lists \"\(origin.rawValue)\" \
                more than once
                """
        case let .retainedOriginNotInDuplicateGroup(digest, origin):
            return """
                the disposition for \(digest.hexadecimalString) retains \
                \"\(origin.rawValue)\", which does not share that digest
                """
        case let .repeatedDispositionSubject(digest):
            return """
                the disposition record dispositions \(digest.hexadecimalString) more than once
                """
        case let .recordCorpusMismatch(record, expected, found):
            return """
                record \(record.rawValue) applies to corpus \(found.rawValue); this run \
                remediates \(expected.rawValue)
                """
        case let .recordSubjectMismatch(record, expected, found):
            return """
                record \(record.rawValue) was written against inventory \
                \(found.artifact.rawValue) version \(found.version); this run holds \
                \(expected.artifact.rawValue) version \(expected.version)
                """
        case let .collisionCountMismatch(expected, found):
            return """
                the inventory exhibits \(found) identifier collisions; the known corpus \
                exhibits exactly \(expected)
                """
        case let .duplicateHashCountMismatch(expected, found):
            return """
                the inventory exhibits \(found) duplicate content hashes; the known corpus \
                exhibits exactly \(expected)
                """
        case let .correctedOriginNotInCorpus(origin):
            return "the correction names \"\(origin.rawValue)\", which the inventory omits"
        case let .correctionSubjectMismatch(origin, expected, found):
            return """
                the correction for \"\(origin.rawValue)\" restates \(found.rawValue); the \
                inventory records \(expected.rawValue)
                """
        case let .correctionOfNonCollidingEntry(origin, identifier):
            return """
                the correction rewrites \"\(origin.rawValue)\", whose identifier \
                \(identifier.rawValue) names exactly one entry
                """
        case let .collisionGroupNotFullyCorrected(identifier, uncovered):
            return """
                the collision on \(identifier.rawValue) leaves \(uncovered.map(\.rawValue)) \
                uncorrected; a partially corrected group stays ambiguous
                """
        case let .dispositionSubjectNotDuplicatedInCorpus(digest):
            return """
                \(digest.hexadecimalString) is dispositioned but no two inventory entries \
                share it
                """
        case let .dispositionOriginsMismatch(digest, expected, found):
            return """
                the disposition for \(digest.hexadecimalString) names \
                \(found.map(\.rawValue)); the inventory shares it across \
                \(expected.map(\.rawValue))
                """
        case let .duplicateHashNotDispositioned(digests):
            return """
                no disposition is recorded for duplicate content hashes \
                \(digests.map(\.hexadecimalString))
                """
        case let .correctedIdentifiersNotUnique(identifier, origins):
            return """
                after correction, \(identifier.rawValue) still names \
                \(origins.map(\.rawValue))
                """
        case let .duplicateComparisonRecord(comparison, identifier):
            return """
                \(comparison.rawValue) holds two indistinguishable records for \
                \(identifier.rawValue)
                """
        case let .comparisonMatchesNoEntry(comparison, identifier):
            return """
                \(comparison.rawValue) records \(identifier.rawValue) against content the \
                inventory has no entry for
                """
        case let .comparisonReattributionMissing(comparison, identifier, candidates):
            return """
                \(comparison.rawValue) record \(identifier.rawValue) could have measured \
                \(candidates.map(\.rawValue)) and the approved record attributes it to none
                """
        case let .comparisonReattributedOutsideCandidates(comparison, identifier, origin):
            return """
                \(comparison.rawValue) record \(identifier.rawValue) is attributed to \
                \"\(origin.rawValue)\", which it could not have measured
                """
        case let .comparisonReattributionUnused(comparison, identifier):
            return """
                the correction record attributes \(comparison.rawValue) record \
                \(identifier.rawValue), which this run either was not handed or resolved \
                without a decision
                """
        case let .comparisonSourceVersionsMixed(comparison, first, second):
            return """
                \(comparison.rawValue) is recorded at both version \(first) and version \
                \(second); provenance cannot name two
                """
        case let .regeneratedEvidenceNotEncodable(fault):
            return """
                the regenerated evidence could not be encoded canonically: \
                \(Self.text(for: fault))
                """
        }
    }

    private static func text(for fault: ApprovedCorpusRecordFault) -> String {
        switch fault {
        case .recordAbsent: "no such record exists"
        case .recordUnreadable: "the record could not be read"
        case .storeUnavailable: "the record store is unavailable"
        }
    }

    private static func text(for fault: CanonicalEncodingFault) -> String {
        switch fault {
        case .notEncodable: "the value could not be encoded to JSON"
        case let .notWellFormed(offset): "the encoded bytes are malformed at byte \(offset)"
        case let .tooDeep(maximum): "the encoded value nests deeper than \(maximum) levels"
        }
    }
}

extension CorpusRemediationError {
    /// Surfaces a remediation finding as a decoding failure.
    ///
    /// The approved records decode by delegating to their validating initializers, so a
    /// signed record cannot introduce a combination in-process construction would reject.
    public func asDecodingError(codingPath: [any CodingKey]) -> DecodingError {
        DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: description,
                underlyingError: self
            )
        )
    }
}
