import DefAIkeDomain

// The typed archive-audit evidence task 14.8 assembles into the signed release record.
//
// Why the typed representation is here and not a second script. Task 14.6's clause is "treat
// every unapproved dependency, binary digest, notice gap, corpus artifact, or prohibited
// capability as a failing release record input", and task 14.8 joins archive evidence with
// calibration, bundle, privacy, accessibility, localization, legal, governance, device,
// fixture, capability, and limitation evidence into one payload. Everything 14.8 joins is a
// typed value in this module already — ``BundleReleaseEvidence``, ``ParityGateResult``,
// ``ResourceGateResult``, ``AccessibilityMatrixResult``, ``CorpusRemediationOutcome``. Archive
// evidence arriving as a JSON blob would be the one input 14.8 had to parse and interpret
// itself, and interpreting is where a failing input becomes a warning.
//
// So the split is: the audit *measures* in Python, because measuring means reading Mach-O
// symbol tables, walking `Intermediates.noindex`, digesting a 420 MB static archive, and
// running three sibling audit scripts — none of which belongs in a Swift release-validation
// module. The audit's output is *interpreted* here, where the interpretation is a type.
//
// Two structural rules make the interpretation trustworthy, and both are the reason this is a
// type rather than a decoded dictionary:
//
//   * A gate outcome is **derived, never decoded**. ``ArchiveAuditReport/outcome(for:)``
//     computes each outcome from the findings and owed inputs the report carries, and
//     ``ArchiveAuditReport/init(from:)`` refuses a report whose stated outcome disagrees. A
//     report that said `passed` beside a finding is not representable.
//   * An audit that inspected nothing cannot pass. A report claiming inspection with no bundle
//     inventory is refused, and a report that inspected no archives yields `notExecuted` for
//     every gate — which `GateOutcome.isPassing` does not satisfy.
//
// What this file does not do: reach a licensing conclusion, approve a digest, compose notice
// text, or decide whether a distribution may proceed. It carries measurements and gaps.

// MARK: - The bill of materials

/// One component of a Software Bill of Materials, as this module reads it.
///
/// A deliberately small subset of CycloneDX's component schema: the fields a release record
/// needs to say *what shipped, at which bytes, and where it came from*. Fields the audit emits
/// and this type ignores — external references, MIME types, tool metadata — stay in the document
/// on disk, which is the artifact a release publishes; this type is what a gate decision reads.
public struct BillOfMaterialsComponent: Hashable, Sendable, Codable {

    /// CycloneDX component types this module accepts.
    ///
    /// A closed set rather than a free string, because an unexpected type would be a component
    /// nobody decided how to treat, and treating it as a library by default is how an unreviewed
    /// artifact reaches a release record.
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case library
        case file
        case application
        case machineLearningModel = "machine-learning-model"
    }

    /// CycloneDX scope values, which is how the document states that a package resolves into the
    /// graph but is not linked into *this* composition.
    public enum Scope: String, Hashable, Sendable, Codable, CaseIterable {
        case required
        case excluded
        case optional
    }

    public let type: Kind
    public let name: String
    public let version: String?
    public let scope: Scope?

    /// Every recorded digest of this component's bytes, keyed by algorithm name.
    ///
    /// A dictionary rather than a single digest because CycloneDX records a list, and because a
    /// binary artifact with several architecture slices has one digest per slice. An empty
    /// dictionary is meaningful and permitted: a source package has no single shipped byte
    /// sequence to digest, and pretending otherwise would be a fabricated measurement.
    public let hashes: [String: [String]]

    /// The audit's namespaced properties, flattened. Carries the resolved revision, whether the
    /// component ships in this composition, and the digest approval status.
    public let properties: [String: [String]]

    public init(
        type: Kind,
        name: String,
        version: String?,
        scope: Scope?,
        hashes: [String: [String]],
        properties: [String: [String]]
    ) {
        self.type = type
        self.name = name
        self.version = version
        self.scope = scope
        self.hashes = hashes
        self.properties = properties
    }

    /// The resolved source-control revision the audit recorded, when there is one.
    ///
    /// A version tag can be moved; the revision is what binds a pin to fixed bytes, which is why
    /// a release record wants this and not only the version.
    public var resolvedRevision: String? {
        properties["dev.defaike.resolvedRevision"]?.first
    }

    /// Whether this component ships in the composition the document describes.
    public var shipsInThisComposition: Bool {
        properties["dev.defaike.shipsInThisComposition"]?.first == "true"
    }

    /// The approval status string a release approval must carry.
    public static let approvedDigestStatus = "release-approved"

    /// Whether a recorded digest carries a release approval, as the audit labelled it.
    ///
    /// False for the vendored binary artifact today: its digests are a measured baseline. True for
    /// the pixel model, because Requirement 10.4 fixes its weight digest in the requirements
    /// document and the audit cross-checks that value against the shipping constant.
    ///
    /// A component with a digest and no status is treated as **unapproved**, not as approved by
    /// default. That direction is the whole reason "unapproved binary digest" is a failing input
    /// class: a default of approved would mean a new digest-bearing component arrived approved.
    public var digestApprovalIsRecorded: Bool {
        guard !hashes.isEmpty else { return true }
        return properties["dev.defaike.digestApprovalStatus"]?.first == Self.approvedDigestStatus
    }
}

