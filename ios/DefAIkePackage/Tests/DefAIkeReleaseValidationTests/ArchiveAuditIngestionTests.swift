import DefAIkeDomain
import Foundation
import Testing

@testable import DefAIkeReleaseValidation

// Ingesting the archive audit's output, probed one field at a time (task 14.10).
//
// Task 14.6 shipped ``ArchiveAuditReport/decode(_:)``, ``SoftwareBillOfMaterials/decode(_:)``, and
// ``ArchiveAuditValidator`` with no Swift tests at all — task 14.8 flagged that, and the privacy
// and notices halves of task 14.10 are exactly this surface. So this suite is the structural half
// 14.6 designed and never exercised: a clean synthetic document plus one mutation per structural
// rule, each required to produce exactly the refusal it should.
//
// **Every document here is a synthetic fixture written by this test file.** None is the audit's
// real output, none reports a real measurement, and none of the digests, package names, revisions,
// or approval statuses is a real approval. The audit itself
// (`ios/Scripts/audit-release-archives.py`) is untouched by this task and correctly exits 1 in
// this repository with six notice gaps and six owed inputs; that is a fact about the working tree
// rather than something this suite reproduces.
//
// Two rules 14.6 documented as load-bearing, and both are probed here:
//
//   * a gate outcome is **derived, never decoded** — a report whose stated outcome disagrees with
//     the outcome its own findings imply is refused; and
//   * an audit that inspected nothing cannot pass — a report claiming inspection with an empty
//     bundle inventory is refused, and a report that inspected no archive yields `not-executed`.

// MARK: - Synthetic documents

/// A synthetic archive-audit report document, with one knob per structural rule.
///
/// Emitted as text rather than through `JSONSerialization` on purpose. Every value in this
/// document is a string, an integer, or a boolean, so no exact decimal is at risk — but building
/// the bytes directly keeps a probe's mutation visible as the one field it changes, and lets a
/// probe emit a field the wire type cannot represent at all.
struct SyntheticAuditDocument {
    var schemaVersion = 1
    var producedBy = ArchiveAuditReport.expectedProducer
    var archivesInspected = true

    /// One entry per gate, as `(gate identifier, stated outcome, owed input identifiers)`.
    ///
    /// Defaults to the four gates this audit produces evidence for, each stating `passed`, which
    /// is the outcome no finding and no owed input derives.
    var gates: [(gate: String, outcome: String, owed: [String])] = ArchiveAuditFailingInputClass
        .producedGates
        .map(\.rawValue)
        .sorted()
        .map { (gate: $0, outcome: GateOutcome.passed.rawValue, owed: []) }

    /// Findings keyed by failing input class identifier.
    var findingsByClass: [String: [String]] = [:]

    /// Bundle inventories, keyed by composition. Nonempty is what makes "inspected" checkable.
    var bundleFileCounts: [String: [String: Int]] = ["pixel-only": ["DefAIke.app": 42]]

    /// Sets one gate's stated outcome, leaving the others alone.
    mutating func state(_ outcome: String, for gate: ReleaseGate) {
        for index in gates.indices where gates[index].gate == gate.rawValue {
            gates[index].outcome = outcome
        }
    }

    /// Adds one finding under `rawClass`, and states the gate it routes to as `failed`.
    ///
    /// Both halves together, so the default document stays internally consistent and a probe that
    /// means to break the agreement has to break it explicitly.
    mutating func addFinding(_ rawClass: String, detail: String, statingFailedFor gate: ReleaseGate?)
    {
        findingsByClass[rawClass, default: []].append(detail)
        if let gate { state(GateOutcome.failed.rawValue, for: gate) }
    }

    var data: Data { Data(text.utf8) }

