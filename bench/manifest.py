"""The resolved manifest: one row per image actually on disk.

The distinction between this and the spec matters. The spec says what we intend to fetch;
the manifest says what we got. Benchmarks must read the manifest, and any report that
quotes projected counts instead of resolved ones is lying by omission.
"""

from __future__ import annotations

from pathlib import Path

import polars as pl

from bench import paths
from bench.spec import Spec

# Per-image provenance the spec requires us to carry: source, licence, generator,
# capture era. Written for every row regardless of which slice it came from.
CANONICAL = [
    "id",
    "slice",
    "label",
    "scope",
    "authenticity",
    "source_platform",
    "generator",
    "path",
    "sha256",
    "bytes",
    "width",
    "height",
    "format",
    "licence",
    "commercial",
    "capture_era",
]


def annotate(df: pl.DataFrame, spec: Spec, slice_id: str) -> pl.DataFrame:
    """Attach the licence and provenance fields from the spec to every row."""
    if df.is_empty():
        return df
    sl = spec.slice_by_id(slice_id)
    return df.with_columns(
        licence=pl.lit(sl.licence),
        commercial=pl.lit(sl.commercial),
        capture_era=pl.lit(sl.capture_era),
        source=pl.lit(sl.source),
    )


def combine(frames: list[pl.DataFrame]) -> pl.DataFrame:
    """Union slices with differing extra columns, keeping the canonical ones aligned."""
    frames = [f for f in frames if not f.is_empty()]
    if not frames:
        return pl.DataFrame()
    return pl.concat(frames, how="diagonal_relaxed")


def write(df: pl.DataFrame) -> None:
    paths.ensure_dirs()
    df.write_parquet(paths.manifest_path())


def read() -> pl.DataFrame:
    p = paths.manifest_path()
    if not p.exists():
        raise FileNotFoundError(f"no manifest at {p}; run `bench fetch` first")
    return pl.read_parquet(p)


def verify(df: pl.DataFrame) -> dict[str, object]:
    """Check the manifest against the filesystem, in both directions.

    Both directions matter. Manifest-to-disk catches a partial fetch. Disk-to-manifest
    catches orphans, which is not hypothetical: an interrupted fetch run left ~600 images
    on disk that no manifest row referenced, and a one-way check would have counted them
    toward the byte budget while no benchmark could ever read them.
    """
    missing: list[str] = []
    size_mismatch: list[str] = []
    root = paths.data_root()

    referenced: set[Path] = set()
    for row in df.iter_rows(named=True):
        p = root / str(row["path"])
        referenced.add(p)
        if not p.exists():
            missing.append(str(row["id"]))
        elif p.stat().st_size != row["bytes"]:
            size_mismatch.append(str(row["id"]))

    images_root = root / "images"
    on_disk = {p for p in images_root.rglob("*") if p.is_file()} if images_root.exists() else set()
    orphans = sorted(on_disk - referenced)
    orphan_bytes = sum(p.stat().st_size for p in orphans)

    dup = df.filter(pl.col("sha256").is_duplicated())["sha256"].n_unique() if len(df) else 0

    return {
        "rows": len(df),
        "files_on_disk": len(on_disk),
        "missing_files": len(missing),
        "size_mismatch": len(size_mismatch),
        "orphan_files": len(orphans),
        "orphan_bytes": orphan_bytes,
        "duplicate_content_hashes": dup,
        "missing_sample": missing[:5],
        "mismatch_sample": size_mismatch[:5],
        "orphan_paths": orphans,
    }


def prune_orphans(df: pl.DataFrame) -> tuple[int, int]:
    """Delete image files no manifest row references. Returns (files, bytes) removed."""
    res = verify(df)
    orphans: list[Path] = res["orphan_paths"]  # type: ignore[assignment]
    freed = 0
    for p in orphans:
        freed += p.stat().st_size
        p.unlink()
    return len(orphans), freed


def summarise(df: pl.DataFrame) -> pl.DataFrame:
    """Per-slice roll-up used by `bench datasets --resolved`."""
    if df.is_empty():
        return pl.DataFrame()
    return (
        df.group_by("slice")
        .agg(
            images=pl.len(),
            real=(pl.col("label") == "real").sum(),
            fake=(pl.col("label") == "fake").sum(),
            gb=(pl.col("bytes").sum() / 1e9).round(2),
            generators=pl.col("generator").filter(pl.col("generator") != "").n_unique(),
            licence=pl.col("licence").first(),
            capture_era=pl.col("capture_era").first(),
        )
        .sort("slice")
    )
