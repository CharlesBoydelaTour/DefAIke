import DefAIkeDomain
import DefAIkeTestSupport
import Foundation

/// The smallest lifecycle policy a cleanup double needs.
///
/// Structurally valid and deliberately synthetic. **None of these numbers is an approved
/// release value**: the five cleanup deadlines are an unresolved external decision, so a
/// test states the deadline it wants to reason about and nothing here may be copied into
/// a shipping artifact.
enum LifecycleFixture {
    static func policy(
        id: String = "lifecycle-0001",
        deadlineMilliseconds: UInt64 = 30_000
    ) -> DataLifecyclePolicy {
        let deadline = duration(deadlineMilliseconds)
        do {
            return try DataLifecyclePolicy(
                id: PortValue.artifactID(id),
                schemaVersion: .v1,
                deadlines: SessionCleanupReason.allCases.map {
                    DataLifecyclePolicy.Deadline(reason: $0, deadline: deadline)
                },
                approval: approval()
            )
        } catch {
            preconditionFailure("the lifecycle fixture must be schema-valid: \(error)")
        }
    }

    static func duration(_ milliseconds: UInt64) -> ValidatedDuration {
        do {
            return try ValidatedDuration(validating: milliseconds)
        } catch {
            preconditionFailure("\(milliseconds)ms is not a valid duration: \(error)")
        }
    }

    static func approval(decision: ApprovalDecision = .approved) -> ApprovalRecord {
        ApprovalRecord(
            source: evidence(),
            decision: decision,
            approver: approver(),
            decidedAt: VirtualSessionClock.defaultStart
        )
    }

    static func evidence(_ artifact: String = "evidence-0001") -> EvidenceSource {
        do {
            return EvidenceSource(
                artifact: PortValue.artifactID(artifact),
                version: try SchemaSemanticVersion(validating: "1.0.0"),
                contentDigest: TestSHA256.digest(ofUTF8: artifact)
            )
        } catch {
            preconditionFailure("the evidence fixture must be schema-valid: \(error)")
        }
    }

    static func approver(_ raw: String = "role.release-owner") -> ApproverID {
        guard let id = ApproverID(raw) else {
            preconditionFailure("approver identifier is not canonical: \(raw)")
        }
        return id
    }
}
