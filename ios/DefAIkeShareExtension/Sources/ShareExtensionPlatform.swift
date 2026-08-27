import DefAIkeDomain
import DefAIkeSharedTransfer
import Foundation
import UniformTypeIdentifiers

// The platform boundary the Share Extension's composition root owns, and nothing else does.
//
// Three things live here, and each is here because no library module is allowed to hold it:
//
//   1. **The observed extension identity.** `ShareExtensionPreflight` compares a
//      `DeviceContext` against the signed allowlist; it does not observe one, because a
//      component that both observed and compared could describe itself into a match.
//   2. **The item-provider access.** `SharedItemRepresentationAccess` states outright that
//      "the only implementation that touches an extension item or an item provider lives in
//      the Share Extension target". Keeping `NSItemProvider` out of `DefAIkeSharedTransfer`
//      is what lets the one-item rule, the consent ordering, and the atomic publication be
//      exercised on a host with no share sheet and no device.
//   3. **The resource governor.** Measuring this process is a platform act, and the process
//      being measured is the *extension*, whose limits are a separately approved budget
//      (Requirements 11.1 and 11.3). What the governor must not do is invent a limit: every
//      number it compares against comes from the signed `ResourceBudget`, and a metric this
//      environment cannot measure is reported as unmeasurable rather than as within limit.
//
// The main application's composition root holds its own equivalents of items 1 and 3. They are
// deliberately not shared: the two shipping executables have no source in common, and moving a
// platform measurement into `DefAIkeSharedTransfer` — the one module that ships in both —
// would put process introspection inside the module whose whole value is that it only moves,
// protects, measures, and deletes bytes.
//
// Nothing here decides a policy value, and nothing here reports a user-facing outcome.

// MARK: - Observed extension identity

/// The running extension's identity, observed rather than declared.
///
/// Every field is read from the process. None is read from a signed artifact, because the whole
/// point is to have something independent for the startup gate to compare an artifact against.
///
/// The build identity matters more here than anywhere else: it is stamped into every published
/// ticket as `extensionBuildID`, and the claiming application compares it against its own build
/// identity, so a wrong value is a `handoff-error` for every handoff this build ever stages
/// (Requirement 2.19).
enum ObservedExtensionIdentity {

    /// Info.plist key carrying the release-controlled application build identity.
    ///
    /// Deliberately not `CFBundleVersion` or `CFBundleShortVersionString`: this target's local
    /// values are `0` and `0.0.0`, matching the containing app's, and both are development
    /// stand-ins rather than the distributed build identity the Release Process assigns.
    static let appBuildInfoKey = "DefAIkeAppBuildID"

    /// Which field of the running identity could not be observed.
    ///
    /// A closed vocabulary so a startup refusal can name one field instead of reporting
    /// "identity unavailable". None of these is an `AnalysisError`: no session exists.
    enum UnobservableIdentity: String, Error, Hashable, Sendable, CaseIterable {
        /// `hw.machine` produced no canonical identifier.
        case hardwareIdentifier
        /// The operating-system version did not parse as a canonical platform version.
        case osVersion
        /// The distributed build identity is absent from Info.plist.
        case appBuild
    }

