import Testing

@testable import DefAIkeDomain
@testable import DefAIkePresentation

// Requirement 8.2 fixes the three pixel-label strings character for character, so
// these tests are about exactness rather than about behavior: exactly three strings
// exist, each label maps to exactly one, and anything that is not one of them is
// refused rather than repaired.

@Suite("Fixed pixel label text")
struct FixedPixelLabelTextTests {

    @Test("Exactly three label strings exist")
    func exactlyThreeStrings() {
        #expect(FixedPixelLabelText.allTexts.count == 3)
        #expect(PixelLabelKey.allCases.count == 3)
        #expect(PixelEvidence.allCases.count == 3)
    }

    @Test("Each label carries its exact required string")
    func exactStrings() {
        #expect(
            FixedPixelLabelText(label: .signalsConsistentWithAIGeneration).value
                == "Signals consistent with AI generation"
        )
        #expect(
            FixedPixelLabelText(label: .noStrongSignalDetected).value
                == "No strong signal detected"
        )
        #expect(FixedPixelLabelText(label: .notEnoughSignal).value == "Not enough signal")
    }

    @Test("Runtime evidence and encoded key agree", arguments: PixelEvidence.allCases)
    func evidenceAndKeyAgree(evidence: PixelEvidence) {
        #expect(
            FixedPixelLabelText(evidence: evidence) == FixedPixelLabelText(label: evidence.labelKey)
        )
    }

    @Test("An exact string recovers its label", arguments: PixelLabelKey.allCases)
    func exactRoundTrip(label: PixelLabelKey) {
        let text = FixedPixelLabelText(label: label)
        #expect(FixedPixelLabelText(exact: text.value)?.label == label)
        #expect(throws: Never.self) {
            try FixedPixelLabelText.validate(rendered: text.value, for: label)
        }
    }

    @Test(
        "A near miss is a different claim and is refused",
        arguments: [
            "signals consistent with AI generation",
            "Signals consistent with AI generation.",
            "Signals consistent with AI generation ",
            " Signals consistent with AI generation",
            "Signals  consistent with AI generation",
            "Signals consistent with A.I. generation",
            "No strong signals detected",
            "Not enough signals",
            "Likely AI generated",
            "",
        ]
    )
    func nearMissesRejected(candidate: String) {
        #expect(FixedPixelLabelText(exact: candidate) == nil)
    }

    @Test("Validation of a wrong rendered string fails closed")
    func validationFailsClosed() {
        let label = PixelLabelKey.noStrongSignalDetected

        #expect(
            throws: PresentationCopyError.pixelLabelTextMismatch(
                label: label,
                expected: "No strong signal detected",
                found: "No signal detected"
            )
        ) {
            try FixedPixelLabelText.validate(rendered: "No signal detected", for: label)
        }
    }

    @Test("Validation refuses one label's string under another label")
    func crossLabelValidationFails() {
        #expect(throws: PresentationCopyError.self) {
            try FixedPixelLabelText.validate(
                rendered: FixedPixelLabelText(label: .notEnoughSignal).value,
                for: .noStrongSignalDetected
            )
        }
    }

    @Test("No fixed label carries a digit, percentage, or probability word")
    func labelsCarryNoMagnitude() {
        // Requirement 8.13: no probability or confidence representation on any
        // user-facing surface. The three approved labels are a qualified vocabulary,
        // so none of them may read as a magnitude.
        let prohibited = [
            "%", "probab", "confidence", "certain", "likelihood", "chance", "score",
        ]
        for text in FixedPixelLabelText.allTexts {
            #expect(text.contains(where: \.isNumber) == false, "\(text) contains a digit")
            for fragment in prohibited {
                #expect(
                    text.lowercased().contains(fragment) == false,
                    "\(text) contains \(fragment)"
                )
            }
        }
    }

    @Test("A resolved pixel presentation carries the exact required string")
    func presentationCarriesExactString() throws {
        let binding = try CopyFixture.pixelOnlyBinding()

        for evidence in PixelEvidence.allCases {
            let presentation = try binding.presentation(forPixel: evidence)
            #expect(
                presentation.fixedLabelText.value
                    == FixedPixelLabelText(label: evidence.labelKey).value
            )
            #expect(FixedPixelLabelText.allTexts.contains(presentation.fixedLabelText.value))
        }
    }
}
