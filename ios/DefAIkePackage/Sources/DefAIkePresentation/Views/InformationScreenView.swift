#if canImport(SwiftUI)

import DefAIkeDomain
import SwiftUI

// One destination for every statement that is not a result.
//
// The analysis screen used to carry all of this: three limitation paragraphs and three onward rows,
// stacked under the two evidence cards. Two things were wrong with that, and both were visible in a
// screenshot rather than arguable:
//
//   1. **The report was mostly not the report.** The two lane cards - the only part that describes
//      the image a user just chose - were a third of the page. Everything below was standing text
//      that says the same thing on every screen, for every image, forever.
//   2. **The onward rows did nothing.** Navigating to a disclosure screen needs a Release Readiness
//      Record, no installed artifact supplies one, so `openDisclosurePath` was wired to an empty
//      closure. Three rows drew a chevron and a press state and then did not move.
//
// So the standing text lives here, and the rows open this. That makes them honest - they navigate
// somewhere - and it lets the report be about the image.
//
// What this screen does *not* do, and the constraint is the same one as everywhere else: it chooses
// no wording. Every string is resolved from the approved catalog through ``AccessibleTextResolver``,
// and a section whose text will not resolve is not rendered rather than shown as a heading over
// nothing.

/// Every statement that is not about one particular image.
///
/// Presented as a sheet from the analysis screen. It holds no session, reads no evidence, and has no
/// action other than dismissing itself, so it cannot show or affect a result.
public struct InformationScreenView: View {
    /// The report whose approved copy this screen reads, when a report exists.
    ///
    /// The limitations and the three onward statements are addressed through a *session's* approved
    /// copy binding, so they can only be resolved when a completed report supplied one. Before any
    /// analysis has run there is no binding, and the limitation sections are therefore absent rather
    /// than filled with wording from nowhere.
    public let report: EvidenceReportPresentation?

    /// The resolver supplying approved text.
    public let resolver: AccessibleTextResolver

    /// What dismissing the screen does.
    public let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        report: EvidenceReportPresentation?,
        resolver: AccessibleTextResolver,
        dismiss: @escaping () -> Void
    ) {
        self.report = report
        self.resolver = resolver
        self.dismiss = dismiss
    }

    private var palette: Palette { .resolved(for: Appearance(colorScheme)) }

    private var textSize: SupportedTextSize { SupportedTextSize(dynamicTypeSize) }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Space.section) {
                    section(
                        heading: .informationLimitationsHeading,
                        references: limitationReferences
                    )
                    section(
                        heading: .informationAboutHeading,
                        references: aboutReferences
                    )
                }
                .frame(maxWidth: Layout.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.pageMargin)
                .padding(.vertical, Space.section)
            }
        }
        .background(Color(palette.background))
        .accessibilityElement(children: .contain)
    }

    /// The title and the one control this screen has.
    ///
    /// The dismiss control is a real ``Button`` with an approved label, not a drag-to-dismiss
    /// affordance: a sheet that can only be closed by dragging has no operable control at all, which
    /// Requirement 12.11 would refuse.
    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if let title = resolvedChrome(.informationTitle) {
                Text(verbatim: title)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Color(palette.textPrimary))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: Space.padding)
            if let label = resolvedChrome(.informationDismissAction) {
                Button(action: dismiss) {
                    Text(verbatim: label)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Color(palette.textPrimary))
                }
                .frame(
                    minWidth: CGFloat(MinimumActivationArea.requiredEdgeLength),
                    minHeight: CGFloat(MinimumActivationArea.requiredEdgeLength),
                    alignment: .trailing
                )
                .contentShape(Rectangle())
                .accessibilityLabel(Text(verbatim: label))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Layout.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.pageMargin)
        .padding(.vertical, Space.padding)
        .overlay(alignment: .bottom) { RowDivider(palette: palette) }
    }

    /// One headed group of statements, or nothing when none of them resolves.
    ///
    /// The emptiness check is the point: a heading over no statements would tell a user there is
    /// something here to read when there is not.
    @ViewBuilder
    private func section(
        heading: ChromeCopySurface,
        references: [ResolvedCopyReference]
    ) -> some View {
        let statements = references.compactMap { resolver.resolvedText(for: .approvedCopy($0)) }
        if let title = resolvedChrome(heading), !statements.isEmpty {
            VStack(alignment: .leading, spacing: Space.inner) {
                Text(verbatim: title)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(Color(palette.textPrimary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                ForEach(Array(statements.enumerated()), id: \.offset) { _, statement in
                    Text(verbatim: statement)
                        .font(VisualEmphasis.limitation.font)
                        .foregroundStyle(Color(palette.foreground(for: .limitation)))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(VisualEmphasis.limitation.textAlignment)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The three limitation statements a completed report carries.
    private var limitationReferences: [ResolvedCopyReference] {
        guard let report else { return [] }
        return [
            report.limitations.scopeCopy,
            report.limitations.falseResultCopy,
            report.limitations.bytePreservation.limitationCopy,
        ]
    }

    /// The privacy, model, and correction statements.
    private var aboutReferences: [ResolvedCopyReference] {
        guard let report else { return [] }
        return ReportDisclosurePath.allCases.map(report.disclosurePaths.reference)
    }

    /// One resolved chrome string, or `nil` when it will not resolve.
    private func resolvedChrome(_ surface: ChromeCopySurface) -> String? {
        resolver.resolvedText(for: .approvedChromeCopy(ChromeCopyReference(surface)))
    }
}

#endif
