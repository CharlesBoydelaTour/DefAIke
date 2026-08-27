"""Metrics, verified against values computed by hand.

A metrics module that is merely self-consistent is worthless: it will report a confident
number for a broken detector. Every function here is checked against an arithmetic result
worked out independently, and the tie-handling cases exist because saturating detectors
produce heavy ties and that is exactly where naive implementations inflate scores.
"""

from __future__ import annotations

import numpy as np
import polars as pl
import pytest

from bench import metrics


# --- AUC ----------------------------------------------------------------------------


def test_auc_perfect_separation():
    y = [0, 0, 1, 1]
    s = [0.1, 0.2, 0.8, 0.9]
    assert metrics.auc(y, s) == 1.0


def test_auc_inverted_is_zero():
    y = [0, 0, 1, 1]
    s = [0.9, 0.8, 0.2, 0.1]
    assert metrics.auc(y, s) == 0.0


def test_auc_hand_computed_with_partial_overlap():
    """2 reals {1,3}, 2 fakes {2,4}. Pairs: (2>1)(2<3)(4>1)(4>3) -> 3/4."""
    y = [0, 1, 0, 1]
    s = [1.0, 2.0, 3.0, 4.0]
    assert metrics.auc(y, s) == pytest.approx(0.75)


def test_auc_all_ties_is_one_half():
    """Every score identical means no ranking information at all."""
    y = [0, 0, 1, 1]
    s = [5.0, 5.0, 5.0, 5.0]
    assert metrics.auc(y, s) == pytest.approx(0.5)


def test_auc_counts_ties_as_half():
    """1 real, 1 fake, tied: exactly one pair, counted as half."""
    assert metrics.auc([0, 1], [2.0, 2.0]) == pytest.approx(0.5)


def test_auc_single_class_is_nan():
    assert np.isnan(metrics.auc([1, 1, 1], [0.1, 0.2, 0.3]))


def test_auc_matches_brute_force_on_random_data():
    """Independent check: count discordant pairs directly."""
    rng = np.random.default_rng(0)
    y = rng.integers(0, 2, 200).astype(bool)
    s = rng.normal(size=200).round(1)  # rounding forces ties
    pos, neg = s[y], s[~y]
    brute = np.mean([(1.0 if p > n else 0.5 if p == n else 0.0) for p in pos for n in neg])
    assert metrics.auc(y, s) == pytest.approx(brute, abs=1e-9)


# --- ROC and TPR@FPR ----------------------------------------------------------------


def test_roc_starts_at_origin():
    fpr, tpr, _ = metrics.roc_curve([0, 1], [0.1, 0.9])
    assert fpr[0] == 0.0 and tpr[0] == 0.0


def test_tpr_at_fpr_perfect_detector():
    y = [0] * 100 + [1] * 100
    s = [0.0] * 100 + [1.0] * 100
    tpr, _ = metrics.tpr_at_fpr(y, s, 0.01)
    assert tpr == 1.0


def test_tpr_at_fpr_hand_computed():
    """100 reals uniform on [0,1); 100 fakes at 1.5. FPR<=1% admits all fakes."""
    y = [0] * 100 + [1] * 100
    s = list(np.linspace(0, 0.99, 100)) + [1.5] * 100
    tpr, thr = metrics.tpr_at_fpr(y, s, 0.01)
    assert tpr == pytest.approx(1.0)
    # 1% of 100 reals admits one false positive, so the threshold lands on the top real
    # score. Under `score >= thr` that admits exactly that one real and all 100 fakes.
    assert thr == pytest.approx(0.99)
    assert metrics.fpr_at_threshold(y, s, thr) <= 0.01 + 1e-9


def test_tpr_at_fpr_is_conservative_never_interpolates():
    """Only one real above the fakes: at 0% FPR no fake can pass."""
    y = [0, 0, 1, 1]
    s = [10.0, 0.0, 1.0, 2.0]
    tpr, _ = metrics.tpr_at_fpr(y, s, 0.0)
    assert tpr == 0.0


def test_tpr_at_fpr_with_ties_does_not_overstate():
    """Reals and fakes tied at the same score cannot be separated by any threshold."""
    y = [0] * 50 + [1] * 50
    s = [1.0] * 100
    tpr, _ = metrics.tpr_at_fpr(y, s, 0.01)
    assert tpr == 0.0


