import DefAIkeDomain
import Testing

@testable import DefAIkeTestSupport

/// Checks the call spy, which several later properties use as their oracle.
///
/// Nonoccurrence assertions are only as trustworthy as the recorder: if it silently dropped
/// a call, "no downstream work happened" would pass while the work happened.
@Suite("Port call recorder")
struct PortCallRecorderTests {

    @Test("Calls are recorded in order")
    func recordsOrder() {
        let recorder = PortCallRecorder()
        let session = PortValue.sessionID()

        recorder.record(.validate(session))
        recorder.record(.preprocess(session))
        recorder.record(.infer(session))

        #expect(recorder.callKinds == [.validate, .preprocess, .infer])
        #expect(recorder.callCount(of: .validate) == 1)
        #expect(recorder.didCall(.validate(session)))
        #expect(!recorder.didCall(PortCallKind.calibrate))
    }

    @Test("A call for one session is not reported for another")
    func payloadDiscriminatesSessions() {
        let recorder = PortCallRecorder()
        recorder.record(.validate(PortValue.sessionID("session-0001")))

        #expect(!recorder.didCall(.validate(PortValue.sessionID("session-0002"))))
        #expect(recorder.didCall(.validate))
    }

    @Test("Ordering is checked across every call of each kind")
    func orderingSpansRepeatedCalls() {
        let recorder = PortCallRecorder()
        let session = PortValue.sessionID()

        recorder.record(.validate(session))
        recorder.record(.validate(session))
        recorder.record(.infer(session))

        #expect(recorder.allCalls(of: .validate, precede: .infer))
        #expect(!recorder.allCalls(of: .infer, precede: .validate))
    }

    @Test("An ordering claim about a call that never happened is vacuously true")
    func orderingWithMissingCallIsVacuous() {
        let recorder = PortCallRecorder()
        recorder.record(.validate(PortValue.sessionID()))

        #expect(recorder.allCalls(of: .validate, precede: .infer))
        #expect(recorder.allCalls(of: .fuse, precede: .calibrate))
    }

    @Test("Nonevidence calls do not count as evidence work")
    func cleanupIsNotEvidenceWork() {
        let recorder = PortCallRecorder()
        let session = PortValue.sessionID()

        recorder.record(.sharePeek)
        recorder.record(.observeResource(.peakResidentMemory))
        recorder.record(.deleteSession(session))
        recorder.record(.deleteAbandonedData)

        #expect(recorder.producedNoEvidenceWork)
    }

    @Test(
        "Every evidence-producing call is detected as evidence work",
        arguments: PortCall.evidenceProducingCalls
    )
    func evidenceWorkIsDetected(kind: PortCallKind) {
        let recorder = PortCallRecorder()
        let session = PortValue.sessionID()

        switch kind {
        case .validate: recorder.record(.validate(session))
        case .preprocess: recorder.record(.preprocess(session))
        case .loadModel: recorder.record(.loadModel(PortValue.bundleID()))
        case .infer: recorder.record(.infer(session))
        case .calibrate: recorder.record(.calibrate)
        case .provenanceAnalyze: recorder.record(.provenanceAnalyze(session))
        case .fuse: recorder.record(.fuse)
        default:
            Issue.record("\(kind) is listed as evidence-producing but is not covered here")
        }

        #expect(!recorder.producedNoEvidenceWork)
    }

    @Test("Reset clears the log")
    func resetClearsLog() {
        let recorder = PortCallRecorder()
        recorder.record(.calibrate)
        recorder.reset()

        #expect(recorder.calls.isEmpty)
        #expect(recorder.producedNoEvidenceWork)
    }

    @Test("Concurrent recording keeps every call")
    func concurrentRecordingIsComplete() async {
        let recorder = PortCallRecorder()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    recorder.record(.observeResource(index.isMultiple(of: 2)
                        ? .peakResidentMemory
                        : .temporaryStorage))
                }
            }
        }

        #expect(recorder.callCount(of: .observeResource) == 100)
    }
}
