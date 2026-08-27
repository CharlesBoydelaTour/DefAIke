"""OpenFakeTiny fetcher — the `reddit` config only.

Deliberately not taking the `core` config. Its real side descends from LAION-400M, a
pre-2022 web scrape, which is exactly the capture-era skew the whole composition exists
to avoid; it would also cost half the byte budget to reintroduce a known bias.

The parent dataset has a documented defect: ~19.77% of synthetic images across five
generators carry a prompt that does not match the image (reported Nov 2025, fix pending).
Labels are unaffected and labels are all we use, but the `prompt` column is not carried
into the manifest so nothing downstream can mistake it for ground truth.
"""

from __future__ import annotations

from pathlib import Path

import polars as pl
import pyarrow.parquet as pq

from bench import net, paths
from bench.imageio import rel_to_data, write_verified
from bench.spec import Slice

URL = (
    "https://huggingface.co/datasets/ComplexDataLab/OpenFakeTiny/"
    "resolve/main/reddit/test-00000-of-00001.parquet"
)

# Generators whose prompt field is known-unreliable upstream.
PROMPT_DEFECT_GENERATORS = frozenset(
    {"flux-realism", "sd-3.5", "sdxl-realvis-v5", "sd-1.5-dreamshaper", "sd-1.5-epicdream"}
)


def fetch(sl: Slice, *, out_dir: Path | None = None) -> pl.DataFrame:
    out_dir = out_dir or paths.images_dir("openfaketiny_reddit")
    out_dir.mkdir(parents=True, exist_ok=True)

    local = paths.cache_dir() / "openfaketiny_reddit_test.parquet"
    net.download(URL, local, label="OpenFakeTiny reddit")

    tbl = pq.read_table(local, columns=["image", "label", "model", "type", "release_date"])
    images = tbl.column("image").to_pylist()
    labels = tbl.column("label").to_pylist()
    models = tbl.column("model").to_pylist()
    types = tbl.column("type").to_pylist()
    dates = tbl.column("release_date").to_pylist()

    rows: list[dict] = []
    skipped = 0

    for i, blob in enumerate(images):
        data = blob.get("bytes") if isinstance(blob, dict) else None
        if not data:
            skipped += 1
            continue

        written = write_verified(data, out_dir, f"oft_reddit_{i:06d}")
        if written is None:
            skipped += 1
            continue

        raw_label = str(labels[i] or "").strip().lower()
        is_fake = raw_label in ("fake", "synthetic", "1", "ai")
        model = str(models[i] or "")

        rows.append(
            {
                "id": f"oft_reddit_{i:06d}",
                "slice": "openfaketiny_reddit",
                "label": "fake" if is_fake else "real",
                "scope": "FULL_SYNTHETIC" if is_fake else "REAL",
                "authenticity": "FAKE" if is_fake else "REAL",
                "source_platform": "Reddit",
                "generator": model if is_fake else "",
                "type": str(types[i] or ""),
                "date": str(dates[i] or ""),
                "prompt_defect": model in PROMPT_DEFECT_GENERATORS,
                "path": rel_to_data(written.path),
                "sha256": written.sha256,
                "bytes": written.bytes,
                "width": written.width,
                "height": written.height,
                "format": written.format,
            }
        )

    df = pl.DataFrame(rows)
    print(f"  wrote {len(df):,} images, {skipped} skipped")
    if len(df):
        counts = df.group_by("label").agg(n=pl.len()).sort("label").to_dicts()
        print(f"  measured balance: {counts}  (spec assumed 625/625)")
        n_defect = int(df["prompt_defect"].sum())
        if n_defect:
            print(f"  {n_defect} row(s) from generators with the upstream prompt defect")
    return df
