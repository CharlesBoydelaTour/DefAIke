"""Row-group selection for So-Fake-OOD.

This is the only genuinely non-obvious algorithm in the fetch path. Its job is to cope
with a layout measured to be hostile: ~66 rows per row group, ~97 MB per group, and
REAL / FULL_SYNTHETIC / TAMPERED interleaved rather than clustered, so a row group can
never be narrowed to one class.

What the selection must guarantee:
  - never keep a TAMPERED row (out of v0 scope)
  - never keep a link-only row (we do not have its bytes)
  - spread across shards, so no single shard dominates the sample
  - prefer recent generators, so GPT-image-2 is not diluted by the older ten
  - report transfer cost honestly, including the bytes we are forced to over-fetch
"""

from __future__ import annotations

import polars as pl
import pytest

from bench.sources import sofake
from bench.spec import Slice

RECENT = ["GPT-image-2", "GPT-image-1.5", "nano_banana_2", "seedream4.5", "FLUX_2"]
OLD = ["GPT4o", "Imagen4", "Hidream"]


def fake_index(n_shards=8, groups_per_shard=6, rows_per_group=66) -> pl.DataFrame:
    """Synthetic index mirroring the measured real layout, including interleaving."""
    rows = []
    for shard in range(n_shards):
        for group in range(groups_per_shard):
            for i in range(rows_per_group):
                # Deterministic interleave: ~25% real, ~37% tampered, rest synthetic.
                m = (i + group + shard) % 8
                if m in (0, 1):
                    scope, plat, gen = "REAL", ["Reddit", "Tumblr", "Bluesky"][i % 3], None
                elif m in (2, 3, 4):
                    scope, plat, gen = "TAMPERED", None, None
                elif m in (5, 6):
                    scope, plat, gen = "FULL_SYNTHETIC", None, RECENT[i % len(RECENT)]
                else:
                    scope, plat, gen = "FULL_SYNTHETIC", None, OLD[i % len(OLD)]
                rows.append(
                    {
                        "id": f"s{shard}g{group}r{i}",
                        "scope": scope,
                        "source_platform": plat,
                        "generator": gen,
                        "release_form": "image",
                        "shard": shard,
                        "row_group": group,
                        "row_idx": group * rows_per_group + i,
                    }
                )
    return pl.DataFrame(rows).with_columns(
        shard=pl.col("shard").cast(pl.Int32), row_group=pl.col("row_group").cast(pl.Int32)
    )


def a_slice() -> Slice:
    return Slice(
        id="s", source="hf:o/d", role="real", licence="X", commercial=False,
        capture_era="2026", take=100, est_bytes=1, raw={},
    )


@pytest.fixture
def sel():
    return sofake.select(
        fake_index(), a_slice(), want_real=200, want_fake=100,
        recent_generators=RECENT, avg_item_bytes=1_000_000, seed=42,
    )


def test_never_keeps_tampered_rows(sel):
    assert len(sel.rows.filter(pl.col("scope") == "TAMPERED")) == 0


def test_meets_both_quotas(sel):
    assert len(sel.rows.filter(pl.col("scope") == "REAL")) == 200
    assert len(sel.rows.filter(pl.col("scope") == "FULL_SYNTHETIC")) == 100


def test_prefers_recent_generators_over_older_ones(sel):
    fakes = sel.rows.filter(pl.col("scope") == "FULL_SYNTHETIC")
    recent = len(fakes.filter(pl.col("generator").is_in(RECENT)))
    assert recent / len(fakes) > 0.5, "recent generators should dominate the fake quota"


def test_spreads_across_shards(sel):
    """Round-robin exists so one shard cannot supply the whole sample."""
    per_shard = sel.groups.group_by("shard").agg(n=pl.len())
    assert sel.groups["shard"].n_unique() >= 6
    assert per_shard["n"].max() - per_shard["n"].min() <= 2


def test_excludes_link_only_rows():
    idx = fake_index()
    idx = idx.with_columns(
        release_form=pl.when(pl.col("scope") == "REAL")
        .then(pl.lit("link"))
        .otherwise(pl.lit("image"))
    )
    sel = sofake.select(idx, a_slice(), want_real=50, want_fake=50,
                        recent_generators=RECENT, avg_item_bytes=1, seed=1)
    assert len(sel.rows.filter(pl.col("scope") == "REAL")) == 0, "link-only reals are unfetchable"


def test_excludes_x_and_instagram_platforms():
    idx = fake_index().with_columns(
        source_platform=pl.when(pl.col("scope") == "REAL")
        .then(pl.lit("X"))
        .otherwise(pl.col("source_platform"))
    )
    sel = sofake.select(idx, a_slice(), want_real=50, want_fake=50,
                        recent_generators=RECENT, avg_item_bytes=1, seed=1)
    assert "X" not in sel.rows["source_platform"].to_list()


def test_reports_over_fetch_honestly(sel):
    """Interleaving makes transfer exceed kept bytes. That must be visible, not hidden."""
    assert sel.transfer_bytes > sel.keep_bytes
    assert 0.0 < sel.efficiency < 1.0


def test_selection_is_deterministic_under_seed():
    args = dict(want_real=120, want_fake=60, recent_generators=RECENT, avg_item_bytes=1)
    a = sofake.select(fake_index(), a_slice(), seed=7, **args)
    b = sofake.select(fake_index(), a_slice(), seed=7, **args)
    assert a.rows["id"].to_list() == b.rows["id"].to_list()


def test_different_seeds_give_different_samples():
    args = dict(want_real=120, want_fake=60, recent_generators=RECENT, avg_item_bytes=1)
    a = sofake.select(fake_index(), a_slice(), seed=1, **args)
    b = sofake.select(fake_index(), a_slice(), seed=2, **args)
    assert a.rows["id"].to_list() != b.rows["id"].to_list()


def test_every_kept_row_lives_in_a_downloaded_group(sel):
    """A kept row we never download is a manifest that lies."""
    pairs = set(zip(sel.groups["shard"], sel.groups["row_group"]))
    for r in sel.rows.iter_rows(named=True):
        assert (r["shard"], r["row_group"]) in pairs


def test_quota_larger_than_pool_degrades_gracefully():
    """Asking for more than exists should return what exists, not raise."""
    sel = sofake.select(fake_index(n_shards=2, groups_per_shard=1), a_slice(),
                        want_real=10_000, want_fake=10_000,
                        recent_generators=RECENT, avg_item_bytes=1, seed=3)
    assert len(sel.rows) > 0
    assert len(sel.rows.filter(pl.col("scope") == "TAMPERED")) == 0


def test_shard_url_matches_published_naming():
    assert sofake.shard_url(0).endswith("test_image-00000-of-00046.parquet")
    assert sofake.shard_url(45).endswith("test_image-00045-of-00046.parquet")
