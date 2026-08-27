"""Evaluation runner: score providers x rungs -> scores table -> sliced metrics.

Kept deliberately thin. Scoring and metrics are separate steps with a persisted table
between them, for three reasons: scoring is the expensive part and must be resumable,
re-slicing metrics should never require re-scoring, and a scores table on disk is the
artifact that makes a published number reproducible by a reader.

Coverage is reported, never inferred. A provider that has no opinion returns NaN, and the
runner records how many rows it actually scored, so a metrics table can never be built from
a silently empty run.
"""

from __future__ import annotations

import polars as pl

from bench import degrade, manifest, metrics, paths
from bench.detectors.base import ScoreProvider


def scores_path() -> str:
    return str(paths.data_root() / "scores.parquet")


def completed_pairs() -> set[tuple[str, str]]:
    """(detector, rung) pairs already on disk, so a resumed run can skip them."""
    p = paths.data_root() / "scores.parquet"
    if not p.exists():
        return set()
    done = pl.read_parquet(p, columns=["detector", "rung"]).unique()
    return {(r["detector"], r["rung"]) for r in done.iter_rows(named=True)}


def score(
    providers: list[ScoreProvider],
    rungs: list[str] | None = None,
    *,
    rows: pl.DataFrame | None = None,
    progress: bool = True,
    checkpoint: bool = False,
    resume: bool = False,
) -> pl.DataFrame:
    """Run every provider over every rung. Returns a long table of one row per score.

    `checkpoint=True` writes each (detector, rung) to disk as it completes rather than only
    at the end. That is not a nicety: a Corvi2023 run at ~675 ms/image takes hours, and a
    process killed three rungs in lost all three because persistence happened once, at the
    end. Scoring is the expensive step in this project and it must be crash-safe.

    `resume=True` additionally skips pairs already present on disk.
    """
    rows = manifest.read() if rows is None else rows
    rungs = list(degrade.ALL_RUNGS) if rungs is None else rungs
    already = completed_pairs() if resume else set()

    out: list[pl.DataFrame] = []
    for prov in providers:
        for rung in rungs:
            if not prov.supports_rung(rung):
                continue
            if (prov.info.name, rung) in already:
                if progress:
                    print(f"  {prov.info.name:<18} {rung:<18} skipped (already on disk)",
                          flush=True)
                continue

            vals = prov.scores_for(rows, rung)
            n_scored = int(pl.Series(vals).is_not_nan().sum())
            if progress:
                print(f"  {prov.info.name:<18} {rung:<18} scored {n_scored:>6,}/{len(rows):,}",
                      flush=True)
            if n_scored == 0:
                continue

            frame = rows.select(
                "id", "slice", "label", "generator", "source_platform", "width", "height"
            ).with_columns(
                detector=pl.lit(prov.info.name),
                detector_kind=pl.lit(prov.info.kind),
                scored_by_us=pl.lit(prov.info.scored_by_us),
                rung=pl.lit(rung),
                score=pl.Series(vals, dtype=pl.Float64),
            ).filter(pl.col("score").is_not_nan())

            out.append(frame)
            if checkpoint:
                write_scores(frame)  # merges by (detector, rung)

    if not out:
        return pl.DataFrame()
    return pl.concat(out, how="diagonal_relaxed").filter(pl.col("score").is_not_nan())


def write_scores(df: pl.DataFrame, *, merge: bool = True) -> None:
    """Persist scores, merging with any existing table by default.

    Merging rather than overwriting, because scoring is the expensive step: a run of one
    extra rung should extend the matrix, not discard the hours already spent on the others.
    Rows are keyed by (detector, rung, id) and the incoming run wins on collision, so
    re-scoring a rung after a code change replaces it cleanly.
    """
    paths.ensure_dirs()
    out = df
    existing_path = paths.data_root() / "scores.parquet"
    if merge and existing_path.exists() and not df.is_empty():
        old = pl.read_parquet(existing_path)
        incoming = df.select("detector", "rung").unique()
        keep = old.join(incoming, on=["detector", "rung"], how="anti")
        out = pl.concat([keep, df], how="diagonal_relaxed")
    out.write_parquet(existing_path)


