import Foundation
import os

/// Where a DEBUG build writes the values it records but never shows.
///
/// Three vocabularies in this target exist so a launch can be *audited* rather than rendered:
/// `MainAppStartupRefusal`, `IngestAttemptRecord`, and `UnpresentableTerminalOutcome`. None of them
/// reaches a screen, by design — a refused startup has no session to describe, and a refused ingest
/// attempt returns the screen to ready, which looks exactly like nothing having happened.
///
/// That makes them invisible during local development, which is how a blank screen stays
/// unexplained. This type is the one place a DEBUG build makes them visible, and it is deliberately
/// narrow:
///
///   * **Not user-facing.** The unified log is a developer surface. Nothing here is localized,
///     nothing goes through the approved-copy mechanism, and nothing appears on screen — so this
///     cannot become a route for unapproved wording, which is what `StartupBlockedView` and the
///     view-state gap vocabularies exist to prevent.
///   * **Not present in a Release build.** Every call site is inside `#if DEBUG`. This file itself
///     is compiled in both configurations so the shipping files can name the type without their own
///     directives, but `emit(_:_:)` has no callers outside DEBUG blocks.
///   * **Carries no session content.** The values it logs are closed vocabularies and identifiers.
///     No image bytes, no file path, no user filename, and no measured dimension passes through it.
///
/// `os.Logger` rather than standard error, measured rather than assumed: an iOS app's stderr is not
/// routed to the unified log, so a `FileHandle.standardError.write` is invisible to
/// `simctl spawn … log stream` and therefore invisible during a UI test, which launches the app
/// itself and offers no console to attach to.
enum DevelopmentDiagnostics {

    /// The subsystem to filter on:
    ///
    ///     xcrun simctl spawn booted log stream \
    ///       --predicate 'subsystem == "dev.defaike.development"'
    static let subsystem = "dev.defaike.development"

    private static let logger = Logger(subsystem: subsystem, category: "recorded-but-not-rendered")

    /// Records one non-projected value.
    ///
    /// `kind` is a stable token so a log line can be grepped; `value` is interpolated as public
    /// data because every value passed here is a closed-vocabulary case or a synthetic identifier,
    /// never user content.
    static func emit(_ kind: String, _ value: some Any) {
        logger.debug("defaike.\(kind, privacy: .public): \(String(describing: value), privacy: .public)")
    }
}