    var text: String {
        let gateEntries = gates.map { entry in
            let owed = entry.owed.map { "\"\($0)\"" }.joined(separator: ", ")
            return """
                    {
                      "gate": "\(entry.gate)",
                      "outcome": "\(entry.outcome)",
                      "unprovisionedInputs": [\(owed)]
                    }
                """
        }
        let findingEntries = findingsByClass.keys.sorted().map { key in
            let details = (findingsByClass[key] ?? [])
                .map { "\"\($0)\"" }
                .joined(separator: ", ")
            return "    \"\(key)\": [\(details)]"
        }
        let factEntries = bundleFileCounts.keys.sorted().map { composition in
            let bundles = (bundleFileCounts[composition] ?? [:]).keys.sorted().map {
                "\"\($0)\": \(bundleFileCounts[composition]?[$0] ?? 0)"
            }
            return "    \"\(composition).bundleFileCounts\": {\(bundles.joined(separator: ", "))}"
        }
        return """
            {
              "schemaVersion": \(schemaVersion),
              "producedBy": "\(producedBy)",
              "archivesInspected": \(archivesInspected),
              "gates": [
            \(gateEntries.joined(separator: ",\n"))
              ],
              "findingsByClass": {
            \(findingEntries.joined(separator: ",\n"))
              },
              "observations": [
                {
                  "kind": "synthetic-observation",
                  "requirements": ["14.6"],
                  "note": "a synthetic observation written by the test suite"
                }
              ],
              "facts": {
            \(factEntries.joined(separator: ",\n"))
              }
            }
            """
    }
}

/// A synthetic CycloneDX 1.6 document, with one knob per structural rule.
struct SyntheticBillOfMaterials {
    struct Component {
        var type = "library"
        var name: String
        var version: String? = "1.0.0"
        var scope: String? = "required"
        var hashes: [(algorithm: String, content: String)] = []
        var properties: [(name: String, value: String)] = []
    }

    var bomFormat = SoftwareBillOfMaterials.supportedFormat
    var specVersion = SoftwareBillOfMaterials.supportedSpecificationVersion
    var components: [Component] = [
        Component(
            name: "synthetic-shipped-library",
            properties: [
                (name: "dev.defaike.resolvedRevision", value: "0000000000000000000000000000000000000000"),
                (name: "dev.defaike.shipsInThisComposition", value: "true"),
            ]
        )
    ]

    var data: Data { Data(text.utf8) }

    var text: String {
        let entries = components.map { component in
            var fields = [
                "      \"type\": \"\(component.type)\"",
                "      \"name\": \"\(component.name)\"",
            ]
            if let version = component.version {
                fields.append("      \"version\": \"\(version)\"")
            }
            if let scope = component.scope {
                fields.append("      \"scope\": \"\(scope)\"")
            }
            if !component.hashes.isEmpty {
                let hashes = component.hashes.map {
                    "{\"alg\": \"\($0.algorithm)\", \"content\": \"\($0.content)\"}"
                }
                fields.append("      \"hashes\": [\(hashes.joined(separator: ", "))]")
            }
            if !component.properties.isEmpty {
                let properties = component.properties.map {
                    "{\"name\": \"\($0.name)\", \"value\": \"\($0.value)\"}"
                }
                fields.append("      \"properties\": [\(properties.joined(separator: ", "))]")
            }
            return "    {\n\(fields.joined(separator: ",\n"))\n    }"
        }
        return """
            {
              "bomFormat": "\(bomFormat)",
              "specVersion": "\(specVersion)",
              "components": [
            \(entries.joined(separator: ",\n"))
              ],
              "dependencies": []
            }
            """
    }
}

// MARK: - The clean report

/// The baseline report, verified before any refusal probe runs.
@Suite("Archive audit ingestion: the clean synthetic report")
struct ArchiveAuditCleanReportTests {

    @Test("The clean synthetic report decodes and every produced gate passes")
    func cleanReportDecodes() throws {
        let report = try ArchiveAuditReport.decode(SyntheticAuditDocument().data)
        #expect(report.schemaVersion == 1)
        #expect(report.archivesInspected)
        #expect(report.gates.count == 4)
        #expect(report.gates.count == ArchiveAuditFailingInputClass.producedGates.count)
        #expect(report.everyProducedGatePasses)
        #expect(report.unprovisionedInputs.isEmpty)
        #expect(report.exercisedFailingInputClasses.isEmpty)
        // The one modelled fact, which is what makes "the audit inspected something" checkable
        // rather than asserted.
        #expect(report.bundleFileCounts["pixel-only"]?["DefAIke.app"] == 42)
        // Observations travel unchanged rather than being reclassified.
        #expect(report.observations.count == 1)
        let observation = try #require(report.observations.first)
        #expect(observation.kind == "synthetic-observation")
        #expect(observation.requirements == ["14.6"])
    }

    @Test("Every produced gate is present and ordered by identifier")
    func gatesAreCompleteAndOrdered() throws {
        let report = try ArchiveAuditReport.decode(SyntheticAuditDocument().data)
        var identifiers: [String] = []
        for gate in report.gates {
            identifiers.append(gate.gate.rawValue)
        }
        #expect(identifiers == identifiers.sorted())
        #expect(Set(identifiers) == Set(ArchiveAuditFailingInputClass.producedGates.map(\.rawValue)))
    }