def test_tpr_at_fpr_single_class_is_nan():
    tpr, _ = metrics.tpr_at_fpr([1, 1], [0.1, 0.2], 0.01)
    assert np.isnan(tpr)


# --- balanced accuracy and FPR ------------------------------------------------------


def test_balanced_accuracy_hand_computed():
    """TPR = 2/3, TNR = 1/2 -> 0.5 * (2/3 + 1/2) = 0.58333."""
    y = [0, 0, 1, 1, 1]
    s = [-1.0, 1.0, 1.0, 1.0, -1.0]
    assert metrics.balanced_accuracy(y, s, 0.0) == pytest.approx(0.5833333, abs=1e-6)


def test_balanced_accuracy_is_half_when_predicting_one_class():
    y = [0] * 90 + [1] * 10
    s = [1.0] * 100  # everything flagged fake
    assert metrics.balanced_accuracy(y, s, 0.0) == pytest.approx(0.5)


def test_balanced_accuracy_ignores_class_imbalance():
    """The reason we use it: 90/10 imbalance must not inflate the score."""
    y = [0] * 90 + [1] * 10
    s = [-1.0] * 90 + [-1.0] * 10  # everything called real
    assert metrics.balanced_accuracy(y, s, 0.0) == pytest.approx(0.5)


def test_fpr_at_threshold_hand_computed():
    """4 reals, 1 above threshold -> 0.25."""
    y = [0, 0, 0, 0, 1]
    s = [1.0, -1.0, -1.0, -1.0, 1.0]
    assert metrics.fpr_at_threshold(y, s, 0.0) == pytest.approx(0.25)


# --- ECE ----------------------------------------------------------------------------


def test_ece_zero_for_perfectly_calibrated():
    """Half the samples at p=0.5 correct, half wrong: confidence equals accuracy."""
    p = [0.5] * 100
    y = [1] * 50 + [0] * 50
    val, _ = metrics.ece(y, p, n_bins=10)
    assert val == pytest.approx(0.0, abs=1e-9)


def test_ece_maximal_for_confidently_wrong():
    p = [1.0] * 50
    y = [0] * 50
    val, _ = metrics.ece(y, p, n_bins=10)
    assert val == pytest.approx(1.0)


def test_ece_hand_computed_two_bins():
    """Bin p=0.9 (n=2, acc 0.5, gap 0.4) and p=0.1 (n=2, acc 0.0, gap 0.1).
    ECE = 0.5*0.4 + 0.5*0.1 = 0.25."""
    p = [0.9, 0.9, 0.1, 0.1]
    y = [1, 0, 0, 0]
    val, _ = metrics.ece(y, p, n_bins=10)
    assert val == pytest.approx(0.25)


def test_ece_bins_expose_direction_not_just_magnitude():
    p = [0.95] * 20 + [0.05] * 20
    y = [0] * 20 + [1] * 20  # confidently wrong in both directions
    val, bins = metrics.ece(y, p, n_bins=10)
    populated = [b for b in bins if b["n"]]
    assert len(populated) == 2
    assert all(b["gap"] > 0.9 for b in populated)
    assert val > 0.9


def test_ece_empty_is_nan():
    val, bins = metrics.ece([], [], n_bins=5)
    assert np.isnan(val) and bins == []


# --- sigmoid ------------------------------------------------------------------------


def test_sigmoid_is_stable_at_extremes():
    out = metrics.sigmoid(np.array([-1000.0, 0.0, 1000.0]))
    assert np.all(np.isfinite(out))
    assert out[0] == pytest.approx(0.0)
    assert out[1] == pytest.approx(0.5)
    assert out[2] == pytest.approx(1.0)


# --- compute() ----------------------------------------------------------------------


def separable(n=500, sep=3.0, seed=0):
    rng = np.random.default_rng(seed)
    y = np.r_[np.zeros(n, bool), np.ones(n, bool)]
    s = np.r_[rng.normal(-sep / 2, 1, n), rng.normal(sep / 2, 1, n)]
    return y, s


def test_compute_on_separable_data():
    y, s = separable()
    m = metrics.compute(y, s, n_boot=100)
    assert m.n == 1000 and m.n_real == 500 and m.n_fake == 500
    assert m.auc > 0.95
    assert m.balanced_accuracy > 0.9
    assert 0.0 <= m.tpr_at_1pct_fpr <= 1.0


