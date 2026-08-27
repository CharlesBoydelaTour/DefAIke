"""Reference detectors: the six published logit columns ReWIND ships.

Why this exists. Building a benchmark harness and validating it are different problems, and
validating normally requires a model, which requires weights, a framework, and compute. The
ReWIND CSV short-circuits that: it carries per-image logits from six detectors the QuAD
authors ran, on 5,582 real in-the-wild images. So the metrics module, the slicing, and the
eval runner can all be exercised end-to-end against genuine published numbers at zero
download cost, and any disagreement between our metrics and their reported behaviour is a
bug in ours.

Two honest limits, both enforced in code rather than left to the reader.

First, these are not our measurements. `scored_by_us=False`, and they must never appear in a
comparison that implies we ran them under our own preprocessing.

Second, and more restrictive: the published logits were computed on ReWIND's images as
distributed. Those images are already degraded in the wild, which is the entire point of the
dataset — but that means the scores correspond to the images we fetched, i.e. our `clean`
rung, and nothing else. There is no way to obtain a reference logit for our synthetic rungs
without running the detectors ourselves. `supports_rung` therefore admits only `clean`, and
asking for another rung returns NaN rather than a plausible-looking number.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import polars as pl

from bench.detectors.base import DetectorInfo

# Column name in the ReWIND CSV -> what we can say about the detector.
#
# Identification discipline: B-Free and DRCT I verified against their own repositories
# during the survey. The other four are named only as column headers by QuAD, and I have not
# independently confirmed which paper each refers to, so they are recorded as unverified
# rather than given a citation I cannot stand behind.
REFERENCE_DETECTORS: dict[str, dict] = {
    "B-Free": {
        "source": "grip-unina/B-Free (CVPR 2025), bias-free training paradigm",
        "identified": True,
        # 3,112 of ReWIND's 5,582 rows come from the `viral_bfree` collection, which the
        # B-Free authors assembled, and QuAD is by the same group. Measured effect: B-Free
        # scores AUC 0.9711 on viral_bfree against 0.9335 pooled, while every other
        # detector sits between 0.68 and 0.81 there. Its lead is real but this corpus
        # cannot measure how much of it is home advantage.
        "home_turf": "viral_bfree",
        "trained_on": (
            "COCO reals (51,517) + Stable Diffusion 2.1 self-conditioned and inpainted "
            "generations (309,102). SD 2.1 ONLY — no commercial or 2026 generators."
        ),
        "architecture": (
            "DINOv2 ViT with 4 registers, 504x504 crops with NO resize, multi-crop averaged"
        ),
    },
    "DRCT": {
        "source": "DRCT: Diffusion Reconstruction Contrastive Training (ICML 2024)",
        "identified": True,
    },
    "DMID": {"source": "named in QuAD; paper not independently confirmed", "identified": False},
    "CoDE": {"source": "named in QuAD; paper not independently confirmed", "identified": False},
    "D3": {"source": "named in QuAD; paper not independently confirmed", "identified": False},
    "CO-SPY": {"source": "named in QuAD; paper not independently confirmed", "identified": False},
}

SUPPORTED_RUNGS = frozenset({"clean"})
MANIFEST_PREFIX = "ref_"


@dataclass
class ReferenceDetector:
    """Looks up a published logit by image id. Satisfies ScoreProvider, not Detector."""

    detector: str

    def __post_init__(self) -> None:
        if self.detector not in REFERENCE_DETECTORS:
            raise KeyError(
                f"unknown reference detector {self.detector!r}; "
                f"have {sorted(REFERENCE_DETECTORS)}"
            )
        meta = REFERENCE_DETECTORS[self.detector]
        note = (
            "Published logits, not our measurement. Valid only on ReWIND rows at the "
            "`clean` rung, since the authors scored the images as distributed."
        )
        if not meta["identified"]:
            note += " Detector identity unconfirmed."
        if home := meta.get("home_turf"):
            note += (
                f" EVALUATED PARTLY ON ITS OWN DATA: the `{home}` collection is "
                f"{home}'s, so this detector's score here is optimistic by an "
                f"unmeasurable amount."
            )
        self.home_turf: str | None = meta.get("home_turf")
        if arch := meta.get("architecture"):
            note += f" Architecture: {arch}."
        self.info = DetectorInfo(
            name=f"ref:{self.detector}",
            kind="reference",
            licence="GRIP-UNINA non-commercial",
            commercial=False,
            params=None,
            input_resolution=None,
            source=meta["source"],
            notes=note,
            scored_by_us=False,
            trained_on=meta.get("trained_on", "unknown"),
        )

    @property
    def column(self) -> str:
        return f"{MANIFEST_PREFIX}{self.detector}"

    def supports_rung(self, rung: str) -> bool:
        return rung in SUPPORTED_RUNGS

    def scores_for(self, rows: pl.DataFrame, rung: str) -> np.ndarray:
        """One score per row, NaN where unavailable.

        NaN is returned rather than raising for two distinct reasons: the requested rung is
        not `clean`, or the row is not from ReWIND. Both are expected in a full matrix run,
        and the runner reports coverage so the gaps are visible.
        """
        if not self.supports_rung(rung):
            return np.full(len(rows), np.nan, dtype=np.float64)
        if self.column not in rows.columns:
            return np.full(len(rows), np.nan, dtype=np.float64)
        return rows[self.column].cast(pl.Float64).to_numpy().astype(np.float64)


def available(manifest: pl.DataFrame) -> list[str]:
    """Which reference detectors the manifest actually carries values for."""
    out = []
    for name in REFERENCE_DETECTORS:
        col = f"{MANIFEST_PREFIX}{name}"
        if col in manifest.columns and manifest[col].is_not_null().any():
            out.append(name)
    return out


def all_detectors() -> list[ReferenceDetector]:
    return [ReferenceDetector(n) for n in REFERENCE_DETECTORS]