    @Test("One planted finding fails exactly the gate its class routes to")
    func onePlantedFindingFailsOneGate() throws {
        var probes = 0
        for inputClass in ArchiveAuditFailingInputClass.allCases {
            probes += 1
            var document = SyntheticAuditDocument()
            document.addFinding(
                inputClass.rawValue,
                detail: "synthetic planted \(inputClass.rawValue)",
                statingFailedFor: inputClass.gate
            )
            let report = try ArchiveAuditReport.decode(document.data)
            var failed: Set<ReleaseGate> = []
            for gate in report.gates where !gate.outcome.isPassing {
                failed.insert(gate.gate)
            }
            #expect(failed == Set([inputClass.gate]))
            #expect(report.exercisedFailingInputClasses == Set([inputClass]))
            #expect(!report.everyProducedGatePasses)
            // The audit's own detail travels verbatim rather than being re-templated.
            let entry = try #require(report.gates.first { $0.gate == inputClass.gate })
            let details = entry.findings.map(\.detail).joined(separator: " | ")
            #expect(details.contains("synthetic planted"))
        }
        #expect(probes == 5)
        #expect(probes == ArchiveAuditFailingInputClass.allCases.count)
    }

    @Test("A report that inspected no archive yields not-executed for every gate")
    func aReportThatInspectedNothingYieldsNoResult() throws {
        var document = SyntheticAuditDocument()
        document.archivesInspected = false
        // An uninspected report's derived outcome is `not-executed`, so its stated outcomes have
        // to say so — which is itself the derived-outcome rule holding.
        for gate in ArchiveAuditFailingInputClass.producedGates {
            document.state(GateOutcome.notExecuted.rawValue, for: gate)
        }
        // The inventory stays nonempty, so this probe turns on `archivesInspected` alone.
        let report = try ArchiveAuditReport.decode(document.data)
        #expect(!report.archivesInspected)
        for gate in report.gates {
            #expect(gate.outcome == GateOutcome.notExecuted)
            #expect(!gate.outcome.isPassing)
        }
        #expect(!report.everyProducedGatePasses)
    }
}

// MARK: - Report refusals

/// Every structural refusal ``ArchiveAuditReport/decode(_:)`` makes, one mutation each.
@Suite("Archive audit ingestion: report refusals")
struct ArchiveAuditReportRefusalTests

{
    /// Decodes `document` and returns the binding error, or records an issue.
    private func refusal(
        of document: SyntheticAuditDocument,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> ArchiveAuditBindingError? {
        do {
            _ = try ArchiveAuditReport.decode(document.data)
            Issue.record("decoding accepted a report it must refuse", sourceLocation: sourceLocation)
            return nil
        } catch let error as ArchiveAuditBindingError {
            return error
        } catch {
            Issue.record("an unexpected decoding error", sourceLocation: sourceLocation)
            return nil
        }
    }

    @Test("An unknown producer is refused")
    func unknownProducerIsRefused() throws {
        var document = SyntheticAuditDocument()
        document.producedBy = "ios/Scripts/some-other-tool.py"
        let recorded = try #require(refusal(of: document))
        guard case let .unexpectedProducer(named) = recorded else {
            Issue.record("an unknown producer must be refused as one")
            return
        }
        #expect(named == "ios/Scripts/some-other-tool.py")
    }

    @Test("An unsupported schema version is refused in both directions")
    func unsupportedSchemaVersionIsRefused() throws {
        var probes = 0
        for version in [0, -1, ArchiveAuditReport.maximumSupportedSchemaVersion + 1] {
            probes += 1
            var document = SyntheticAuditDocument()
            document.schemaVersion = version
            let recorded = try #require(refusal(of: document))
            guard case let .unsupportedSchemaVersion(named) = recorded else {
                Issue.record("an unsupported schema version must be refused as one")
                continue
            }
            #expect(named == version)
        }
        // Both directions plus zero: a version this revision cannot interpret and a version that
        // is not a version at all are each refused rather than partially read.
        #expect(probes == 3)
    }

    @Test("A gate this audit produces no evidence for is refused")
    func aGateOutsideTheAuditIsRefused() throws {
        var probes = 0
        // A real `ReleaseGate` the audit does not produce, and a string that is no gate at all.
        // Both are refused the same way, which is the point: a report claiming authority it does
        // not have and a report naming nothing are both unreadable rather than partially read.
        for raw in [ReleaseGate.deviceAllowlist.rawValue, "not-a-gate-at-all"] {
            probes += 1
            var document = SyntheticAuditDocument()
            document.gates.append((gate: raw, outcome: GateOutcome.passed.rawValue, owed: []))
            let recorded = try #require(refusal(of: document))
            guard case let .gateNotProducedByThisAudit(named) = recorded else {
                Issue.record("a gate outside this audit must be refused as one")
                continue
            }
            #expect(named == raw)
        }
        #expect(probes == 2)
    }

    @Test("An omitted produced gate is refused rather than left missing")
    func anOmittedGateIsRefused() throws {
        var probes = 0
        for omitted in ArchiveAuditFailingInputClass.producedGates.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            probes += 1
            var document = SyntheticAuditDocument()
            document.gates.removeAll { $0.gate == omitted.rawValue }
            #expect(document.gates.count == 3)
            let recorded = try #require(refusal(of: document))
            guard case let .gateMissingFromReport(named) = recorded else {
                Issue.record("an omitted produced gate must be refused as one")
                continue
            }
            // Refused as *a* missing gate; the decoder reports the first in identifier order, so a
            // probe that removed a later gate hears about that gate and a probe that removed an
            // earlier one hears about it too.
            #expect(ArchiveAuditFailingInputClass.producedGates.contains(named))
            if named != omitted {
                #expect(named.rawValue < omitted.rawValue)
            }
        }
        #expect(probes == 4)
    }