    /// The observed `DeviceContext`, or the field that could not be observed.
    ///
    /// Fails closed. There is no default hardware identifier, no default build identity, and no
    /// substitution of a marketing version for a build identity.
    static func observed(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> Result<DeviceContext, UnobservableIdentity> {
        guard let hardware = hardwareIdentifier() else {
            return .failure(.hardwareIdentifier)
        }
        guard
            let osVersion = try? PlatformVersion(
                validating: operatingSystemVersionString(processInfo)
            )
        else {
            return .failure(.osVersion)
        }
        guard let raw = bundle.object(forInfoDictionaryKey: appBuildInfoKey) as? String,
            let appBuild = AppBuildID(raw)
        else {
            return .failure(.appBuild)
        }
        return .success(
            DeviceContext(
                hardwareIdentifier: hardware,
                osVersion: osVersion,
                appBuild: appBuild,
                environment: environment
            )
        )
    }

    /// Where this process is running.
    ///
    /// Compile-time, because the answer decides whether a measurement can ever be release
    /// evidence and a runtime check could be wrong in exactly the direction that matters. A
    /// simulator build reports `iOSSimulator`, and no simulator result can satisfy a
    /// physical-device gate — including the Share Extension handoff gates, which Requirement
    /// 11.20 requires to be approved independently of main-application analysis.
    static var environment: ExecutionEnvironment {
        #if targetEnvironment(simulator)
        return .iOSSimulator
        #elseif os(iOS)
        return .physicalIPhone
        #else
        return .developmentMac
        #endif
    }

    /// The hardware identifier, for example `iPhone15,2`.
    ///
    /// `hw.machine` is the exact model string the Release Approved iPhone Allowlist is keyed on.
    /// Never a device family, marketing name, or chip generation.
    private static func hardwareIdentifier() -> DeviceHardwareID? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var raw = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &raw, &size, nil, 0) == 0 else { return nil }
        // The null terminator is truncated before decoding, so the identifier is exactly the
        // model string and not a string with a trailing zero byte that would fail canonical
        // identifier validation.
        let bytes = raw.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return DeviceHardwareID(String(decoding: bytes, as: UTF8.self))
    }

    private static func operatingSystemVersionString(_ processInfo: ProcessInfo) -> String {
        let version = processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

// MARK: - Item-provider access

/// Loads one shared item's file representation and lends it for the length of an access window.
///
/// `NSItemProvider`'s file-loading contract is the one the design's research finding 2 names:
/// the completion handler receives a temporary URL the framework reclaims when the handler
/// returns, so the receiver must copy it into its own storage first. The handler is
/// synchronous and `consume` is `async`, so the representation is relocated into
/// extension-owned protected storage inside the handler and `consume` then borrows *that* file.
///
/// Recorded consequence, not a hidden one: this is one relocation more than a design that could
/// run `consume` inside the framework's own window, exactly as the Photos route's access
/// adapter records. `linkItem` is attempted first, so the common case adds a directory entry
/// rather than a byte copy; `copyItem` is the fallback when the framework's temporary file is on
/// another volume. The relocated file is removed as soon as `consume` returns, on every path.
///
/// The borrowed file is created inside a directory created at the bound `FileProtectionLevel`,
/// so it is protected for its whole lifetime (Requirement 9.6). Nothing here loosens that level
/// to make a relocation succeed.
///
/// `openInPlace` is always `false`: `SharedItemAccessPolicy` has one case, so a caller cannot
/// ask to analyze a file the host application still owns and can change underneath a running
/// handoff.
struct ExtensionItemRepresentationAccess: SharedItemRepresentationAccess {

    /// The providers this activation offered, by the token the domain names them with.
    ///
    /// Main-actor isolated, and that is load-bearing rather than incidental: an `NSItemProvider`
    /// is a UIKit-supplied object and is not `Sendable`, so it must not cross an isolation
    /// boundary at all. The registry therefore owns both the provider *and* the load, and hands
    /// back only `Sendable` values — a file URL this extension owns and the form the provider
    /// answered with. Nothing in this struct ever holds an item provider.
    let registry: SharedItemProviderRegistry

    /// The bound protection level for ephemeral files, from the signed Extension Execution
    /// Policy. Supplied, never chosen here.
    let protectionLevel: FileProtectionLevel

    /// Applies iOS data protection. The platform implementation on device; injectable so a
    /// host check can observe what was requested.
    let protection: any DataProtectionApplying

    /// Where relocated representations live, inside this extension's own container.
    let borrowRoot: URL

    init(
        registry: SharedItemProviderRegistry,
        protectionLevel: FileProtectionLevel,
        protection: any DataProtectionApplying = PlatformDataProtection(),
        borrowRoot: URL = FileManager.default.temporaryDirectory
            .appending(path: "share-borrow", directoryHint: .isDirectory)
    ) {
        self.registry = registry
        self.protectionLevel = protectionLevel
        self.protection = protection
        self.borrowRoot = borrowRoot
    }

    func withRepresentation(
        of provider: SharedItemProvider,
        consume: @Sendable (BorrowedSharedRepresentation) async -> StagedRepresentation
    ) async throws(SharedItemProviderFault) -> StagedRepresentation {
        let relocated = try await registry.relocateRepresentation(
            for: provider.token,
            into: borrowRoot,
            level: protectionLevel,
            protection: protection
        )
        defer { try? FileManager.default.removeItem(at: relocated.url) }

        if Task.isCancelled { throw .cancelled }
        return await consume(
            BorrowedSharedRepresentation(fileURL: relocated.url, form: relocated.form)
        )
    }
}

/// One representation, relocated into extension-owned protected storage.
///
/// Every member is `Sendable`, which is the whole point: this is what crosses back out of the
/// main actor in place of the item provider.
struct RelocatedRepresentation: Hashable, Sendable {
    let url: URL
    let form: SharedRepresentationForm
}

/// Registers the item providers one activation offered, and names them for the domain.
///
/// The registry exists because the domain names an offered item by an opaque `ProviderToken`
/// rather than by a framework object: carrying an `NSItemProvider` into `DefAIkeDomain` would
/// put Foundation's item-provider surface in the module the main application also links, and
/// would make the activation-counting rules untestable without a share sheet.
///
/// A token names one provider for one activation. It is never derived from a file name, a host
/// application identity, or the bytes, so it is not session-correlatable user content
/// (Requirement 9.11).
///
/// What this registry does *not* do is choose. It registers every provider the host offered,
/// including zero and many, and returns the domain-shaped activation carrying all of them —
/// because Requirement 2.7 refuses any count other than one, and a registry that quietly kept
/// the first provider would make that refusal unreachable.
@MainActor
final class SharedItemProviderRegistry {
    private var providers: [UInt64: NSItemProvider] = [:]
    private var nextRawValue: UInt64 = 1

    init() {}

    /// Registers every provider the activation offered and returns the activation naming them.
    ///
    /// `itemCount` on each reference is the number of items *that provider's extension item*
    /// carried, which is the count the host actually offered. It is not clamped to one, not
    /// defaulted to one, and not inferred from the activation rule: the activation rule limits
    /// what a share sheet presents, and runtime counting stays authoritative
    /// (design, Share Extension handoff sequence).
    func register(_ items: [OfferedExtensionItem]) -> ShareActivation {
        providers.removeAll()
        var references: [SharedItemProvider] = []
        references.reserveCapacity(items.count)
        for item in items {
            let raw = nextRawValue
            nextRawValue += 1
            // `nil` for any attachment count other than one, which is exactly the case the
            // refusal path handles: there is no single item to load, so there is nothing to
            // register, and the reference below still reports the true count.
            providers[raw] = item.soleAttachment
            guard
                let reference = SharedItemProvider(
                    token: ProviderToken(rawValue: raw),
                    itemCount: item.attachmentCount,
                    // Recorded, never trusted. Classification sniffs the actual container in the
                    // main application (Requirements 2.15 and 3.1).
                    contentTypeHint: item.contentTypeHint
                )
            else {
                // Only a negative count is rejected by the initializer, and an array's count
                // cannot be negative, so this is unreachable. Skipping rather than substituting
                // keeps this from inventing a count: a provider that cannot be named is a
                // provider the activation does not offer, and dropping it can only move the
                // total further from one, never towards it.
                continue
            }
            references.append(reference)
        }
        return ShareActivation(providers: references)
    }

    /// Forgets every registration, so a token from a finished activation names nothing.
    func clear() { providers.removeAll() }

    // MARK: - Loading, without letting the provider escape

    /// Loads the representation `SharedItemRepresentationRequest` names and relocates it into
    /// extension-owned protected storage.
    ///
    /// The item provider never leaves this actor. What comes back is a `RelocatedRepresentation`,
    /// whose members are all `Sendable`, so the streaming copy that follows can run off the main
    /// actor without a UIKit object crossing a boundary.
    ///
    /// The requested containers are tried in the order
    /// `SharedItemRepresentationRequest.requestedContainers` fixes, so the provider resolves a
    /// *typed* representation before the generic image fallback is attempted. Asking for the
    /// container the item already is is the closest a load can come to avoiding a transcode, and it
    /// establishes nothing about byte originality — both forms map to an unknown Byte Preservation
    /// Status (Requirement 2.11).
    func relocateRepresentation(
        for token: ProviderToken,
        into borrowRoot: URL,
        level: FileProtectionLevel,
        protection: any DataProtectionApplying
    ) async throws(SharedItemProviderFault) -> RelocatedRepresentation {
        // `nil` covers a finished activation and a token naming an item that did not carry exactly
        // one attachment. Neither is loadable, and neither reads a byte.
        guard let provider = providers[token.rawValue] else {
            throw .itemUnavailable
        }

        var lastFault: SharedItemProviderFault = .representationUnavailable
        for container in SharedItemRepresentationRequest.requestedContainers {
            guard let type = UTType(container.rawValue),
                provider.hasItemConformingToTypeIdentifier(type.identifier)
            else {
                continue
            }
            do {
                let url = try await Self.load(
                    provider,
                    as: type,
                    into: borrowRoot,
                    level: level,
                    protection: protection
                )
                return RelocatedRepresentation(url: url, form: .typedFileRepresentation)
            } catch {
                if error == .cancelled { throw .cancelled }
                lastFault = error
            }
        }

        // The generic fallback. A representation the provider did not identify as one of the
        // requested containers is still staged: the Input Validator refuses an unsupported
        // container by sniffing the actual bytes, and hiding it here would make Requirement 2.15's
        // `unsupported-static-format` unreachable through the Share route.
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            throw lastFault
        }
        let url = try await Self.load(
            provider,
            as: .image,
            into: borrowRoot,
            level: level,
            protection: protection
        )
        return RelocatedRepresentation(url: url, form: .untypedFileRepresentation)
    }

    /// Loads one typed representation and relocates it, returning the relocated location.
    ///
    /// The relocation happens inside the completion handler, before it returns, because that is the
    /// whole duration of the framework's access window: the URL the handler receives names a file
    /// the framework reclaims, so a URL that outlives the handler names nothing.
    private static func load(
        _ provider: NSItemProvider,
        as type: UTType,
        into borrowRoot: URL,
        level: FileProtectionLevel,
        protection: any DataProtectionApplying
    ) async throws(SharedItemProviderFault) -> URL {
        // Created at the bound level before anything is placed inside it, so no relocated
        // representation exists for even one moment at a weaker level (Requirement 9.6).
        do {
            try protection.createProtectedDirectory(at: borrowRoot, level: level)
        } catch {
            throw .transferFailed
        }
        let destination = borrowRoot.appending(
            path: randomObjectName(),
            directoryHint: .notDirectory
        )

        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                _ = provider.loadFileRepresentation(
                    for: type,
                    openInPlace: false
                ) { url, _, error in
                    guard let url, error == nil else {
                        continuation.resume(throwing: error ?? RelocationFailure.noRepresentation)
                        return
                    }
                    // Inside the window. Nothing captures `url` past this point.
                    do {
                        try relocateFile(from: url, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: RelocationFailure.relocationFailed)
                    }
                }
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw .cancelled
        } catch RelocationFailure.noRepresentation {
            throw .representationUnavailable
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw .transferFailed
        }
        return destination
    }

    /// Why a relocation produced no borrowed file.
    ///
    /// Local to the bridge between the completion handler and the typed throw. It never reaches a
    /// caller: `load(_:as:into:level:protection:)` maps it onto the seam's own closed fault
    /// vocabulary, so no framework error, path, or host bundle identifier escapes this file.
    private enum RelocationFailure: Error {
        case noRepresentation
        case relocationFailed
    }

    /// Links the provider's file into extension-owned storage, copying only when linking cannot
    /// cross the volume boundary.
    ///
    /// The host's file is opened for reading only. Nothing here writes, truncates, moves, or
    /// removes it — that is the host's to reclaim.
    /// `nonisolated` because the framework calls its completion handler on a queue of its own
    /// choosing, and the relocation has to happen inside that call. It touches no registry state.
    private nonisolated static func relocateFile(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        do {
            try manager.linkItem(at: source, to: destination)
        } catch {
            try manager.copyItem(at: source, to: destination)
        }
    }

    /// 128 random bits. Never derived from a file name, a host application identity, or the bytes
    /// (Requirement 9.11).
    private nonisolated static func randomObjectName() -> String {
        var generator = SystemRandomNumberGenerator()
        var name = ""
        name.reserveCapacity(32)
        for _ in 0..<16 {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            name += String(format: "%02x", byte)
        }
        return name
    }
}

