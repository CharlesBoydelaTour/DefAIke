import SwiftUI

/// Scene composition and dependency assembly for the main iPhone app.
///
/// This target holds no evidence semantics. Both capability compositions compile this file; each
/// also compiles exactly one of `PixelOnly/` or `PixelPlusProvenance/`, which supplies
/// `CompiledCapabilityComposition`.
///
/// The scene passes the compiled composition and, in a Release build, nothing else. This
/// repository carries no release-controlled input set, so `MainAppComposition.start(...)` refuses
/// with `releaseInputsUnprovisioned`, ingest is never exposed, and no `ReleaseAdmission` is
/// constructed. That is the fail-closed state the design requires, not a placeholder — the graph
/// downstream of the gate is assembled in `MainAppComposition.swift` and is complete; it is simply
/// unreachable until a distributed build carries its signed input set.
/// `UnprovisionedReleaseInput` enumerates exactly what is owed.
///
/// A DEBUG build passes a locally assembled input set instead, so a developer can see the
/// application's own screens on a Simulator. It changes nothing about the gate: all seven
/// preflight steps still run and can still refuse, `ReleaseAdmission` is still constructible only
/// inside `StartupPreflight.swift`, and the inputs are *supplied* rather than the checks skipped.
/// It produces no release evidence — see `DevelopmentProvisioning.swift`, which states the three
/// places where its inputs are fabricated and why they can never ship.
@main
struct DefAIkeApp: App {
    var body: some Scene {
        WindowGroup {
            MainAppRootView(
                composition: CompiledCapabilityComposition.self,
                provisioning: developmentProvisioning
            )
        }
    }

    /// The locally assembled input set in a DEBUG build, and `nil` in every Release build.
    ///
    /// The `#else` branch is the shipped behaviour, unchanged: no provisioning, so the startup
    /// gate refuses at its first step. There is no build setting, launch argument, or environment
    /// variable that can turn the DEBUG branch on in a Release configuration, because the symbol
    /// it names does not exist there.
    private var developmentProvisioning: MainAppReleaseProvisioning? {
        #if DEBUG
        DevelopmentProvisioning.forLocalInspection(
            composition: CompiledCapabilityComposition.self
        )
        #else
        nil
        #endif
    }
}
