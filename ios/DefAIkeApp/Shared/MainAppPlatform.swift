import DefAIkeCoreML
import DefAIkeDomain
import DefAIkeImagePipeline
import DefAIkeModelBundle
import DefAIkeSharedTransfer
import CoreML
import Foundation
import PhotosUI
import SwiftUI

// The platform boundary the composition root owns, and nothing else does.
//
// Four things live here, and each is here because no library module is allowed to hold it:
//
//   1. **The observed device identity.** `StartupPreflight` compares a `DeviceContext`
//      against the signed allowlist; it does not observe one, because a module that both
//      observed and compared could describe itself into a match. Observation is a platform
//      act, so it belongs in the app target.
//   2. **The Photos representation access.** `PhotosProviderSeam` states outright that "the
//      only implementation that touches `PhotosUI` lives in the app composition". Keeping
//      `PhotosUI` out of `DefAIkeSharedTransfer` is what keeps it out of the Share
//      Extension's module closure.
//   3. **Two module-boundary bridges.** `PreparedModelInputStore` says "the composition root
//      bridges the two" about `PreparedPixelResolving`, and `CompiledPixelModelLocating`
//      says resolving a verified bundle to a directory is deliberately outside
//      `DefAIkeCoreML`. Neither edge may be added to `Package.swift`.
//   4. **The resource governor.** Measuring this process is a platform act. What it must not
//      do is invent a limit: every number it compares against comes from the signed
//      `ResourceBudget`, and a metric this environment cannot measure is reported as
//      unmeasurable rather than as within limit.
//
// Nothing here decides a policy value, and nothing here reports a user-facing outcome.

// MARK: - Observed device identity

/// The running build's identity, observed rather than declared.
///
/// Every field is read from the process. None is read from a signed artifact, because the
/// whole point is to have something independent for the startup gate to compare an artifact
/// against (Requirements 1.2 through 1.4 and 13.18).
enum ObservedDeviceIdentity {

    /// Info.plist key carrying the release-controlled application build identity.
    ///
    /// Deliberately not `CFBundleVersion` or `CFBundleShortVersionString`: the repository's
    /// local values are `0` and `0.0.0`, which are development stand-ins rather than the
    /// distributed build identity the Release Process assigns. Reading the placeholder would
    /// manufacture an `AppBuildID` that no allowlist entry can legitimately name.
    static let appBuildInfoKey = "DefAIkeAppBuildID"

