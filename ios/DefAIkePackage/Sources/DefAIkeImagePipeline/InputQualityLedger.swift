import DefAIkeDomain

// What this session measured about its input, and the failure snapshot those
// measurements survive into.
//
// Two sets of requirements meet here, and they pull in opposite directions:
//
//   * Requirements 3.5, 3.6, and 3.14 want a measurement to outlive the *step* that
//     took it. A decode that completed and was then refused by the budget, and an
//     accepted decode that later failed in preprocessing, both still have to report the
//     Byte Preservation Status and the pre-orientation dimensions that were established
//     before the failure.
//   * Requirements 3.13 and 3.15 want a measurement to *not* outlive its **session**.
//     The session that follows a failed one is initialized with no error category and
//     no data from the failure, and no restart is needed to get there.
//
// "Outlives the step" and "outlives the session" are different lifetimes, and this
// actor exists to keep them apart. It holds exactly one session's slot: opening a
// session replaces the slot outright, so there is no table for a finished session to
// linger in, and every read is keyed by session identity, so a late write or a late
// read belonging to a session that has already ended cannot touch or observe the one
// that replaced it.
//
// It also holds no error category at all. A snapshot's category comes from the fault
// presented at the moment the snapshot is taken, which is what makes "a new session
// inherits no error" structural rather than a clearing step somebody has to remember:
// there is no field to inherit.
//
// Everything retained here is a measurement or an identity. No encoded bytes, no
// decoded pixels, no evidence, no verdict, and no user content — a dimension pair and
// a preservation status are the whole of it.