    @Test("A stated outcome that disagrees with the findings is refused")
    func aStatedOutcomeThatDisagreesIsRefused() throws {
        // The load-bearing check. Without it a release record's archive gates would be whatever a
        // JSON file said they were.
        var probes = 0
        for inputClass in ArchiveAuditFailingInputClass.allCases {
            probes += 1
            var document = SyntheticAuditDocument()
            // A finding, and a gate that still states `passed` beside it.
            document.addFinding(
                inputClass.rawValue,
                detail: "synthetic planted \(inputClass.rawValue)",
                statingFailedFor: nil
            )
            let recorded = try #require(refusal(of: document))
            guard case let .statedOutcomeContradictsFindings(gate, stated, derived) = recorded else {
                Issue.record("a stated outcome beside a finding must be refused as a disagreement")
                continue
            }
            #expect(gate == inputClass.gate)
            #expect(stated == GateOutcome.passed)
            #expect(derived == GateOutcome.failed)
        }
        #expect(probes == 5)
    }

    @Test("A stated failure with nothing failing is refused too")
    func aStatedFailureWithNothingFailingIsRefused() throws {
        // The other direction. A report that overstates a failure is as unreadable as one that
        // understates it: both mean the stated field is not derived from the findings.
        var document = SyntheticAuditDocument()
        document.state(GateOutcome.failed.rawValue, for: .corpusExclusion)
        let recorded = try #require(refusal(of: document))
        guard case let .statedOutcomeContradictsFindings(gate, stated, derived) = recorded else {
            Issue.record("a stated failure with nothing failing must be refused")
            return
        }
        #expect(gate == ReleaseGate.corpusExclusion)
        #expect(stated == GateOutcome.failed)
        #expect(derived == GateOutcome.passed)
    }

    @Test("An outcome identifier that is no outcome is refused")
    func anUnknownOutcomeIdentifierIsRefused() throws {
        var document = SyntheticAuditDocument()
        document.state("passed-with-warnings", for: .privacyAudit)
        let recorded = try #require(refusal(of: document))
        guard case let .statedOutcomeContradictsFindings(gate, stated, derived) = recorded else {
            Issue.record("an unreadable outcome must be refused rather than defaulted")
            return
        }
        #expect(gate == ReleaseGate.privacyAudit)
        // Reported as `not-executed` on the stated side, because there is no fourth `GateOutcome`
        // for the decoder to carry an unreadable value in — and `not-executed` is the honest
        // reading of a value nothing could interpret.
        #expect(stated == GateOutcome.notExecuted)
        #expect(derived == GateOutcome.passed)
    }