def read_scores() -> pl.DataFrame:
    p = paths.data_root() / "scores.parquet"
    if not p.exists():
        raise FileNotFoundError(f"no scores at {p}; run `bench eval` first")
    return pl.read_parquet(p)


def headline(df: pl.DataFrame, *, n_boot: int = 400) -> pl.DataFrame:
    """One row per (detector, rung). The table that picks the shipping model.

    Annotated with `resolution_shortcut` so a reader cannot mistake a `clean` or `light`
    number for a clean one: on this corpus resolution alone scores 63.1%, and those two
    rungs leave dimensions untouched.
    """
    res = metrics.by_group(df, ["detector", "rung"], n_boot=n_boot, min_n=50)
    if res.is_empty():
        return res
    return res.with_columns(
        resolution_shortcut=pl.col("rung").is_in(list(degrade.RESOLUTION_PRESERVING))
    ).sort(["detector", "rung"])


def by_generator(df: pl.DataFrame, *, rung: str = "clean", n_boot: int = 200) -> pl.DataFrame:
    """Per-generator slice. Reals carry no generator, so they are shared across groups.

    Each generator's rows are evaluated against the whole real pool, because a per-generator
    AUC needs negatives and the negatives are not generator-specific. That makes the numbers
    comparable across generators, which is the point of the slice.
    """
    sub = df.filter(pl.col("rung") == rung)
    if sub.is_empty():
        return pl.DataFrame()

    reals = sub.filter(pl.col("label") == "real")
    rows: list[dict] = []
    for det in sub["detector"].unique().to_list():
        d_reals = reals.filter(pl.col("detector") == det)
        d_fakes = sub.filter((pl.col("detector") == det) & (pl.col("label") == "fake"))
        for gen in d_fakes["generator"].unique().to_list():
            if not gen:
                continue
            g = d_fakes.filter(pl.col("generator") == gen)
            merged = pl.concat([d_reals, g], how="diagonal_relaxed")
            y = (merged["label"] == "fake").to_numpy()
            m = metrics.compute(y, merged["score"].to_numpy(), n_boot=n_boot)
            rows.append({
                "detector": det,
                "generator": gen,
                "n_fake": m.n_fake,
                "n_real": m.n_real,
                "auc": m.auc,
                "tpr_at_1pct_fpr": m.tpr_at_1pct_fpr,
                "balanced_accuracy": m.balanced_accuracy,
            })
    # Guard the empty case explicitly: sorting a frame with no schema raises. This is not
    # hypothetical — the reference detectors only cover ReWIND, which carries no generator
    # attribution, so this slice is legitimately empty for them.
    if not rows:
        return pl.DataFrame()
    return pl.DataFrame(rows).sort(["detector", "auc"], descending=[False, True])


def common_subset(df: pl.DataFrame, *, rung: str = "clean") -> pl.DataFrame:
    """Restrict to images that EVERY detector scored, so a comparison is valid.

    This exists because the headline table is a trap. The reference detectors cover only
    ReWIND's 5,582 rows at the clean rung, while a pixel-scoring model covers everything. A
    reader comparing rows across that boundary is comparing detectors on different data, and
    the corpora differ enormously in difficulty — ClipBased scores AUC 0.80 on ReWIND and
    0.64 on the 2026-generator slice. Any cross-detector claim has to come from here.
    """
    at_rung = df.filter(pl.col("rung") == rung)
    if at_rung.is_empty():
        return at_rung
    n_det = at_rung["detector"].n_unique()
    ids = (
        at_rung.group_by("id")
        .agg(k=pl.col("detector").n_unique())
        .filter(pl.col("k") == n_det)["id"]
        .implode()
    )
    return at_rung.filter(pl.col("id").is_in(ids))


