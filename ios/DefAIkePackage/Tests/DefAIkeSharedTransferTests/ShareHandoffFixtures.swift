import DefAIkeDomain
import Foundation

@testable import DefAIkeSharedTransfer

// The Share Extension doubles, and the activation values the coordinator needs as arguments.
//
// Two of these doubles carry the assertions the requirements actually need:
//
//   * ``FakeSharedItemAccess``'s access window is **real**. It writes the programmed bytes to
//     a temporary file, lends that file for exactly the length of the consume closure, and
//     removes it the moment the closure returns. It also counts how many times it was asked
//     for a representation at all, which is what makes "no byte is read before consent" an
//     observable nonoccurrence rather than a comment.
//   * ``ScriptedConsentPresenter`` records every request it was shown, so "the consent action
//     was never presented" is assertable for a refused activation and for a pending handoff.
//
// **No number here is an approved release value.** The byte counts, capacities, budget
// limits, and copy keys are test scaffolding for unresolved external decisions; nothing here
// may be copied into a shipping artifact.

// MARK: - Activation values

extension Sample {
    /// One provider offered by a host application.
    static func sharedProvider(
        token: UInt64 = 1,
        itemCount: Int = 1,
        contentTypeHint: ContentTypeHint? = Sample.contentTypeHint()
    ) -> SharedItemProvider {
        guard let provider = SharedItemProvider(
            token: ProviderToken(rawValue: token),
            itemCount: itemCount,
            contentTypeHint: contentTypeHint
        ) else {
            preconditionFailure("a provider fixture with count \(itemCount) must be constructible")
        }
        return provider
    }

    /// An activation offering exactly the providers given.
    static func activation(_ providers: SharedItemProvider...) -> ShareActivation {
        ShareActivation(providers: providers)
    }

    /// Consent for `provider` under `policyID`.
    static func consent(
        for provider: SharedItemProvider,
        policyID: ArtifactID = Sample.artifactID("extension-execution-0001"),
        confirmedAt: Date = fixtureNow
    ) -> ConfirmedConsent {
        guard let consent = ConfirmedConsent(
            provider: provider,
            extensionExecutionPolicyID: policyID,
            confirmedAt: confirmedAt
        ) else {
            preconditionFailure("consent for a one-item provider must be constructible")
        }
        return consent
    }

    static func copyKey(_ raw: String = "share.handoff.open-defaike") -> ApprovedCopyKey {
        guard let key = ApprovedCopyKey(raw) else {
            preconditionFailure("approved copy key is not canonical: \(raw)")
        }
        return key
    }

    /// The manual instruction, addressed by a synthetic copy key.
    ///
    /// The key names an entry the Approved Verdict Copy catalog does not have to carry yet;
    /// the wording is decision D1 and stays unresolved.
    static func manualInstruction(
        copyKey: ApprovedCopyKey = Sample.copyKey()
    ) -> ManualOpenInstruction {
        ManualOpenInstruction(copyKey: copyKey)
    }

    /// A complete, structurally valid Share Extension budget.
    ///
    /// Entirely synthetic: the numbers are decision D6 and stay unresolved. The two byte
    /// limits the coordinator reserves against are parameters so a test can put a
    /// representation on either side of them.
    static func shareBudget(
        encodedInputSizeBytes: Decimal = 1_000_000,
        temporaryStorageBytes: Decimal = 1_000_000
    ) -> ResourceBudget {
        do {
            return try ResourceBudget(
                id: artifactID("budget-share-extension-0001"),
                schemaVersion: .v1,
                target: .shareExtension,
                hardLimits: try ResourceMetric.requiredMetrics(for: .shareExtension)
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { metric in
                        try ResourceLimitEntry(
                            metric: metric,
                            limit: try shareLimit(
                                for: metric,
                                encodedInputSizeBytes: encodedInputSizeBytes,
                                temporaryStorageBytes: temporaryStorageBytes
                            ),
                            measurementConditions: evidence("share-measurement-\(metric.rawValue)")
                        )
                    },
                validationPlan: artifactID("validation-plan-0001")
            )
        } catch {
            preconditionFailure("the share budget fixture must be schema-valid: \(error)")
        }
    }

