"""So-Fake-OOD-v3 fetcher.

Why this file is the most involved one: the dataset embeds image bytes in parquet, and
its physical layout is hostile to selective reading. Measured on shard 0:

  - 46 shards, ~2.91 GB each, ~135 GB total
  - 30 row groups per shard, only ~68 rows per group => ~97 MB per row group
  - the `image` column is 99.7% of the bytes; all metadata columns together are ~1 MB
  - REAL / FULL_SYNTHETIC / TAMPERED rows are INTERLEAVED, not clustered

The interleaving is the crux. A row group is the smallest unit parquet lets us fetch, so
any group we touch delivers ~68 rows of which only ~25% are REAL. We cannot beat that
with predicates. What we can do:

  1. Index pass reads metadata columns only (~1 MB/shard, ~46 MB total). Cheap, and it
     tells us the exact composition of every row group before we spend a byte on images.
  2. Fetch pass picks whole row groups and keeps every useful row in them, so the
     unavoidable over-fetch at least yields both reals and fakes rather than one class.

Consequence, stated plainly because it belongs in the record: network transfer materially
exceeds bytes-on-disk for this slice. The spec's ceiling governs disk.
"""

from __future__ import annotations

import concurrent.futures as cf
import json
from dataclasses import dataclass
from pathlib import Path

import duckdb
import polars as pl
from tqdm import tqdm

from bench import paths
from bench.imageio import rel_to_data, write_verified
from bench.spec import Slice

N_SHARDS = 46
BASE = "https://huggingface.co/datasets/saberzl/So-Fake-OOD/resolve/main/data"

# Columns worth indexing. Deliberately excludes `image` and `mask` (the payload) and the
# free-text/url columns we have no use for.
META_COLS = [
    "id",
    "scope",
    "label",
    "authenticity",
    "source_type",
    "source_name",
    "source_platform",
    "generator",
    "editor",
    "release_form",
    "filename",
    "width",
    "height",
    "version",
]


def shard_url(i: int) -> str:
    return f"{BASE}/test_image-{i:05d}-of-{N_SHARDS:05d}.parquet"


def _connect() -> duckdb.DuckDBPyConnection:
    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute("SET enable_progress_bar=false;")
    return con


def _index_shard(i: int) -> pl.DataFrame:
    """Read one shard's metadata columns plus row-group boundaries. No image bytes."""
    url = shard_url(i)
    con = _connect()
    try:
        # Row-group sizes come from the footer, so we can map row_idx -> row_group
        # exactly rather than assuming a uniform 68.
        rg = con.execute(
            f"SELECT DISTINCT row_group_id, row_group_num_rows "
            f"FROM parquet_metadata('{url}') ORDER BY row_group_id"
        ).fetchall()

        # to_arrow_table() materialises. .arrow() hands back a lazy RecordBatchReader
        # that a later execute() on the same connection silently invalidates.
        cols = ", ".join(META_COLS)
        rows = con.execute(
            f"SELECT {cols}, file_row_number AS row_idx "
            f"FROM read_parquet('{url}', file_row_number=true) "
            f"ORDER BY row_idx"
        ).to_arrow_table()
    finally:
        con.close()

    boundaries: list[int] = []
    running = 0
    for _rg_id, n in rg:
        running += n
        boundaries.append(running)

    def to_group(idx: int) -> int:
        for g, end in enumerate(boundaries):
            if idx < end:
                return g
        return len(boundaries) - 1

    df = pl.from_arrow(rows)
    return df.with_columns(
        shard=pl.lit(i, dtype=pl.Int32),
        row_group=pl.Series([to_group(v) for v in df["row_idx"]], dtype=pl.Int32),
    )


def build_index(workers: int = 8, force: bool = False) -> pl.DataFrame:
    """Index every shard. ~46 MB of transfer for the whole dataset's metadata."""
    out = paths.index_path("sofake_ood")
    if out.exists() and not force:
        return pl.read_parquet(out)

    paths.ensure_dirs()
    frames: list[pl.DataFrame] = []
    failures: list[tuple[int, str]] = []

    with cf.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(_index_shard, i): i for i in range(N_SHARDS)}
        for fut in cf.as_completed(futures):
            i = futures[fut]
            try:
                frames.append(fut.result())
                print(f"  indexed shard {i:>2}  ({len(frames)}/{N_SHARDS})", flush=True)
            except Exception as e:  # a single bad shard must not lose the whole pass
                failures.append((i, f"{type(e).__name__}: {e}"))
                print(f"  !! shard {i:>2} FAILED: {type(e).__name__}: {e}", flush=True)

    if not frames:
        raise RuntimeError(f"index pass produced nothing; failures={failures}")

    df = pl.concat(frames).sort(["shard", "row_idx"])
    df.write_parquet(out)

    if failures:
        (paths.cache_dir() / "index_sofake_ood_failures.json").write_text(
            json.dumps(failures, indent=2)
        )
        print(f"  WARNING: {len(failures)} shard(s) failed; recorded in cache")

    return df