    /// The observed `DeviceContext`, or the field that could not be observed.
    ///
    /// Fails closed. There is no default hardware identifier, no default build identity, and
    /// no substitution of a marketing version for a build identity.
    static func observed(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> Result<DeviceContext, UnobservableIdentity> {
        guard let hardware = hardwareIdentifier() else {
            return .failure(.hardwareIdentifier)
        }
        guard let osVersion = try? PlatformVersion(validating: operatingSystemVersionString(processInfo)) else {
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

    /// Where this process is running.
    ///
    /// Compile-time, because the answer decides whether a measurement can ever be release
    /// evidence and a runtime check could be wrong in exactly the direction that matters
    /// (Requirement 13.16). A simulator build reports `iOSSimulator`, and no simulator result
    /// can satisfy a physical-device gate.
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
    /// `hw.machine` is the exact model string the Release Approved iPhone Allowlist is
    /// keyed on. Never a device family, marketing name, or chip generation: an unlisted
    /// iPhone must stay unlisted even when a listed sibling would pass.
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

// MARK: - Photos representation access

/// Registers the picker items one presentation selected, and lends their representations.
///
/// The registry exists because the domain names a selected item by an opaque
/// `ProviderToken` rather than by a framework object: `PhotosPickerItem` is `PhotosUI`, and
/// carrying one into `DefAIkeDomain` would put SwiftUI in the module the Share Extension
/// links. So the view registers what the user selected, the domain carries tokens, and this
/// actor is the only thing that knows the correspondence.
///
/// A token names one selection for one presentation. It is never derived from a file name,
/// an asset identifier, or the bytes, so it is not session-correlatable user content
/// (Requirement 9.11).
actor PhotosPickerItemRegistry {
    private var items: [UInt64: PhotosPickerItem] = [:]
    private var nextRawValue: UInt64 = 1

    /// Registers `selection` and returns the domain-shaped selection naming it.
    ///
    /// Replaces any previous registration: one presentation at a time, and an abandoned
    /// presentation's items are not kept.
    func register(_ selection: [PhotosPickerItem]) -> PhotosPickerSelection {
        items.removeAll()
        var references: [PhotosPickerItemReference] = []
        references.reserveCapacity(selection.count)
        for item in selection {
            let raw = nextRawValue
            nextRawValue += 1
            items[raw] = item
            references.append(
                PhotosPickerItemReference(
                    token: ProviderToken(rawValue: raw),
                    // Recorded, never trusted. Classification sniffs the actual container
                    // later (Requirements 2.15 and 3.1).
                    contentTypeHint: item.supportedContentTypes.first.flatMap {
                        ContentTypeHint($0.identifier)
                    }
                )
            )
        }
        return PhotosPickerSelection(items: references)
    }

    /// The item one token names, or `nil` once the presentation is over.
    func item(for token: ProviderToken) -> PhotosPickerItem? { items[token.rawValue] }

    /// Forgets every registration. Called when a presentation ends, so a token from a
    /// finished presentation names nothing.
    func clear() { items.removeAll() }
}

/// Loads one selected item's file representation and lends it for the provider's window.
///
/// `Transferable`'s importing closure is static: it receives a `ReceivedTransferredFile`
/// whose URL the framework reclaims when the closure returns, and it has no way to reach a
/// caller's `consume`. So the representation is first relocated into a directory this app
/// owns, at the approved protection level, and `consume` then borrows *that* file.
///
/// Recorded consequence, not a hidden one: this is one relocation more than a design that
/// could run `consume` inside the framework's own window. `linkItem` is attempted first, so
/// the common case adds a directory entry rather than a byte copy; `copyItem` is the
/// fallback when the framework's temporary file is on another volume. The relocated file is
/// removed as soon as `consume` returns, on every path.
///
/// The borrowed file is created inside a directory created at the bound
/// `FileProtectionLevel`, so it is protected for its whole lifetime (Requirement 9.6).
/// Nothing here loosens that level to make a relocation succeed.
struct PhotosPickerRepresentationAccess: PhotosRepresentationAccess {

    /// The registry naming the items this presentation offered.
    let registry: PhotosPickerItemRegistry

    /// The bound protection level for ephemeral analysis files, from the signed
    /// Data Lifecycle Policy. Supplied, never chosen here.
    let protectionLevel: FileProtectionLevel

    /// Applies iOS data protection. The platform implementation on device; injectable so a
    /// host check can observe what was requested.
    let protection: any DataProtectionApplying

    /// Where relocated representations live, inside this app's own container.
    let borrowRoot: URL

    init(
        registry: PhotosPickerItemRegistry,
        protectionLevel: FileProtectionLevel,
        protection: any DataProtectionApplying = PlatformDataProtection(),
        borrowRoot: URL = FileManager.default.temporaryDirectory
            .appending(path: "photos-borrow", directoryHint: .isDirectory)
    ) {
        self.registry = registry
        self.protectionLevel = protectionLevel
        self.protection = protection
        self.borrowRoot = borrowRoot
    }

    func withRepresentation(
        of item: PhotosPickerItemReference,
        consume: @Sendable (BorrowedRepresentation) async -> RetainedRepresentation
    ) async throws(PhotosProviderFault) -> RetainedRepresentation {
        guard let picked = await registry.item(for: item.token) else {
            throw .itemUnavailable
        }

        let relocated: RelocatedRepresentation
        do {
            relocated = try await relocate(picked)
        } catch {
            #if DEBUG
            // Which of the four faults fired. The port narrows all of them to one
            // `decodingError` by the time the ingest coordinator sees them, which is correct for
            // an audit but leaves a local run unable to tell "the provider offered nothing" from
            // "the copy did not complete". Not user-facing, and absent from a Release build.
            DevelopmentDiagnostics.emit("photos-representation-fault", error)
            #endif
            throw error
        }
        defer { try? FileManager.default.removeItem(at: relocated.url) }

        if Task.isCancelled { throw .cancelled }
        return await consume(
            BorrowedRepresentation(
                fileURL: relocated.url,
                suppliedContentTypeHint: relocated.suppliedContentTypeHint,
                form: relocated.form
            )
        )
    }

    /// One representation, relocated into app-owned protected storage.
    private struct RelocatedRepresentation {
        let url: URL
        let suppliedContentTypeHint: ContentTypeHint?
        let form: SuppliedRepresentationForm
    }

    /// Loads the typed file representation and relocates it under `borrowRoot`.
    private func relocate(
        _ item: PhotosPickerItem
    ) async throws(PhotosProviderFault) -> RelocatedRepresentation {
        let transferred: TransferredRepresentationFile?
        do {
            transferred = try await item.loadTransferable(type: TransferredRepresentationFile.self)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            #if DEBUG
            DevelopmentDiagnostics.emit("photos-loadTransferable-threw", error)
            #endif
            throw .transferFailed
        }
        guard let transferred else { throw .representationUnavailable }
        guard FileManager.default.fileExists(atPath: transferred.url.path(percentEncoded: false)) else {
            // The framework already reclaimed its temporary file. Nothing was read.
            throw .representationUnavailable
        }

        // Created at the bound level before anything is placed inside it, so no relocated
        // representation exists for even one moment at a weaker level.
        do {
            try protection.createProtectedDirectory(at: borrowRoot, level: protectionLevel)
        } catch {
            #if DEBUG
            DevelopmentDiagnostics.emit("photos-borrow-root-unavailable", error)
            #endif
            throw .transferFailed
        }

        let destination = borrowRoot.appending(
            path: randomObjectName(),
            directoryHint: .notDirectory
        )
        do {
            try relocateFile(from: transferred.url, to: destination)
        } catch {
            #if DEBUG
            DevelopmentDiagnostics.emit("photos-relocate-failed", error)
            #endif
            throw .transferFailed
        }

        let declared = transferred.contentType.flatMap { ContentTypeHint($0.identifier) }
        return RelocatedRepresentation(
            url: destination,
            suppliedContentTypeHint: declared,
            // A typed answer is one the provider identified as a requested container. It
            // establishes that these are the provider's current bytes and nothing more:
            // both forms map to an unknown Byte Preservation Status (Requirement 2.11).
            form: transferred.matchedRequestedContainer
                ? .typedFileRepresentation
                : .untypedFileRepresentation
        )
    }

    /// Links the provider's file into app-owned storage, copying only when linking cannot
    /// cross the volume boundary.
    private func relocateFile(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        do {
            try manager.linkItem(at: source, to: destination)
        } catch {
            try manager.copyItem(at: source, to: destination)
        }
    }

    /// 128 random bits. Never derived from a file name, an asset identifier, or the bytes
    /// (Requirement 9.11).
    private func randomObjectName() -> String {
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

/// The typed file representation the Photos route asks for.
///
/// One `Transferable` per requested container, in the order
/// `PhotosRepresentationRequest.requestedContainers` fixes, so the picker resolves a typed
/// representation before falling back to a generic image. `.current` is not expressible as
/// an importing option, so the containers themselves are what avoid a transcode: asking for
/// the container the item already is is the closest an import can come to the encoding
/// policy the design names, and it establishes nothing about byte originality.
private struct TransferredRepresentationFile: Transferable {
    let url: URL
    let contentType: UTType?

    /// Whether the provider resolved one of the requested containers rather than the
    /// generic image fallback.
    let matchedRequestedContainer: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .jpeg) { received in
            Self(url: received.file, contentType: .jpeg, matchedRequestedContainer: true)
        }
        FileRepresentation(importedContentType: .png) { received in
            Self(url: received.file, contentType: .png, matchedRequestedContainer: true)
        }
        FileRepresentation(importedContentType: .heic) { received in
            Self(url: received.file, contentType: .heic, matchedRequestedContainer: true)
        }
        FileRepresentation(importedContentType: .heif) { received in
            Self(url: received.file, contentType: .heif, matchedRequestedContainer: true)
        }
        FileRepresentation(importedContentType: .image) { received in
            Self(url: received.file, contentType: nil, matchedRequestedContainer: false)
        }
    }
}

// MARK: - Module-boundary bridges

/// Resolves a prepared model-input token against the image pipeline's own store.
///
/// The bridge `PreparedModelInputStore` names. `DefAIkeImagePipeline` must not depend on
/// `DefAIkeCoreML`, so it cannot conform to `PreparedPixelResolving` itself, and the edge
/// is deliberately absent from `Package.swift`.
///
/// It copies the bytes rather than reshaping them: the store already guarantees the tightly
/// packed, row-major, three-bytes-per-pixel, unnormalized invariant the seam states, so any
/// arithmetic here would be a second, unvalidated preprocessing step (Requirements 4.6
/// through 4.8).
struct PreparedModelInputBridge: PreparedPixelResolving {
    let store: PreparedModelInputStore

    func preparedPixels(for token: ModelInputToken) async -> PreparedPixelData? {
        guard let prepared = await store.preparedInput(for: token) else { return nil }
        // `nil` is impossible for a stored input, whose initializer enforces the same shape
        // rule. Kept as a refusal rather than a force-unwrap: a buffer that is not the shape
        // it claims must not reach the framework.
        return PreparedPixelData(
            edge: prepared.edge,
            channelOrder: prepared.channelOrder,
            bytes: prepared.bytes
        )
    }
}

/// Locates the compiled Core ML model a verified bundle declares.
///
/// The answer needs two things `DefAIkeCoreML` deliberately does not have: the approved
/// bundle layout that names the compiled model's relative path, and the installed root the
/// bundle's declared paths are relative to. Both are supplied.
///
/// `nil` is a fail-closed refusal and never a reason to look elsewhere. There is no search
/// order, no fallback root, and no acceptance of a path the bundle does not declare: the
/// declared path is checked against the verified artifact inventory before it is used, so a
/// layout that names a file the signed manifest never covered resolves to nothing.
struct BundleCompiledModelLocator: CompiledPixelModelLocating {
    /// The approved layout naming the compiled model's canonical relative path.
    let layout: ApprovedBundleLayout

    /// The installed root the bundle's declared relative paths resolve against.
    let installedRoot: URL

    func compiledModelLocation(for bundle: BoundModelBundle) -> URL? {
        let path = layout.compiledModel
        guard bundle.manifest.declaredPaths.contains(path.rawValue) else { return nil }
        guard bundle.integrity.verifiedArtifactDigests.contains(where: {
            $0.path.rawValue == path.rawValue
        }) else {
            return nil
        }
        return installedRoot.appending(path: path.rawValue, directoryHint: .notDirectory)
    }
}

// MARK: - Resource governor

/// Measures this process against the signed budget for one target.
///
/// It compares; it never decides a number. Every ceiling comes from the injected
/// `ResourceBudget`, and there is no member that raises, waives, or overrides one.
///
/// Honesty about measurement is the load-bearing part. `ResourceObservation.notMeasurable`
/// exists because the design only claims to stop before a hard limit "where measurable", and
/// this governor uses it for every metric iOS does not expose a reading for. An unmeasurable
/// metric is never reported as within limit, so an unmeasured mandatory metric surfaces as
/// the gap it is rather than as a pass.
///
/// Deliberately absent: any timeout, deadline, or elapsed-time member. Requirement 15.10
/// forbids an unmeasured requirement-level time limit, and the two latency metrics in the
/// budget are physical-device measurements a Device Validation Plan records rather than
/// runtime deadlines this type enforces.
actor PlatformResourceGovernor: ResourceGoverning {
    let target: ExecutionTarget

    /// Outstanding reservations, so a numeric metric's committed headroom is the sum of what
    /// was granted rather than a guess.
    private var outstanding: [ResourceReservationToken: ResourceReservationRequest] = [:]
    private var nextTokenValue: UInt64 = 1

    init(target: ExecutionTarget) {
        self.target = target
    }

    func reserve(
        _ request: ResourceReservationRequest,
        budget: ResourceBudget
    ) async throws(AnalysisFault) -> ResourceReservation {
        guard budget.target == target else {
            // A reservation checked against the other target's budget has no correct
            // behavior available to it (Requirement 11.1).
            throw .analysis(.resourceLimit, stage: request.stage)
        }
        guard case let .numeric(value: ceiling, unit: unit)? = budget.limit(for: request.metric),
            unit == request.unit
        else {
            // No numeric ceiling for this metric in this budget, or a unit that cannot be
            // compared to it. Fail closed rather than grant unbounded headroom.
            throw .analysis(.resourceLimit, stage: request.stage)
        }

        let committed = committedAmount(for: request.metric)
        guard committed + request.amount.value <= ceiling.value else {
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
            return measured > ceiling.value ? .wouldBreachHardLimit(metric) : .withinHardLimit(metric)
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
    /// Only two metrics have a reading a running process can take honestly. The rest are
    /// physical-device measurements a Device Validation Plan records under declared
    /// conditions, and reporting a runtime approximation of one would put an unmeasured
    /// number where a measured one is required.
    private func measuredValue(of metric: ResourceMetric, in unit: ResourceLimitUnit) -> Decimal? {
        switch metric {
        case .peakResidentMemory:
            guard unit == .bytes, let footprint = physicalFootprintInBytes() else { return nil }
            return Decimal(footprint)
        case .decodedPixelCount, .encodedInputSize:
            // Reserved quantities rather than sampled ones: what is committed is exactly
            // what the stages asked for and this governor granted.
            guard unit == expectedUnit(for: metric) else { return nil }
            return committedAmount(for: metric)
        case .temporaryStorage, .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency,
            .energyImpact, .thermalState:
            return nil
        }
    }

    private func expectedUnit(for metric: ResourceMetric) -> ResourceLimitUnit? {
        switch metric {
        case .decodedPixelCount: .pixels
        case .encodedInputSize, .peakResidentMemory, .temporaryStorage: .bytes
        case .coldModelLoadTime, .warmAnalysisLatency, .handoffLatency: .milliseconds
        case .energyImpact: .milliwattHours
        case .thermalState: nil
        }
    }

    /// This process's physical footprint, which is the reading Apple's memory limits are
    /// applied against. `nil` when the kernel call fails, which is unmeasurable rather than
    /// zero.
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