    /// A budget whose `encoded-input-size` limit is stated in the wrong unit.
    ///
    /// The one way to reach "the bound budget defines no comparable limit for this metric"
    /// without removing a required metric, which the schema forbids.
    static func shareBudgetWithMistypedEncodedInputLimit() -> ResourceBudget {
        do {
            return try ResourceBudget(
                id: artifactID("budget-share-extension-mistyped-0001"),
                schemaVersion: .v1,
                target: .shareExtension,
                hardLimits: try ResourceMetric.requiredMetrics(for: .shareExtension)
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { metric in
                        let limit: ValidatedLimit =
                            metric == .encodedInputSize
                            ? .numeric(
                                value: try PositiveDecimal(validating: 1_000_000),
                                unit: .milliseconds
                            )
                            : try shareLimit(
                                for: metric,
                                encodedInputSizeBytes: 1_000_000,
                                temporaryStorageBytes: 1_000_000
                            )
                        return try ResourceLimitEntry(
                            metric: metric,
                            limit: limit,
                            measurementConditions: evidence("share-measurement-\(metric.rawValue)")
                        )
                    },
                validationPlan: artifactID("validation-plan-0001")
            )
        } catch {
            preconditionFailure("the share budget fixture must be schema-valid: \(error)")
        }
    }

    private static func shareLimit(
        for metric: ResourceMetric,
        encodedInputSizeBytes: Decimal,
        temporaryStorageBytes: Decimal
    ) throws -> ValidatedLimit {
        if metric.isCategorical { return .thermal(maximumState: .fair) }
        switch metric {
        case .encodedInputSize:
            return .numeric(
                value: try PositiveDecimal(validating: encodedInputSizeBytes),
                unit: .bytes
            )
        case .temporaryStorage:
            return .numeric(
                value: try PositiveDecimal(validating: temporaryStorageBytes),
                unit: .bytes
            )
        case .peakResidentMemory:
            return .numeric(value: try PositiveDecimal(validating: 1_000_000), unit: .bytes)
        case .handoffLatency:
            return .numeric(value: try PositiveDecimal(validating: 1_000), unit: .milliseconds)
        case .energyImpact:
            return .numeric(
                value: try PositiveDecimal(validating: 1_000),
                unit: .milliwattHours
            )
        case .decodedPixelCount, .coldModelLoadTime, .warmAnalysisLatency, .thermalState:
            preconditionFailure("\(metric.rawValue) is not a Share Extension metric")
        }
    }
}

// MARK: - The candidate session identifier

/// Mints one known candidate identifier, so a test can assert that the published ticket
/// carries exactly the identifier the extension allocated.
struct FixedCandidateSessionIdentifierSource: CandidateSessionIdentifierSource {
    let sessionID: AnalysisSessionID

    init(_ sessionID: AnalysisSessionID = Sample.sessionID("session-share-candidate")) {
        self.sessionID = sessionID
    }

    func makeCandidateSessionID() -> AnalysisSessionID { sessionID }
}

// MARK: - The item-provider double

