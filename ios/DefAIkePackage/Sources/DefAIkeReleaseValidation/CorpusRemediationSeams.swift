import DefAIkeDomain

// The one thing corpus remediation reaches out for: the two approved records that carry the
// decisions it is forbidden to make.
//
// Everything else about a remediation is a pure function of values already in hand — the
// pre-correction inventory, the affected comparisons, and the identity the regenerated
// evidence publishes under. The correction mapping and the duplicate-hash disposition are not,
// because they are decisions rather than data, and a tool that could produce either would be
// answering Requirements 14.7 and 14.8 on a release owner's behalf.
//
// So they arrive through a seam with **no default implementation anywhere in this module**. A
// remediator that has not been given a reader cannot be constructed, and a reader that has no
// record for a corpus reports that fact rather than synthesizing one. That is the whole of the
// fail-closed requirement in structural form: the absent-input path leads to
// ``CorpusRemediationError/identifierCorrectionMissing(corpus:fault:)`` or
// ``CorpusRemediationError/duplicateDispositionMissing(corpus:fault:)`` and nowhere else.
//
// Deliberately absent from the seam:
//
//   * any member that writes, creates, drafts, or amends a record;
//   * any member that returns a partial, provisional, or candidate correction;
//   * any member that lists, ranks, or offers alternatives, so a run has nothing to choose
//     between and no way to prefer one mapping over another;
//   * any member that returns a classification, a disposition, or a retention set separately
//     from the approved record that carries them, so a caller cannot assemble a record out of
//     parts; and
//   * any member touching licence terms, dataset terms, publication permission, or any other
//     distribution-rights conclusion. Those belong to `DistributionRightsRecord` and the
//     release-readiness record, and this seam cannot reach them.

/// Why an approved corpus-remediation record could not be read.
///
/// Structural outcomes only, with no framework error and no absolute path. Every one of them
/// is a refusal: there is no case that means "read a substitute", and none that a remediation
/// run can recover from, because recovering would mean deciding.
public enum ApprovedCorpusRecordFault: Error, Equatable, Sendable, CaseIterable {
    /// No approved record exists for that corpus.
    ///
    /// The case Requirements 14.7 and 14.8 turn on. A run stops here; it does not derive a
    /// correction from the corrected identifier rule and does not classify a duplicate.
    case recordAbsent

    /// The record exists but its content could not be read.
    case recordUnreadable

    /// The record store itself is unavailable.
    case storeUnavailable
}

/// Reads the two approved records one corpus remediation depends on.
///
/// Two members, each returning one whole record for one corpus. That shape is the point: a
/// member that returned a set would let a run pick, and a member that returned a fragment
/// would let a caller build a record the approval never covered.
///
/// Whether the returned records are *coherent with the inventory in hand* — same corpus, same
/// subject inventory version, covering exactly the collisions and duplicates it exhibits — is
/// ``CorpusRemediator``'s reconciliation, not this seam's. The seam answers only "what did the
/// approved record say".
public protocol ApprovedCorpusRemediationReading: Sendable {
    /// The approved identifier correction for one corpus (Requirement 14.7).
    func identifierCorrection(
        forCorpus corpus: ArtifactID
    ) throws(ApprovedCorpusRecordFault) -> CorpusIdentifierCorrection

    /// The approved duplicate content-hash disposition for one corpus (Requirement 14.8).
    func duplicateHashDisposition(
        forCorpus corpus: ArtifactID
    ) throws(ApprovedCorpusRecordFault) -> DuplicateHashDispositionRecord
}