# ---------------------------------------------------------------------------------


@dataclass
class Selection:
    """Which rows to fetch, and the honest cost of doing so."""

    rows: pl.DataFrame  # the rows we will keep
    groups: pl.DataFrame  # shard/row_group pairs we must download
    transfer_bytes: int
    keep_bytes: int

    @property
    def efficiency(self) -> float:
        return self.keep_bytes / self.transfer_bytes if self.transfer_bytes else 0.0


def select(
    index: pl.DataFrame,
    sl: Slice,
    *,
    want_real: int,
    want_fake: int,
    recent_generators: list[str],
    avg_item_bytes: int,
    seed: int = 42,
) -> Selection:
    """Choose row groups to fetch, then choose which of their rows to keep.

    Strategy: rank row groups by how many useful rows they hold (reals weighted highest,
    then recent-generator fakes), spread the pick across all 46 shards so no shard
    dominates, and walk down the ranking until both quotas are met.
    """
    usable = index.filter(
        (pl.col("scope") != "TAMPERED")
        & (pl.col("release_form") == "image")
        & (~pl.col("source_platform").is_in(["X", "Instagram"]) | pl.col("source_platform").is_null())
    )

    is_real = pl.col("scope") == "REAL"
    is_recent = pl.col("generator").is_in(recent_generators)

    scored = usable.with_columns(
        useful_real=is_real.cast(pl.Int32),
        useful_recent=(~is_real & is_recent).cast(pl.Int32),
        useful_other=(~is_real & ~is_recent).cast(pl.Int32),
    )

    # Determinism note: polars group_by does not guarantee row order, and rank("ordinal")
    # breaks ties by row position. Without maintain_order plus explicit (shard, row_group)
    # tiebreakers, two runs with the same seed pick different groups. A benchmark corpus
    # that cannot be reproduced is not a benchmark corpus.
    per_group = (
        scored.group_by(["shard", "row_group"], maintain_order=True)
        .agg(
            n_real=pl.col("useful_real").sum(),
            n_recent=pl.col("useful_recent").sum(),
            n_other=pl.col("useful_other").sum(),
            n_rows=pl.len(),
        )
        .with_columns(score=pl.col("n_real") * 2 + pl.col("n_recent") * 2 + pl.col("n_other"))
        .sort(["score", "shard", "row_group"], descending=[True, False, False])
        # Round-robin across shards: rank groups within each shard, then order by that
        # rank first so we take the best group from every shard before any shard's second.
        .with_columns(
            within_shard=pl.col("score").rank("ordinal", descending=True).over("shard")
        )
        .sort(["within_shard", "score", "shard", "row_group"],
              descending=[False, True, False, False])
    )

    chosen: list[tuple[int, int]] = []
    got_real = got_recent = got_other = 0
    fake_quota = want_fake

    for row in per_group.iter_rows(named=True):
        if got_real >= want_real and (got_recent + got_other) >= fake_quota:
            break
        chosen.append((row["shard"], row["row_group"]))
        got_real += row["n_real"]
        got_recent += row["n_recent"]
        got_other += row["n_other"]

    groups = pl.DataFrame(
        {"shard": [c[0] for c in chosen], "row_group": [c[1] for c in chosen]},
        schema={"shard": pl.Int32, "row_group": pl.Int32},
    )

    # Now decide which rows inside those groups we actually keep. Sort before sampling so
    # the shuffle is seeded off a stable row order rather than join output order.
    in_scope = scored.join(groups, on=["shard", "row_group"], how="inner").sort(
        ["shard", "row_group", "row_idx"]
    )

    def pick(frame: pl.DataFrame, n: int) -> pl.DataFrame:
        if n <= 0 or frame.is_empty():
            return frame.head(0)
        return frame.sample(fraction=1.0, shuffle=True, seed=seed).head(n)

    reals = pick(in_scope.filter(is_real), want_real)
    # Prefer recent generators, then backfill with the rest, so GPT-image-2 and friends
    # are not diluted away by the older ten.
    fakes_recent = pick(in_scope.filter(~is_real & is_recent), want_fake)
    fakes_other = pick(
        in_scope.filter(~is_real & ~is_recent), max(0, want_fake - len(fakes_recent))
    )

    keep = pl.concat([reals, fakes_recent, fakes_other]).sort(["shard", "row_group", "row_idx"])

    # A row group is the atomic download unit, so transfer is groups x group size.
    group_bytes = avg_item_bytes * int(per_group["n_rows"].mean() or 68)
    return Selection(
        rows=keep,
        groups=groups,
        transfer_bytes=len(groups) * group_bytes,
        keep_bytes=len(keep) * avg_item_bytes,
    )


