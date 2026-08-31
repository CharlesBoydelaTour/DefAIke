import DefAIkePresentation
import SwiftUI

/// The banner a locally provisioned build shows above every screen.
///
/// This type is compiled into both configurations on purpose, and its body is empty in a Release
/// build. `MainAppScene.swift` is shipping code, and putting a `#if DEBUG` in the middle of its
/// view builder would make the shipping composition root read differently in the two
/// configurations. A named view whose Release rendering is provably `EmptyView` is the smaller
/// claim: the shipping file always builds the same hierarchy, and this type decides whether
/// anything is in it.
///
/// # Why a banner exists at all
///
/// `DevelopmentProvisioning` supplies its own Calibration Policy. Its category boundary is tied
/// to the checkpoint's published model boundary and its abstention band covers measured Core ML
/// conversion drift, but neither was derived from product calibration slices, a measured
/// false-accusation rate, and an approved pass rule. The compiled model, its weights, and the
/// logit it produces are real; the mapping from that logit to one of the three fixed pixel labels
/// is not approved. A label displayed on that basis is a development observation, and Requirement
/// 8.4 forbids presenting a model signal as proof of anything.
///
/// So the notice is not a courtesy. It is what keeps the screens below it from reading as a
/// verdict, and it is placed above them rather than beside them so it cannot be scrolled past
/// before a label is read.
///
/// # It is still approved-mechanism copy
///
/// The wording is not written here. It is addressed to
/// `ChromeCopySurface.developmentBuildNotice` and resolved through the same
/// `AccessibleTextResolver` and the same validated String Catalog every other string on screen
/// goes through, so it obeys the same rule as the rest: an unresolvable notice renders nothing.
/// That is the correct failure mode even for this string — a build that cannot resolve its own
/// warning has already refused to start, because `ChromeCopyCoverage` runs inside
/// `EnglishStringCatalog.loadShippedCatalog()`.
struct DevelopmentProvisioningNotice: View {

    /// The resolver supplying approved text, from the admitted application.
    let resolver: AccessibleTextResolver

    var body: some View {
        #if DEBUG
        // Rendered only when this build's provisioning actually came from the development seam.
        // The property is a constant inside `#if DEBUG`, so a Release build has no path here at
        // all and a DEBUG build cannot separate the notice from the seam that requires it.
        if DevelopmentProvisioning.suppliesUnapprovedInputs,
            let text = resolver.resolvedText(
                for: .approvedChromeCopy(ChromeCopyReference(.developmentBuildNotice))
            )
        {
            // `Text(verbatim:)` for the same reason `AccessibleElementView` uses it: the string
            // already came from the approved catalog, and a second localized lookup on an
            // already-resolved value is how a key ends up on screen.
            Text(verbatim: text)
                .font(.footnote)
                .fontWeight(.semibold)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.yellow.opacity(0.35))
                // One accessible element carrying exactly the approved sentence. It is not
                // hidden from assistive technology: a user who cannot see the banner needs the
                // warning more than one who can, and Requirement 12.7 requires meaning to
                // travel as text rather than as the background colour that draws the eye to it.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: text))
                .accessibilityIdentifier("defaike.development.unapproved-inputs-notice")
        }
        #else
        // A Release build renders nothing, because a Release build has no development seam to
        // warn about: `DevelopmentProvisioning` does not exist in it, and
        // `MainAppRootView` is constructed with no provisioning at all.
        EmptyView()
        #endif
    }
}
