// The claims a presentation model must not be able to represent.
//
// Requirement 8.9 forbids any claim of certainty, authenticity, authorship, intent,
// complete editing history, or absence of localized editing in approved copy and in
// every Combined Summary. Requirement 8.13 removes probability and confidence
// representations - numeric values, percentages, categorical confidence levels, and
// equivalent graphical encodings - from every Version 1 user-facing surface.
// Requirements 8.3 through 8.8 fix the qualified framing each individual state must
// use instead.
//
// Those are enforced structurally rather than by screening English text, because a
// word filter cannot tell a claim from a disclaimer: "not proof of authenticity" is
// required copy and contains the forbidden noun. Two mechanisms carry the guarantee:
//
//   1. No presentation model has a field a prohibited claim could occupy. There is
//      no `Double`, no percentage, no score, no level enum, no raw logit, and no
//      graphical-magnitude field anywhere in this module. The three fixed pixel
//      strings and the qualified per-state framing come from human-approved copy
//      addressed by key (``ResolvedCopyReference``), so a component cannot write its
//      own user-facing sentence.
//   2. The wording itself is approved outside the code. A catalogue carries an
//      `ApprovalRecord`, and ``ApprovedCopyBinding`` refuses a rejected one. The
//      design's non-property validation for Requirement 8 is human content approval
//      plus English UI snapshots, and this module does not substitute for either.
//
// This file is the written-down form of mechanism 1: the closed list of what may not
// appear, and the marker every presentation model carries to say it complies.

/// One claim category no presentation field may represent.
///
/// Closed and audited rather than advisory: the presentation test target enumerates
/// every model's stored properties and fails when one could carry any of these. A new
/// case here is a deliberate widening of the ban, never a new field.
public enum ProhibitedPresentationClaim: String, Hashable, Sendable, CaseIterable {
    /// A consumer probability, likelihood, or chance (Requirements 8.3 and 8.13).
    case probability

    /// A confidence value, percentage, or categorical confidence level
    /// (Requirement 8.13).
    case confidence

    /// A numeric percentage or score, or a graphical encoding equivalent to one
    /// such as a filled gauge, meter, or bar magnitude (Requirement 8.13).
    case percentageOrScore = "percentage-or-score"

    /// An uncalibrated raw model output presented as a consumer measure.
    ///
    /// A raw logit is not banned from existence: Requirement 8.15 permits one inside
    /// optional technical details when the approved optional-detail artifact enables
    /// it and labels it uncalibrated. It is banned from every evidence-carrying
    /// presentation model, so it can never sit beside a label and read as a score.
    case rawLogit = "raw-logit"

    /// Certainty about the result rather than probabilistic consistency
    /// (Requirements 8.3 and 8.9).
    case certainty

    /// That the image is authentic, genuine, or unmanipulated. A non-positive pixel
    /// label and an absent Content Credential are both explicitly not authenticity
    /// results (Requirements 8.4, 8.5, 8.7, and 8.9).
    case authenticity

    /// Who created or captured the depicted image. Cryptographic claim validation
    /// establishes binding, not factual truth of any signed assertion
    /// (Requirements 8.6 and 8.9).
    case authorship

    /// Why an image was made or shared (Requirement 8.9).
    case intent

    /// That the complete editing history of the image is known (Requirement 8.9).
    case completeEditingHistory = "complete-editing-history"

    /// That no localized editing occurred. Localized edits are outside the evidence
    /// scope entirely (Requirements 8.9 and 8.10).
    case absenceOfLocalizedEditing = "absence-of-localized-editing"
}

/// A presentation model that represents none of the ``ProhibitedPresentationClaim``
/// categories.
///
/// Conformance is a claim about shape, and the presentation test target checks it by
/// reflection over every stored property: no floating-point or numeric magnitude
/// field, no percentage, and no field whose name implies a probability, confidence,
/// score, or logit. A model that needs a number that is genuinely not a result
/// magnitude - a recorded pixel dimension, for example - carries it as the domain's
/// own measured value type rather than as a bare `Double`.
///
/// The protocol adds no requirements on purpose. Its job is to name the contract in
/// one place and to give the audit something to be generic over, not to hand a model
/// a way to satisfy the rule by implementing a method.
public protocol ProbabilityFreePresentationModel: Hashable, Sendable {}
