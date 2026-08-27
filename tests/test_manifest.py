"""Resolved manifest: provenance annotation, union across slices, integrity checking.

The spec says what we intend to fetch; the manifest says what we got. Anything that
reports projected counts as if they were measured is the failure mode these tests exist
to prevent.
"""

from __future__ import annotations

import polars as pl
import pytest

from bench import manifest, paths, spec


@pytest.fixture
def sp():
    return spec.load()


def row(**kw):
    base = {
        "id": "i1", "slice": "sofake_ood_real", "label": "real", "scope": "REAL",
        "authenticity": "REAL", "source_platform": "Reddit", "generator": "",
        "path": "images/x/i1.jpg", "sha256": "a" * 64, "bytes": 10,
        "width": 4, "height": 4, "format": "jpeg",
    }
    return {**base, **kw}


def test_annotate_attaches_licence_and_era_to_every_row(sp):
    df = manifest.annotate(pl.DataFrame([row(), row(id="i2")]), sp, "sofake_ood_real")
    assert df["licence"].unique().to_list() == ["CC-BY-NC-4.0"]
    assert df["commercial"].unique().to_list() == [False]
    assert df["capture_era"].unique().to_list() == ["2024-2026"]
    assert "source" in df.columns


def test_annotate_is_a_noop_on_empty(sp):
    assert manifest.annotate(pl.DataFrame(), sp, "sofake_ood_real").is_empty()


def test_combine_unions_slices_with_different_extra_columns(sp):
    a = manifest.annotate(pl.DataFrame([row()]), sp, "sofake_ood_real")
    b = manifest.annotate(
        pl.DataFrame([row(id="r1", slice="rewind_no_ammeba", estimated_QF=91)]),
        sp, "rewind_no_ammeba",
    )
    out = manifest.combine([a, b])
    assert len(out) == 2
    assert "estimated_QF" in out.columns
    # The So-Fake row has no QF, so it must be null rather than silently dropped.
    assert out.filter(pl.col("slice") == "sofake_ood_real")["estimated_QF"].to_list() == [None]


def test_combine_drops_empty_frames():
    assert manifest.combine([pl.DataFrame(), pl.DataFrame()]).is_empty()


def test_canonical_columns_all_present_after_annotate(sp):
    df = manifest.annotate(pl.DataFrame([row()]), sp, "sofake_ood_real")
    missing = [c for c in manifest.CANONICAL if c not in df.columns]
    assert not missing, f"manifest missing canonical provenance columns: {missing}"


def test_verify_flags_missing_files(sp, tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    df = manifest.annotate(pl.DataFrame([row()]), sp, "sofake_ood_real")
    res = manifest.verify(df)
    assert res["missing_files"] == 1
    assert res["rows"] == 1


def test_verify_flags_size_mismatch(sp, tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    f = tmp_path / "data" / "images" / "x"
    f.mkdir(parents=True)
    (f / "i1.jpg").write_bytes(b"only4")  # declared bytes = 10
    df = manifest.annotate(pl.DataFrame([row()]), sp, "sofake_ood_real")
    res = manifest.verify(df)
    assert res["missing_files"] == 0
    assert res["size_mismatch"] == 1


def test_verify_passes_when_filesystem_agrees(sp, tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    d = tmp_path / "data" / "images" / "x"
    d.mkdir(parents=True)
    (d / "i1.jpg").write_bytes(b"0123456789")
    df = manifest.annotate(pl.DataFrame([row()]), sp, "sofake_ood_real")
    res = manifest.verify(df)
    assert res["missing_files"] == 0 and res["size_mismatch"] == 0


def test_verify_detects_duplicate_content(sp, tmp_path, monkeypatch):
    """Two ids with one content hash means we paid for the same image twice."""
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    df = manifest.annotate(
        pl.DataFrame([row(), row(id="i2", path="images/x/i2.jpg")]), sp, "sofake_ood_real"
    )
    assert manifest.verify(df)["duplicate_content_hashes"] == 1


def test_summarise_reports_per_slice_balance_and_licence(sp):
    df = manifest.combine([
        manifest.annotate(
            pl.DataFrame([row(), row(id="i2", label="fake", scope="FULL_SYNTHETIC",
                                     generator="GPT-image-2")]),
            sp, "sofake_ood_real"),
    ])
    s = manifest.summarise(df)
    assert s["images"].to_list() == [2]
    assert s["real"].to_list() == [1]
    assert s["fake"].to_list() == [1]
    assert s["generators"].to_list() == [1]  # blank generator not counted


def test_summarise_empty_is_empty():
    assert manifest.summarise(pl.DataFrame()).is_empty()


def test_read_without_fetch_gives_actionable_error(tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    with pytest.raises(FileNotFoundError, match="run `bench fetch`"):
        manifest.read()


def test_write_then_read_roundtrips(sp, tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    df = manifest.annotate(pl.DataFrame([row()]), sp, "sofake_ood_real")
    manifest.write(df)
    assert paths.manifest_path().exists()
    assert manifest.read()["id"].to_list() == ["i1"]


# --- orphan detection ---------------------------------------------------------------
# Regression tests for a real incident: an interrupted fetch left ~600 images on disk that
# no manifest row referenced. A manifest-to-disk-only check reported everything healthy
# while those bytes counted against the budget and no benchmark could read them.


def setup_disk(tmp_path, monkeypatch, files: dict[str, bytes]):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    for rel, data in files.items():
        p = tmp_path / "data" / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)


def test_verify_detects_orphan_files_on_disk(sp, tmp_path, monkeypatch):
    setup_disk(tmp_path, monkeypatch, {
        "images/x/i1.jpg": b"0123456789",
        "images/x/orphan.jpg": b"junkjunk",
    })
    df = manifest.annotate(pl.DataFrame([row()]), sp, "sofake_ood_real")
    res = manifest.verify(df)
    assert res["files_on_disk"] == 2
    assert res["orphan_files"] == 1
    assert res["orphan_bytes"] == 8
    assert res["missing_files"] == 0


def test_verify_reports_no_orphans_when_clean(sp, tmp_path, monkeypatch):
    setup_disk(tmp_path, monkeypatch, {"images/x/i1.jpg": b"0123456789"})
    df = manifest.annotate(pl.DataFrame([row()]), sp, "sofake_ood_real")
    res = manifest.verify(df)
    assert res["orphan_files"] == 0
    assert res["files_on_disk"] == res["rows"] == 1


def test_prune_orphans_removes_only_unreferenced_files(sp, tmp_path, monkeypatch):
    setup_disk(tmp_path, monkeypatch, {
        "images/x/i1.jpg": b"0123456789",
        "images/x/orphan_a.jpg": b"aaaa",
        "images/y/orphan_b.jpg": b"bbbbbb",
    })
    df = manifest.annotate(pl.DataFrame([row()]), sp, "sofake_ood_real")
    n, freed = manifest.prune_orphans(df)
    assert n == 2
    assert freed == 10
    assert (tmp_path / "data" / "images" / "x" / "i1.jpg").exists()
    assert not (tmp_path / "data" / "images" / "x" / "orphan_a.jpg").exists()
    assert manifest.verify(df)["orphan_files"] == 0


def test_prune_is_a_noop_when_nothing_is_orphaned(sp, tmp_path, monkeypatch):
    setup_disk(tmp_path, monkeypatch, {"images/x/i1.jpg": b"0123456789"})
    df = manifest.annotate(pl.DataFrame([row()]), sp, "sofake_ood_real")
    assert manifest.prune_orphans(df) == (0, 0)
    assert (tmp_path / "data" / "images" / "x" / "i1.jpg").exists()