# ---------------------------------------------------------------------------------
#  Fetch pass. Row groups are the atomic download unit, so we read whole groups and
#  keep the rows the selection asked for.
# ---------------------------------------------------------------------------------


def _fetch_group(
    shard: int,
    row_group: int,
    wanted_ids: set[str],
    out_dir: Path,
) -> tuple[list[dict], list[str]]:
    """Read one row group, write the wanted images. Returns (rows, skipped_ids)."""
    import pyarrow.parquet as pq
    from huggingface_hub import HfFileSystem

    fs = HfFileSystem()
    hf_path = (
        f"datasets/saberzl/So-Fake-OOD/data/test_image-{shard:05d}-of-{N_SHARDS:05d}.parquet"
    )

    rows: list[dict] = []
    skipped: list[str] = []

    with fs.open(hf_path, "rb") as fh:
        pf = pq.ParquetFile(fh)
        tbl = pf.read_row_group(
            row_group,
            columns=["id", "scope", "authenticity", "source_platform", "generator", "filename", "image"],
        )

    ids = tbl.column("id").to_pylist()
    images = tbl.column("image").to_pylist()
    scopes = tbl.column("scope").to_pylist()
    auth = tbl.column("authenticity").to_pylist()
    plats = tbl.column("source_platform").to_pylist()
    gens = tbl.column("generator").to_pylist()

    for i, rid in enumerate(ids):
        if rid not in wanted_ids:
            continue
        blob = images[i]
        data = blob.get("bytes") if isinstance(blob, dict) else None
        written = write_verified(data or b"", out_dir, rid) if data else None
        if written is None:
            skipped.append(rid)
            continue
        rows.append(
            {
                "id": rid,
                "slice": "sofake_ood",
                "label": "real" if scopes[i] == "REAL" else "fake",
                "scope": scopes[i],
                "authenticity": auth[i],
                "source_platform": plats[i],
                "generator": gens[i],
                "path": rel_to_data(written.path),
                "sha256": written.sha256,
                "bytes": written.bytes,
                "width": written.width,
                "height": written.height,
                "format": written.format,
                "shard": shard,
                "row_group": row_group,
            }
        )

    return rows, skipped


def fetch(selection: Selection, *, workers: int = 6, out_dir: Path | None = None) -> pl.DataFrame:
    """Download the selected row groups and write their wanted images to disk.

    Resumable: completed (shard, row_group) pairs are recorded, so an interrupted run
    picks up where it stopped instead of re-downloading ~97 MB groups it already has.
    """
    out_dir = out_dir or paths.images_dir("sofake_ood")
    out_dir.mkdir(parents=True, exist_ok=True)
    state_file = paths.state_path("sofake_ood")

    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    done: set[str] = set(state.get("done", []))
    rows: list[dict] = state.get("rows", [])
    skipped: list[str] = state.get("skipped", [])

    by_group: dict[tuple[int, int], set[str]] = {}
    for r in selection.rows.iter_rows(named=True):
        by_group.setdefault((r["shard"], r["row_group"]), set()).add(r["id"])

    todo = [(s, g, ids) for (s, g), ids in sorted(by_group.items()) if f"{s}:{g}" not in done]
    if not todo:
        print("  all row groups already fetched")
        return pl.DataFrame(rows) if rows else pl.DataFrame()

    print(f"  {len(todo)} row group(s) to fetch, {len(done)} already done")

    def save() -> None:
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(
            json.dumps({"done": sorted(done), "rows": rows, "skipped": skipped})
        )

    with cf.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(_fetch_group, s, g, ids, out_dir): (s, g) for s, g, ids in todo}
        completed = 0
        with tqdm(total=len(todo), desc="  row groups", unit="grp") as bar:
            for fut in cf.as_completed(futures):
                s, g = futures[fut]
                try:
                    got, bad = fut.result()
                    rows.extend(got)
                    skipped.extend(bad)
                    done.add(f"{s}:{g}")
                except Exception as e:
                    print(f"\n  !! shard {s} group {g} failed: {type(e).__name__}: {e}")
                completed += 1
                bar.update(1)
                bar.set_postfix(images=len(rows), skipped=len(skipped))
                if completed % 10 == 0:
                    save()

    save()
    if skipped:
        print(f"  {len(skipped)} image(s) skipped as undecodable")
    return pl.DataFrame(rows)
