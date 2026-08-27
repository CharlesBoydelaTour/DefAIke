"""ReWIND fetcher (GRIP-UNINA, non-commercial).

Two-tier by necessity. The distributed archive carries every subset except AMMeBa, which
the authors cannot redistribute; AMMeBa is 4,064 of 9,646 instances (42%) and is reachable
only through URLs with expected link rot. We take the archive and report coverage honestly
rather than asserting a count we cannot guarantee.

Join on the FULL archive path, never the basename. Measured: 624 basenames are shared by
more than one CSV row, and `src.jpg` alone is used by 24 rows whose labels disagree —
some REAL, some FAKE. A basename join silently mislabels images and overwrites files,
which is the worst class of bug available here because it looks like a model result.
Archive member paths match the CSV `filename` column exactly, so an exact join is available
and is what we use.

The CSV is why this slice earns its place at only 1.5 GB. Beyond `estimated_QF` it ships
three no-reference IQA scores and logits from six published detectors, so Task 5 can
compare against six baselines on identical images without running them, and Task 7 can fit
quality-conditioned calibration against three different IQA definitions.
"""

from __future__ import annotations

import zipfile
from pathlib import Path

import polars as pl

from bench import net, paths
from bench.imageio import rel_to_data, write_verified
from bench.spec import Slice

CSV_URL = "https://raw.githubusercontent.com/grip-unina/QuAD/main/datasets/ReWIND/ReWIND.csv"
EXCLUDED_SUBSET = "ammeba"

IQA_COLUMNS = ["IQA_QCN", "IQA_LoDa", "IQA_TReS"]
REFERENCE_DETECTORS = ["DMID", "CoDE", "D3", "B-Free", "DRCT", "CO-SPY"]
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".heic"}


def fetch_metadata() -> pl.DataFrame:
    dest = paths.cache_dir() / "ReWIND.csv"
    net.download(CSV_URL, dest, label="ReWIND.csv")
    return pl.read_csv(dest)


def _stem_for(member: str) -> str:
    """Collision-free stem from the archive path.

    `viral_bfree/src.jpg` and `FOSID/src.jpg` must not both become `src.jpg`.
    """
    rel = member[len("ReWIND/"):] if member.startswith("ReWIND/") else member
    return Path(rel).with_suffix("").as_posix().replace("/", "__")


def fetch(sl: Slice, *, out_dir: Path | None = None) -> pl.DataFrame:
    out_dir = out_dir or paths.images_dir("rewind_no_ammeba")
    out_dir.mkdir(parents=True, exist_ok=True)

    meta = fetch_metadata()
    archive = paths.cache_dir() / "ReWIND.zip"
    net.download(sl.source, archive, expect_md5=sl.archive_md5, label="ReWIND.zip")

    have_iqa = [c for c in IQA_COLUMNS if c in meta.columns]
    have_det = [c for c in REFERENCE_DETECTORS if c in meta.columns]

    # Exact path join. See module docstring for why basenames are unusable.
    by_path: dict[str, dict] = {str(r["filename"]): r for r in meta.iter_rows(named=True)}

    rows: list[dict] = []
    skipped = excluded = unmatched = non_image = 0

    with zipfile.ZipFile(archive) as zf:
        members = [m for m in zf.namelist() if not m.endswith("/")]
        for member in members:
            if Path(member).suffix.lower() not in IMAGE_SUFFIXES:
                non_image += 1
                continue
            if any(p.lower() == EXCLUDED_SUBSET for p in Path(member).parts):
                excluded += 1
                continue

            info = by_path.get(member)
            if info is None:
                unmatched += 1
                continue

            written = write_verified(zf.read(member), out_dir, _stem_for(member))
            if written is None:
                skipped += 1
                continue

            label = str(info.get("label", "")).strip().upper()
            is_fake = label == "FAKE"
            row = {
                "id": _stem_for(member),
                "slice": "rewind_no_ammeba",
                "label": "fake" if is_fake else "real",
                "scope": "FULL_SYNTHETIC" if is_fake else "REAL",
                "authenticity": "FAKE" if is_fake else "REAL",
                "source_platform": str(info.get("src_dataset", "")),
                "generator": "",
                "src": str(info.get("src", "")),
                "archive_path": member,
                "estimated_QF": info.get("estimated_QF"),
                "date": str(info.get("date", "") or ""),
                "source_md5": str(info.get("md5", "") or ""),
                "path": rel_to_data(written.path),
                "sha256": written.sha256,
                "bytes": written.bytes,
                "width": written.width,
                "height": written.height,
                "format": written.format,
            }
            # Carry the published IQA scores and baseline detector logits through.
            for c in have_iqa:
                row[c] = info.get(c)
            for c in have_det:
                row[f"ref_{c}"] = info.get(c)
            rows.append(row)

    df = pl.DataFrame(rows)
    print(
        f"  members {len(members):,} | kept {len(df):,} | non-image {non_image} | "
        f"ammeba {excluded} | unmatched {unmatched} | undecodable {skipped}"
    )
    print(f"  coverage: {len(df):,} of {len(meta):,} CSV rows ({len(df) / len(meta):.1%}) "
          f"— remainder is AMMeBa, URL-only")
    if len(df):
        n_uniq = df["path"].n_unique()
        assert n_uniq == len(df), f"output path collision: {len(df) - n_uniq} duplicate(s)"
        counts = df.group_by("label").agg(n=pl.len()).sort("label").to_dicts()
        print(f"  measured balance: {counts}")
        print(f"  reference columns carried: {len(have_iqa)} IQA + {len(have_det)} detectors")
    return df
