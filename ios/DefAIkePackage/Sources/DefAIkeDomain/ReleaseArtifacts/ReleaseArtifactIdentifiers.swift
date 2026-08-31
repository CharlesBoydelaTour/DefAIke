// Opaque identifiers referenced only by policy and release-artifact schemas.
//
// `Sources/DefAIkeDomain/Core/CoreIdentifiers.swift` declares the identifiers
// core session values reference and invites later tasks to add further ones in the
// same shape. These are those: nothing in the session path names a signing key, a
// fixture, a release slice, or an approver, so they live with the artifact schemas
// that do.
//
// Every identifier here names something whose *content* is an externally approved,
// versioned decision. Holding an identifier is never evidence that the named key,
// device, fixture, slice, or approval passed anything.

/// Identity of one capability in a release capability set.
///
/// Which capabilities a build compiles is a fact about its module graph; which
/// capabilities a release *enables* is a separate signed decision.
public struct CapabilityID: CanonicalIdentifier {
    /// Pixel analysis, the required Version 1 evidence capability.
    public static let pixelAnalysis = CapabilityID(literal: "pixel-analysis")

    /// On-device Content Credential validation, enabled only when the Provenance
    /// Feasibility Gate passes (Requirements 6.1 and 6.2).
    public static let contentCredentialValidation = CapabilityID(
        literal: "content-credential-validation"
    )

    /// Combined Summary production from an approved Evidence Fusion Rule.
    public static let evidenceFusion = CapabilityID(literal: "evidence-fusion")

    /// Consented Share Extension handoff to the main application.
    public static let shareExtensionHandoff = CapabilityID(literal: "share-extension-handoff")

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

    /// Builds one of the named constants above. Not usable for arbitrary input.
    private init(literal: String) {
        self.rawValue = literal
    }
}

/// Identity of one release signing key.
///
/// Key generation, custody, rotation, and revocation stay in the Bundle
/// Verification Policy and its governance record. This identifier names a key; it
/// asserts nothing about whether that key is trusted.
public struct SigningKeyID: CanonicalIdentifier {
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

/// Identity of one immutable fixture in a Release Fixture Suite.
public struct FixtureID: CanonicalIdentifier {
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

/// Identity of one self-test case named by a Model Bundle's self-test specification.
public struct SelfTestCaseID: CanonicalIdentifier {
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

/// Identity of one predeclared mandatory Release Gating Slice (Requirement 5.15).
public struct ReleaseSliceID: CanonicalIdentifier {
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

/// Normalized, vendor-independent status key produced by a provenance validator.
///
/// The Provenance Policy maps these keys onto the five enabled evidence states.
/// The key space belongs to the approved policy, not to this module, so no
/// constant is declared: a library status that the policy does not map is a policy
/// gap rather than something code silently interprets.
public struct ProvenanceValidatorStatusID: CanonicalIdentifier {
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

/// Exact device hardware identifier, for example an Apple machine identifier.
///
/// Startup preflight matches this value exactly. A device is never approved by
/// family, marketing name, or capability inference (Requirements 1.3 and 13.1).
public struct DeviceHardwareID: CanonicalIdentifier {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard CanonicalIdentifierSyntax.isCanonical(
            rawValue,
            maximumCharacterCount: Self.maximumCharacterCount,
            // Apple's `hw.machine` values use a comma, for example `iPhone18,1`.
            // Keep that vendor punctuation confined to device identities rather than
            // widening every artifact and policy identifier in the domain.
            additionalAllowedPunctuation: [","]
        ) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

/// Non-user-derived identity of the role or owner recorded on an approval.
///
/// An approver identity is audit metadata. It records who decided, never that the
/// decision was favorable.
public struct ApproverID: CanonicalIdentifier {
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
