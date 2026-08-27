"""Evaluation runner: scoring, coverage, and the guards around empty slices.

Two behaviours matter most. Rows a provider had no opinion about must be dropped rather than
counted, or a metrics table gets built from fabricated zeros. And empty slices must return
empty frames rather than raising — which is not hypothetical, since the reference detectors
cover only ReWIND and ReWIND carries no generator attribution.
"""

from __future__ import annotations

import numpy as np
import polars as pl
import pytest

from bench import degrade, evaluate, metrics
from bench.detectors import base


class Stub:
    """Score provider with controllable coverage and separability."""

    def __init__(self, name="stub", rungs=None, sep=3.0, seed=0):
        self.info = base.DetectorInfo(
            name=name, kind="torch", licence="MIT", commercial=True, params=10
        )
        self._rungs = rungs
        self._sep = sep
        self._seed = seed

    def supports_rung(self, rung):
        return True if self._rungs is None else rung in self._rungs

    def scores_for(self, rows, rung):
        rng = np.random.default_rng(self._seed)
        y = (rows["label"] == "fake").to_numpy()
        return np.where(y, rng.normal(self._sep / 2, 1, len(rows)),
                        rng.normal(-self._sep / 2, 1, len(rows)))


class Silent(Stub):
    """Returns NaN for everything: the provider that has no opinion."""

    def scores_for(self, rows, rung):
        return np.full(len(rows), np.nan)


def corpus(n=200):
    rng = np.random.default_rng(1)
    return pl.DataFrame({
        "id": [f"i{i}" for i in range(n)],
        "slice": ["sofake_ood"] * n,
        "label": ["fake" if i % 2 else "real" for i in range(n)],
        "generator": ["gpt-image-2" if i % 2 else "" for i in range(n)],
        "source_platform": ["Reddit" if i % 2 == 0 else "" for i in range(n)],
        "width": rng.choice([1024, 1280, 1536], n),
        "height": rng.choice([1024, 720, 1536], n),
        "path": [f"images/i{i}.jpg" for i in range(n)],
    })


# --- score() ------------------------------------------------------------------------


def test_score_produces_one_row_per_image_per_rung():
    df = evaluate.score([Stub()], ["clean", "heavy"], rows=corpus(50), progress=False)
    assert len(df) == 100
    assert set(df["rung"].unique()) == {"clean", "heavy"}


def test_score_records_provenance_columns():
    df = evaluate.score([Stub()], ["clean"], rows=corpus(20), progress=False)
    assert df["detector"].unique().to_list() == ["stub"]
    assert df["detector_kind"].unique().to_list() == ["torch"]
    assert df["scored_by_us"].unique().to_list() == [True]


def test_score_skips_unsupported_rungs():
    df = evaluate.score([Stub(rungs={"clean"})], ["clean", "heavy"], rows=corpus(20),
                        progress=False)
    assert df["rung"].unique().to_list() == ["clean"]


def test_score_drops_rows_the_provider_had_no_opinion_on():
    """NaN must not become a data point; that would fabricate results."""
    df = evaluate.score([Silent()], ["clean"], rows=corpus(20), progress=False)
    assert df.is_empty()


def test_score_with_no_providers_is_empty_not_an_error():
    assert evaluate.score([], ["clean"], rows=corpus(10), progress=False).is_empty()


def test_score_defaults_to_every_rung():
    df = evaluate.score([Stub()], None, rows=corpus(10), progress=False)
    assert set(df["rung"].unique()) == set(degrade.ALL_RUNGS)


def test_score_combines_multiple_providers():
    df = evaluate.score([Stub("a"), Stub("b")], ["clean"], rows=corpus(20), progress=False)
    assert set(df["detector"].unique()) == {"a", "b"}
    assert len(df) == 40


# --- headline() ---------------------------------------------------------------------


def test_headline_one_row_per_detector_rung():
    df = evaluate.score([Stub("a"), Stub("b")], ["clean", "heavy"], rows=corpus(400),
                        progress=False)
    out = evaluate.headline(df, n_boot=20)
    assert len(out) == 4
    assert {"detector", "rung", "auc", "tpr_at_1pct_fpr", "resolution_shortcut"} <= set(out.columns)


def test_headline_flags_resolution_preserving_rungs():
    """A reader must not mistake a clean-rung score for one free of the resolution tell."""
    df = evaluate.score([Stub()], ["clean", "light", "heavy"], rows=corpus(400),
                        progress=False)
    out = evaluate.headline(df, n_boot=20)
    flags = dict(zip(out["rung"], out["resolution_shortcut"]))
    assert flags["clean"] is True
    assert flags["light"] is True
    assert flags["heavy"] is False


