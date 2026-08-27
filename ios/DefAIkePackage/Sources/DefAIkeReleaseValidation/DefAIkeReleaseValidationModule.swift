/// Boundary marker for nonshipping release tooling.
///
/// Responsibility: Model Bundle creation checks, calibration and release-slice
/// gates, fixture generation, device-result collection, device-allowlist
/// construction, and release-readiness record validation.
///
/// Dependency rule: `DefAIkeDomain` and `DefAIkeModelBundle`. This module is
/// linked only by test and tool targets; it is absent from both shipping
/// compositions. Automation here checks presence, identity, consistency, and
/// pass/fail status only. It does not generate legal advice, decide data rights,
/// choose a provenance trust policy, or approve governance risk.
///
/// In place: fixture-catalog completeness and asset verification, the eight parity
/// comparison runners, Initial Model Bundle creation plus release evidence, and
/// evaluation-corpus identifier remediation with evidence regeneration.
///
/// The parity runners compare an approved expected value against what a device observed,
/// for every comparison Requirements 13.6 through 13.11 name, and they produce no expected
/// value of their own: there is no digest computation, no preprocessing, no inference, and
/// no member that could complete a catalogue from the implementation under test. Two rules
/// are structural rather than documentary. A required comparison with no observation is a
/// failing cell that stays in the denominator of the measured agreement, so `notExecuted` is
/// unreachable for a cell and a run cannot raise its own ratio by observing fewer fixtures.
/// And a parity gate cannot be satisfied by a host or simulator process: an agreement carries
/// proof that its observations came from a physical iPhone on a plan candidate under the
/// bound version tuple, and a gate result additionally consults the environment this module
/// was compiled for, which no parameter changes. This repository has no physical device, so
/// every parity gate here is failing and the report names the reason.
///
/// The corpus tooling chooses neither of the two decisions Requirements 14.7 and 14.8
/// reserve for a release owner. The correction mapping for the known identifier collisions
/// and the classification and disposition of each known duplicate content hash both arrive
/// whole, through a seam with no default implementation, and a run without them fails rather
/// than deriving one. What the tooling contributes is reconciliation: it proves the corrected
/// identifiers are unique, relabels the affected comparisons without ever reading a recorded
/// measurement, and binds every regenerated artifact to the immutable identifiers and versions
/// it was produced from. It reaches no conclusion about licences, dataset terms, or whether
/// anything may be published.
///
/// The bundle tooling computes no digest, states no verification rule, selects no signing
/// key, and records no approval. It builds the canonical artifact tree, manifest, digest
/// inventory, notices, compatibility record, self-test references, and a signing *request*
/// from approved records; it then reads the signed result back through
/// `DefAIkeModelBundle`'s own verifiers and records the six gates Requirement 14.13 names.
/// Whether those recorded results permit a distribution is the Release Readiness Record's
/// decision, not this module's.
///
/// Populated by tasks 2.1 through 2.5 and the release-validation tasks.
public enum DefAIkeReleaseValidationModule: Sendable {
    /// Stable module identifier used by module-boundary and release-audit checks.
    public static let name = "DefAIkeReleaseValidation"
}
