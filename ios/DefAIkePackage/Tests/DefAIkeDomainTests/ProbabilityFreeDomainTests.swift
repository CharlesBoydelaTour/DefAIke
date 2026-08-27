import Foundation
import Testing

@testable import DefAIkeDomain

// Requirements 8.9 and 8.13: no user-facing surface may show a probability,
// confidence value or level, percentage, score, raw logit, or probability-like
// encoding, and no result may claim certainty, authenticity, authorship, intent,
// complete editing history, or absent localized editing.
//
// The presentation layer has its own audit over presentation models. This one asks the
// same question of the values those models are built from: a magnitude that no domain
// session value can hold cannot be formatted, so the guarantee is a shape rather than
// a filter. Every value one Analysis Session produces is audited here — reports across
// the whole label and lane space, failure snapshots for all ten error categories, both
// progress states, the quality record, the session binding, and the Share ticket that
// crosses the process boundary.
//
// Two negative controls keep the audit honest: a deliberately non-compliant stand-in
// that must be flagged, and a real release artifact whose approved decimals the audit
// does see. The second one is why the audit's scope is the session value graph and
// stated as such, rather than "the domain".

@Suite("Domain session values represent no result magnitude")
struct ProbabilityFreeDomainTests {

    @Test("Every completed report is magnitude-free", arguments: SessionValue.allReports)
    func reportIsClean(report: EvidenceReport) {
        let findings = ProhibitedMagnitudeAudit.findings(in: report)
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test("Every failure snapshot is magnitude-free", arguments: AnalysisError.allCases)
    func snapshotIsClean(error: AnalysisError) throws {
        let snapshot = try #require(SessionValue.snapshot(error: error))
        let findings = ProhibitedMagnitudeAudit.findings(in: snapshot)
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test("Every terminal outcome is magnitude-free")
    func terminalOutcomesAreClean() throws {
        let report = try #require(SessionValue.report())
        let snapshot = try #require(SessionValue.snapshot())
        for outcome in [
            SessionTerminalOutcome.completed(report),
            .cancelled,
            .failed(snapshot),
        ] {
            let findings = ProhibitedMagnitudeAudit.findings(in: outcome)
            #expect(findings.isEmpty, "\(outcome.endReason.rawValue): \(findings)")
        }
    }

    @Test("Every provenance lane state is magnitude-free")
    func lanesAreClean() {
        // A validated claim projects signer and assertion detail. That projection is
        // bounded display-safe text and approved copy keys, so there is no numeric
        // trust score, match percentage, or similarity value anywhere in it.
        for lane in SessionValue.allLanes {
            let findings = ProhibitedMagnitudeAudit.findings(in: lane)
            #expect(findings.isEmpty, "\(findings)")
        }
    }

    @Test("The quality record holds measurements, not magnitudes")
    func qualityRecordIsClean() {
        // Integer dimensions and boolean conditions are measurements and stay
        // representable. A floating-point quality value would be the shape an
        // unvalidated derived feature arrives in, so the value vocabulary has no such
        // case at all.
        for record in [
            InputQualityRecord.unmeasured,
            SessionValue.quality(),
            SessionValue.quality(width: 439, height: 440),
        ] {
            let findings = ProhibitedMagnitudeAudit.findings(in: record)
            #expect(findings.isEmpty, "\(findings)")
        }
        for value in [ValidatedQualityValue.integer(440), .boolean(true)] {
            #expect(ProhibitedMagnitudeAudit.findings(in: value).isEmpty)
        }
    }

    @Test("A floating-point quality value cannot be decoded into the record")
    func floatingPointQualityValueRefused() throws {
        // The vocabulary is closed at integer and boolean, so a payload naming a
        // decimal, double, or ratio shape is refused rather than widened.
        for kind in ["double", "decimal", "ratio", "probability", "float"] {
            let payload = Data(#"{"kind":"\#(kind)","\#(kind)":0.87}"#.utf8)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(ValidatedQualityValue.self, from: payload)
            }
        }
        // The two real shapes still decode, so the refusal is not blanket.
        #expect(
            try JSONDecoder().decode(
                ValidatedQualityValue.self,
                from: Data(#"{"kind":"integer","integer":440}"#.utf8)
            ) == .integer(440)
        )
    }

    @Test("The session binding is magnitude-free")
    func bindingIsClean() {
        let findings = ProhibitedMagnitudeAudit.findings(in: SessionValue.binding())
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test("Progress carries measured work, never a result magnitude")
    func progressIsClean() {
        // A completion fraction is derived work progress and exists only as a computed
        // value over two measured integer counts. It is never stored, never derived
        // from a logit or a label, and never a probability of a verdict.
        for stage in AnalysisStage.allCases {
            var states: [AnalysisProgressState] = [.indeterminate(stage: stage)]
            for unit in ProgressUnit.allCases {
                states.append(.determinate(completed: 3, total: 8, unit: unit, stage: stage))
            }
            for state in states {
                let findings = ProhibitedMagnitudeAudit.findings(in: state)
                #expect(findings.isEmpty, "\(stage.rawValue): \(findings)")
            }
        }
        #expect(
            AnalysisProgressState.determinate(
                completed: 3, total: 8, unit: .encodedBytes, stage: .inputValidation
            ).fractionOfWorkCompleted == 0.375
        )
    }

    @Test("The Share ticket is magnitude-free, timestamp included")
    func ticketIsClean() throws {
        // The ticket is the one session value that carries a wall-clock instant, and
        // Foundation stores a `Date` as a floating-point interval. A lifecycle
        // timestamp is not a result magnitude, so the audit treats `Date` as an opaque
        // leaf; pinning that list keeps the exception narrow and visible.
        #expect(DomainValueWalk.opaqueLeafTypeNames == ["Date"])

        let ticket = try #require(SessionValue.ticket())
        let findings = ProhibitedMagnitudeAudit.findings(in: ticket)
        #expect(findings.isEmpty, "\(findings)")
    }

    @Test("No session value names a raw logit")
    func noRawLogitField() throws {
        // A raw logit exists between the model and calibration and stops there: it is
        // never carried into a report, a snapshot, or a ticket. The audit's name rule
        // catches the field even if it were an integer.
        let values: [Any] = [
            try #require(SessionValue.report()),
            try #require(SessionValue.snapshot()),
            try #require(SessionValue.ticket()),
        ]
        for value in values {
            var named: [String] = []
            DomainValueWalk.visit(value, rootName: "value") { path, _ in
                if path.lowercased().contains("logit") { named.append(path) }
            }
            #expect(named.isEmpty, "\(named)")
        }
    }
}

@Suite("The magnitude audit can fail")
struct ProhibitedMagnitudeAuditTests {

    @Test("A numeric field is reported, populated or not")
    func numericFieldReported() {
        for model in [NonCompliantValue.populated, .empty] {
            let findings = ProhibitedMagnitudeAudit.findings(in: model)
            #expect(
                findings.contains { $0.path == "NonCompliantValue.magnitude" },
                "\(findings)"
            )
        }
    }

    @Test("A prohibited field name is reported even without a number")
    func prohibitedNameReported() {
        let findings = ProhibitedMagnitudeAudit.findings(in: NonCompliantValue.empty)
        #expect(findings.contains { $0.path == "NonCompliantValue.confidenceLevel" })
    }

    @Test("A nested magnitude is reported under its own path")
    func nestedMagnitudeReported() {
        let findings = ProhibitedMagnitudeAudit.findings(in: NonCompliantValue.nested)
        #expect(
            findings.contains { $0.path == "NonCompliantValue.inner.magnitude" },
            "\(findings)"
        )
    }