def test_headline_on_empty_scores_is_empty():
    assert evaluate.headline(pl.DataFrame(), n_boot=10).is_empty()


# --- slices -------------------------------------------------------------------------


def test_by_generator_evaluates_each_generator_against_the_whole_real_pool():
    df = evaluate.score([Stub()], ["clean"], rows=corpus(400), progress=False)
    out = evaluate.by_generator(df, n_boot=20)
    assert len(out) == 1
    assert out["generator"][0] == "gpt-image-2"
    assert out["n_real"][0] == 200


def test_by_generator_empty_when_no_attribution_available():
    """Regression: this crashed on `.sort()` over a frame with no schema."""
    rows = corpus(40).with_columns(generator=pl.lit(""))
    df = evaluate.score([Stub()], ["clean"], rows=rows, progress=False)
    out = evaluate.by_generator(df, n_boot=10)
    assert out.is_empty()


def test_by_generator_empty_for_a_rung_with_no_scores():
    df = evaluate.score([Stub()], ["clean"], rows=corpus(40), progress=False)
    assert evaluate.by_generator(df, rung="severe", n_boot=10).is_empty()


def test_by_source_slices_by_collection():
    df = evaluate.score([Stub()], ["clean"], rows=corpus(400), progress=False)
    out = evaluate.by_source(df, n_boot=20)
    assert len(out) >= 1
    assert "Reddit" in out["source_platform"].to_list()


def test_by_source_empty_when_no_platform_recorded():
    rows = corpus(40).with_columns(source_platform=pl.lit(""))
    df = evaluate.score([Stub()], ["clean"], rows=rows, progress=False)
    assert evaluate.by_source(df, n_boot=10).is_empty()


# --- resolution baseline ------------------------------------------------------------


def test_resolution_baseline_detects_the_shortcut():
    """Fakes at exactly 1024x1024, reals elsewhere: resolution alone should separate."""
    n = 200
    rows = pl.DataFrame({
        "label": ["fake"] * n + ["real"] * n,
        "width": [1024] * n + [1280] * n,
        "height": [1024] * n + [853] * n,
    })
    base_ = evaluate.resolution_baseline(rows)
    assert base_["accuracy"] == pytest.approx(1.0)
    assert base_["tpr"] == pytest.approx(1.0)
    assert base_["fpr"] == pytest.approx(0.0)


def test_resolution_baseline_is_chance_when_sizes_carry_no_signal():
    n = 100
    rows = pl.DataFrame({
        "label": ["fake", "real"] * n,
        "width": [1280] * 2 * n,
        "height": [853] * 2 * n,
    })
    base_ = evaluate.resolution_baseline(rows)
    assert base_["tpr"] == pytest.approx(0.0)
    assert base_["balanced_accuracy"] == pytest.approx(0.5)


# --- persistence --------------------------------------------------------------------


