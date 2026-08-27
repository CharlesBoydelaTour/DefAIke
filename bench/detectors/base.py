"""The detector interface every candidate is measured through.

Two protocols rather than one, because the framework has to accommodate a case that is not
a model at all. ReWIND ships logits from six published detectors, which lets the entire
metrics and evaluation path be exercised on real numbers before a single weight is
downloaded — but those logits are a lookup keyed by image, not a function of pixels, so
they cannot satisfy `score(image)`.

`Detector` is for anything that turns pixels into a logit. `ScoreProvider` is the wider
interface the evaluation runner consumes, and a lookup table satisfies it.

Sign convention, fixed everywhere: a POSITIVE logit means AI-generated, negative means
real. This matches ReWIND's published columns, so their numbers drop in without a flip.
Getting it backwards is a silent failure, which is why `metrics.compute` warns when AUC
lands below chance.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Protocol, runtime_checkable

import numpy as np
import polars as pl
from PIL import Image


@dataclass(frozen=True)
class DetectorInfo:
    """Metadata the decision table needs, per PLAN.md Task 3.

    `params` and `input_resolution` are what make the accuracy-per-megabyte and
    accuracy-per-millisecond tradeoffs computable later, and `licence`/`commercial` keep the
    project's nonprofit constraint visible at the point of model choice rather than
    discovered at ship time.
    """

    name: str
    kind: str  # "reference" | "torch" | "coreml"
    licence: str
    commercial: bool
    params: int | None = None
    input_resolution: tuple[int, int] | None = None
    source: str = ""
    notes: str = ""
    # False when scores come from someone else's run rather than ours.
    scored_by_us: bool = True
    # What the PRETRAINED weights were fitted on, by whoever trained them. This project
    # trains nothing; every detector here ships pretrained. Recorded because generator drift
    # is the dominant failure mode measured so far, and a detector's training generators
    # predict where it goes blind. "unknown" is a real answer and must not be hidden.
    trained_on: str = "unknown"

    def as_row(self) -> dict:
        d = asdict(self)
        d["input_resolution"] = (
            f"{self.input_resolution[0]}x{self.input_resolution[1]}"
            if self.input_resolution
            else None
        )
        return d


@runtime_checkable
class Detector(Protocol):
    """Turns an image into a logit. Positive means AI-generated."""

    info: DetectorInfo

    def score(self, image: Image.Image) -> float: ...

    def score_batch(self, images: list[Image.Image]) -> list[float]: ...


@runtime_checkable
class ScoreProvider(Protocol):
    """What the evaluation runner actually consumes.

    Returns one score per row of `rows`, aligned by position, with NaN where the provider
    has no opinion. NaN is meaningful and must not be silently coerced: the reference
    detectors genuinely have no score for our synthetic rungs, and pretending otherwise
    would fabricate numbers.
    """

    info: DetectorInfo

    def supports_rung(self, rung: str) -> bool: ...

    def scores_for(self, rows: pl.DataFrame, rung: str) -> np.ndarray: ...


# Preprocessing, not inference, is the bottleneck in this pipeline. Measured on an M3 Pro at
# the `screenshot_shared` rung: 7.2 ms/image to read and decode, 85.4 ms to degrade, 3.5 ms to
# transform, against 9.3 ms to infer on MPS. So ~72% of wall time was one CPU core doing JPEG
# work while an 18-core GPU idled. Overlapping the two is worth roughly 3x end to end.
#
# Threads rather than processes: Pillow releases the GIL across decode, encode and resize,
# which is nearly all of that 92.6 ms, and threads avoid pickling images between processes.
#
# This CANNOT change any score. `degrade.degrade` is seeded per-image from `key=id`, so its
# output is independent of execution order, and results are reassembled by row index. That
# property is load-bearing and `tests/test_parallel_scoring.py` pins it.
# Measured end-to-end on an M3 Pro (6 performance + 6 efficiency cores, 18-core GPU) over 320
# images at the `screenshot_shared` rung, scores asserted identical at every setting:
#
#   workers   ms/image   speedup   peak RSS
#         1      117.4     1.00x     1.28 GB
#         4       30.6     3.83x     1.61 GB
#         6       23.4     5.01x     1.73 GB
#         8       21.6     5.42x     1.83 GB   <- default
#        10       21.4     5.48x     2.22 GB
#
# 8 slightly oversubscribes the performance cores, which the efficiency cores absorb; 10 buys
# another 1% for 0.4 GB and is not worth it. Override with BENCH_WORKERS for other machines.
PREPROCESS_WORKERS = 8
PREPARE_WINDOW = 96  # rows in flight; bounds peak memory


def _worker_count(explicit: int | None = None) -> int:
    import os

    if explicit is not None:
        return max(1, explicit)
    env = os.environ.get("BENCH_WORKERS")
    if env and env.isdigit():
        return max(1, int(env))
    return min(PREPROCESS_WORKERS, (os.cpu_count() or 4))


class BaseModelDetector:
    """Convenience base for pixel-scoring detectors.

    Handles the degradation-and-load loop so each concrete detector only implements
    `score_batch`. Deliberately does NOT cache decoded images: at native resolution this
    corpus is 8 GB and caching it would trade a real memory problem for an imagined speedup.
    """

    info: DetectorInfo
    batch_size: int = 16

    def score(self, image: Image.Image) -> float:
        return self.score_batch([image])[0]

    def score_batch(self, images: list[Image.Image]) -> list[float]:
        raise NotImplementedError

    def supports_rung(self, rung: str) -> bool:
        return True

    def _prepare(self, row: dict, rung: str) -> Image.Image | None:
        """Read, decode and degrade one image. Runs on a worker thread.

        Returns None for anything unreadable so the caller leaves NaN, which the runner
        reports as reduced coverage rather than hiding.
        """
        from bench import degrade, paths

        try:
            img = Image.open(paths.data_root() / str(row["path"]))
            img.load()
            return degrade.degrade(img.convert("RGB"), rung, key=str(row["id"])).image
        except Exception:
            return None

    def scores_for(
        self, rows: pl.DataFrame, rung: str, *, workers: int | None = None
    ) -> np.ndarray:
        from concurrent.futures import ThreadPoolExecutor

        out = np.full(len(rows), np.nan, dtype=np.float64)
        n_workers = _worker_count(workers)
        records = list(enumerate(rows.iter_rows(named=True)))

        if n_workers == 1:
            prepared = ((i, self._prepare(r, rung)) for i, r in records)
            self._consume(prepared, out)
            return out

        # Windowed submission keeps at most PREPARE_WINDOW decoded images resident. Submitting
        # every row at once would pull the whole 8 GB corpus into memory.
        with ThreadPoolExecutor(max_workers=n_workers) as pool:
            for start in range(0, len(records), PREPARE_WINDOW):
                window = records[start : start + PREPARE_WINDOW]
                images = pool.map(lambda ir: self._prepare(ir[1], rung), window)
                self._consume(
                    ((i, im) for (i, _), im in zip(window, images)),
                    out,
                )
        return out

    def _consume(self, prepared, out: np.ndarray) -> None:
        """Batch whatever survived preparation and write scores back by row index."""
        batch: list[Image.Image] = []
        idx: list[int] = []
        for i, img in prepared:
            if img is None:
                continue
            batch.append(img)
            idx.append(i)
            if len(batch) >= self.batch_size:
                out[idx] = self.score_batch(batch)
                batch, idx = [], []
        if batch:
            out[idx] = self.score_batch(batch)
