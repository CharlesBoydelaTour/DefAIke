"""Parallel preprocessing must be a pure speedup: identical scores, identical NaN placement.

Preprocessing was ~72% of wall time in this pipeline (85.4 ms/image to degrade against 9.3 ms
to infer on MPS), so it is now overlapped across threads. That is only safe because
`degrade.degrade` is seeded per-image from `key=id` rather than from a shared RNG, which makes
its output independent of execution order.

If someone ever reseeds degradation from a global RNG, or reassembles results by completion
order instead of row index, the scores silently change and every number in PLAN.md becomes
unreproducible. These tests exist to fail loudly at that moment.
"""

from __future__ import annotations

import numpy as np
import polars as pl
import pytest
from PIL import Image

from bench.detectors import base
from bench.detectors.base import BaseModelDetector, DetectorInfo


class CountingDetector(BaseModelDetector):
    """Scores an image by its mean pixel value, so the score depends on the actual pixels.

    A constant would pass these tests even if parallelism corrupted the images, so the score
    has to be pixel-derived for the comparison to mean anything.
    """

    def __init__(self):
        self.info = DetectorInfo(name="counting", kind="torch", licence="MIT", commercial=True)
        self.batches: list[int] = []

    def score_batch(self, images: list[Image.Image]) -> list[float]:
        self.batches.append(len(images))
        return [float(np.asarray(im.convert("RGB"), dtype=np.float64).mean()) for im in images]


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    """A small on-disk corpus with deterministic, per-image-distinct content."""
    root = tmp_path / "data"
    (root / "images").mkdir(parents=True)
    rows = []
    rng = np.random.default_rng(0)
    for i in range(37):  # not a multiple of the batch size or the window
        arr = rng.integers(0, 255, size=(80, 96, 3), dtype=np.uint8)
        rel = f"images/img{i:03d}.png"
        Image.fromarray(arr).save(root / rel)
        rows.append({
            "id": f"id{i:03d}",
            "path": rel,
            "slice": "test",
            "label": "fake" if i % 2 else "real",
            "generator": "",
            "source_platform": "",
            "width": 96,
            "height": 80,
        })
    monkeypatch.setattr("bench.paths.data_root", lambda: root)
    return pl.DataFrame(rows)


@pytest.mark.parametrize("rung", ["clean", "moderate", "screenshot_shared", "thumbnail"])
def test_parallel_matches_serial_exactly(corpus, rung):
    """Bit-for-bit equality, not approximate. Any drift means degradation is order-dependent."""
    serial = CountingDetector().scores_for(corpus, rung, workers=1)
    for w in (2, 6, 12):
        parallel = CountingDetector().scores_for(corpus, rung, workers=w)
        assert np.array_equal(serial, parallel), f"{rung} diverged at workers={w}"


def test_scores_align_with_rows_not_completion_order(corpus):
    """Results must be keyed by row index. Thread completion order is arbitrary."""
    det = CountingDetector()
    scores = det.scores_for(corpus, "clean", workers=6)
    for i, row in enumerate(corpus.iter_rows(named=True)):
        img = Image.open(corpus_path(corpus, row)).convert("RGB")
        expected = float(np.asarray(img, dtype=np.float64).mean())
        assert scores[i] == pytest.approx(expected), f"row {i} ({row['id']}) got another row"


def corpus_path(frame, row):
    from bench import paths

    return paths.data_root() / row["path"]


def test_unreadable_rows_stay_nan_in_place(corpus, monkeypatch):
    """Coverage loss must be reported, not silently filled, and must land on the right row."""
    bad = {5, 17, 30}
    real_prepare = CountingDetector._prepare

    def flaky(self, row, rung):
        if int(row["id"][2:]) in bad:
            return None
        return real_prepare(self, row, rung)

    monkeypatch.setattr(CountingDetector, "_prepare", flaky)
    scores = CountingDetector().scores_for(corpus, "clean", workers=6)
    nan_idx = set(np.flatnonzero(np.isnan(scores)).tolist())
    assert nan_idx == bad
    assert np.isfinite(scores[list(set(range(37)) - bad)]).all()


def test_every_row_is_visited_exactly_once(corpus):
    det = CountingDetector()
    det.scores_for(corpus, "clean", workers=6)
    assert sum(det.batches) == len(corpus)


def test_window_bounds_images_in_flight(corpus):
    """Peak memory is bounded by the window, not by corpus size. 8 GB of images would
    otherwise be resident at once."""
    assert base.PREPARE_WINDOW <= 128
    assert base.PREPARE_WINDOW >= base.PREPROCESS_WORKERS


def test_worker_count_respects_env(monkeypatch):
    monkeypatch.setenv("BENCH_WORKERS", "3")
    assert base._worker_count() == 3
    assert base._worker_count(8) == 8, "explicit argument must win over the environment"
    monkeypatch.setenv("BENCH_WORKERS", "not-a-number")
    assert base._worker_count() >= 1, "a malformed value must not crash a multi-hour run"


def test_worker_count_never_zero(monkeypatch):
    monkeypatch.setenv("BENCH_WORKERS", "0")
    assert base._worker_count() >= 1
    assert base._worker_count(0) >= 1


def test_degradation_is_keyed_not_globally_seeded():
    """The property the whole parallel path rests on, asserted directly."""
    from bench import degrade

    img = Image.fromarray(
        np.random.default_rng(1).integers(0, 255, (120, 140, 3), dtype=np.uint8)
    )
    first = degrade.degrade(img, "screenshot_shared", key="abc").image
    _ = [degrade.degrade(img, "screenshot_shared", key=f"other{i}") for i in range(5)]
    again = degrade.degrade(img, "screenshot_shared", key="abc").image
    assert np.array_equal(np.asarray(first), np.asarray(again)), (
        "degradation depends on call order; parallel scoring is unsafe"
    )
