import DefAIkeDomain

// Choosing the one action the bound contract assigns to each observed metadata state.
//
// Requirement 3.8 gives the Preprocessor exactly one job here: apply *the* handling the
// Analysis Session-bound contract assigns to the observed state. Not a reasonable
// handling, not the handling for the nearest state, and not a built-in default when the
// contract is silent.
//
// ``MetadataStateRules`` already makes silence unrepresentable: its initializer proves
// exact coverage of all four states, so a decoded contract with a gap or a duplicate is
// a schema fault at decode time and never reaches this module. This file does not
// reimplement that. What it adds is the adapter-side check that the rule list actually
// in hand binds the observed state exactly once, which matters for one reason: the rule
// list is a public array on a public type, so a contract value can be assembled in
// process without passing through the validating initializer. A shipping composition
// only ever gets a decoded contract, but "only ever" is an argument about today's call
// graph, and the cost of checking is one filter over four entries.
//
// The check is deliberately not `precondition`. A contract that fails it is a session
// that returns `preprocessing-error`, not a crash: Requirement 3.11 is explicit that an
// inapplicable contract is an Analysis Error, and a trap would take the whole
// application down on input the user cannot control.

/// The one action the bound contract assigns to each observed metadata state.
///
/// Constructing this value is the whole of the contract lookup. Everything downstream
/// takes actions from here, so there is no second place where a state could be mapped
/// to an action differently.
struct BoundMetadataActions: Hashable, Sendable {
    let orientation: OrientationAction
    let colorProfile: ColorProfileAction
    let alpha: AlphaAction
}

/// Validates and performs the contract's metadata-state lookups.
enum MetadataActionBinding {
    /// The single action `rules` binds to `state`, or `nil` when it does not bind
    /// exactly one.
    ///
    /// Exactly one: zero matches is a gap and more than one is a contradiction, and
    /// neither may be resolved by taking the first entry, which is what a dictionary
    /// lookup over the same data would silently do.
    static func soleAction<Action: Hashable & Codable & Sendable>(
        for state: ImageMetadataState,
        in rules: [MetadataStateRules<Action>.Rule]
    ) -> Action? {
        let matching = rules.filter { $0.state == state }
        guard matching.count == 1 else { return nil }
        return matching[0].action
    }

    /// Whether `rules` binds every one of the four metadata states exactly once.
    ///
    /// Checked over all four states rather than only the observed one. A contract that
    /// is total for the state this image happens to present but not for the others is
    /// still not a total contract, and accepting it would mean whether an input is
    /// rejected depends on which input arrived first.
    static func isTotal<Action: Hashable & Codable & Sendable>(
        _ rules: [MetadataStateRules<Action>.Rule]
    ) -> Bool {
        ImageMetadataState.allCases.allSatisfy { state in
            rules.filter { $0.state == state }.count == 1
        }
    }

    /// The three actions the contract binds to the observed states.
    ///
    /// Throws ``PreprocessingFailure/metadataRuleNotTotal(field:)`` when any of the
    /// three maps is not total, before any pixel work and without applying the two maps
    /// that were total.
    static func bind(
        _ observed: ObservedImageMetadata,
        contract: PreprocessingContract
    ) throws(PreprocessingFailure) -> BoundMetadataActions {
        guard isTotal(contract.orientationRules.rules) else {
            throw .metadataRuleNotTotal(field: "orientationRules")
        }
        guard isTotal(contract.colorProfileRules.rules) else {
            throw .metadataRuleNotTotal(field: "colorProfileRules")
        }
        guard isTotal(contract.alphaRules.rules) else {
            throw .metadataRuleNotTotal(field: "alphaRules")
        }
        guard
            let orientation = soleAction(
                for: observed.orientation,
                in: contract.orientationRules.rules
            ),
            let colorProfile = soleAction(
                for: observed.colorProfile,
                in: contract.colorProfileRules.rules
            ),
            let alpha = soleAction(for: observed.alpha, in: contract.alphaRules.rules)
        else {
            // Unreachable given the three totality checks above. Kept as a fail-closed
            // branch because the alternative to an error here is applying a state's
            // action to a different state.
            throw .metadataRuleNotTotal(field: "metadataStateRules")
        }
        return BoundMetadataActions(
            orientation: orientation,
            colorProfile: colorProfile,
            alpha: alpha
        )
    }
}