/// A ``SharedItemRepresentationAccess`` whose access window really closes.
///
/// Programmed with one outcome per instance, because one instance stands for one activation.
/// It records what it did so a test can assert a nonoccurrence — most importantly that the
/// provider was never asked for anything at all before the consent action was confirmed.
actor FakeSharedItemAccess: SharedItemRepresentationAccess {

    /// What this provider does when asked for a representation.
    enum Offer: Sendable {
        /// Lend a representation built from `bytes` for the length of the window.
        case representation(bytes: [UInt8], form: SharedRepresentationForm)

        /// Produce no representation at all, so no byte is ever read.
        case noRepresentation(SharedItemProviderFault)
    }

    private let offer: Offer

    /// Whether the lent file is removed when the window closes.
    ///
    /// Removal is the realistic behavior and the default. A test can keep the file to prove
    /// that staging left the host's representation untouched.
    private let reclaimsRepresentation: Bool

    /// Providers this double was asked about, in order. Empty means the host was never
    /// touched.
    private(set) var requestedProviders: [SharedItemProvider] = []

    /// How many times the consume closure ran.
    private(set) var consumeCount = 0

    /// Files this provider lent, so a test can check they are gone afterwards.
    private(set) var lentFiles: [URL] = []

    init(_ offer: Offer, reclaimsRepresentation: Bool = true) {
        self.offer = offer
        self.reclaimsRepresentation = reclaimsRepresentation
    }

    /// Lends a representation containing `bytes`, typed as a requested container.
    static func lending(
        _ bytes: [UInt8],
        form: SharedRepresentationForm = .typedFileRepresentation,
        reclaimsRepresentation: Bool = true
    ) -> FakeSharedItemAccess {
        FakeSharedItemAccess(
            .representation(bytes: bytes, form: form),
            reclaimsRepresentation: reclaimsRepresentation
        )
    }

    /// Produces nothing, which is the pre-byte provider failure.
    static func failing(_ fault: SharedItemProviderFault) -> FakeSharedItemAccess {
        FakeSharedItemAccess(.noRepresentation(fault))
    }

    func withRepresentation(
        of provider: SharedItemProvider,
        consume: @Sendable (BorrowedSharedRepresentation) async -> StagedRepresentation
    ) async throws(SharedItemProviderFault) -> StagedRepresentation {
        requestedProviders.append(provider)

        switch offer {
        case .noRepresentation(let fault):
            // Nothing is written and `consume` is never called, so no byte of the item
            // exists anywhere in DefAIke.
            throw fault

        case .representation(let bytes, let form):
            guard let fileURL = try? Self.writeTemporaryRepresentation(bytes) else {
                throw .transferFailed
            }
            lentFiles.append(fileURL)
            consumeCount += 1
            let outcome = await consume(
                BorrowedSharedRepresentation(fileURL: fileURL, form: form)
            )
            // The window closes here. A framework provider reclaims its temporary
            // representation at this point, so this one does too.
            if reclaimsRepresentation {
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            }
            return outcome
        }
    }

    /// Removes anything this provider lent and did not reclaim.
    func cleanUp() {
        for file in lentFiles {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    private static func writeTemporaryRepresentation(_ bytes: [UInt8]) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "defaike-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A host-shaped name, so nothing downstream can be reading the extension.
        let fileURL = directory.appending(path: "representation", directoryHint: .notDirectory)
        try Data(bytes).write(to: fileURL)
        return fileURL
    }
}

// MARK: - The consent double

/// A ``ShareConsentPresenting`` that answers from a script and records what it was shown.
actor ScriptedConsentPresenter: ShareConsentPresenting {
    private let answer: @Sendable (ShareConsentRequest) -> ShareConsentDecision

    /// Requests this presenter was shown, in order. Empty means the consent action never
    /// appeared.
    private(set) var presentedRequests: [ShareConsentRequest] = []

    init(_ answer: @escaping @Sendable (ShareConsentRequest) -> ShareConsentDecision) {
        self.answer = answer
    }

    /// Confirms consent for whatever provider and policy it was shown, which is what a
    /// correct consent screen does.
    static func confirming() -> ScriptedConsentPresenter {
        ScriptedConsentPresenter { request in
            .confirmed(
                Sample.consent(
                    for: request.provider,
                    policyID: request.extensionExecutionPolicyID
                )
            )
        }
    }

    /// Returns a token that was not minted for the request it answers.
    static func confirming(with consent: ConfirmedConsent) -> ScriptedConsentPresenter {
        ScriptedConsentPresenter { _ in .confirmed(consent) }
    }

    static func declining() -> ScriptedConsentPresenter {
        ScriptedConsentPresenter { _ in .declined }
    }

    static func cancelling() -> ScriptedConsentPresenter {
        ScriptedConsentPresenter { _ in .cancelled }
    }

    func presentConsent(for request: ShareConsentRequest) async -> ShareConsentDecision {
        presentedRequests.append(request)
        return answer(request)
    }
}

// MARK: - The resource governor double

/// A deterministic ``ResourceGoverning`` for the Share Extension target.
///
/// Nothing is measured for real: the governor compares a request against the *signed budget
/// it was handed*, plus whatever the test declared already in use. Comparing against the
/// artifact rather than against a constant is the point — a governor carrying its own numbers
/// would be the source-code default the requirements forbid.
actor ProgrammedShareResourceGovernor: ResourceGoverning {
    let target: ExecutionTarget

    private var refused: Set<ResourceMetric> = []
    private var priorUse: [ResourceMetric: Decimal] = [:]
    private var substitutedBudgetID: ArtifactID?
    private var outstanding: [ResourceReservationToken: ResourceReservation] = [:]
    private var nextNumber: UInt64 = 1

    /// Requests this governor was asked to grant, in order.
    private(set) var requests: [ResourceReservationRequest] = []

    /// Reservations handed back, in order.
    private(set) var releases: [ResourceReservationToken] = []

    init(target: ExecutionTarget = .shareExtension) {
        self.target = target
    }

    /// Refuses every reservation for `metric`, whatever the amount.
    func refuse(_ metric: ResourceMetric) { refused.insert(metric) }

    /// Declares how much of `metric` is already in use before this handoff.
    func setPriorUse(_ amount: Decimal, for metric: ResourceMetric) {
        priorUse[metric] = amount
    }

    /// Mints reservations that name a different budget than the one asked for.
    func substituteBudget(_ id: ArtifactID) { substitutedBudgetID = id }

    /// Reservations granted and not yet released. Nonempty after a handoff means a leak.
    func outstandingReservations() -> [ResourceReservation] { Array(outstanding.values) }

    func reserve(
        _ request: ResourceReservationRequest,
        budget: ResourceBudget
    ) throws(AnalysisFault) -> ResourceReservation {
        requests.append(request)
        guard !refused.contains(request.metric) else {
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        guard budget.target == target else {
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        guard case .numeric(let limit, let unit) = budget.limit(for: request.metric),
            unit == request.unit
        else {
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        let held = outstanding.values
            .filter { $0.request.metric == request.metric }
            .reduce(Decimal(0)) { $0 + $1.request.amount.value }
        let already = held + (priorUse[request.metric] ?? 0)
        guard already + request.amount.value <= limit.value else {
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        let reservation = ResourceReservation(
            token: ResourceReservationToken(rawValue: nextNumber),
            request: request,
            budgetID: substitutedBudgetID ?? budget.id,
            target: target
        )
        nextNumber += 1
        outstanding[reservation.token] = reservation
        return reservation
    }

    func release(_ reservation: ResourceReservation) {
        releases.append(reservation.token)
        // Idempotent: releasing twice is not an error, so cleanup can be unconditional.
        outstanding.removeValue(forKey: reservation.token)
    }

    func observe(
        _ metric: ResourceMetric,
        budget: ResourceBudget
    ) -> ResourceObservation {
        // The Share staging path reserves rather than samples; a sampled observation is the
        // Device Validation Suite's and the Resource Controller's work.
        .withinHardLimit(metric)
    }
}

// MARK: - Store doubles

/// A store whose atomic promotion fails and whose every other operation is the real one.
///
/// The closest a host can come to an interruption between finalizing the staged bytes and
/// committing them: the copy completed, and the rename that would have made it a session
/// never happened.
struct PromotionRefusingStore: EphemeralFileStoring {
    let underlying: ProtectedEphemeralFileStore
    let fault: EphemeralStoreError = .storeUnavailable

    func create(
        in scope: EphemeralStorageScope,
        protection: FileProtectionLevel
    ) async throws(EphemeralStoreError) -> EphemeralStorageKey {
        try await underlying.create(in: scope, protection: protection)
    }

    func append(
        _ chunk: [UInt8],
        to key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) {
        try await underlying.append(chunk, to: key)
    }

    func finalize(
        _ key: EphemeralStorageKey
    ) async throws(EphemeralStoreError) -> EphemeralWriteReceipt {
        try await underlying.finalize(key)
    }

    func read(_ key: EphemeralStorageKey) async throws(EphemeralStoreError) -> [UInt8] {
        try await underlying.read(key)
    }

    func receipt(for key: EphemeralStorageKey) async -> EphemeralWriteReceipt? {
        await underlying.receipt(for: key)
    }

    func move(
        _ key: EphemeralStorageKey,
        to scope: EphemeralStorageScope
    ) async throws(EphemeralStoreError) {
        throw fault
    }

    func keys(in scope: EphemeralStorageScope) async -> Set<EphemeralStorageKey> {
        await underlying.keys(in: scope)
    }

    func deleteAll(
        in scope: EphemeralStorageScope,
        reason: SessionCleanupReason
    ) async throws(EphemeralStoreError) -> EphemeralDeletionReceipt {
        try await underlying.deleteAll(in: scope, reason: reason)
    }

    func occupiedScopes() async -> Set<EphemeralStorageScope> {
        await underlying.occupiedScopes()
    }
}
