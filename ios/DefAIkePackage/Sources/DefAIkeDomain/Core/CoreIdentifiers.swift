// The opaque versioned identifiers referenced by core session values.
//
// Only identifiers that a task 1.2 type actually references are declared here.
// A later task that needs an additional identifier adds it in the same shape.

/// Identity of one Analysis Session.
///
/// The Share route allocates this value while staging, where it is only a
/// candidate. Successful atomic `staging → ready` publication turns it into the
/// identity of exactly one pending session, and claim must preserve it unchanged.
public struct AnalysisSessionID: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Identity of one application build.
public struct AppBuildID: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Identity of one Release Approved iPhone Configuration allowlist entry.
///
/// Which configurations exist is an externally approved, versioned decision. This
/// type names an entry; it does not assert that any entry is approved.
public struct ApprovedConfigurationID: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Identity of one signed, versioned Model Bundle.
public struct ModelBundleID: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Identity of one immutable versioned release artifact.
///
/// This is the identifier boundary between core session values and the policy and
/// release-artifact schemas. A session records which Preprocessing Contract,
/// Calibration Policy, Provenance Policy, Evidence Fusion Rule, Data Lifecycle
/// Policy, Resource Budget, Approved Verdict Copy compatibility record, capability
/// manifest, activation receipt, and evidence-scope artifact version it was bound
/// to by identifier alone. Resolving an identifier to a validated schema value is
/// the artifact layer's responsibility, and presence of an identifier is never
/// evidence that the named artifact was approved.
public struct ArtifactID: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Identity of one Input Quality Record feature required by a Calibration Policy.
public struct QualityFeatureID: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Stable localization key addressing one Approved Verdict Copy entry.
///
/// The domain carries keys, never display text. Whether a key has an approved
/// value compatible with the session's bundle and capability set is resolved by
/// the presentation layer against the versioned copy artifact; an unresolvable key
/// is a fail-closed presentation error, not a free-form string to render.
public struct ApprovedCopyKey: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Identity of one model checkpoint.
public struct ModelCheckpointIdentifier: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}