    @Test("An unknown failing input class is refused")
    func anUnknownFailingInputClassIsRefused() throws {
        var document = SyntheticAuditDocument()
        document.findingsByClass["unmodelled-class"] = ["something the audit measured"]
        let recorded = try #require(refusal(of: document))
        guard case let .unknownFailingInputClass(named) = recorded else {
            Issue.record("an unknown finding class must be refused as one")
            return
        }
        #expect(named == "unmodelled-class")
    }

    @Test("An unknown owed-input identifier is refused")
    func anUnknownOwedInputIsRefused() throws {
        var document = SyntheticAuditDocument()
        for index in document.gates.indices where document.gates[index].gate == "archive-audit" {
            document.gates[index].owed = ["some-input-nobody-enumerated"]
            document.gates[index].outcome = GateOutcome.failed.rawValue
        }
        let recorded = try #require(refusal(of: document))
        guard case let .unknownUnprovisionedInput(named) = recorded else {
            Issue.record("an unknown owed input must be refused as one")
            return
        }
        #expect(named == "some-input-nobody-enumerated")
    }

    @Test("Each enumerated owed input decodes and fails its gate")
    func eachEnumeratedOwedInputDecodes() throws {
        var probes = 0
        for owed in UnprovisionedArchiveAuditInput.allCases {
            probes += 1
            var document = SyntheticAuditDocument()
            for index in document.gates.indices
            where document.gates[index].gate == ReleaseGate.archiveAudit.rawValue {
                document.gates[index].owed = [owed.rawValue]
                document.gates[index].outcome = GateOutcome.failed.rawValue
            }
            let report = try ArchiveAuditReport.decode(document.data)
            #expect(report.unprovisionedInputs == [owed])
            let entry = try #require(report.gates.first { $0.gate == .archiveAudit })
            #expect(entry.outcome == GateOutcome.failed)
            #expect(entry.findings.isEmpty)
            // Owed is not the same as failing-with-a-finding, and both block. The distinction is
            // what lets a release audit tell "nobody supplied it" from "it was measured and bad".
            #expect(!report.everyProducedGatePasses)
        }
        #expect(probes == 6)
        #expect(probes == UnprovisionedArchiveAuditInput.allCases.count)
    }

    @Test("A report claiming inspection with an empty bundle inventory is refused")
    func inspectionWithNoInventoryIsRefused() throws {
        var probes = 0
        // Three shapes of "no inventory": no composition at all, a composition with no bundle, and
        // a bundle whose file count is zero. All three describe an audit that examined nothing.
        let empties: [[String: [String: Int]]] = [
            [:],
            ["pixel-only": [:]],
            ["pixel-only": ["DefAIke.app": 0]],
        ]
        for counts in empties {
            probes += 1
            var document = SyntheticAuditDocument()
            document.bundleFileCounts = counts
            let recorded = try #require(refusal(of: document))
            #expect(recorded == ArchiveAuditBindingError.archivesClaimedInspectedWithNoBundleInventory)
        }
        #expect(probes == 3)
    }

    @Test("A report that inspected nothing is not required to inventory anything")
    func anUninspectedReportNeedsNoInventory() throws {
        // The inverse of the rule above, and it has to hold or the audit could never report a run
        // that found no archive to inspect.
        var document = SyntheticAuditDocument()
        document.archivesInspected = false
        document.bundleFileCounts = [:]
        for gate in ArchiveAuditFailingInputClass.producedGates {
            document.state(GateOutcome.notExecuted.rawValue, for: gate)
        }
        let report = try ArchiveAuditReport.decode(document.data)
        #expect(!report.archivesInspected)
        #expect(report.bundleFileCounts.isEmpty)
        #expect(!report.everyProducedGatePasses)
    }

    @Test("Bytes that are not a report at all are a decoding error rather than a binding error")
    func malformedBytesAreADecodingError() throws {
        var caught: (any Error)?
        do {
            _ = try ArchiveAuditReport.decode(Data("not json at all".utf8))
        } catch {
            caught = error
        }
        let recorded = try #require(caught)
        #expect(!(recorded is ArchiveAuditBindingError))
        // Untyped `throws` on purpose: `JSONDecoder` throws `DecodingError`, and translating that
        // into a binding error it is not would make the two indistinguishable.
        #expect(recorded is DecodingError)
    }
}

// MARK: - Bill of materials refusals

/// Every structural refusal ``SoftwareBillOfMaterials/decode(_:)`` makes.
@Suite("Archive audit ingestion: bill of materials refusals")
struct SoftwareBillOfMaterialsRefusalTests {