def test_scores_roundtrip(tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    df = evaluate.score([Stub()], ["clean"], rows=corpus(30), progress=False)
    evaluate.write_scores(df)
    back = evaluate.read_scores()
    assert len(back) == len(df)
    assert back["detector"].unique().to_list() == ["stub"]


def test_read_scores_without_a_run_is_actionable(tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    with pytest.raises(FileNotFoundError, match="run `bench eval`"):
        evaluate.read_scores()


# --- the guard the plan explicitly asks for -----------------------------------------


def test_inverted_labels_produce_sub_chance_auc_end_to_end():
    """PLAN.md Task 3: a silent label flip must be caught, not averaged away."""
    rows = corpus(400)
    flipped = rows.with_columns(
        label=pl.when(pl.col("label") == "fake").then(pl.lit("real")).otherwise(pl.lit("fake"))
    )
    df = evaluate.score([Stub()], ["clean"], rows=rows, progress=False)
    bad = df.join(flipped.select("id", flipped_label=pl.col("label")), on="id").with_columns(
        label=pl.col("flipped_label")
    )
    out = evaluate.headline(bad, n_boot=20)
    assert out["auc"][0] < 0.5
    assert "below chance" in out["warnings"][0]


# --- score-table merging ------------------------------------------------------------
# Regression tests for a real loss: `bench eval --rung thumbnail` overwrote a completed
# seven-rung matrix, discarding roughly 40 minutes of scoring. Scoring is the expensive
# step, so adding a rung must extend the table rather than replace it.


def test_write_scores_merges_a_new_rung_into_an_existing_table(tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    first = evaluate.score([Stub()], ["clean"], rows=corpus(20), progress=False)
    evaluate.write_scores(first)
    second = evaluate.score([Stub()], ["heavy"], rows=corpus(20), progress=False)
    evaluate.write_scores(second)

    back = evaluate.read_scores()
    assert set(back["rung"].unique()) == {"clean", "heavy"}
    assert len(back) == len(first) + len(second)


def test_write_scores_replaces_a_rescored_rung_rather_than_duplicating(tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    evaluate.write_scores(evaluate.score([Stub()], ["clean"], rows=corpus(20), progress=False))
    again = evaluate.score([Stub(sep=0.1, seed=9)], ["clean"], rows=corpus(20), progress=False)
    evaluate.write_scores(again)

    back = evaluate.read_scores()
    assert len(back) == 20, "re-scoring a rung must overwrite, not append"
    assert back["score"].to_list() == pytest.approx(again["score"].to_list())


def test_write_scores_keeps_other_detectors_when_one_is_rescored(tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    evaluate.write_scores(
        evaluate.score([Stub("a"), Stub("b")], ["clean"], rows=corpus(20), progress=False)
    )
    evaluate.write_scores(evaluate.score([Stub("a")], ["clean"], rows=corpus(20), progress=False))

    back = evaluate.read_scores()
    assert set(back["detector"].unique()) == {"a", "b"}


def test_write_scores_can_still_overwrite_explicitly(tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    evaluate.write_scores(evaluate.score([Stub()], ["clean"], rows=corpus(20), progress=False))
    evaluate.write_scores(
        evaluate.score([Stub()], ["heavy"], rows=corpus(20), progress=False), merge=False
    )
    assert evaluate.read_scores()["rung"].unique().to_list() == ["heavy"]


# --- common subset ------------------------------------------------------------------


def test_common_subset_restricts_to_rows_every_detector_scored():
    """The guard against comparing detectors evaluated on different data."""
    rows = corpus(40)
    full = evaluate.score([Stub("wide")], ["clean"], rows=rows, progress=False)
    narrow = evaluate.score([Stub("narrow")], ["clean"], rows=rows.head(10), progress=False)
    both = pl.concat([full, narrow], how="diagonal_relaxed")

    sub = evaluate.common_subset(both, rung="clean")
    assert sub["id"].n_unique() == 10
    assert sub["detector"].n_unique() == 2


def test_common_subset_empty_for_a_rung_with_no_scores():
    df = evaluate.score([Stub()], ["clean"], rows=corpus(20), progress=False)
    assert evaluate.common_subset(df, rung="severe").is_empty()


def test_compare_ranks_detectors_on_the_common_subset():
    rows = corpus(400)
    good = evaluate.score([Stub("good", sep=4.0)], ["clean"], rows=rows, progress=False)
    weak = evaluate.score([Stub("weak", sep=0.1, seed=5)], ["clean"], rows=rows, progress=False)
    out = evaluate.compare(pl.concat([good, weak], how="diagonal_relaxed"), n_boot=20)
    assert out["detector"].to_list()[0] == "good"
    assert out["auc"][0] > out["auc"][1]


def test_compare_needs_more_than_one_detector_to_be_meaningful():
    df = evaluate.score([Stub()], ["clean"], rows=corpus(200), progress=False)
    out = evaluate.compare(df, n_boot=10)
    assert len(out) == 1  # returns it, but the caller should not present it as a comparison


# --- stratified sampling ------------------------------------------------------------


def test_stratified_sample_keeps_small_generators_represented():
    """GPT-image-2 is 155 of 10,832 images; naive sampling would nearly drop it."""
    rows = pl.concat([
        corpus(200),
        pl.DataFrame({
            "id": [f"rare{i}" for i in range(25)],
            "slice": ["sofake_ood"] * 25,
            "label": ["fake"] * 25,
            "generator": ["GPT-image-2"] * 25,
            "source_platform": [""] * 25,
            "width": [1024] * 25,
            "height": [1024] * 25,
            "path": [f"images/rare{i}.jpg" for i in range(25)],
        }),
    ], how="diagonal_relaxed")

    out = evaluate.stratified_sample(rows, 120, min_per_generator=20)
    gens = out.filter(pl.col("label") == "fake")["generator"].to_list()
    assert gens.count("GPT-image-2") >= 20


def test_stratified_sample_is_roughly_balanced():
    out = evaluate.stratified_sample(corpus(400), 200, min_per_generator=10)
    n_real = int((out["label"] == "real").sum())
    n_fake = int((out["label"] == "fake").sum())
    assert abs(n_real - n_fake) <= max(2, 0.1 * len(out))


def test_stratified_sample_is_deterministic():
    a = evaluate.stratified_sample(corpus(400), 100, seed=7)
    b = evaluate.stratified_sample(corpus(400), 100, seed=7)
    assert sorted(a["id"].to_list()) == sorted(b["id"].to_list())
