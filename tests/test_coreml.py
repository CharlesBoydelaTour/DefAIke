"""Core ML export: the normalisation contract and the placement verdict.

The dangerous failure in a Core ML port is not a crash, it is a working model that is quietly
wrong. Normalisation moved from Python into the exported graph, so if the wrapper's arithmetic
diverges from `commfor.build_transform()` by even a constant, the model still runs, still
returns plausible logits, and sits at a shifted operating point against a CALIBRATED threshold.
Nothing surfaces that but a test.

`test_wrapper_matches_the_reference_transform_exactly` is therefore the important one here: it
pins the composition `ImageType(scale=1/255) -> Normalised(mean,std)` against the torchvision
pipeline every measured number in PLAN.md was produced with.

Conversion itself is slow and needs coremltools, so those tests are opt-in via
RUN_COREML_TESTS=1 and skipped otherwise.
"""

from __future__ import annotations

import os

import numpy as np
import pytest
import torch
from PIL import Image

from bench import coreml
from bench.detectors import commfor

HEAVY = pytest.mark.skipif(
    os.environ.get("RUN_COREML_TESTS") != "1",
    reason="set RUN_COREML_TESTS=1 to run conversion tests (slow, needs coremltools)",
)


# --- the normalisation contract -----------------------------------------------------------


class Identity(torch.nn.Module):
    def forward(self, x):  # noqa: D102
        return x


def test_wrapper_matches_the_reference_transform_exactly():
    """`ImageType(scale=1/255)` then `Normalised` must equal ToTensor + Normalize.

    If this drifts, the exported model is wrong in a way no other test would catch.
    """
    img = Image.fromarray(
        np.random.default_rng(4).integers(0, 256, (commfor.CROP, commfor.CROP, 3), dtype=np.uint8)
    )
    tf = commfor.build_transform()
    reference = tf.transforms[3](tf.transforms[2](img))  # Normalize(ToTensor(img))

    # What the exported graph sees: Core ML scales uint8 by 1/255, the wrapper does the rest.
    scaled = torch.from_numpy(
        np.asarray(img, dtype=np.float32).transpose(2, 0, 1)[None] / 255.0
    )
    through_graph = coreml.Normalised(Identity(), commfor.MEAN, commfor.STD)(scaled)

    assert torch.allclose(through_graph[0], reference, atol=1e-6), (
        "exported normalisation diverges from the reference transform"
    )


def test_wrapper_uses_per_channel_std():
    """The reason normalisation is inside the graph at all: std differs per channel, and Core
    ML's ImageType `scale` is a single scalar."""
    assert len(set(commfor.STD)) > 1, "if std were uniform, scale/bias alone would do"
    w = coreml.Normalised(Identity(), commfor.MEAN, commfor.STD)
    out = w(torch.ones(1, 3, 4, 4))
    per_channel = {round(float(out[0, c].mean()), 6) for c in range(3)}
    assert len(per_channel) == 3, "channels must be scaled differently"


def test_wrapper_is_a_pure_reparameterisation():
    """Zero-mean/unit-std input must pass through untouched, proving no hidden extra op."""
    w = coreml.Normalised(Identity(), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0))
    x = torch.rand(1, 3, 8, 8)
    assert torch.equal(w(x), x)


# --- placement verdict logic ---------------------------------------------------------------


def make_placement(ane, gpu=0, cpu=0):
    p = coreml.Placement()
    p.counts = {k: v for k, v in (("ANE", ane), ("GPU", gpu), ("CPU", cpu)) if v}
    p.total = ane + gpu + cpu
    return p


def test_full_ane_passes():
    p = make_placement(262, cpu=2)
    assert p.ane_fraction == pytest.approx(262 / 264)
    assert p.verdict().startswith("PASS")


def test_no_ane_fails_loudly():
    """The Task 4 gate. A CPU-only fallback must never read as success — it would keep every
    accuracy number intact while destroying the power budget."""
    assert make_placement(0, cpu=200).verdict().startswith("FAIL")


def test_partial_and_weak_are_distinguished():
    assert make_placement(60, cpu=40).verdict().startswith("PARTIAL")
    assert make_placement(10, cpu=90).verdict().startswith("WEAK")


def test_empty_placement_does_not_divide_by_zero():
    assert coreml.Placement().ane_fraction == 0.0
    assert coreml.Placement().verdict().startswith("FAIL")


# --- artifact naming ----------------------------------------------------------------------


def test_package_path_encodes_variant_and_resolution():
    p = coreml.package_path("lowq")
    assert p.name == f"commfor-lowq-{commfor.CROP}.mlpackage"
    assert coreml.package_path("frontier") != p, "variants must not overwrite each other"


def test_deployment_target_is_pinned():
    assert coreml.DEPLOYMENT_TARGET == "iOS17"
    assert (coreml.INPUT_NAME, coreml.OUTPUT_NAME) == ("image", "logit")


# --- conversion (opt-in) -------------------------------------------------------------------


@HEAVY
def test_export_then_placement_and_parity():
    path, _ = coreml.export("lowq")
    assert path.exists()
    pl = coreml.placement(path)
    assert pl.ane_fraction >= 0.9, f"ANE residency regressed to {pl.ane_fraction:.3f}"
    r = coreml.parity("lowq", path, n=24)
    assert r["spearman_rho"] > 0.999, "rank order drifted; AUC would change"
    assert r["decision_agreement"] == 1.0