/// One extension item the host offered, with its attachments as the host supplied them.
///
/// The count is the array's length rather than a separate field, so there is no number to
/// transpose and no way to declare a count that disagrees with the attachments present. That
/// count is what Requirement 2.7 is about, and it reaches `ShareActivation` unmodified.
struct OfferedExtensionItem {
    /// Every attachment this extension item carried, in the order the host supplied them.
    ///
    /// Deliberately the whole array. Zero and many have to survive to the refusal, so nothing here
    /// filters, sorts, or truncates.
    let attachments: [NSItemProvider]

    /// What the sharing application claimed the content type is. Never trusted.
    let contentTypeHint: ContentTypeHint?

    /// How many items this extension item offered.
    var attachmentCount: Int { attachments.count }

    /// The sole attachment, or `nil` for any other count.
    ///
    /// The only sanctioned way from an offered item to a provider: no `first`, no `prefix(1)`, and
    /// no "pick the best attachment".
    var soleAttachment: NSItemProvider? {
        attachments.count == 1 ? attachments[0] : nil
    }
}

// MARK: - Resource governor

/// Measures this extension process against the signed Share Extension budget.
///
/// It compares; it never decides a number. Every ceiling comes from the injected
/// `ResourceBudget`, and there is no member that raises, waives, or overrides one. The target is
/// fixed at construction and is always `.shareExtension`, so a reservation cannot be checked
/// against the main application's budget (Requirement 11.1).
///
/// Honesty about measurement is the load-bearing part. `ResourceObservation.notMeasurable`
/// exists because the design only claims to stop before a hard limit "where measurable", and
/// this governor uses it for every metric iOS does not expose a reading for. An unmeasurable
/// metric is never reported as within limit.
///
/// Deliberately absent: any timeout, deadline, or elapsed-time member. Handoff latency is one of
/// the Share Extension budget's metrics (Requirement 11.3), and it is a physical-device
/// measurement a Device Validation Plan records under declared conditions — not a runtime
/// deadline this type enforces (Requirement 15.10).
actor ExtensionResourceGovernor: ResourceGoverning {

    /// Fixed. There is no initializer parameter for it, so this governor cannot be constructed
    /// for the other target.
    let target: ExecutionTarget = .shareExtension

    /// Outstanding reservations, so a numeric metric's committed headroom is the sum of what was
    /// granted rather than a guess.
    private var outstanding: [ResourceReservationToken: ResourceReservationRequest] = [:]
    private var nextTokenValue: UInt64 = 1

    init() {}

    func reserve(
        _ request: ResourceReservationRequest,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ResourceReservation {
        guard budget.target == target else {
            // A reservation checked against the main application's budget has no correct
            // behavior available to it (Requirement 11.1).
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        guard case let .numeric(value: ceiling, unit: unit)? = budget.limit(for: request.metric),
            unit == request.unit
        else {
            // No numeric ceiling for this metric in this budget, or a unit that cannot be
            // compared to it. Fail closed rather than grant unbounded headroom: treating a
            // missing limit as unlimited would make the approved budget advisory.
            throw .analysis(.resourceLimit, stage: request.stage)
        }

        let committed = committedAmount(for: request.metric)
        guard committed + request.amount.value <= ceiling.value else {
            // Requirement 11.8: the affected work stops before it starts, so no session and no
            // inference ever began.
            throw .analysis(.resourceLimit, stage: request.stage)
        }

        let token = ResourceReservationToken(rawValue: nextTokenValue)
        nextTokenValue += 1
        outstanding[token] = request
        return ResourceReservation(
            token: token,
            request: request,
            budgetID: budget.id,
            target: target
        )
    }

    func release(_ reservation: ResourceReservation) async {
        outstanding.removeValue(forKey: reservation.token)
    }

    func observe(
        _ metric: ResourceMetric,
        budget: ResourceBudget
    ) async -> ResourceObservation {
        guard budget.target == target, let limit = budget.limit(for: metric) else {
            return .notMeasurable(metric)
        }
        switch limit {
        case let .thermal(maximumState: maximum):
            guard let state = observedThermalState() else { return .notMeasurable(metric) }
            return state > maximum ? .wouldBreachHardLimit(metric) : .withinHardLimit(metric)
        case let .numeric(value: ceiling, unit: unit):
            guard let measured = measuredValue(of: metric, in: unit) else {
                return .notMeasurable(metric)
            }
            return measured > ceiling.value
                ? .wouldBreachHardLimit(metric)
                : .withinHardLimit(metric)
        }
    }

    /// Headroom already granted for one metric.
    private func committedAmount(for metric: ResourceMetric) -> Decimal {
        outstanding.values
            .filter { $0.metric == metric }
            .reduce(Decimal.zero) { $0 + $1.amount.value }
    }

    /// The thermal state, or `nil` when the platform reports one this build does not name.
    ///
    /// An unnamed state is unmeasurable rather than mapped to the nearest neighbour: guessing
    /// downward would hide a breach and guessing upward would invent one.
    private func observedThermalState() -> ThermalState? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: nil
        }
    }

    /// The current reading for one metric, or `nil` when this environment has none.
    ///
    /// Only two of the Share Extension budget's six metrics have a reading a running process can
    /// take honestly. Encoded input size is a reserved quantity rather than a sampled one, so
    /// what is committed is exactly what the staging path asked for and this governor granted.
    /// Temporary storage, handoff latency, and energy impact are physical-device measurements a
    /// Device Validation Plan records under declared conditions, and reporting a runtime
    /// approximation of one would put an unmeasured number where a measured one is required.
    private func measuredValue(
        of metric: ResourceMetric,
        in unit: ResourceLimitUnit
    ) -> Decimal? {
        switch metric {
        case .peakResidentMemory:
            guard unit == .bytes, let footprint = physicalFootprintInBytes() else { return nil }
            return Decimal(footprint)
        case .encodedInputSize:
            guard unit == .bytes else { return nil }
            return committedAmount(for: metric)
        case .decodedPixelCount, .temporaryStorage, .coldModelLoadTime, .warmAnalysisLatency,
            .handoffLatency, .energyImpact, .thermalState:
            // `decodedPixelCount`, `coldModelLoadTime`, and `warmAnalysisLatency` are
            // main-application metrics the Share Extension budget does not carry at all: the
            // extension decodes nothing and loads no model. They are listed rather than
            // defaulted so this switch stays total and a new metric has to be classified.
            return nil
        }
    }

    /// This process's physical footprint, which is the reading Apple's memory limits are applied
    /// against. `nil` when the kernel call fails, which is unmeasurable rather than zero.
    ///
    /// A share extension's memory ceiling is lower than an application's, which is precisely why
    /// the Share Extension budget is separately measured (Requirement 11.3). The number this
    /// returns is a reading, never a limit.
    private func physicalFootprintInBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }
}
