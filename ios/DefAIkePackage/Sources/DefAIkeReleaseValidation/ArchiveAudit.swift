import DefAIkeDomain
import Foundation

// Ingesting the archive audit's output as typed release evidence, and the one seam it needs.
//
// The audit itself is `ios/Scripts/audit-release-archives.py`. It generates the Software Bill of
// Materials, reconciles dependency identities and binary digests, inventories both bundles,
// checks required notices and forbidden corpus content, audits privacy manifests, and runs the
// three sibling audit scripts that own the forbidden-dependency, endpoint, result-export, and
// offline claims. What arrives here is its report.
//
// Reading rather than re-measuring is the division of labour, and the reason is not convenience:
// the measurements are Mach-O symbol tables, object files under `Intermediates.noindex`, a 420 MB
// static archive, and 10,832 corpus files indexed by size and then digested. None of that belongs
// in a Swift module that must stay linkable by a test target and absent from both shipping
// compositions. What does belong here is the *decision*, because task 14.8 needs typed evidence
// and a decision expressed as a type cannot be softened by the code that consumes it.

// MARK: - The seam

/// Why an archive-audit report could not be read.
///
/// Structural outcomes only: no framework error, no absolute path, no partial document. Each is a
/// refusal, and none is recoverable, because recovering would mean this module deciding what the
/// audit would have measured.
public enum ArchiveAuditReportFault: Error, Equatable, Sendable, CaseIterable,
    CustomStringConvertible
{
    /// No report exists. The audit was not run.
    case reportAbsent

    /// A report exists but its bytes could not be read or decoded.
    case reportUnreadable

    /// A report exists and names a bill of materials that does not.
    ///
    /// Distinct from ``reportUnreadable`` because the two are closed by different work: an
    /// unreadable report needs the audit re-run, and a missing bill of materials needs it run
    /// with `--sbom-directory`.
    case billOfMaterialsAbsent

    public var description: String {
        switch self {
        case .reportAbsent: "no archive-audit report exists"
        case .reportUnreadable: "the archive-audit report could not be read"
        case .billOfMaterialsAbsent: "the report names a bill of materials that does not exist"
        }
    }
}

/// Reads one archive-audit run's output.
///
/// Two members, and the shape is the point. The report and the per-composition bill of materials
/// are separate artifacts the audit writes to separate paths, and a reader that returned them
/// together could substitute one composition's document for another's without anything noticing.
/// Asking for a named composition's document by name is what makes the mismatch checkable.
///
/// **There is no default implementation anywhere in this module.** A validator that has not been
/// given a reader cannot be constructed.
///
/// Deliberately absent from the seam:
///
///   * any member that returns a gate outcome, an approval, or an eligibility conclusion, so a
///     reader cannot supply the answer alongside the evidence;
///   * any member that writes, records, or publishes anything. The audit produces artifacts; this
///     module reads them; and
///   * any member that takes a path, a URL, or a file handle. Where the artifacts live is the
///     caller's business, and a seam that carried a path would make this module's behaviour
///     depend on a filesystem layout no release artifact declares.
public protocol ArchiveAuditReportReading: Sendable {
    /// The audit's release-record input document, as written by `--release-input`.
    func auditReport() throws(ArchiveAuditReportFault) -> Data

    /// One composition's bill of materials, as written by `--sbom-directory`.
    func billOfMaterials(
        forComposition composition: String
    ) throws(ArchiveAuditReportFault) -> Data
}

// MARK: - The report

/// One archive-audit run, as release evidence.
///
/// Decoding is where every structural rule is enforced, so a report that reached this type is one
/// whose gate outcomes are consistent with its own findings. In particular:
///
///   * an unrecognised producer, schema version, gate, finding class, or owed-input identifier is
///     a refusal rather than a dropped field;
///   * every gate this task produces evidence for must be present, so an omission is seen;
///   * every stated outcome is re-derived from the findings and owed inputs, and a disagreement
///     is a refusal. This is the check that makes the whole ingestion trustworthy: without it,
///     the release record's archive gates would be whatever a JSON file said they were; and
///   * a report claiming to have inspected archives while inventorying no bundle is a refusal,
///     because an audit that examined nothing finds nothing and would otherwise pass.
public struct ArchiveAuditReport: Sendable {

    /// The one producer this module accepts.
    public static let expectedProducer = "ios/Scripts/audit-release-archives.py"

    /// The highest report schema version this revision can fully interpret.
    public static let maximumSupportedSchemaVersion = 1

    public let schemaVersion: Int
    public let archivesInspected: Bool

    /// One entry per gate this task produces evidence for, in `ReleaseGate` declaration order.
    public let gates: [ArchiveAuditGateEvidence]