    @Test("Findings are reported once per field, and never as an optional's payload")
    func findingsAreDeduplicated() {
        let findings = ProhibitedMagnitudeAudit.findings(in: NonCompliantValue.populated)
        #expect(Set(findings).count == findings.count)
        #expect(!findings.contains { $0.path.hasSuffix(".some") })
    }

    @Test("Integer measurements are not reported")
    func integersAreNotMagnitudes() {
        // A recorded dimension and a byte count are measurements. Banning them would
        // push real data into looser types, which is the opposite of the goal.
        #expect(ProhibitedMagnitudeAudit.findings(in: MeasuredValue()).isEmpty)
    }

    @Test("The audit sees the approved decimals in a release artifact")
    func artifactDecimalsAreVisible() throws {
        // This is the boundary of the audit's scope, made executable. A Calibration
        // Policy legitimately carries a decimal false-accusation budget and a
        // predeclared decimal confidence level; a Resource Budget carries measured
        // numeric limits. Those are approved release inputs, not user-facing result
        // fields, and they are why this audit is scoped to session values instead of
        // being applied to the artifact layer.
        let policy = try Sample.calibrationPolicy()
        let policyFindings = ProhibitedMagnitudeAudit.findings(in: policy)
        #expect(!policyFindings.isEmpty)
        #expect(policyFindings.contains { $0.path.lowercased().contains("confidencelevel") })

        let budgetFindings = ProhibitedMagnitudeAudit.findings(
            in: try Sample.resourceBudget(target: .mainApplication)
        )
        #expect(!budgetFindings.isEmpty)
    }
}

/// A deliberately non-compliant stand-in, so the audit is proven able to fail.
///
/// Nothing shaped like this is representable among the domain's session values.
private struct NonCompliantValue {
    struct Inner {
        let magnitude: Decimal
    }

    let magnitude: Double?
    let confidenceLevel: String?
    let inner: Inner?

    static let populated = NonCompliantValue(
        magnitude: 0.87,
        confidenceLevel: nil,
        inner: nil
    )
    static let empty = NonCompliantValue(
        magnitude: nil,
        confidenceLevel: "high",
        inner: nil
    )
    static let nested = NonCompliantValue(
        magnitude: nil,
        confidenceLevel: nil,
        inner: Inner(magnitude: 1)
    )
}

/// Integer and boolean measurements, which the audit must leave alone.
private struct MeasuredValue {
    let decodedWidth = 900
    let byteCount: UInt64 = 2048
    let onDeviceProcessing = true
}