def compare(df: pl.DataFrame, *, rung: str = "clean", n_boot: int = 400) -> pl.DataFrame:
    """Valid cross-detector table, computed on the common subset only."""
    sub = common_subset(df, rung=rung)
    if sub.is_empty():
        return pl.DataFrame()
    out = metrics.by_group(sub, "detector", n_boot=n_boot, min_n=50)
    return out.sort("auc", descending=True)


def by_source(df: pl.DataFrame, *, rung: str = "clean", n_boot: int = 200) -> pl.DataFrame:
    """Per-source-dataset slice, the fallback when generator attribution is unavailable.

    For ReWIND this splits by originating collection (viral B-Free, FOSID, Google
    Fact-Check, RRDataset), which is a real axis: those collections differ in how the
    images reached the web and therefore in how damaged they are.
    """
    sub = df.filter((pl.col("rung") == rung) & (pl.col("source_platform") != ""))
    if sub.is_empty():
        return pl.DataFrame()
    return metrics.by_group(
        sub, ["detector", "source_platform"], n_boot=n_boot, min_n=50
    ).sort(["detector", "auc"], descending=[False, True])


def stratified_sample(
    rows: pl.DataFrame, n: int, *, seed: int = 42, min_per_generator: int = 20
) -> pl.DataFrame:
    """Balanced subsample that keeps every generator represented.

    A full 7-rung matrix over 10,832 images is ~76k inferences per detector, which is hours.
    Subsampling is the pragmatic answer, but a naive random sample would drop the small
    recent generators — GPT-image-2 is only 155 images — and those are precisely the ones
    the project cares about. So generators are floored before the remainder is filled.
    """
    reals = rows.filter(pl.col("label") == "real")
    fakes = rows.filter(pl.col("label") == "fake")
    half = n // 2

    kept: list[pl.DataFrame] = []
    used = 0
    for gen in fakes.filter(pl.col("generator") != "")["generator"].unique().to_list():
        g = fakes.filter(pl.col("generator") == gen)
        take = min(len(g), max(min_per_generator, 0))
        kept.append(g.sample(take, seed=seed))
        used += take

    remaining = max(0, half - used)
    if remaining:
        already = pl.concat(kept)["id"] if kept else pl.Series("id", [], dtype=pl.String)
        rest = fakes.filter(~pl.col("id").is_in(already.implode()))
        kept.append(rest.sample(min(len(rest), remaining), seed=seed))

    fake_sel = pl.concat(kept, how="diagonal_relaxed").unique(subset=["id"])
    real_sel = reals.sample(min(len(reals), len(fake_sel)), seed=seed)
    return pl.concat([real_sel, fake_sel], how="diagonal_relaxed")


def resolution_baseline(rows: pl.DataFrame | None = None) -> dict:
    """The number every detector has to beat to have demonstrated anything.

    A detector scoring at or below this has learned canvas dimensions, not synthesis.
    Computed here rather than quoted from a note so it stays current with the corpus.
    """
    rows = manifest.read() if rows is None else rows
    gen_sizes = [(1024, 1024), (1024, 1536), (1536, 1024), (2048, 2048),
                 (1402, 1122), (1344, 768), (768, 1344)]
    pred = pl.any_horizontal(
        [(pl.col("width") == w) & (pl.col("height") == h) for w, h in gen_sizes]
    )
    d = rows.with_columns(pred_fake=pred)
    n_fake = int((d["label"] == "fake").sum())
    n_real = int((d["label"] == "real").sum())
    tp = int(d.filter(pl.col("pred_fake") & (pl.col("label") == "fake")).height)
    fp = int(d.filter(pl.col("pred_fake") & (pl.col("label") == "real")).height)
    return {
        "rule": "image resolution matches a known generator canvas",
        "accuracy": (tp + (n_real - fp)) / len(d) if len(d) else float("nan"),
        "balanced_accuracy": 0.5 * (tp / n_fake + (n_real - fp) / n_real)
        if n_fake and n_real
        else float("nan"),
        "tpr": tp / n_fake if n_fake else float("nan"),
        "fpr": fp / n_real if n_real else float("nan"),
    }