def test_compute_reports_confidence_interval_that_brackets_the_estimate():
    y, s = separable()
    m = metrics.compute(y, s, n_boot=300)
    assert m.tpr_at_1pct_fpr_lo <= m.tpr_at_1pct_fpr <= m.tpr_at_1pct_fpr_hi


def test_compute_surfaces_the_thin_tail_as_a_warning():
    """The corpus has ~53 reals in the tail; a small slice has effectively none.

    With 50 reals, a 1% FPR budget rounds to zero admissible false positives, which is a
    real and important degenerate case: the operating point cannot be estimated at all.
    """
    y, s = separable(n=50)
    m = metrics.compute(y, s, n_boot=50)
    assert m.fpr_tail_n == 0
    assert any("FPR tail" in w for w in m.warnings)


def test_predict_fake_uses_inclusive_threshold():
    """Pinned because roc_curve's thresholds depend on it matching."""
    assert metrics.predict_fake(np.array([1.0]), 1.0)[0]
    assert not metrics.predict_fake(np.array([0.999]), 1.0)[0]
    assert not metrics.predict_fake(np.array([1e300]), np.inf)[0]


def test_compute_flags_inverted_labels():
    """The guard the plan asks for: a silent label flip must not pass unnoticed."""
    y, s = separable()
    m = metrics.compute(y, -s, n_boot=50)
    assert m.auc < 0.5
    assert any("below chance" in w for w in m.warnings)


def test_compute_single_class_returns_nans_not_an_exception():
    m = metrics.compute([1] * 20, list(range(20)), n_boot=10)
    assert m.n_real == 0
    assert np.isnan(m.auc)
    assert any("single-class" in w for w in m.warnings)


def test_compute_drops_non_finite_scores_and_says_so():
    y = [0, 0, 1, 1, 1]
    s = [0.1, 0.2, np.nan, 0.8, np.inf]
    m = metrics.compute(y, s, n_boot=20)
    assert m.n == 3
    assert any("non-finite" in w for w in m.warnings)


def test_compute_rejects_length_mismatch():
    with pytest.raises(ValueError, match="length mismatch"):
        metrics.compute([0, 1], [0.1, 0.2, 0.3])


def test_operating_point_threshold_actually_achieves_target_fpr():
    """The reported threshold must really hold FPR at or below 1% on the same data."""
    y, s = separable()
    m = metrics.compute(y, s, n_boot=50)
    assert metrics.fpr_at_threshold(y, s, m.threshold_at_1pct_fpr) <= 0.01 + 1e-9


# --- slicing ------------------------------------------------------------------------


def frame():
    rng = np.random.default_rng(1)
    rows = []
    for gen, sep in [("gpt-image-2", 3.0), ("nano_banana", 0.2)]:
        for rung in ["clean", "heavy"]:
            for lab in ["real", "fake"]:
                mu = sep / 2 if lab == "fake" else -sep / 2
                for _ in range(60):
                    rows.append({"generator": gen, "rung": rung, "label": lab,
                                 "score": float(rng.normal(mu, 1))})
    return pl.DataFrame(rows)


def test_by_group_returns_one_row_per_group():
    out = metrics.by_group(frame(), ["generator", "rung"], n_boot=20)
    assert len(out) == 4
    assert set(out.columns) >= {"generator", "rung", "auc", "tpr_at_1pct_fpr", "ece", "n"}


def test_by_group_separates_easy_from_hard_generators():
    """Slicing exists to expose exactly this: one generator is detectable, one is not."""
    out = metrics.by_group(frame(), "generator", n_boot=20)
    easy = out.filter(pl.col("generator") == "gpt-image-2")["auc"][0]
    hard = out.filter(pl.col("generator") == "nano_banana")["auc"][0]
    assert easy > 0.9
    assert hard < 0.7
    assert easy > hard


def test_by_group_flags_small_groups_rather_than_hiding_them():
    small = pl.DataFrame({
        "generator": ["x"] * 6,
        "label": ["real", "fake"] * 3,
        "score": [0.1, 0.9, 0.2, 0.8, 0.3, 0.7],
    })
    out = metrics.by_group(small, "generator", min_n=20, n_boot=10)
    assert len(out) == 1
    assert "only 6 image" in out["warnings"][0]


def test_by_group_empty_frame_is_empty():
    empty = pl.DataFrame({"generator": [], "label": [], "score": []})
    assert metrics.by_group(empty, "generator").is_empty()
