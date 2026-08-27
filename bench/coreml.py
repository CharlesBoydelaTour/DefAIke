"""Core ML export for the winning detector, plus the three checks that decide if it ships.

PLAN.md Task 4 treats one question as a hard gate: does the model *place on the Apple Neural
Engine*? Not "does it convert" — a converted model that silently falls back to CPU keeps every
number identical while losing the power and latency budget the share extension depends on. That
failure is invisible unless you look, so this module looks, using `MLComputePlan` to read the
per-operation device assignment rather than inferring it from a stopwatch.

Three things are verified here, in the order that they can kill the design:

  1. `export`   — does the graph convert at all, at FP16, for an iOS deployment target
  2. `placement`— which compute device does each operation actually land on
  3. `parity`   — does the Core ML model agree numerically with PyTorch on real images

Parity is last but is not a formality. Preprocessing drift is the standard silent failure in
these ports: the model runs, returns plausible logits, and is quietly wrong because the
normalisation, colour order or resize filter shifted. A calibrated decision boundary makes this
worse, because a small systematic offset moves the operating point without looking like a bug.

DESIGN DECISION, worth stating because it shapes the iOS code. Normalisation is baked INTO the
exported graph and the input is declared as an `ImageType`, so the app hands Core ML a
CVPixelBuffer and nothing else. The alternative — a raw `TensorType` — pushes ImageNet
mean/std arithmetic into Swift, where it is both slower and the most likely place for a port to
drift from the Python reference. Per-channel std (0.229/0.224/0.225) cannot be expressed with
Core ML's single scalar `scale`, so a thin wrapper module does it inside the graph instead.

Resize and centre-crop stay in the app. `resize_short_edge(440) -> centre_crop(384)` is not
expressible as a fixed-shape graph op, and Task 11's parity test is the place that pins the
app's implementation of it against this reference.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import torch
from PIL import Image

from bench import paths
from bench.detectors import commfor

# iOS 17 is the floor: it covers the ANE generations worth targeting and is where the
# `mlprogram` FP16 path is well supported. Raising it further buys nothing here.
DEPLOYMENT_TARGET = "iOS17"
INPUT_NAME = "image"
OUTPUT_NAME = "logit"


class Normalised(torch.nn.Module):
    """Wraps the detector so the graph accepts [0,1] RGB and normalises internally.

    Exists because Core ML's `ImageType.scale` is a single scalar while ImageNet's std is
    per-channel. Putting the division here keeps the app's job to "hand over a pixel buffer".
    """

    def __init__(self, model: torch.nn.Module, mean, std):
        super().__init__()
        self.model = model
        self.register_buffer("mean", torch.tensor(mean).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(std).view(1, 3, 1, 1))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.model((x - self.mean) / self.std)


def artifact_dir() -> Path:
    d = paths.data_root() / "coreml"
    d.mkdir(parents=True, exist_ok=True)
    return d


def package_path(variant: str) -> Path:
    return artifact_dir() / f"commfor-{variant}-{CROP_TAG}.mlpackage"


CROP_TAG = f"{commfor.CROP}"


# --- 1. export ----------------------------------------------------------------------------


def export(variant: str = "lowq", *, force: bool = False) -> tuple[Path, dict]:
    """Trace and convert. Returns the .mlpackage path and a report."""
    import coremltools as ct

    out = package_path(variant)
    if out.exists() and not force:
        return out, {"status": "cached"}

    det = commfor.CommForFrontierDetector(variant=variant, device="cpu")
    wrapped = Normalised(det.model, commfor.MEAN, commfor.STD).eval()

    example = torch.rand(1, 3, commfor.CROP, commfor.CROP)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example, strict=False)

    t0 = time.perf_counter()
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name=INPUT_NAME,
                shape=(1, 3, commfor.CROP, commfor.CROP),
                scale=1 / 255.0,  # to [0,1]; mean/std handled inside the graph
                bias=[0.0, 0.0, 0.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name=OUTPUT_NAME)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=getattr(ct.target, DEPLOYMENT_TARGET),
        compute_units=ct.ComputeUnit.ALL,
    )
    elapsed = time.perf_counter() - t0

    mlmodel.short_description = (
        f"AI-generated image detector, {commfor.TIMM_ARCH}. Input: {commfor.CROP}x{commfor.CROP} "
        f"RGB, already resized short-edge-{commfor.RESIZE_SHORT_EDGE} and centre-cropped. "
        f"Output: single raw logit; >= {det.decision_threshold} means AI-generated."
    )
    mlmodel.author = "derived from Thermostatic/community-forensics (MIT)"
    mlmodel.license = "MIT"
    mlmodel.version = f"{variant}-2026-08"
    if out.exists():
        import shutil

        shutil.rmtree(out)
    mlmodel.save(str(out))

    size = sum(f.stat().st_size for f in out.rglob("*") if f.is_file())
    return out, {
        "status": "converted",
        "convert_seconds": round(elapsed, 1),
        "package_mb": round(size / 1e6, 1),
        "decision_threshold": det.decision_threshold,
    }


# --- 2. ANE placement ---------------------------------------------------------------------


@dataclass
class Placement:
    """Per-operation compute-device assignment. The Task 4 gate."""

    counts: dict[str, int] = field(default_factory=dict)
    total: int = 0
    unsupported_by_ane: list[str] = field(default_factory=list)

    @property
    def ane_fraction(self) -> float:
        return self.counts.get("ANE", 0) / max(self.total, 1)

    def verdict(self) -> str:
        f = self.ane_fraction
        if f >= 0.9:
            return "PASS - essentially fully on ANE"
        if f >= 0.5:
            return "PARTIAL - meaningful ANE residency, some fallback"
        if f > 0:
            return "WEAK - mostly not on ANE"
        return "FAIL - no ANE residency"


def compile_package(package: Path, *, force: bool = False) -> Path:
    """Compile .mlpackage -> .mlmodelc, the form the app actually loads."""
    import coremltools as ct

    out = package.with_suffix(".mlmodelc")
    if out.exists() and not force:
        return out
    if out.exists():
        import shutil

        shutil.rmtree(out)
    produced = Path(ct.utils.compile_model(str(package)))
    if produced != out:
        import shutil

        if out.exists():
            shutil.rmtree(out)
        shutil.move(str(produced), str(out))
    return out


def placement(package: Path) -> Placement:
    """Read the actual per-op device assignment via MLComputePlan.

    This is the check that cannot be replaced by timing. A model that falls back to CPU still
    produces correct logits, so only the compute plan distinguishes "fast on ANE" from
    "accidentally on CPU and fine on a Mac".
    """
    import coremltools as ct
    from coremltools.models.compute_plan import MLComputePlan

    # MLComputePlan reads a COMPILED model (.mlmodelc), not the .mlpackage. Compiling here
    # rather than relying on an implicit conversion, because the compiled form is also what
    # the app embeds, so this measures the artifact that actually ships.
    compiled = compile_package(package)
    plan = MLComputePlan.load_from_path(str(compiled), compute_units=ct.ComputeUnit.ALL)
    struct = plan.model_structure
    program = getattr(struct, "program", None)
    if program is None:
        raise RuntimeError("compute plan carries no mlprogram structure")

    res = Placement()
    for _fname, func in program.functions.items():
        for op in func.block.operations:
            usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
            if usage is None:
                continue  # const and other no-compute ops
            res.total += 1
            dev = type(usage.preferred_compute_device).__name__
            key = {"MLNeuralEngineComputeDevice": "ANE",
                   "MLGPUComputeDevice": "GPU",
                   "MLCPUComputeDevice": "CPU"}.get(dev, dev)
            res.counts[key] = res.counts.get(key, 0) + 1
            supported = {
                type(d).__name__ for d in (usage.supported_compute_devices or [])
            }
            if "MLNeuralEngineComputeDevice" not in supported:
                res.unsupported_by_ane.append(getattr(op, "operator_name", str(op)))
    return res


# --- 3. parity ----------------------------------------------------------------------------


def _reference_crops(n: int, seed: int = 21) -> tuple[list[Image.Image], list[str]]:
    """Real corpus images, put through the exact preprocessing the app will do."""
    import polars as pl

    from bench import manifest

    mf = manifest.read().sample(n, seed=seed)
    tf_resize = commfor.build_transform().transforms[0]
    tf_crop = commfor.build_transform().transforms[1]
    crops, ids = [], []
    for r in mf.iter_rows(named=True):
        try:
            im = Image.open(paths.data_root() / r["path"])
            im.load()
            crops.append(tf_crop(tf_resize(im.convert("RGB"))))
            ids.append(str(r["id"]))
        except Exception:
            continue
    return crops, ids


def parity(variant: str, package: Path, *, n: int = 64) -> dict:
    """Compare Core ML logits against PyTorch on identical 384x384 crops.

    Agreement is reported at the CALIBRATED boundary, not at zero, because that is the
    threshold the product uses and a systematic offset there is what would actually change a
    verdict.
    """
    import coremltools as ct

    det = commfor.CommForFrontierDetector(variant=variant, device="cpu")
    thr = det.decision_threshold
    crops, ids = _reference_crops(n)
    if not crops:
        raise RuntimeError("no reference images available for parity")

    to_tensor = commfor.build_transform().transforms[2]
    normalise = commfor.build_transform().transforms[3]
    with torch.no_grad():
        batch = torch.stack([normalise(to_tensor(c)) for c in crops])
        torch_logits = det.model(batch).squeeze(-1).numpy().astype(np.float64)

    mlmodel = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.ALL)
    coreml_logits = np.array(
        [float(np.asarray(mlmodel.predict({INPUT_NAME: c})[OUTPUT_NAME]).reshape(-1)[0])
         for c in crops],
        dtype=np.float64,
    )

    delta = coreml_logits - torch_logits
    agree = (coreml_logits >= thr) == (torch_logits >= thr)
    # Rank agreement matters more than absolute drift for AUC, which is rank-only.
    from scipy.stats import spearmanr

    rho = float(spearmanr(coreml_logits, torch_logits).statistic)
    return {
        "n": len(crops),
        "max_abs_delta": float(np.abs(delta).max()),
        "mean_abs_delta": float(np.abs(delta).mean()),
        "bias": float(delta.mean()),
        "spearman_rho": rho,
        "decision_agreement": float(agree.mean()),
        "disagreements": [
            {"id": ids[i], "torch": float(torch_logits[i]), "coreml": float(coreml_logits[i])}
            for i in np.flatnonzero(~agree)[:8]
        ],
        "threshold": thr,
    }


# --- latency (Mac-relative only) -----------------------------------------------------------


def latency(package: Path, *, units: str = "ALL", n: int = 40) -> dict:
    """Mac-side latency. Indicative ONLY.

    PLAN.md is explicit that M3 Pro milliseconds are not iPhone milliseconds. This is here to
    compare compute-unit configurations against each other on one machine, which is a valid
    relative signal, and to catch an order-of-magnitude regression. Absolute on-device numbers
    require a tethered Xcode Performance Report.
    """
    import coremltools as ct

    mlmodel = ct.models.MLModel(str(package), compute_units=getattr(ct.ComputeUnit, units))
    img = Image.fromarray(
        np.random.default_rng(3).integers(0, 255, (commfor.CROP, commfor.CROP, 3), dtype=np.uint8)
    )
    for _ in range(5):
        mlmodel.predict({INPUT_NAME: img})
    t = time.perf_counter()
    for _ in range(n):
        mlmodel.predict({INPUT_NAME: img})
    el = time.perf_counter() - t
    return {"units": units, "ms_per_image": round(1000 * el / n, 2)}
