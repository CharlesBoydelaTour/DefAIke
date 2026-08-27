import DefAIkeDomain

// The correction channel destination.
//
// Requirement 14.14 requires each public release to publish the versioned active known
// limitations and a user-accessible correction channel identified in the release-readiness
// record. Requirement 8.17 requires a path to that channel from every Evidence Report.
//
// This is the destination where "do not invent content" matters most, so it is worth being
// exact about what exists and what does not.
//
// What exists: the release-readiness record's correction-channel gate entry, which carries an
// immutable reference - an artifact identifier, an exact version, and a digest binding the
// reference to fixed bytes - plus the gate's own pass or fail result. That is enough to know
// *which* published channel this release binds and whether the release actually published it.
//
// What does not exist anywhere in this repository: the channel itself. There is no address, no
// mailbox, no form, no identifier a user could act on. The domain has no type for one, and it
// would be wrong to add a placeholder here: a hard-coded address is a promise the project has
// not made, and an example address on a correction channel is worse than none, because a
// correction a user believes was filed and was not is indistinguishable from an ignored one.
//
// So this screen does three things and refuses one:
//
//   * it resolves the one approved sentence introducing the channel, the same
//     ``VerdictCopySurface/correctionChannel`` surface the report's onward path is labelled
//     with;
//   * it carries the supplied reference, so a release audit and a snapshot test can see which
//     published version this build binds;
//   * it records ``UnapprovedDisclosureSurface/correctionChannelAddress`` as blocked, so the
//     absence is enumerable rather than discovered when a user taps and nothing happens; and
//   * it refuses to exist at all when the release did not publish the channel. That is the
//     fail-closed rule: an unsatisfied gate means there is nothing to point at, and the
//     honest response is no screen rather than an empty one.

/// The correction channel destination (Requirements 8.17 and 14.14).
public struct CorrectionChannelScreen: Hashable, Sendable, ProbabilityFreePresentationModel {
    /// Surfaces this screen needs and nothing in this repository supplies. Nothing is
    /// rendered for them.
    ///
    /// One entry, and it is external content rather than an approved-copy decision: the
    /// channel's own user-accessible address.
    public static let unapprovedSurfaces: Set<UnapprovedDisclosureSurface> = [
        .correctionChannelAddress
    ]

    /// The one approved sentence this screen shows (Requirement 14.14).
    public let channelCopy: ResolvedCopyReference

    /// The published correction channel this release binds.
    ///
    /// A reference, not an address. It names which version of the channel document this
    /// release published and binds that name to fixed content; it carries nothing a user
    /// could contact, because nothing in this repository supplies that.
    public let channel: SuppliedDocumentReference

    init(channelCopy: ResolvedCopyReference, channel: SuppliedDocumentReference) {
        self.channelCopy = channelCopy
        self.channel = channel
    }

    /// Whether this screen can present an address a user could act on.
    ///
    /// Always false today, and stated as a property rather than left implicit so a release
    /// audit reads the same answer a user would experience. It becomes true only when the
    /// release artifact supplies the channel's contents, which is a change outside this
    /// module.
    public var presentsAnActionableAddress: Bool { false }

    /// The destinations this screen answers for (Requirement 8.17).
    public var destinations: [RequiredDisclosureDestination] {
        RequiredDisclosureDestination.allCases.filter { $0.screen == .correctionChannel }
    }
}

// MARK: - Assembly

extension CorrectionChannelScreen {
    /// Projects the correction-channel screen from one checked input.
    ///
    /// Fails closed when the release-readiness record's correction-channel gate is
    /// unsatisfied - a missing result and a failing result alike. Neither is a reason to show
    /// a channel, and neither is a reason to substitute one.
    static func projecting(
        _ input: DisclosureScreenInput
    ) throws(DisclosureAssemblyError) -> CorrectionChannelScreen {
        let gate = input.release.record(for: .correctionChannel)
        guard gate.isSatisfied else {
            throw .correctionChannelNotSupplied(outcome: gate.outcome)
        }

        let channelCopy: ResolvedCopyReference
        do {
            channelCopy = try input.copy.reference(for: .correctionChannel)
        } catch {
            throw .copy(error)
        }

        return CorrectionChannelScreen(
            channelCopy: channelCopy,
            channel: SuppliedDocumentReference(source: gate.evidence)
        )
    }
}