/// A Software Bill of Materials as release evidence.
///
/// The format and version are checked rather than assumed. A document in a format this module
/// does not read would decode field by field into something plausible and wrong, so the two
/// identifying fields are validated at construction and the type cannot exist otherwise.
public struct SoftwareBillOfMaterials: Hashable, Sendable {

    /// The one format this module reads. See `ios/Scripts/audit-release-archives.py` for why
    /// CycloneDX rather than SPDX; the short version is that a binary digest is a first-class
    /// field there, an SBOM whose central failing-input class is a digest wants that, and the
    /// JSON schema survives `Codable` without a parser.
    public static let supportedFormat = "CycloneDX"

    /// The one specification version this module reads.
    public static let supportedSpecificationVersion = "1.6"

    public let format: String
    public let specificationVersion: String
    public let components: [BillOfMaterialsComponent]

    /// Edges from the composition to what it contains, keyed by reference.
    public let dependencies: [String: [String]]

    public init(
        format: String,
        specificationVersion: String,
        components: [BillOfMaterialsComponent],
        dependencies: [String: [String]]
    ) throws(ArchiveAuditBindingError) {
        guard format == Self.supportedFormat,
              specificationVersion == Self.supportedSpecificationVersion
        else {
            throw ArchiveAuditBindingError.unsupportedBillOfMaterialsFormat(
                format: format,
                specVersion: specificationVersion
            )
        }
        guard !components.isEmpty else {
            throw ArchiveAuditBindingError.billOfMaterialsEmpty
        }
        self.format = format
        self.specificationVersion = specificationVersion
        self.components = components
        self.dependencies = dependencies
    }

    /// Every library component that ships in the described composition.
    public var shippedLibraries: [BillOfMaterialsComponent] {
        components.filter { $0.type == .library && $0.shipsInThisComposition }
    }

    /// Every component whose digest is an approval subject and carries no approval.
    ///
    /// The direct expression of Requirement 14.6's "unapproved binary digest" class. Restricted
    /// to libraries and models, and that restriction is a correction rather than a convenience:
    /// the first version of this member filtered on "has a digest", which selected all thirty
    /// `file` components too. Those are the release artifact manifest — the audit digests every
    /// shipped byte so corpus membership and substitution are checkable — and a manifest entry is
    /// evidence, not a pending approval. Reporting `DefAIke.app/PkgInfo` as an unapproved binary
    /// digest would bury the one component that genuinely is one.
    public var componentsWithUnapprovedDigests: [BillOfMaterialsComponent] {
        components.filter { component in
            switch component.type {
            case .library, .machineLearningModel:
                !component.hashes.isEmpty && !component.digestApprovalIsRecorded
            case .file, .application:
                false
            }
        }
    }
}

// MARK: - One gate's archive evidence