    private func refusal(
        of document: SyntheticBillOfMaterials,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> ArchiveAuditBindingError? {
        do {
            _ = try SoftwareBillOfMaterials.decode(document.data)
            Issue.record("decoding accepted a document it must refuse", sourceLocation: sourceLocation)
            return nil
        } catch let error as ArchiveAuditBindingError {
            return error
        } catch {
            Issue.record("an unexpected decoding error", sourceLocation: sourceLocation)
            return nil
        }
    }

    @Test("The clean synthetic document decodes")
    func cleanDocumentDecodes() throws {
        let bom = try SoftwareBillOfMaterials.decode(SyntheticBillOfMaterials().data)
        #expect(bom.format == SoftwareBillOfMaterials.supportedFormat)
        #expect(bom.specificationVersion == SoftwareBillOfMaterials.supportedSpecificationVersion)
        #expect(bom.components.count == 1)
        #expect(bom.shippedLibraries.count == 1)
        // No digest, so no approval is owed: a source package has no single shipped byte sequence
        // to digest, and treating that as an unapproved digest would be a fabricated measurement.
        #expect(bom.componentsWithUnapprovedDigests.isEmpty)
        let component = try #require(bom.components.first)
        #expect(component.shipsInThisComposition)
        #expect(component.resolvedRevision == String(repeating: "0", count: 40))
    }

    @Test("An unsupported format or specification version is refused")
    func unsupportedFormatIsRefused() throws {
        var probes = 0
        let mutations: [(String, String)] = [
            ("SPDX", SoftwareBillOfMaterials.supportedSpecificationVersion),
            (SoftwareBillOfMaterials.supportedFormat, "1.5"),
            ("SPDX", "2.3"),
        ]
        for (format, specVersion) in mutations {
            probes += 1
            var document = SyntheticBillOfMaterials()
            document.bomFormat = format
            document.specVersion = specVersion
            let recorded = try #require(refusal(of: document))
            guard case let .unsupportedBillOfMaterialsFormat(named, version) = recorded else {
                Issue.record("an unsupported format must be refused as one")
                continue
            }
            #expect(named == format)
            #expect(version == specVersion)
        }
        #expect(probes == 3)
    }

    @Test("A document with no component is refused")
    func anEmptyDocumentIsRefused() throws {
        var document = SyntheticBillOfMaterials()
        document.components = []
        let recorded = try #require(refusal(of: document))
        #expect(recorded == ArchiveAuditBindingError.billOfMaterialsEmpty)
    }

    @Test("An unmodelled component type is refused rather than defaulted to a library")
    func anUnmodelledComponentTypeIsRefused() throws {
        var document = SyntheticBillOfMaterials()
        document.components.append(
            SyntheticBillOfMaterials.Component(type: "framework", name: "synthetic-framework")
        )
        let recorded = try #require(refusal(of: document))
        guard case let .billOfMaterialsComponentNotReconciled(detail) = recorded else {
            Issue.record("an unmodelled component type must be refused as unreconciled")
            return
        }
        #expect(detail.contains("synthetic-framework"))
        #expect(detail.contains("framework"))
    }

    @Test("An unmodelled scope is refused")
    func anUnmodelledScopeIsRefused() throws {
        var document = SyntheticBillOfMaterials()
        document.components[0].scope = "provided"
        let recorded = try #require(refusal(of: document))
        guard case let .billOfMaterialsComponentNotReconciled(detail) = recorded else {
            Issue.record("an unmodelled scope must be refused as unreconciled")
            return
        }
        #expect(detail.contains("provided"))
    }

    @Test("Every modelled component type and scope decodes")
    func everyModelledKindAndScopeDecodes() throws {
        var probes = 0
        for kind in BillOfMaterialsComponent.Kind.allCases {
            for scope in BillOfMaterialsComponent.Scope.allCases {
                probes += 1
                var document = SyntheticBillOfMaterials()
                document.components = [
                    SyntheticBillOfMaterials.Component(
                        type: kind.rawValue,
                        name: "synthetic-\(kind.rawValue)-\(scope.rawValue)",
                        scope: scope.rawValue
                    )
                ]
                let bom = try SoftwareBillOfMaterials.decode(document.data)
                let component = try #require(bom.components.first)
                #expect(component.type == kind)
                #expect(component.scope == scope)
            }
        }
        // Counted-work floor: the closed vocabularies are total over the decoder.
        #expect(probes == 12)
        #expect(
            probes == BillOfMaterialsComponent.Kind.allCases.count
                * BillOfMaterialsComponent.Scope.allCases.count
        )
    }

