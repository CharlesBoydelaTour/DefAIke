#!/usr/bin/env python3
"""Adds proposed Approved Verdict Copy to the shipped String Catalog and the four
Localization Readiness catalogs.

Every value this writes is PROPOSED WORDING, NOT APPROVED (decision D1), recorded in each
entry's `comment` exactly as the existing chrome copy already is. Approving the wording is a
content decision outside this repository; this script only stops the surfaces rendering
nothing so the design can be reviewed.

Two rules it follows without exception:

  1. **No existing entry is modified.** The nine keys already present in each catalog are
     written back byte-identical. The readiness catalogs were hand-authored and are
     internally inconsistent (`LongWord` lowercases `AI` in one entry and preserves case in
     the rest, and uses `unbreakabletoken` there against `unbreakablesinglewordtoken`
     elsewhere; `Pseudolocalized` maps `h`, `w`, and `I` two different ways). Rather than
     normalise them - which would silently change a release gate's inputs - this leaves them
     alone and applies one stated rule to the new keys only.

  2. **The readiness transformations are derived, not invented, and their limits are stated.**
     Measured against the nine existing entries:

       | Variant           | Reproduced | Why not all nine |
       |-------------------|------------|------------------|
       | `Expansion`       | 9/9        | rule is the catalog's own |
       | `Bidirectional`   | 9/9        | rule is the catalog's own |
       | `LongWord`        | 8/9        | one entry lowercases `AI` and uses a shorter token |
       | `Pseudolocalized` | 3/9        | `h`, `w`, and `I` are accented in some entries and left bare in others, so no single character map can reproduce the set |

     `Pseudolocalized` is therefore the one variant whose new entries follow a rule the
     existing entries do not all follow. The map used is the dominant one, derived from those
     entries and resolving each inconsistency toward the accented form, because an unaccented
     letter exercises nothing. That is a deliberate, stated choice rather than a silent one,
     and it changes no existing value.

Idempotent: running it twice produces the same files.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "DefAIkePackage"
SHIPPED = ROOT / "Sources/DefAIkePresentation/ApprovedCopy/Localizable.xcstrings"
READINESS = ROOT / "Tests/DefAIkePresentationTests/Resources/LocalizationReadiness"

D1 = "PROPOSED WORDING, NOT APPROVED (decision D1)."

# --------------------------------------------------------------------------------------
# The authored English, one entry per VerdictCopySurface the compositions can reach.
#
# Constraints every sentence below is written against:
#   * Requirement 8.4 - never proof of authenticity, authorship, intent, editing history,
#     or the absence of localized editing.
#   * Requirement 8.9 - no claim of certainty.
#   * Requirement 8.13 - no probability, confidence, percentage, score, or level.
#   * Requirement 11.17 - an Analysis Error describes the application's own work failing and
#     is never a statement about the image.
#   * SessionRecovery has one case, so every recovery means "choose an image", never resume,
#     retry this session, or recompute.
# --------------------------------------------------------------------------------------

ENTRIES = {}


def entry(key, value, comment):
    ENTRIES[key] = (value, f"{D1} {comment}")


# The qualified explanation beside each of the three fixed labels (Requirements 8.3-8.5).
entry(
    "copy.pixel-explanation.signals-consistent-with-ai-generation",
    "This image contains patterns that often appear in images generated entirely by AI. "
    "That is not proof of how it was made. This app cannot tell you who made it, what it "
    "was made for, or whether any part of it was edited.",
    "Explanation for the Positive Pixel Label. States consistency, never a conclusion "
    "(Requirement 8.3), and explicitly disclaims authorship, intent, and editing history "
    "(Requirement 8.9). Do not add a probability, a confidence level, or a likelihood word "
    "such as 'probably' or 'likely'.",
)
entry(
    "copy.pixel-explanation.no-strong-signal-detected",
    "This app did not find the patterns it looks for. That is not a finding that the image "
    "is real or unedited. Resaving, cropping, or screenshotting an image can remove those "
    "patterns, so an AI-generated image can also look like this.",
    "Explanation for the Non Positive Pixel Label. Requirement 8.4 forbids presenting this "
    "as authenticity, so the sentence states what was not found and then names why absence "
    "is uninformative. Do not reword this as 'no AI detected' or 'appears authentic'.",
)
entry(
    "copy.pixel-explanation.not-enough-signal",
    "There was not enough usable signal in this image to report either way. Heavy "
    "compression, a small image, or a screenshot can all cause this.",
    "Explanation for the Insufficient Evidence Outcome (Requirement 8.8). An abstention, not "
    "a middle result: it must not read as a weak positive or a weak negative, and must carry "
    "no scale between the other two labels.",
)

# The provenance lane.
entry(
    "copy.provenance-unavailable",
    "This version cannot check Content Credentials. A separate version of DefAIke does, as a second "
    "and independent check.",
    "The unavailable source-lane state (Requirement 6.9). States a capability this build does not "
    "have, never a property of the image, and names the pixel-plus-provenance composition so the "
    "absence reads as a build boundary rather than as a finding. Do not phrase this as 'no credential "
    "found', which is a different lane state with its own copy. "
    "Deliberately names no URL, App Store link, or install action: the distribution identity of the "
    "second composition is an owed release-controlled input, and a tappable link to a build that has "
    "no distribution channel yet would be a promise this application cannot keep.",
)
entry(
    "copy.provenance-state.validated",
    "This image carries a Content Credential that matches the exact bytes analysed. That "
    "confirms the credential belongs to these bytes. It does not confirm that what the "
    "credential says about the image is true.",
    "Requirement 8.6: cryptographic validation establishes binding, not the factual truth of "
    "any signed assertion. The second sentence is the whole point of the entry and must not "
    "be dropped or softened.",
)
entry(
    "copy.provenance-state.invalid",
    "This image carries a Content Credential that does not match the bytes analysed. The "
    "image may have been changed after it was signed, or the credential may have been "
    "altered.",
    "States the mismatch and offers both readings without choosing one. Do not attribute the "
    "mismatch to tampering as a conclusion, which would be a claim about intent "
    "(Requirement 8.9).",
)
entry(
    "copy.provenance-state.absent",
    "This image carries no Content Credential. Most images do not, so this says nothing "
    "about how the image was made.",
    "Requirement 8.7: an absent Content Credential is explicitly not an authenticity result. "
    "The second sentence prevents absence being read as suspicion.",
)
entry(
    "copy.provenance-state.unsupported",
    "This image carries credential data that this app cannot read.",
    "A limit of the validator, not a finding about the image. Distinct from absent and from "
    "invalid, both of which have their own copy.",
)
entry(
    "copy.provenance-state.indeterminate",
    "This app could not finish checking this image's Content Credential, so there is no "
    "result from that source.",
    "An inconclusive validator run (Requirement 6.21). Must be distinguishable from the "
    "unavailable lane, which is a build that cannot check at all.",
)
entry(
    "copy.screenshot-provenance-explanation",
    "Taking a screenshot creates a new image and usually removes any Content Credential the "
    "original had. A missing credential on a screenshot tells you nothing about the original "
    "image.",
    "Requirement 6.x screenshot explanation. Shown beside the provenance lane so an absent "
    "credential on a screenshot is not read as a finding.",
)

# The two lanes disagreeing.
entry(
    "copy.apparent-inconsistency",
    "The two checks above point in different directions. Both are shown exactly as they were "
    "found. This app does not decide between them.",
    "The apparent-inconsistency notice. Requirements 7.1 and 7.8 keep the lanes independent, "
    "so this names the disagreement and must not resolve it, rank the lanes, or suggest which "
    "to believe.",
)

# Limitations shown on every completed report.
entry(
    "copy.evidence-scope",
    "This app looks for signs that an entire image was generated. It does not detect edited "
    "regions, composites, face swaps, retouching, video, or audio, and it does not identify "
    "which tool was used.",
    "Requirement 8.10 evidence scope and unsupported scope. Localized editing is outside the "
    "scope entirely, which is why it is listed rather than qualified.",
)
entry(
    "copy.false-result-limitation",
    "Both kinds of mistake happen. A real photograph can be reported as showing AI signals, "
    "and an AI-generated image can be reported as showing none. Do not rely on this result on "
    "its own.",
    "Requirement 8.11 false-positive and false-negative statement. States both directions "
    "symmetrically so neither label is presented as the more trustworthy one, and carries no "
    "rate, frequency, or percentage.",
)
entry(
    "copy.byte-preservation-limitation.original-bytes",
    "The exact file you chose was analysed, with no changes.",
    "Requirement 2.9 byte-preservation limitation for the strongest recorded status. It "
    "states what was analysed and claims nothing further about the result.",
)
entry(
    "copy.byte-preservation-limitation.platform-transformed-copy",
    "iOS supplied a converted copy rather than the original file. Converting an image can "
    "remove the patterns this app looks for, so treat this result with extra caution.",
    "Requirement 2.10. Names the platform as the cause so the user does not read it as their "
    "own mistake, and states the consequence for the result.",
)
entry(
    "copy.byte-preservation-limitation.unknown",
    "This app could not confirm whether it received the original file or a converted copy. If "
    "it was converted, some patterns may have been lost.",
    "Requirement 2.11. The status must never be upgraded toward original bytes without "
    "evidence, so this states the uncertainty rather than assuming either case.",
)

# Onward disclosure paths.
# These three are load-bearing in two places at once, which constrains their length. The report
# renders each as a *navigation row label* (`report.disclosurePaths.reference(for:)`), and the
# destination screen renders the same reference as its own body copy
# (`DisclosureScreens.copy(for:)`). One surface, two uses, and the vocabulary defines no second
# key for either - so a five-line paragraph becomes a five-line tappable row, which is what the
# first draft of these did and what a simulator screenshot immediately showed to be wrong.
#
# One clear sentence is the length that serves both. Only the row is reachable today: navigating
# to a disclosure screen needs a Release Readiness Record no installed artifact supplies, so
# `openDisclosurePath` is wired to nothing.
entry(
    "copy.privacy-explanation",
    "Your image is analysed on this device. It is never uploaded, saved, or shared.",
    "The in-application privacy explanation, and the label of the row that opens it. Both "
    "clauses are behaviours the application enforces: on-device inference, no network use for "
    "analysis, no persistence, and no export. Kept to one sentence because the report renders "
    "this as a single tappable row.",
)
entry(
    "copy.model-information",
    "One model runs on your device. It is not perfect, and it is never updated over the network.",
    "Model identity, limitations, and release status, and the label of the row that opens it. "
    "Names no version number, no metric, and no score, because Requirement 8.13 keeps "
    "measurement off every user-facing surface; the bound version is a technical-details row "
    "instead.",
)
entry(
    "copy.correction-channel",
    "You can report a result that looks wrong. Your image is never included in a report.",
    "The externally supplied correction channel, and the label of the row that opens it. "
    "Deliberately promises no response, correction, or timescale, and states the privacy "
    "boundary because a report is the one place a user might expect their image to travel.",
)

# --------------------------------------------------------------------------------------
# The ten Analysis Error categories, and the recovery each offers.
#
# Requirement 11.17: an error is never one of the three labels and never a statement about
# the image's content. Requirement 4.17: one category, one recovery, no evidence verdict.
# --------------------------------------------------------------------------------------

ERRORS = {
    "unsupported-media": (
        "That file is not a still image, so there was nothing for this app to analyse.",
        "Choose a still image to start again.",
        "the selected item is not a still image at all - a video, a live photo, or a document",
    ),
    "unsupported-static-format": (
        "That image format is not supported. This app analyses JPEG, PNG, and HEIC images.",
        "Choose a JPEG, PNG, or HEIC image to start again.",
        "a still image in a container the app does not accept",
    ),
    "decoding-error": (
        "That image could not be read. The file may be incomplete or damaged.",
        "Choose another image to start again.",
        "a supported container whose bytes will not decode",
    ),
    "resource-limit": (
        "Analysis stopped because it needed more memory or time than this app is allowed to "
        "use on this device.",
        "Close other apps to free up memory, then choose an image to start again.",
        "a Resource Budget breach, which returns no evidence at all",
    ),
    "preprocessing-error": (
        "The image could not be prepared for analysis, so no result was produced.",
        "Choose another image to start again.",
        "a failure resizing, cropping, or colour-converting the decoded image",
    ),
    "model-load-error": (
        "The on-device model could not be loaded, so no analysis ran.",
        "Choose an image to start again.",
        "the Model Bundle failing to verify, load, or activate",
    ),
    "inference-error": (
        "The analysis did not finish running on this device, so no result was produced.",
        "Choose an image to start again.",
        "the model failing during execution",
    ),
    "invalid-output-error": (
        "The model returned something this app could not use, so no result is being shown.",
        "Choose an image to start again.",
        "model output that fails validation before calibration",
    ),
    "calibration-input-error": (
        "The result could not be turned into one of this app's three labels, so no result is "
        "being shown.",
        "Choose an image to start again.",
        "calibration refusing its input, which must never fall back to a label",
    ),
    "handoff-error": (
        "The image shared from the other app did not arrive intact, so it was not analysed.",
        "Share the image again, or choose it from your photos to start again.",
        "a Share Extension handoff that could not be claimed or verified",
    ),
}

for name, (message, recovery, cause) in ERRORS.items():
    entry(
        f"copy.analysis-error.{name}",
        message,
        f"Analysis Error message for the {name} category, raised by {cause}. "
        "Requirement 11.17 keeps this distinguishable from every pixel label, provenance "
        "state, and the cancelled terminal, and it must never describe the image's content.",
    )
    entry(
        f"copy.error-recovery.{name}",
        recovery,
        f"Recovery offered for the {name} category. SessionRecovery has one case, so this "
        "names choosing an image and nothing else - never resume, retry this session, or "
        "recompute, none of which is representable (Requirement 3.15).",
    )


# --------------------------------------------------------------------------------------
# Application chrome added by the second design pass.
#
# Chrome rather than verdict copy: each of these names something the *application* does - reveal a
# group, open a screen, dismiss it - and none of them states an outcome or changes meaning when the
# Model Bundle changes. `ChromeCopyCoverage` refuses a build whose catalog omits any of them, so a
# missing value here is a launch refusal rather than a control with no name.
# --------------------------------------------------------------------------------------

entry(
    "copy.chrome.limitations-disclosure-action",
    "What this cannot tell you",
    "Label for ChromeCopySurface.limitationsDisclosureAction, the control that reveals the three "
    "limitation statements. Phrased as what the user gains by opening it rather than as a category "
    "name, because a heading reading 'Limitations' invites being skipped. Names no outcome, so it is "
    "chrome and not verdict copy.",
)
entry(
    "copy.chrome.disclosure-expanded-state",
    "Showing",
    "Value for ChromeCopySurface.disclosureExpandedState. Requirement 12.7 forbids a state carried "
    "only by a glyph, and SwiftUI's AccessibilityTraits has no expanded member, so the state is a "
    "word. One word, because it is spoken after the control's own label.",
)
entry(
    "copy.chrome.disclosure-collapsed-state",
    "Hidden",
    "Value for ChromeCopySurface.disclosureCollapsedState. The counterpart to the expanded state; see "
    "that entry.",
)
entry(
    "copy.chrome.information-action",
    "Information",
    "Label for ChromeCopySurface.informationAction, the control that opens the information screen. "
    "Deliberately not 'About': the screen carries the limitations and the privacy statement, which "
    "are not an about-box.",
)
entry(
    "copy.chrome.information-title",
    "Information",
    "Title for ChromeCopySurface.informationTitle. Matches the control that opens it, so the "
    "destination is recognisable as the thing that was tapped.",
)
entry(
    "copy.chrome.information-dismiss-action",
    "Done",
    "Label for ChromeCopySurface.informationDismissAction. The platform's own word for closing a "
    "sheet that changed nothing, so it does not imply saving or accepting anything.",
)
entry(
    "copy.chrome.information-limitations-heading",
    "What this cannot tell you",
    "Heading for ChromeCopySurface.informationLimitationsHeading, introducing the limitation "
    "statements on the information screen. Deliberately the same words as the disclosure control on "
    "the report, so the two routes to the same content are recognisably the same content.",
)
entry(
    "copy.chrome.information-about-heading",
    "How this app works",
    "Heading for ChromeCopySurface.informationAboutHeading, introducing the privacy, model, and "
    "correction statements. Groups them as behaviour rather than as credentials, because that is what "
    "they describe.",
)

# --------------------------------------------------------------------------------------
# The readiness transformations.
# --------------------------------------------------------------------------------------


def expansion(text):
    """Doubles the string inside brackets. Reproduces all nine existing entries exactly."""
    return f"⟦{text} · {text}⟧"


def bidirectional(text):
    """Wraps in RTL isolates with an Arabic marker. Reproduces all nine exactly."""
    return f"⁧[عربي] {text}⁩"


TOKEN = "unbreakablesinglewordtoken"

# `LocalizationReadinessCatalogTests.longWordCarriesAnUnbreakableToken` requires the longest
# whitespace-delimited run in every long-word value to be at least this many characters. The point of
# the variant is that "a layout that only fits because English words are short fails here rather than
# in front of a user", so the floor is the whole test.
LONG_WORD_FLOOR = 40


def long_word(text):
    """Strips every non-alphanumeric character, repeats until it clears the floor, appends the token.

    The dominant rule, reproducing eight of the nine existing entries. The ninth
    (`pixel-label.signals-consistent-with-ai-generation`) lowercases `AI` and uses a shorter token;
    it is left untouched rather than normalised.

    The repeat is a `while` rather than a single doubling, and the difference is not cosmetic: a
    single doubling was enough for every string that already existed, because the shortest was
    thirteen characters, but "Done" doubles to eight and lands at thirty-four - under the floor. The
    loop keeps the rule honest for a short label instead of quietly producing a value the readiness
    suite would refuse.
    """
    joined = "".join(character for character in text if character.isalnum())
    if not joined:
        return TOKEN
    stem = joined
    while len(stem) + len(TOKEN) < LONG_WORD_FLOOR:
        stem += joined
    return stem + TOKEN


# The dominant map, derived programmatically from the existing entries rather than transcribed
# by hand - the first attempt at writing it out mistyped one glyph and reproduced nothing.
# Where the hand-authored catalog accented a letter in one entry and left it bare in another,
# the accented form is taken: it is the stronger test, because an unaccented letter exercises
# nothing.
PSEUDO_MAP = str.maketrans(
    "ACDGINSYacdeghilnorstuwyz",
    "ÀÇĎĢĪŅŞÝàçďēģĥīľņōŗşţūŵýž",
)


def pseudolocalized(text):
    """Accents the Latin letters and brackets the result."""
    return "[" + text.translate(PSEUDO_MAP) + "]"


VARIANTS = {
    "Expansion": ("en-x-expand", expansion),
    "LongWord": ("en-x-longword", long_word),
    "Bidirectional": ("ar-x-bidi", bidirectional),
    "Pseudolocalized": ("en-x-pseudo", pseudolocalized),
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def main():
    if not SHIPPED.exists():
        sys.exit(f"error: {SHIPPED} not found")

    shipped = json.loads(SHIPPED.read_text())
    english = {
        key: value["localizations"]["en"]["stringUnit"]["value"]
        for key, value in shipped["strings"].items()
    }
    preexisting = set(english)

    added = 0
    for key, (value, comment) in sorted(ENTRIES.items()):
        if key in preexisting:
            continue
        shipped["strings"][key] = {
            "comment": comment,
            "extractionState": "manual",
            "localizations": {"en": unit(value)},
        }
        english[key] = value
        added += 1

    shipped["strings"] = dict(sorted(shipped["strings"].items()))
    SHIPPED.write_text(json.dumps(shipped, ensure_ascii=False, indent=2) + "\n")
    print(f"shipped catalog: +{added} entries, {len(shipped['strings'])} total")

    for name, (language, transform) in VARIANTS.items():
        path = READINESS / f"{name}.xcstrings"
        catalog = json.loads(path.read_text())
        existing = set(catalog["strings"])
        new = 0
        for key in sorted(english):
            if key in existing:
                continue  # never rewrite a hand-authored entry
            catalog["strings"][key] = {
                "extractionState": "manual",
                "localizations": {language: unit(transform(english[key]))},
            }
            new += 1
        catalog["strings"] = dict(sorted(catalog["strings"].items()))
        path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
        print(f"{name}: +{new} entries, {len(catalog['strings'])} total")


if __name__ == "__main__":
    main()
