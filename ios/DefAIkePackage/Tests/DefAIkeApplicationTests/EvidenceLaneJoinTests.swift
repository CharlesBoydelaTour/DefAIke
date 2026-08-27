import DefAIkeDomain
import Testing

@testable import DefAIkeApplication

/// The immutable join of the two evidence source lanes.
///
/// Every test here is about structure rather than about a policy value. The interesting
/// ones are the negative and the order-insensitive cases: a lane that already resolved
/// cannot be written again, and the earlier join value is still readable and unchanged
/// after a later lane arrives, which is what "neither analyzer receives mutable access to
/// the other lane" means when the lanes are values (Requirements 7.1, 7.4, and 7.5).
@Suite("Evidence lane join")
struct EvidenceLaneJoinTests {
    // MARK: Both lanes are required

    @Test("A new join has neither lane and yields no report input")
    func newJoinHasNeitherLane() {
        let join = EvidenceLaneJoin.unresolved

        #expect(join.pixel == nil)
        #expect(join.provenance == nil)
        #expect(join.isComplete == false)
        #expect(join.resolvedLanes == nil)
        #expect(join.unresolvedLanes == Set(EvidenceSourceLane.allCases))
    }

    @Test("One resolved lane is still incomplete and names the outstanding lane")
    func oneLaneIsNotEnough() {
        let pixelOnly = EvidenceLaneJoin.unresolved.resolving(pixel: .noStrongSignalDetected)
        #expect(pixelOnly?.isComplete == false)
        #expect(pixelOnly?.resolvedLanes == nil)
        #expect(pixelOnly?.unresolvedLanes == [.provenance])

        let provenanceOnly = EvidenceLaneJoin.unresolved
            .resolving(provenance: .unavailable(.validatorNotCompiledIntoRelease))
        #expect(provenanceOnly?.isComplete == false)
        #expect(provenanceOnly?.resolvedLanes == nil)
        #expect(provenanceOnly?.unresolvedLanes == [.pixel])
    }

    @Test("The unavailable state resolves the provenance lane like any other")
    func unavailableLaneResolvesTheLane() {
        for reason in UnavailableReason.allCases {
            let join = EvidenceLaneJoin.unresolved
                .resolving(pixel: .notEnoughSignal)?
                .resolving(provenance: .unavailable(reason))

            #expect(join?.isComplete == true)
            #expect(join?.resolvedLanes?.provenance == .unavailable(reason))
        }
    }

    @Test("Every lane a session can resolve completes the join", arguments: PixelEvidence.allCases)
    func everyLaneCompletesTheJoin(pixel: PixelEvidence) {
        for lane in ProvenanceSample.allLanes {
            let join = EvidenceLaneJoin.unresolved
                .resolving(pixel: pixel)?
                .resolving(provenance: lane)

            #expect(join?.resolvedLanes == ResolvedEvidenceLanes(pixel: pixel, provenance: lane))
        }
    }

    // MARK: Arrival order does not matter

    @Test("Both arrival orders produce the same joined lanes")
    func arrivalOrderIsIrrelevant() {
        for pixel in PixelEvidence.allCases {
            for lane in ProvenanceSample.allLanes {
                let pixelFirst = EvidenceLaneJoin.unresolved
                    .resolving(pixel: pixel)?
                    .resolving(provenance: lane)
                let provenanceFirst = EvidenceLaneJoin.unresolved
                    .resolving(provenance: lane)?
                    .resolving(pixel: pixel)

                #expect(pixelFirst == provenanceFirst)
                #expect(pixelFirst?.resolvedLanes == provenanceFirst?.resolvedLanes)
            }
        }
    }

    // MARK: Neither lane can reach the other

    @Test("Recording the provenance lane leaves the earlier pixel-only join unchanged")
    func laterLaneDoesNotMutateEarlierJoin() {
        guard let afterPixel = EvidenceLaneJoin.unresolved
            .resolving(pixel: .signalsConsistentWithAIGeneration)
        else {
            Issue.record("the pixel lane must resolve on an empty join")
            return
        }

        let afterBoth = afterPixel.resolving(provenance: .available(ProvenanceSample.validated()))

        // The value the pixel branch produced is still exactly what it produced. A join is
        // a value, so the provenance branch had nothing to write through.
        #expect(afterPixel.pixel == .signalsConsistentWithAIGeneration)
        #expect(afterPixel.provenance == nil)
        #expect(afterPixel.isComplete == false)

        #expect(afterBoth?.pixel == .signalsConsistentWithAIGeneration)
        #expect(afterBoth?.provenance == .available(ProvenanceSample.validated()))
    }

    @Test("Recording the pixel lane leaves the earlier provenance-only join unchanged")
    func earlierProvenanceJoinIsUnchanged() {
        guard let afterProvenance = EvidenceLaneJoin.unresolved
            .resolving(provenance: .available(.absent))
        else {
            Issue.record("the provenance lane must resolve on an empty join")
            return
        }

        let afterBoth = afterProvenance.resolving(pixel: .notEnoughSignal)

        #expect(afterProvenance.provenance == .available(.absent))
        #expect(afterProvenance.pixel == nil)
        #expect(afterProvenance.isComplete == false)

        #expect(afterBoth?.provenance == .available(.absent))
        #expect(afterBoth?.pixel == .notEnoughSignal)
    }

    @Test("A resolved pixel lane refuses a second write")
    func pixelLaneResolvesOnce() {
        let join = EvidenceLaneJoin.unresolved.resolving(pixel: .notEnoughSignal)

        #expect(join?.resolving(pixel: .signalsConsistentWithAIGeneration) == nil)
        #expect(join?.resolving(pixel: .notEnoughSignal) == nil)
        #expect(join?.pixel == .notEnoughSignal)
    }

    @Test("A resolved provenance lane refuses a second write")
    func provenanceLaneResolvesOnce() {
        let join = EvidenceLaneJoin.unresolved.resolving(provenance: .available(.absent))

        #expect(join?.resolving(provenance: .available(ProvenanceSample.validated())) == nil)
        #expect(
            join?.resolving(provenance: .unavailable(.validatorNotCompiledIntoRelease)) == nil
        )
        #expect(join?.provenance == .available(.absent))
    }

    @Test("A complete join refuses a further write to either lane")
    func completeJoinRefusesBothLanes() {
        let complete = EvidenceLaneJoin.unresolved
            .resolving(pixel: .noStrongSignalDetected)?
            .resolving(provenance: .available(ProvenanceSample.indeterminate()))

        #expect(complete?.isComplete == true)
        #expect(complete?.resolving(pixel: .notEnoughSignal) == nil)
        #expect(complete?.resolving(provenance: .available(.absent)) == nil)
    }
}