/// One Analysis Session's recorded input quality, and the failure snapshot it produces.
///
/// An actor because the measurements are written from inside the validating call and
/// read from whatever isolation the coordinator commits a terminal outcome in.
public actor InputQualityLedger {
    /// One open session and everything measured about its input so far.
    private struct OpenSession {
        /// The session these measurements belong to. Never reassigned: a new session
        /// gets a new ``OpenSession``, not this one with a different identity.
        let sessionID: AnalysisSessionID

        /// Established by ingest before validation begins, so it is known for every
        /// failure this pipeline can report (Requirement 3.14).
        let bytePreservationStatus: BytePreservationStatus

        /// The actual decoded dimensions, recorded when — and only when — an image has
        /// completely decoded.
        ///
        /// `nil` while no image has completely decoded, and it stays `nil` rather than
        /// becoming a zero, a placeholder, or the container's declared size. A dimension
        /// that was never measured is unknown, and unknown is a different fact from
        /// small: a substituted zero would read as a sub-440 short edge, and a
        /// substituted declared value would read as a measurement of pixels nobody
        /// decoded.
        var decodedDimensions: PixelDimensions?
    }

    /// The single open session, or `nil` before the first one and after a discard.
    ///
    /// One slot rather than a table, deliberately. The application analyzes one Analysis
    /// Session at a time, and a table would let a finished session's measurements sit
    /// beside a new session's until something remembered to remove them — which is the
    /// exact carry-over Requirement 3.15 forbids.
    private var open: OpenSession?

    public init() {}

    /// The session currently open, or `nil` when none is.
    ///
    /// An identity, not a measurement. Lets a caller confirm which session the ledger
    /// speaks for without reading anything about its input.
    public var openSessionID: AnalysisSessionID? { open?.sessionID }

    /// Opens `asset`'s session, discarding every measurement from every earlier session.
    ///
    /// The whole slot is replaced, so nothing survives the transition: not a dimension,
    /// not a status, not an identity, and not an error category, because none is stored.
    /// A new session is therefore isolated from a failed one by construction rather than
    /// by a reset that could be skipped (Requirements 3.13 and 3.15).
    ///
    /// The Byte Preservation Status is taken from the accepted ingest rather than passed
    /// in beside it, so the status recorded for a session is the one ingest actually
    /// established for those bytes and cannot be restated as something else here.
    public func beginSession(for asset: ImportedEncodedAsset) {
        open = OpenSession(
            sessionID: asset.sessionID,
            bytePreservationStatus: asset.preservationStatus,
            decodedDimensions: nil
        )
    }

    /// Records the actual dimensions of an image that has completely decoded.
    ///
    /// The values are the decoded ones exactly as decoded, before any orientation
    /// permutation is applied, and ``PixelDimensions/shortEdge`` is `min(width, height)`
    /// of that unswapped pair (Requirements 3.5 and 3.6). No orientation declaration is
    /// read anywhere in this file, so there is no path by which a declared rotation can
    /// exchange the recorded axes and move the short edge that the sub-440 abstention
    /// rule depends on.
    ///
    /// A record naming a session that is not the open one is discarded rather than
    /// applied: a measurement arriving late from a session that has already ended must
    /// not land in the session that replaced it (Requirement 3.15).
    public func record(
        completelyDecoded dimensions: PixelDimensions,
        for sessionID: AnalysisSessionID
    ) {
        guard var session = open, session.sessionID == sessionID else { return }
        // The first complete decode is the one the record describes. One session decodes
        // exactly one image — a container holding more than one is `unsupported-media`
        // before any decode is entered — so a second measurement would be a defect, and
        // letting it redefine the recorded short edge would move a boundary that an
        // abstention decision may already have used.
        guard session.decodedDimensions == nil else { return }
        session.decodedDimensions = dimensions
        open = session
    }

    /// The Input Quality Record for `sessionID`, or `nil` when it has measured nothing.
    ///
    /// `nil` covers three different situations on purpose — no session is open, a
    /// different session is open, or nothing has been measured yet — because all three
    /// mean the same thing to a caller: this ledger holds no measurement it can attribute
    /// to `sessionID`. An empty record is not synthesized for any of them; a record
    /// exists once a decode has produced one.
    public func qualityRecord(for sessionID: AnalysisSessionID) -> InputQualityRecord? {
        guard let session = open, session.sessionID == sessionID else { return nil }
        return session.decodedDimensions.flatMap(Self.record)
    }

    /// The Byte Preservation Status recorded for `sessionID`, or `nil` when the ledger
    /// holds no session by that identity.
    public func bytePreservationStatus(
        for sessionID: AnalysisSessionID
    ) -> BytePreservationStatus? {
        guard let session = open, session.sessionID == sessionID else { return nil }
        return session.bytePreservationStatus
    }

    /// The failure snapshot for `sessionID` under `fault`, or `nil` when there is no
    /// failure to snapshot.
    ///
    /// What it preserves is what had been established before the failure: the Byte
    /// Preservation Status, which ingest fixes before validation starts, and the
    /// pre-orientation dimensions, when a decode had completed (Requirement 3.14). What
    /// it cannot carry is evidence — ``AnalysisFailureSnapshot`` has no field for a pixel
    /// label, a provenance state, or a combined summary, so a failed session cannot
    /// report a partial verdict.
    ///
    /// `nil` in exactly two cases, and neither is a failure being dropped:
    ///
    ///   * ``AnalysisFault/cancelled``. Cancellation is not an Analysis Error and must
    ///     never be presented as one, so it has no snapshot to take even when
    ///     measurements exist (Requirements 11.17 and 15.7).
    ///   * `sessionID` is not the open session. A snapshot for a session this ledger no
    ///     longer speaks for would be assembled from another session's measurements,
    ///     which is exactly the contamination Requirement 3.15 forbids.
    ///
    /// Taking a snapshot reads the slot and does not clear it, so repeated reads for one
    /// session return the same value. Isolation comes from opening the next session, not
    /// from having read this one.
    public func failureSnapshot(
        for sessionID: AnalysisSessionID,
        fault: AnalysisFault
    ) -> AnalysisFailureSnapshot? {
        guard case .analysis(let error, let stage) = fault else { return nil }
        guard let session = open, session.sessionID == sessionID else { return nil }
        // Failable only for a schema version this build cannot produce, and the version
        // used is this build's own. Written as a guard rather than a force-unwrap because
        // the alternative to reporting nothing on a diagnostic path is trapping on it.
        guard let snapshot = AnalysisFailureSnapshot(
            sessionID: session.sessionID,
            error: error,
            stage: stage,
            bytePreservationStatus: session.bytePreservationStatus,
            inputQuality: session.decodedDimensions.flatMap(Self.record)
        ) else {
            return nil
        }
        return snapshot
    }

    /// Discards everything this ledger holds. Idempotent.
    ///
    /// Session data does not outlive its session: terminal cleanup clears the slot, and a
    /// second call is a no-op like every other cleanup path in this package
    /// (Requirement 9.8). Opening the next session clears it as well, so isolation never
    /// depends on cleanup having run first.
    public func discard() {
        open = nil
    }

    /// The record `dimensions` produce.
    ///
    /// Derived from the measured pair rather than stored beside it, so the recorded short
    /// edge cannot disagree with the recorded width and height. `nil` is unreachable:
    /// ``PixelDimensions`` guarantees both values are present and positive, which are the
    /// only conditions ``InputQualityRecord`` rejects. It is returned rather than
    /// force-unwrapped so that a future change to either type surfaces as a missing
    /// record instead of a trap.
    private static func record(of dimensions: PixelDimensions) -> InputQualityRecord? {
        InputQualityRecord(
            decodedWidthBeforeOrientation: dimensions.width,
            decodedHeightBeforeOrientation: dimensions.height,
            // Empty until an approved Calibration Policy defines an additional quality
            // feature and binds it to release-validation evidence (Requirement 5.11).
            // Recording an unvalidated measurement here would put it one policy edit away
            // from changing an outcome.
            validatedFeatures: [:]
        )
    }
}