    /// Every measurement the audit recorded that is not a violation, carried unchanged.
    public let observations: [ArchiveAuditObservation]

    /// How many files each inspected bundle contains, per composition and bundle name.
    ///
    /// The release artifact manifest's shape, kept because it is what makes "the audit inspected
    /// something" checkable rather than asserted.
    public let bundleFileCounts: [String: [String: Int]]

    /// Whether every gate this task produces evidence for is passing.
    ///
    /// Deliberately not called `isEligible` and deliberately not a release decision. Requirement
    /// 14.15's eligibility judgement belongs to the release validator over the whole record; this
    /// answers only whether the archive half contributes a blocker.
    public var everyProducedGatePasses: Bool {
        gates.allSatisfy { $0.outcome.isPassing }
    }

    /// Every failing input class this run actually exercised.
    ///
    /// Reported so a release record can distinguish "the audit found nothing" from "the audit
    /// found nothing and has never been shown to find anything". The audit script's `--self-test`
    /// and `--self-test-archives` are where non-vacuity is established; this is the runtime
    /// summary of which classes fired in the run being recorded.
    public var exercisedFailingInputClasses: Set<ArchiveAuditFailingInputClass> {
        gates.reduce(into: Set()) { $0.formUnion($1.exercisedClasses) }
    }

    /// Every release-controlled input this run does not have, pooled across gates.
    public var unprovisionedInputs: [UnprovisionedArchiveAuditInput] {
        var seen: [UnprovisionedArchiveAuditInput] = []
        for gate in gates {
            for input in gate.unprovisionedInputs where !seen.contains(input) {
                seen.append(input)
            }
        }
        return seen
    }

    /// This run's entries in the release-readiness record.
    ///
    /// One `ReleaseGateRecord` per produced gate, all bound to the same evidence source, because
    /// they came from one audit run over one pair of archives. Splitting them across sources
    /// would let a record mix two runs, which Requirement 13.20's version-tuple rule forbids for
    /// device evidence and which is no more acceptable here.
    public func releaseGateRecords(evidence: EvidenceSource) throws -> [ReleaseGateRecord] {
        try gates.map { try $0.releaseGateRecord(evidence: evidence) }
    }

    init(
        schemaVersion: Int,
        archivesInspected: Bool,
        gates: [ArchiveAuditGateEvidence],
        observations: [ArchiveAuditObservation],
        bundleFileCounts: [String: [String: Int]]
    ) {
        self.schemaVersion = schemaVersion
        self.archivesInspected = archivesInspected
        self.gates = gates
        self.observations = observations
        self.bundleFileCounts = bundleFileCounts
    }
}

// MARK: - Decoding

/// The wire shape of the audit's release-record input, exactly as the script writes it.
///
/// A separate private type from ``ArchiveAuditReport`` on purpose. The wire shape carries a
/// *stated* outcome per gate, and the evidence type carries a *derived* one; giving them one type
/// would mean the stated value had a home in the validated model, and the point is that it does
/// not survive validation.
private struct WireArchiveAuditReport: Decodable {
    struct Gate: Decodable {
        let gate: String
        let outcome: String
        let unprovisionedInputs: [String]
    }

    struct Observation: Decodable {
        let kind: String
        let requirements: [String]?
        let note: String?
    }

    let schemaVersion: Int
    let producedBy: String
    let archivesInspected: Bool
    let gates: [Gate]
    let findingsByClass: [String: [String]]
    let observations: [Observation]
    let facts: WireFacts

    /// The audit's `facts`, of which exactly one field is modelled.
    ///
    /// The audit emits tens of kilobytes of measured facts — per-image symbol counts, endpoint
    /// inventories, object owners, corpus comparison counts. Modelling all of it here would make
    /// this type a second schema for the audit's internals, and every audit change a compile
    /// error in a release-validation module. What a gate decision needs from `facts` is the one
    /// thing that says the audit inspected something, so that is the one thing decoded; the rest
    /// stays in the artifact on disk, which is where a release record references it.
    struct WireFacts: Decodable {
        let bundleFileCounts: [String: [String: Int]]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var counts: [String: [String: Int]] = [:]
            for key in container.allKeys where key.stringValue.hasSuffix(".bundleFileCounts") {
                let composition = String(
                    key.stringValue.dropLast(".bundleFileCounts".count)
                )
                counts[composition] = try container.decode([String: Int].self, forKey: key)
            }
            self.bundleFileCounts = counts
        }
    }

    struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

extension ArchiveAuditReport {

