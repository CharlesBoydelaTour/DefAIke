// Ingest route and byte-preservation vocabulary.

/// The two Version 1 ingest routes.
///
/// Exactly one route is recorded for every Analysis Session (Requirement 2.8), and
/// these two are the complete Version 1 set (Requirement 2.6). An additional route
/// is outside the evidence scope a report states.
public enum InputRoute: String, Codable, Sendable, CaseIterable {
    /// System photo picker, selected-item access only.
    case photosPicker
    /// Share Extension handoff of the exact available encoded bytes.
    case shareExtension
}

/// What is known about the preservation of the analyzed encoded bytes.
///
/// The status describes the bytes DefAIke actually retained, never the source
/// representation's full history. It is chosen conservatively and cannot be
/// upgraded toward ``originalBytes`` without explicit evidence: see
/// ``PreservationBasis``.
public enum BytePreservationStatus: String, Codable, Sendable, CaseIterable {
    /// The retained bytes are a byte-for-byte copy of the source's original
    /// encoded representation (Requirement 2.9).
    case originalBytes
    /// The retained bytes are a byte-for-byte copy of a representation the
    /// platform already transformed (Requirement 2.10).
    case platformTransformedCopy
    /// The retained bytes are a byte-for-byte copy of the available representation
    /// whose preservation history could not be established (Requirement 2.11).
    case unknown
}

/// Why a ``BytePreservationStatus`` was selected.
///
/// This records the evidence for a status decision, not user content: no file
/// name, asset identifier, or path is representable here. Each basis maps to
/// exactly one most conservative status, so a status cannot be justified by a
/// basis that does not support it, and a request for a "current" representation
/// never becomes proof of byte originality.
public enum PreservationBasis: String, Codable, Sendable, CaseIterable {
    /// The provider declared that the representation it supplied is the source's
    /// unmodified original encoded representation.
    case providerDeclaredOriginalRepresentation
    /// The provider declared that it supplied a transformed representation.
    case providerDeclaredTransformedRepresentation
    /// The provider supplied its current representation without establishing
    /// whether that representation is the original.
    case providerDeclaredCurrentRepresentationOnly
    /// No preservation history could be established for the retained bytes.
    case preservationHistoryNotEstablished

    /// The most conservative status this basis supports.
    ///
    /// Total by construction: every basis has exactly one supported status, and
    /// only an explicit original-representation declaration reaches
    /// ``BytePreservationStatus/originalBytes``.
    public var mostConservativeStatus: BytePreservationStatus {
        switch self {
        case .providerDeclaredOriginalRepresentation:
            return .originalBytes
        case .providerDeclaredTransformedRepresentation:
            return .platformTransformedCopy
        case .providerDeclaredCurrentRepresentationOnly, .preservationHistoryNotEstablished:
            return .unknown
        }
    }

    /// Reports whether `status` is supported by this basis.
    ///
    /// Ingest records the status a basis supports; a handoff carries both across
    /// the process boundary unchanged, so this check also detects a ticket whose
    /// status and basis were altered independently.
    public func supports(_ status: BytePreservationStatus) -> Bool {
        mostConservativeStatus == status
    }
}