/// One release-readiness gate's archive-audit evidence.
///
/// The `outcome` is not stored. It is computed from `findings` and `unprovisionedInputs`, so a
/// gate with either cannot be passing and a gate with neither cannot be failing. Requirement
/// 14.15 blocks distribution on a missing or failing mandatory entry, and this is where "missing
/// is not pass" stops being a convention.
public struct ArchiveAuditGateEvidence: Hashable, Sendable {
    public let gate: ReleaseGate

    /// Every finding routed to this gate, each already tagged with its failing input class.
    public let findings: [ArchiveAuditFinding]

    /// Every release-controlled input this gate depends on and does not have.
    public let unprovisionedInputs: [UnprovisionedArchiveAuditInput]

    /// Whether the audit inspected archives at all. A run that inspected none produces
    /// `notExecuted` rather than a pass over nothing.
    public let archivesInspected: Bool

    public init(
        gate: ReleaseGate,
        findings: [ArchiveAuditFinding],
        unprovisionedInputs: [UnprovisionedArchiveAuditInput],
        archivesInspected: Bool
    ) {
        self.gate = gate
        self.findings = findings
        self.unprovisionedInputs = unprovisionedInputs
        self.archivesInspected = archivesInspected
    }

    /// The gate outcome, derived.
    ///
    /// Three values and no fourth, matching `GateOutcome` exactly. There is no "passed with
    /// warnings", because Requirement 14.6 makes each of the five classes a failing input and a
    /// fourth value is how one would stop being one.
    public var outcome: GateOutcome {
        guard archivesInspected else { return .notExecuted }
        return findings.isEmpty && unprovisionedInputs.isEmpty ? .passed : .failed
    }

    /// The failing input classes this gate's findings actually exercised.
    public var exercisedClasses: Set<ArchiveAuditFailingInputClass> {
        Set(findings.map(\.failingInputClass))
    }

    /// This gate's entry in the release-readiness record.
    ///
    /// Every gate this task produces evidence for is unconditional, so applicability is always
    /// `.applicable`: `ReleaseGateRecord` refuses `notApplicable` for an unconditional gate, and
    /// that refusal is deliberately not worked around here. A pixel-only release does not get to
    /// waive its archive audit.
    public func releaseGateRecord(evidence: EvidenceSource) throws -> ReleaseGateRecord {
        try ReleaseGateRecord(
            gate: gate,
            applicability: .applicable,
            outcome: outcome,
            evidence: evidence
        )
    }
}

/// One archive-audit finding, tagged with the class that makes it a failing input.
public struct ArchiveAuditFinding: Hashable, Sendable, Codable {
    public let failingInputClass: ArchiveAuditFailingInputClass

    /// What was measured, in the audit's own words.
    ///
    /// Carried verbatim rather than re-templated. The audit names a bundle, a path, a digest, or
    /// a package identity, and a release record that reworded it would be a second account of
    /// one measurement.
    public let detail: String

    public init(failingInputClass: ArchiveAuditFailingInputClass, detail: String) {
        self.failingInputClass = failingInputClass
        self.detail = detail
    }
}

// MARK: - One measured observation

/// One measurement the audit recorded that is not a violation.
///
/// The Provenance Feasibility Gate inputs tasks 12.3 and 12.5 classified as observations arrive
/// here unchanged: the statically linked HTTP/2 and TLS stack in the provenance archive, the
/// compiled-in OCSP client, the absent bundled model, the endpoint inventory. Keeping the
/// classification rather than re-deciding it is deliberate — two tasks measured those and
/// concluded they are gate inputs, and a third task quietly promoting one to a violation would
/// mean the release record contains two contradictory accounts of the same bytes.
public struct ArchiveAuditObservation: Hashable, Sendable, Codable {
    public let kind: String

    /// The requirement identifiers the observation bears on, as the audit recorded them.
    public let requirements: [String]

    /// The audit's own note. Verbatim, for the same reason a finding's detail is.
    public let note: String?

    public init(kind: String, requirements: [String], note: String?) {
        self.kind = kind
        self.requirements = requirements
        self.note = note
    }
}