    @Test("A digest with no recorded approval is reported as unapproved, never as approved")
    func anUnapprovedDigestIsReportedAsUnapproved() throws {
        var probes = 0
        // Restricted to the two types whose digest is an approval subject. The thirty `file`
        // components in a real document are the release artifact manifest — evidence, not a
        // pending approval — and reporting one as an unapproved binary digest would bury the one
        // component that genuinely is one.
        for kind in BillOfMaterialsComponent.Kind.allCases {
            probes += 1
            var document = SyntheticBillOfMaterials()
            document.components = [
                SyntheticBillOfMaterials.Component(
                    type: kind.rawValue,
                    name: "synthetic-\(kind.rawValue)",
                    hashes: [(algorithm: "SHA-256", content: String(repeating: "0", count: 64))],
                    properties: [
                        (name: "dev.defaike.shipsInThisComposition", value: "true")
                    ]
                )
            ]
            let bom = try SoftwareBillOfMaterials.decode(document.data)
            let unapproved = bom.componentsWithUnapprovedDigests
            switch kind {
            case .library, .machineLearningModel:
                #expect(unapproved.count == 1)
            case .file, .application:
                #expect(unapproved.isEmpty)
            }
        }
        #expect(probes == 4)
    }

    @Test("A recorded release approval clears the digest for the two approval-subject types")
    func arecordedApprovalClearsTheDigest() throws {
        var document = SyntheticBillOfMaterials()
        document.components = [
            SyntheticBillOfMaterials.Component(
                name: "synthetic-approved-library",
                hashes: [(algorithm: "SHA-256", content: String(repeating: "1", count: 64))],
                properties: [
                    (name: "dev.defaike.shipsInThisComposition", value: "true"),
                    (
                        name: "dev.defaike.digestApprovalStatus",
                        value: BillOfMaterialsComponent.approvedDigestStatus
                    ),
                ]
            )
        ]
        let bom = try SoftwareBillOfMaterials.decode(document.data)
        #expect(bom.componentsWithUnapprovedDigests.isEmpty)
        // The status string is the audit's label on a synthetic fixture. It is not a real digest
        // approval, and nothing in this suite treats it as one.
        let component = try #require(bom.components.first)
        #expect(component.digestApprovalIsRecorded)
    }

    @Test("A status string other than the approved one does not clear the digest")
    func anyOtherStatusDoesNotClearTheDigest() throws {
        var probes = 0
        for status in ["pending", "measured-baseline", "approved", ""] {
            probes += 1
            var document = SyntheticBillOfMaterials()
            document.components = [
                SyntheticBillOfMaterials.Component(
                    name: "synthetic-library",
                    hashes: [(algorithm: "SHA-256", content: String(repeating: "2", count: 64))],
                    properties: [
                        (name: "dev.defaike.shipsInThisComposition", value: "true"),
                        (name: "dev.defaike.digestApprovalStatus", value: status),
                    ]
                )
            ]
            let bom = try SoftwareBillOfMaterials.decode(document.data)
            #expect(bom.componentsWithUnapprovedDigests.count == 1)
        }
        // Including the near-miss `approved`, which is not the release-approved status string.
        #expect(probes == 4)
    }
}

// MARK: - The validator

/// A reader holding two synthetic documents, and the reconciliation the validator adds.
struct FakeArchiveAuditReader: ArchiveAuditReportReading {
    var report: Data?
    var reportFault: ArchiveAuditReportFault = .reportAbsent
    var billOfMaterials: [String: Data] = [:]
    var billOfMaterialsFault: ArchiveAuditReportFault = .billOfMaterialsAbsent

    func auditReport() throws(ArchiveAuditReportFault) -> Data {
        guard let report else { throw reportFault }
        return report
    }

    func billOfMaterials(
        forComposition composition: String
    ) throws(ArchiveAuditReportFault) -> Data {
        guard let data = billOfMaterials[composition] else { throw billOfMaterialsFault }
        return data
    }
}

/// The one thing the validator adds over decoding: the two artifacts have to agree.
@Suite("Archive audit ingestion: validator reconciliation")
struct ArchiveAuditValidatorTests {