    /// Decode and validate one audit report.
    ///
    /// Untyped `throws` rather than `throws(ArchiveAuditBindingError)` because `JSONDecoder`
    /// throws `DecodingError`, and a typed signature here would mean either swallowing that or
    /// translating every decoding failure into a binding error it is not. A caller that wants to
    /// distinguish them matches on the error.
    public static func decode(_ data: Data) throws -> ArchiveAuditReport {
        let wire = try JSONDecoder().decode(WireArchiveAuditReport.self, from: data)

        guard wire.producedBy == Self.expectedProducer else {
            throw ArchiveAuditBindingError.unexpectedProducer(wire.producedBy)
        }
        guard wire.schemaVersion <= Self.maximumSupportedSchemaVersion,
              wire.schemaVersion > 0
        else {
            throw ArchiveAuditBindingError.unsupportedSchemaVersion(wire.schemaVersion)
        }

        // Route findings to gates by class, from `findingsByClass` rather than from each gate's
        // own list. The per-gate list carries messages without their class, and a finding whose
        // class had to be inferred from the gate it was filed under would make the class field
        // decorative — while the class is exactly what Requirement 14.6 enumerates.
        var findingsForGate: [ReleaseGate: [ArchiveAuditFinding]] = [:]
        for (rawClass, details) in wire.findingsByClass {
            guard let inputClass = ArchiveAuditFailingInputClass(rawValue: rawClass) else {
                throw ArchiveAuditBindingError.unknownFailingInputClass(rawClass)
            }
            for detail in details {
                findingsForGate[inputClass.gate, default: []].append(
                    ArchiveAuditFinding(failingInputClass: inputClass, detail: detail)
                )
            }
        }

        var evidence: [ArchiveAuditGateEvidence] = []
        var seen: Set<ReleaseGate> = []
        for entry in wire.gates {
            guard let gate = ReleaseGate(rawValue: entry.gate) else {
                throw ArchiveAuditBindingError.gateNotProducedByThisAudit(entry.gate)
            }
            guard ArchiveAuditFailingInputClass.producedGates.contains(gate) else {
                throw ArchiveAuditBindingError.gateNotProducedByThisAudit(entry.gate)
            }
            var owed: [UnprovisionedArchiveAuditInput] = []
            for raw in entry.unprovisionedInputs {
                guard let input = UnprovisionedArchiveAuditInput(rawValue: raw) else {
                    throw ArchiveAuditBindingError.unknownUnprovisionedInput(raw)
                }
                owed.append(input)
            }
            let gateEvidence = ArchiveAuditGateEvidence(
                gate: gate,
                findings: findingsForGate[gate] ?? [],
                unprovisionedInputs: owed,
                archivesInspected: wire.archivesInspected
            )
            guard let stated = GateOutcome(rawValue: entry.outcome) else {
                throw ArchiveAuditBindingError.statedOutcomeContradictsFindings(
                    gate: gate,
                    stated: .notExecuted,
                    derived: gateEvidence.outcome
                )
            }
            guard stated == gateEvidence.outcome else {
                throw ArchiveAuditBindingError.statedOutcomeContradictsFindings(
                    gate: gate,
                    stated: stated,
                    derived: gateEvidence.outcome
                )
            }
            seen.insert(gate)
            evidence.append(gateEvidence)
        }

        let missing = ArchiveAuditFailingInputClass.producedGates.subtracting(seen)
        if let first = missing.sorted(by: { $0.rawValue < $1.rawValue }).first {
            throw ArchiveAuditBindingError.gateMissingFromReport(first)
        }

        let counts = wire.facts.bundleFileCounts
        if wire.archivesInspected {
            let inspected = counts.values.contains { bundles in
                !bundles.isEmpty && bundles.values.allSatisfy { $0 > 0 }
            }
            guard inspected else {
                throw ArchiveAuditBindingError.archivesClaimedInspectedWithNoBundleInventory
            }
        }

        return ArchiveAuditReport(
            schemaVersion: wire.schemaVersion,
            archivesInspected: wire.archivesInspected,
            gates: evidence.sorted { lhs, rhs in
                lhs.gate.rawValue < rhs.gate.rawValue
            },
            observations: wire.observations.map {
                ArchiveAuditObservation(
                    kind: $0.kind,
                    requirements: $0.requirements ?? [],
                    note: $0.note
                )
            },
            bundleFileCounts: counts
        )
    }
}

// MARK: - The bill of materials, decoded

/// The wire shape of a CycloneDX 1.6 document, restricted to the fields this module reads.
private struct WireCycloneDXDocument: Decodable {
    struct NameValue: Decodable {
        let name: String
        let value: String
    }

    struct Hash: Decodable {
        let alg: String
        let content: String
    }

    struct Component: Decodable {
        let type: String
        let name: String
        let version: String?
        let scope: String?
        let hashes: [Hash]?
        let properties: [NameValue]?
    }

