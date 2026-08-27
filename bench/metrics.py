"""Detection metrics, sliceable by dataset, generator and degradation rung.

Design follows from two project requirements rather than from convention.

Requirement 8 says a false accusation is the harmful error, so the headline metric is
TPR@1%FPR, not accuracy. Accuracy at the natural threshold is reported but is close to
meaningless here: a detector can post a fine accuracy while false-accusing 8% of real
photos, which for this app is a product failure.

Requirement 10 says numbers must be honest. Two consequences. TPR@1%FPR is reported with a
bootstrap confidence interval, because on this corpus only ~53 real images sit in the 1%
tail and a point estimate implies precision that is not there — `fpr_tail_n` is returned
alongside so a reader can see the sample the operating point rests on. And AUC is computed
via Mann-Whitney with explicit tie correction, since detectors that saturate produce heavy
ties and the naive trapezoid over a coarse ROC quietly inflates them.

No scikit-learn dependency. These are short functions and implementing them here keeps the
tie and edge-case handling visible instead of buried behind defaults.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field

import numpy as np
import polars as pl

DEFAULT_TARGET_FPR = 0.01
DEFAULT_ECE_BINS = 15


def sigmoid(logit: np.ndarray) -> np.ndarray:
    """Stable logistic. Detector outputs are logits; ECE needs probabilities."""
    z = np.asarray(logit, dtype=np.float64)
    out = np.empty_like(z)
    pos = z >= 0
    out[pos] = 1.0 / (1.0 + np.exp(-z[pos]))
    ez = np.exp(z[~pos])
    out[~pos] = ez / (1.0 + ez)
    return out


def auc(y: np.ndarray, score: np.ndarray) -> float:
    """Area under the ROC, via the Mann-Whitney U statistic with tie correction.

    Equivalent to the probability that a random fake outranks a random real, counting ties
    as half. Exact under ties, unlike a trapezoid over a coarse ROC.
    """
    y = np.asarray(y).astype(bool)
    s = np.asarray(score, dtype=np.float64)
    n_pos, n_neg = int(y.sum()), int((~y).sum())
    if n_pos == 0 or n_neg == 0:
        return float("nan")

    order = np.argsort(s, kind="mergesort")
    ranks = np.empty(len(s), dtype=np.float64)
    sorted_s = s[order]
    i = 0
    while i < len(sorted_s):
        j = i
        while j + 1 < len(sorted_s) and sorted_s[j + 1] == sorted_s[i]:
            j += 1
        ranks[order[i : j + 1]] = 0.5 * (i + j) + 1.0  # average rank for the tie block
        i = j + 1

    u = ranks[y].sum() - n_pos * (n_pos + 1) / 2.0
    return float(u / (n_pos * n_neg))


def roc_curve(y: np.ndarray, score: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """FPR, TPR and thresholds, with tied scores collapsed into a single point.

    Collapsing ties matters: leaving them separate creates ROC points that no threshold can
    actually realise, which is how TPR@low-FPR gets overstated.
    """
    y = np.asarray(y).astype(bool)
    s = np.asarray(score, dtype=np.float64)
    n_pos, n_neg = int(y.sum()), int((~y).sum())
    if n_pos == 0 or n_neg == 0:
        nan = np.array([np.nan])
        return nan, nan, nan

    order = np.argsort(-s, kind="mergesort")
    s_sorted, y_sorted = s[order], y[order]

    distinct = np.where(np.diff(s_sorted))[0]
    idx = np.r_[distinct, len(s_sorted) - 1]

    tp = np.cumsum(y_sorted)[idx]
    fp = np.cumsum(~y_sorted)[idx]

    tpr = np.r_[0.0, tp / n_pos]
    fpr = np.r_[0.0, fp / n_neg]
    thr = np.r_[np.inf, s_sorted[idx]]
    return fpr, tpr, thr


def tpr_at_fpr(
    y: np.ndarray, score: np.ndarray, target_fpr: float = DEFAULT_TARGET_FPR
) -> tuple[float, float]:
    """Best TPR achievable without exceeding target_fpr, and the threshold that does it.

    Conservative by construction: takes the largest threshold whose FPR is still at or below
    target, never interpolating past it. Interpolation would report a TPR no real threshold
    delivers.
    """
    fpr, tpr, thr = roc_curve(y, score)
    if np.isnan(fpr).any():
        return float("nan"), float("nan")
    ok = fpr <= target_fpr + 1e-12
    if not ok.any():
        return 0.0, float(thr[0])
    i = int(np.max(np.flatnonzero(ok)))
    return float(tpr[i]), float(thr[i])


def bootstrap_tpr_at_fpr(
    y: np.ndarray,
    score: np.ndarray,
    target_fpr: float = DEFAULT_TARGET_FPR,
    n_boot: int = 1000,
    alpha: float = 0.05,
    seed: int = 42,
) -> tuple[float, float]:
    """Percentile bootstrap CI for TPR@FPR. Stratified, so class counts stay fixed."""
    y = np.asarray(y).astype(bool)
    s = np.asarray(score, dtype=np.float64)
    pos_idx, neg_idx = np.flatnonzero(y), np.flatnonzero(~y)
    if len(pos_idx) < 2 or len(neg_idx) < 2:
        return float("nan"), float("nan")

    rng = np.random.default_rng(seed)
    vals = np.empty(n_boot, dtype=np.float64)
    for b in range(n_boot):
        pi = rng.choice(pos_idx, size=len(pos_idx), replace=True)
        ni = rng.choice(neg_idx, size=len(neg_idx), replace=True)
        sel = np.r_[pi, ni]
        vals[b] = tpr_at_fpr(y[sel], s[sel], target_fpr)[0]
    lo = float(np.nanpercentile(vals, 100 * alpha / 2))
    hi = float(np.nanpercentile(vals, 100 * (1 - alpha / 2)))
    return lo, hi


def predict_fake(score: np.ndarray, threshold: float) -> np.ndarray:
    """Decision rule, defined in exactly one place: `score >= threshold` means fake.

    The `>=` is deliberate and has to match `roc_curve`, whose thresholds are the score
    values at each ROC point. Using `>` here while the ROC used `>=` makes the threshold
    returned by `tpr_at_fpr` fail to reproduce its own FPR whenever scores tie — and this
    corpus ties heavily, because saturating detectors pin many images at the same value.
    A threshold of +inf correctly predicts nothing as fake.
    """
    return np.asarray(score, dtype=np.float64) >= threshold


def balanced_accuracy(y: np.ndarray, score: np.ndarray, threshold: float = 0.0) -> float:
    """(TPR + TNR) / 2 at a fixed threshold. Insensitive to class imbalance."""
    y = np.asarray(y).astype(bool)
    pred = predict_fake(score, threshold)
    n_pos, n_neg = int(y.sum()), int((~y).sum())
    if n_pos == 0 or n_neg == 0:
        return float("nan")
    tpr = float((pred & y).sum() / n_pos)
    tnr = float((~pred & ~y).sum() / n_neg)
    return 0.5 * (tpr + tnr)


def fpr_at_threshold(y: np.ndarray, score: np.ndarray, threshold: float = 0.0) -> float:
    """False-positive rate: the fraction of real images wrongly flagged as AI.

    The number requirement 8 cares about most.
    """
    y = np.asarray(y).astype(bool)
    pred = predict_fake(score, threshold)
    n_neg = int((~y).sum())
    if n_neg == 0:
        return float("nan")
    return float((pred & ~y).sum() / n_neg)


def ece(
    y: np.ndarray, prob: np.ndarray, n_bins: int = DEFAULT_ECE_BINS
) -> tuple[float, list[dict]]:
    """Expected calibration error, equal-width bins on predicted probability.

    Returns the scalar plus per-bin detail, because the scalar alone hides direction: a
    detector that is confidently wrong on damaged inputs and one that is merely vague both
    post a mediocre ECE, and only the bins distinguish them.
    """
    y = np.asarray(y).astype(bool)
    p = np.clip(np.asarray(prob, dtype=np.float64), 0.0, 1.0)
    if len(p) == 0:
        return float("nan"), []

    edges = np.linspace(0.0, 1.0, n_bins + 1)
    total = 0.0
    bins: list[dict] = []
    for k in range(n_bins):
        lo, hi = edges[k], edges[k + 1]
        m = (p > lo) & (p <= hi) if k > 0 else (p >= lo) & (p <= hi)
        n = int(m.sum())
        if n == 0:
            bins.append({"bin": k, "lo": lo, "hi": hi, "n": 0,
                         "confidence": None, "accuracy": None, "gap": None})
            continue
        conf = float(p[m].mean())
        acc = float(y[m].mean())
        gap = abs(acc - conf)
        total += (n / len(p)) * gap
        bins.append({"bin": k, "lo": lo, "hi": hi, "n": n,
                     "confidence": conf, "accuracy": acc, "gap": gap})
    return float(total), bins


@dataclass(frozen=True)
class Metrics:
    n: int
    n_real: int
    n_fake: int
    auc: float
    balanced_accuracy: float  # at the detector's natural threshold (logit 0)
    fpr_at_zero: float  # how often a real photo is accused at that threshold
    tpr_at_1pct_fpr: float  # HEADLINE
    tpr_at_1pct_fpr_lo: float
    tpr_at_1pct_fpr_hi: float
    threshold_at_1pct_fpr: float
    balanced_accuracy_at_op: float  # at the low-FPR operating point
    ece: float
    fpr_tail_n: int  # reals defining the 1% tail; small means a wide CI
    warnings: tuple[str, ...] = field(default=())

    def as_row(self) -> dict:
        return asdict(self)


def compute(
    labels: np.ndarray | list,
    scores: np.ndarray | list,
    *,
    target_fpr: float = DEFAULT_TARGET_FPR,
    n_boot: int = 1000,
    ece_bins: int = DEFAULT_ECE_BINS,
    seed: int = 42,
) -> Metrics:
    """All metrics for one group. `labels` is truthy for AI-generated."""
    y = np.asarray(labels).astype(bool)
    s = np.asarray(scores, dtype=np.float64)
    if len(y) != len(s):
        raise ValueError(f"labels/scores length mismatch: {len(y)} vs {len(s)}")

    finite = np.isfinite(s)
    warns: list[str] = []
    if not finite.all():
        warns.append(f"dropped {int((~finite).sum())} non-finite score(s)")
        y, s = y[finite], s[finite]

    n_real, n_fake = int((~y).sum()), int(y.sum())
    tail_n = int(round(n_real * target_fpr))

    if n_real == 0 or n_fake == 0:
        warns.append("single-class group; ranking metrics undefined")
        return Metrics(len(y), n_real, n_fake, float("nan"), float("nan"), float("nan"),
                       float("nan"), float("nan"), float("nan"), float("nan"),
                       float("nan"), float("nan"), tail_n, tuple(warns))

    if tail_n < 10:
        warns.append(
            f"only {tail_n} real image(s) define the {target_fpr:.0%} FPR tail; "
            f"TPR@{target_fpr:.0%}FPR is coarse and its CI will be wide"
        )

    a = auc(y, s)
    if a < 0.5:
        warns.append(
            f"AUC {a:.3f} is below chance — check for inverted labels or a flipped score sign"
        )

    tpr, thr = tpr_at_fpr(y, s, target_fpr)
    lo, hi = bootstrap_tpr_at_fpr(y, s, target_fpr, n_boot=n_boot, seed=seed)
    e, _ = ece(y, sigmoid(s), n_bins=ece_bins)

    return Metrics(
        n=len(y),
        n_real=n_real,
        n_fake=n_fake,
        auc=a,
        balanced_accuracy=balanced_accuracy(y, s, 0.0),
        fpr_at_zero=fpr_at_threshold(y, s, 0.0),
        tpr_at_1pct_fpr=tpr,
        tpr_at_1pct_fpr_lo=lo,
        tpr_at_1pct_fpr_hi=hi,
        threshold_at_1pct_fpr=thr,
        balanced_accuracy_at_op=balanced_accuracy(y, s, thr),
        ece=e,
        fpr_tail_n=tail_n,
        warnings=tuple(warns),
    )


def by_group(
    df: pl.DataFrame,
    group_cols: list[str] | str,
    *,
    label_col: str = "label",
    score_col: str = "score",
    fake_value: str = "fake",
    min_n: int = 20,
    n_boot: int = 200,
    target_fpr: float = DEFAULT_TARGET_FPR,
) -> pl.DataFrame:
    """Metrics per group. Fewer bootstrap iterations by default since groups are many.

    Groups below `min_n` are still reported but flagged, rather than dropped: a generator
    the detector fails on is exactly the group that will be small, and silently hiding it
    would defeat the purpose of slicing.
    """
    cols = [group_cols] if isinstance(group_cols, str) else list(group_cols)

    # An empty frame has no schema, so group_by would raise ColumnNotFound rather than
    # returning nothing. Callers legitimately pass empty frames (a provider that scored no
    # rows, a rung with no coverage), so absence is a normal result, not an error.
    if df.is_empty():
        return pl.DataFrame()
    missing = [c for c in cols + [label_col, score_col] if c not in df.columns]
    if missing:
        raise ValueError(f"frame is missing required column(s): {missing}")

    rows: list[dict] = []

    for keys, sub in df.group_by(cols, maintain_order=True):
        key_vals = keys if isinstance(keys, tuple) else (keys,)
        y = (sub[label_col] == fake_value).to_numpy()
        s = sub[score_col].to_numpy()
        m = compute(y, s, n_boot=n_boot, target_fpr=target_fpr)
        row = dict(zip(cols, key_vals))
        row.update(m.as_row())
        row["warnings"] = "; ".join(m.warnings)
        if m.n < min_n:
            row["warnings"] = (row["warnings"] + "; " if row["warnings"] else "") + \
                f"group has only {m.n} image(s)"
        rows.append(row)

    return pl.DataFrame(rows) if rows else pl.DataFrame()