    @Test("A clean pair validates and reports nothing unapproved")
    func aCleanPairValidates() throws {
        let validator = ArchiveAuditValidator(
            reader: FakeArchiveAuditReader(
                report: SyntheticAuditDocument().data,
                billOfMaterials: ["pixel-only": SyntheticBillOfMaterials().data]
            )
        )
        let result = try validator.validate(composition: "pixel-only")
        #expect(result.report.everyProducedGatePasses)
        #expect(result.unapprovedDigestComponents.isEmpty)
        #expect(result.digestEvidenceIsReconciled)
    }

    @Test("An unapproved digest the report never routed is refused as unreconciled")
    func anUnroutedUnapprovedDigestIsRefused() throws {
        // The reconciliation, and the reason it exists: the document is where an unapproved digest
        // is *visible* and the report is where it is *routed to a gate*. A pair in which the
        // document carries one and the report's archive gate still passes would be a failing input
        // nobody counted.
        var document = SyntheticBillOfMaterials()
        document.components = [
            SyntheticBillOfMaterials.Component(
                name: "synthetic-unapproved-library",
                hashes: [(algorithm: "SHA-256", content: String(repeating: "3", count: 64))],
                properties: [(name: "dev.defaike.shipsInThisComposition", value: "true")]
            )
        ]
        let validator = ArchiveAuditValidator(
            reader: FakeArchiveAuditReader(
                report: SyntheticAuditDocument().data,
                billOfMaterials: ["pixel-only": document.data]
            )
        )
        var caught: ArchiveAuditBindingError?
        do {
            _ = try validator.validate(composition: "pixel-only")
        } catch let error as ArchiveAuditBindingError {
            caught = error
        }
        let recorded = try #require(caught)
        guard case let .billOfMaterialsComponentNotReconciled(detail) = recorded else {
            Issue.record("an unrouted unapproved digest must be refused as unreconciled")
            return
        }
        #expect(detail.contains("synthetic-unapproved-library"))
    }

    @Test("An unapproved digest the report did route reconciles")
    func aRoutedUnapprovedDigestReconciles() throws {
        var bom = SyntheticBillOfMaterials()
        bom.components = [
            SyntheticBillOfMaterials.Component(
                name: "synthetic-unapproved-library",
                hashes: [(algorithm: "SHA-256", content: String(repeating: "4", count: 64))],
                properties: [(name: "dev.defaike.shipsInThisComposition", value: "true")]
            )
        ]
        var report = SyntheticAuditDocument()
        report.addFinding(
            ArchiveAuditFailingInputClass.unapprovedBinaryDigest.rawValue,
            detail: "synthetic-unapproved-library carries an unapproved digest",
            statingFailedFor: .archiveAudit
        )
        let validator = ArchiveAuditValidator(
            reader: FakeArchiveAuditReader(
                report: report.data,
                billOfMaterials: ["pixel-only": bom.data]
            )
        )
        let result = try validator.validate(composition: "pixel-only")
        #expect(result.unapprovedDigestComponents.count == 1)
        #expect(result.digestEvidenceIsReconciled)
        #expect(!result.report.everyProducedGatePasses)
    }

    @Test("Asking for a composition the reader does not hold reports the absent document")
    func amissingCompositionReportsTheAbsentDocument() throws {
        let validator = ArchiveAuditValidator(
            reader: FakeArchiveAuditReader(
                report: SyntheticAuditDocument().data,
                billOfMaterials: ["pixel-only": SyntheticBillOfMaterials().data]
            )
        )
        var caught: ArchiveAuditReportFault?
        do {
            _ = try validator.validate(composition: "pixel-plus-provenance")
        } catch let error as ArchiveAuditReportFault {
            caught = error
        }
        // Naming the composition is what makes a substituted document checkable: a reader that
        // returned both artifacts together could hand one composition's document to another.
        #expect(caught == ArchiveAuditReportFault.billOfMaterialsAbsent)
    }

    @Test("An absent report is reported as absent rather than as an empty run")
    func anAbsentReportIsReportedAsAbsent() throws {
        let validator = ArchiveAuditValidator(reader: FakeArchiveAuditReader())
        var caught: ArchiveAuditReportFault?
        do {
            _ = try validator.validate(composition: "pixel-only")
        } catch let error as ArchiveAuditReportFault {
            caught = error
        }
        #expect(caught == ArchiveAuditReportFault.reportAbsent)
        // Three faults, each closed by different work, and none recoverable — recovering would
        // mean this module deciding what the audit would have measured.
        #expect(ArchiveAuditReportFault.allCases.count == 3)
    }
}
