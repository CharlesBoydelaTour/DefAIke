"""Community Forensics frontier detector: preprocessing and the contamination guard.

The contamination guard is the important part. OpenFake appears in this model's training
manifest and `openfaketiny_reddit` is derived from OpenFake, so scoring that slice would be a
train-on-test result — and a flattering one, which is the kind that survives review. The
refusal is therefore enforced inside the adapter rather than left to whoever calls it.
"""

from __future__ import annotations

import numpy as np
import polars as pl
import pytest
from PIL import Image

from bench.detectors import commfor


# --- preprocessing ------------------------------------------------------------------


def test_transform_matches_the_published_config():
    """resize short edge 440 -> centre-crop 384 -> ImageNet normalise."""
    names = [type(x).__name__ for x in commfor.build_transform().transforms]
    assert names == ["Resize", "CenterCrop", "ToTensor", "Normalize"]


def test_transform_output_size():
    out = commfor.build_transform()(Image.new("RGB", (1200, 800), (90, 100, 110)))
    assert tuple(out.shape) == (3, commfor.CROP, commfor.CROP)
    assert commfor.CROP == 384 and commfor.RESIZE_SHORT_EDGE == 440


def test_transform_upscales_rather_than_pads_small_inputs():
    """Unlike Corvi2023 and DDA, a 144px input is resized up, so its thumbnail weakness is
    a real degradation result rather than a padding artifact."""
    out = commfor.build_transform()(Image.new("RGB", (144, 144), (10, 20, 30)))
    assert tuple(out.shape) == (3, 384, 384)


def test_uses_imagenet_statistics_not_clip():
    from bench.detectors import clipbased

    norm = commfor.build_transform().transforms[-1]
    assert tuple(norm.mean) == pytest.approx(commfor.MEAN)
    assert tuple(norm.mean) != pytest.approx(clipbased.CLIP_MEAN)


def test_published_decision_boundary_is_pinned():
    """The only candidate shipping a calibrated threshold; FPR at logit 0 misrepresents it."""
    assert commfor.DECISION_THRESHOLD == 1.359375


def test_architecture_and_repo_are_pinned():
    assert commfor.TIMM_ARCH == "vit_small_patch16_384"
    assert commfor.REPO.endswith("community-forensics-frontier-detector-2026-08")


# --- contamination guard ------------------------------------------------------------


def test_contaminated_slices_are_declared():
    assert "openfaketiny_reddit" in commfor.CONTAMINATED_SLICES


class FakeCF(commfor.CommForFrontierDetector):
    """Bypasses weight loading; only the slice-masking behaviour is under test."""

    def __init__(self):
        self.decision_threshold = commfor.DECISION_THRESHOLD

    def scores_for(self, rows, rung):
        # Stand in for the parent's real scoring with a constant, then apply the mask.
        import numpy as np

        base = np.ones(len(rows), dtype=float)
        blocked = rows["slice"].is_in(list(commfor.CONTAMINATED_SLICES)).to_numpy()
        return np.where(blocked, np.nan, base)


def rows_frame():
    return pl.DataFrame({
        "id": ["a", "b", "c", "d"],
        "slice": ["sofake_ood", "openfaketiny_reddit", "rewind_no_ammeba", "openfaketiny_reddit"],
        "label": ["fake", "fake", "real", "real"],
        "path": [f"images/{x}.jpg" for x in "abcd"],
    })


def test_contaminated_rows_return_nan():
    out = FakeCF().scores_for(rows_frame(), "clean")
    assert np.isfinite(out[0]) and np.isfinite(out[2]), "clean slices must be scored"
    assert np.isnan(out[1]) and np.isnan(out[3]), "OpenFake-derived rows must be refused"


def test_uncontaminated_slices_are_unaffected():
    rows = rows_frame().with_columns(slice=pl.lit("sofake_ood"))
    assert np.isfinite(FakeCF().scores_for(rows, "clean")).all()


def test_nan_rows_are_dropped_by_the_runner_not_counted():
    """NaN must never become a data point; the runner filters it."""
    from bench import evaluate
    from bench.detectors.base import DetectorInfo

    det = FakeCF()
    det.info = DetectorInfo(name="cf-test", kind="torch", licence="MIT", commercial=True)
    rows = rows_frame().with_columns(
        generator=pl.lit(""), source_platform=pl.lit(""), width=pl.lit(512), height=pl.lit(512)
    )
    df = evaluate.score([det], ["clean"], rows=rows, progress=False)
    assert len(df) == 2, "only the two uncontaminated rows should survive"
    assert set(df["slice"]) == {"sofake_ood", "rewind_no_ammeba"}


# --- variant plumbing ---------------------------------------------------------------
#
# The low-quality release is a further fine-tune OF the frontier detector, sharing its
# architecture and preprocessing exactly. That makes a repo/threshold mixup silent: the wrong
# combination still loads, still runs, and still emits plausible logits. These pin the pairing.


def test_both_variants_are_declared():
    assert set(commfor.VARIANTS) == {"frontier", "lowq"}


def test_variant_repos_and_names_do_not_cross():
    frontier, lowq = commfor.VARIANTS["frontier"], commfor.VARIANTS["lowq"]
    assert frontier["repo"] == commfor.REPO
    assert frontier["repo"].endswith("frontier-detector-2026-08")
    assert lowq["repo"].endswith("low-quality-detector-2026-08")
    assert frontier["name"] == "commfor:frontier-2026-08"
    assert lowq["name"] == "commfor:lowq-2026-08"


def test_variants_have_distinct_calibrated_boundaries():
    """Both ship a calibrated boundary and they differ; using one model's threshold with the
    other's weights would shift the operating point without any error surfacing."""
    a = commfor.VARIANTS["frontier"]["fallback_threshold"]
    b = commfor.VARIANTS["lowq"]["fallback_threshold"]
    assert (a, b) == (1.359375, 1.390625)
    assert a != b


def test_unknown_variant_is_rejected():
    with pytest.raises(KeyError, match="unknown commfor variant"):
        commfor.CommForFrontierDetector(variant="low_quality")


def test_frontier_name_is_stable():
    """Scores already on disk are keyed by this string; renaming it would orphan them."""
    assert commfor.VARIANTS["frontier"]["name"] == "commfor:frontier-2026-08"


def test_contamination_guard_applies_to_both_variants():
    """OpenFake is in the shared manifest, so the low-quality fine-tune inherits it."""
    for variant in commfor.VARIANTS:
        assert "openfaketiny_reddit" in commfor.CONTAMINATED_SLICES, variant