    struct Dependency: Decodable {
        let ref: String
        let dependsOn: [String]
    }

    let bomFormat: String
    let specVersion: String
    let components: [Component]
    let dependencies: [Dependency]?
}

extension SoftwareBillOfMaterials {

    /// Decode and validate one CycloneDX document.
    ///
    /// A component whose `type` this module does not model is a refusal rather than a skip, for
    /// the same reason an unknown gate is: a component nobody decided how to treat, treated as a
    /// library by default, is how an unreviewed artifact reaches a release record.
    public static func decode(_ data: Data) throws -> SoftwareBillOfMaterials {
        let wire = try JSONDecoder().decode(WireCycloneDXDocument.self, from: data)
        var components: [BillOfMaterialsComponent] = []
        for component in wire.components {
            guard let kind = BillOfMaterialsComponent.Kind(rawValue: component.type) else {
                throw ArchiveAuditBindingError.billOfMaterialsComponentNotReconciled(
                    "\(component.name) has unmodelled component type \(component.type)"
                )
            }
            var scope: BillOfMaterialsComponent.Scope?
            if let raw = component.scope {
                guard let value = BillOfMaterialsComponent.Scope(rawValue: raw) else {
                    throw ArchiveAuditBindingError.billOfMaterialsComponentNotReconciled(
                        "\(component.name) has unmodelled scope \(raw)"
                    )
                }
                scope = value
            }
            var hashes: [String: [String]] = [:]
            for hash in component.hashes ?? [] {
                hashes[hash.alg, default: []].append(hash.content)
            }
            var properties: [String: [String]] = [:]
            for property in component.properties ?? [] {
                properties[property.name, default: []].append(property.value)
            }
            components.append(
                BillOfMaterialsComponent(
                    type: kind,
                    name: component.name,
                    version: component.version,
                    scope: scope,
                    hashes: hashes,
                    properties: properties
                )
            )
        }
        var dependencies: [String: [String]] = [:]
        for edge in wire.dependencies ?? [] {
            dependencies[edge.ref, default: []].append(contentsOf: edge.dependsOn)
        }
        return try SoftwareBillOfMaterials(
            format: wire.bomFormat,
            specificationVersion: wire.specVersion,
            components: components,
            dependencies: dependencies
        )
    }
}

// MARK: - The validator

/// Reads one archive-audit run and reports what it contributes to the release record.
///
/// Consumes, and does not manufacture, approvals — the same rule the rest of this module follows.
/// It reaches no licensing conclusion, approves no digest, composes no notice, and decides no
/// distribution. What it adds over decoding is the reconciliation between the two artifacts the
/// audit writes: a bill of materials that lists a shipped package the report never reconciled is
/// a finding, because a release record built from the pair would then claim coverage it does not
/// have.
public struct ArchiveAuditValidator: Sendable {
    private let reader: any ArchiveAuditReportReading

    public init(reader: any ArchiveAuditReportReading) {
        self.reader = reader
    }

    /// One composition's validated archive evidence, plus its bill of materials.
    public struct Result: Sendable {
        public let report: ArchiveAuditReport
        public let billOfMaterials: SoftwareBillOfMaterials

        /// Shipped bill-of-materials components carrying a digest no approval covers.
        ///
        /// The bill of materials is where an unapproved binary digest is *visible*; the report is
        /// where it is *routed to a gate*. Both are checked, because a document that recorded a
        /// digest the report failed to route would be a failing input nobody counted.
        public var unapprovedDigestComponents: [BillOfMaterialsComponent] {
            billOfMaterials.componentsWithUnapprovedDigests
        }

        /// Whether the pair is internally consistent: every unapproved digest the document
        /// carries is accounted for by an archive-audit finding or an owed input.
        public var digestEvidenceIsReconciled: Bool {
            guard !unapprovedDigestComponents.isEmpty else { return true }
            let archiveGate = report.gates.first { $0.gate == .archiveAudit }
            guard let archiveGate else { return false }
            return !archiveGate.outcome.isPassing
        }
    }

    /// Read and validate one composition's audit output.
    public func validate(composition: String) throws -> Result {
        let reportData = try reader.auditReport()
        let bomData = try reader.billOfMaterials(forComposition: composition)
        let report = try ArchiveAuditReport.decode(reportData)
        let bom = try SoftwareBillOfMaterials.decode(bomData)
        let result = Result(report: report, billOfMaterials: bom)
        guard result.digestEvidenceIsReconciled else {
            throw ArchiveAuditBindingError.billOfMaterialsComponentNotReconciled(
                result.unapprovedDigestComponents
                    .map(\.name)
                    .sorted()
                    .joined(separator: ", ")
            )
        }
        return result
    }
}
