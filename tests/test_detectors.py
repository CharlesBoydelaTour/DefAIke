"""Detector interface and the reference-logit adapter.

The behaviour most worth pinning is refusal. The reference detectors must return NaN for
rungs they cannot speak to, rather than a plausible number, because their published logits
were computed on ReWIND's images as distributed and there is no honest way to extend them to
our synthetic degradations.
"""

from __future__ import annotations

import numpy as np
import polars as pl
import pytest
from PIL import Image

from bench.detectors import base, reference


# --- DetectorInfo -------------------------------------------------------------------


def test_info_carries_what_the_decision_table_needs():
    """PLAN.md Task 3: params, licence, input resolution."""
    info = base.DetectorInfo(
        name="d", kind="torch", licence="MIT", commercial=True,
        params=28_000_000, input_resolution=(224, 224),
    )
    row = info.as_row()
    assert row["params"] == 28_000_000
    assert row["input_resolution"] == "224x224"
    assert row["licence"] == "MIT"
    assert row["commercial"] is True


def test_info_handles_absent_resolution():
    info = base.DetectorInfo(name="d", kind="reference", licence="X", commercial=False)
    assert info.as_row()["input_resolution"] is None
    assert info.scored_by_us is True


# --- reference detectors ------------------------------------------------------------


def test_all_six_reference_detectors_construct():
    dets = reference.all_detectors()
    assert len(dets) == 6
    assert {d.detector for d in dets} == {"B-Free", "DRCT", "DMID", "CoDE", "D3", "CO-SPY"}


def test_unknown_reference_detector_rejected():
    with pytest.raises(KeyError, match="unknown reference detector"):
        reference.ReferenceDetector("NotAThing")


def test_reference_is_marked_as_not_our_measurement():
    """Guards against a reference row being presented as our own benchmark result."""
    d = reference.ReferenceDetector("B-Free")
    assert d.info.scored_by_us is False
    assert d.info.kind == "reference"
    assert d.info.commercial is False


def test_unidentified_detectors_say_so():
    d = reference.ReferenceDetector("CO-SPY")
    assert "identity unconfirmed" in d.info.notes


def test_identified_detectors_do_not_claim_uncertainty():
    d = reference.ReferenceDetector("DRCT")
    assert "identity unconfirmed" not in d.info.notes


def test_home_turf_confound_is_recorded_for_bfree():
    """B-Free's own collection is 3,112 of ReWIND's 5,582 rows."""
    d = reference.ReferenceDetector("B-Free")
    assert d.home_turf == "viral_bfree"
    assert "OWN DATA" in d.info.notes


def test_other_detectors_have_no_home_turf():
    assert reference.ReferenceDetector("CoDE").home_turf is None


def test_supports_only_the_clean_rung():
    d = reference.ReferenceDetector("B-Free")
    assert d.supports_rung("clean")
    for rung in ("light", "moderate", "heavy", "severe", "screenshot", "screenshot_shared"):
        assert not d.supports_rung(rung), f"must not claim to support {rung}"


def rows_frame():
    return pl.DataFrame({
        "id": ["a", "b", "c"],
        "path": ["x/a.jpg", "x/b.jpg", "x/c.jpg"],
        "label": ["real", "fake", "real"],
        "ref_B-Free": [-1.5, 2.5, None],
    })


def test_scores_for_returns_published_values_on_clean():
    out = reference.ReferenceDetector("B-Free").scores_for(rows_frame(), "clean")
    assert out[0] == pytest.approx(-1.5)
    assert out[1] == pytest.approx(2.5)
    assert np.isnan(out[2]), "a null published logit must become NaN, not zero"


def test_scores_for_returns_all_nan_on_unsupported_rung():
    """The important refusal: no fabricated numbers for synthetic rungs."""
    out = reference.ReferenceDetector("B-Free").scores_for(rows_frame(), "heavy")
    assert len(out) == 3
    assert np.isnan(out).all()


def test_scores_for_returns_nan_when_column_absent():
    df = pl.DataFrame({"id": ["a"], "label": ["real"]})
    out = reference.ReferenceDetector("DRCT").scores_for(df, "clean")
    assert np.isnan(out).all()


def test_scores_are_aligned_by_position():
    out = reference.ReferenceDetector("B-Free").scores_for(rows_frame(), "clean")
    assert len(out) == 3


def test_available_lists_only_populated_columns():
    df = pl.DataFrame({
        "ref_B-Free": [1.0, 2.0],
        "ref_DRCT": [None, None],
        "ref_CoDE": [0.5, -0.5],
    }, strict=False)
    assert reference.available(df) == ["B-Free", "CoDE"]


def test_available_on_frame_with_no_reference_columns():
    assert reference.available(pl.DataFrame({"id": [1]})) == []


def test_reference_satisfies_the_score_provider_protocol():
    assert isinstance(reference.ReferenceDetector("D3"), base.ScoreProvider)


# --- BaseModelDetector --------------------------------------------------------------


class Constant(base.BaseModelDetector):
    """Minimal pixel detector: returns a logit derived from mean brightness."""

    def __init__(self) -> None:
        self.info = base.DetectorInfo(
            name="constant", kind="torch", licence="MIT", commercial=True,
            params=1, input_resolution=(8, 8),
        )
        self.seen = 0

    def score_batch(self, images):
        self.seen += len(images)
        return [float(np.asarray(im.convert("L"), dtype=float).mean() / 255.0 - 0.5)
                for im in images]


def test_model_detector_score_delegates_to_batch():
    d = Constant()
    img = Image.new("RGB", (16, 16), (255, 255, 255))
    assert d.score(img) == pytest.approx(0.5)
    assert d.seen == 1


def test_model_detector_supports_every_rung():
    """Unlike reference lookups, a real model can score any degradation."""
    d = Constant()
    assert all(d.supports_rung(r) for r in
               ("clean", "light", "moderate", "heavy", "severe", "screenshot"))


def test_model_detector_scores_for_reads_degrades_and_scores(tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    d = tmp_path / "data" / "images"
    d.mkdir(parents=True)
    for name, colour in [("a.jpg", (255, 255, 255)), ("b.jpg", (0, 0, 0))]:
        Image.new("RGB", (400, 400), colour).save(d / name)

    rows = pl.DataFrame({
        "id": ["a", "b"],
        "path": ["images/a.jpg", "images/b.jpg"],
        "label": ["fake", "real"],
    })
    out = Constant().scores_for(rows, "moderate")
    assert len(out) == 2
    assert np.isfinite(out).all()
    assert out[0] > out[1], "white image should score above black under this stub"


def test_model_detector_leaves_nan_for_unreadable_files(tmp_path, monkeypatch):
    """A corrupt image must not abort a multi-hour scoring run."""
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    d = tmp_path / "data" / "images"
    d.mkdir(parents=True)
    Image.new("RGB", (300, 300), (128, 128, 128)).save(d / "ok.jpg")
    (d / "bad.jpg").write_bytes(b"not an image")

    rows = pl.DataFrame({
        "id": ["ok", "bad"],
        "path": ["images/ok.jpg", "images/bad.jpg"],
        "label": ["real", "fake"],
    })
    out = Constant().scores_for(rows, "clean")
    assert np.isfinite(out[0])
    assert np.isnan(out[1])
