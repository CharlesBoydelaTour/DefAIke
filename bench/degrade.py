"""Degradation simulation: the AncesTree ladder plus an iOS screenshot profile.

This module is load-bearing for the whole benchmark, not a robustness nicety. Measured on
the resolved corpus, image resolution ALONE separates real from fake at 63.1% accuracy —
21.5% of fakes are exactly 1024x1024 against 0.2% of reals, because generators emit fixed
canvases and cameras do not. Any detector scored on native-resolution images can post a
respectable number by learning canvas dimensions, which transfers to production as nothing.
Degrading inputs is what makes a score mean something.

Primitive operations and their sampling distributions reproduce the published AncesTree
implementation (Guillaro et al., QuAD, APAI Workshop @ CVPR 2026), so calibration fitted
here stays comparable with their released numbers. Parameters taken from their
`ancestree_utils.py`:

  - pipeline is [crop, resize, compress] with inclusion probabilities [0.5, 0.6, 0.95],
    applied in that fixed order; if none is drawn, one is chosen weighted by those same
    probabilities
  - crop reduces ONE side only, chosen 50/50, never below 256 px, with the offset drawn
    from a Gaussian centred on the centre (sigma = slack/4) rather than uniformly
  - crop ratio = clip(100 * exp(-Exponential(1/11.53)), 60, 99.9), so mild crops dominate
  - resize targets the SHORTER side at a uniform integer in [256, 2048], via Pillow or
    OpenCV with a randomly chosen interpolation
  - compression quality factors are drawn from ReWIND_QFs.npy, the empirical distribution
    measured from real in-the-wild images (8,599 samples, mean 83.9, median 85), with
    encoders weighted [0.47 Pillow JPEG, 0.46 OpenCV JPEG, 0.07 Pillow WebP]

Two things here are ours, not theirs: the fixed named rungs (AncesTree samples a random
tree, which is right for fitting calibration but useless for reporting "accuracy at
degradation level N"), and the iOS screenshot profile.
"""

from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

import cv2
import numpy as np
from PIL import Image

from bench import net, paths

# --- AncesTree published constants -------------------------------------------------

CROP_LAMBDA = 11.53
CROP_CLIP = (60.0, 99.9)
CROP_MIN_SIDE = 256
RESIZE_RANGE = (256, 2048)
PIPELINE_PROBS = {"crop": 0.5, "resize": 0.6, "compress": 0.95}
ENCODER_WEIGHTS = {"piljpg": 0.47, "cv2jpg": 0.46, "pilwebp": 0.07}
# The published CSVs add +4 to recorded QF for WebP to offset its better efficiency.
WEBP_QF_OFFSET = 4

QF_URL = (
    "https://raw.githubusercontent.com/grip-unina/QuAD/main/"
    "datasets/AncesTree/code/ReWIND_QFs.npy"
)

PIL_INTERP = [Image.BILINEAR, Image.BICUBIC, Image.LANCZOS]
CV2_INTERP = [cv2.INTER_LINEAR, cv2.INTER_CUBIC, cv2.INTER_LANCZOS4]

_qf_cache: np.ndarray | None = None


def empirical_qfs() -> np.ndarray:
    """The measured real-world QF distribution. Fetched on demand, not vendored.

    Kept out of the repo deliberately: it is GRIP-UNINA non-commercially licensed, and the
    repo stays free of non-commercial artifacts even though the project's licence position
    permits their use.
    """
    global _qf_cache
    if _qf_cache is None:
        dest = paths.cache_dir() / "ReWIND_QFs.npy"
        if not dest.exists():
            net.download(QF_URL, dest, label="ReWIND_QFs.npy")
        _qf_cache = np.load(dest)
    return _qf_cache


# --- primitives ---------------------------------------------------------------------


@dataclass
class OpResult:
    image: Image.Image
    encoded: bytes | None  # raw codec output when the op was a compression
    info: dict


def crop_one_side(img: Image.Image, factor: float, rng: np.random.Generator) -> OpResult:
    """Reduce one dimension by `factor`, offset drawn near the centre.

    Matches AncesTree: only one side shrinks, never below 256 px, and the offset is
    Gaussian around the centre with sigma = slack/4 rather than uniform. The Gaussian
    matters — uniform offsets would over-represent edge crops, which have different
    statistics from the centre crops people actually make.
    """
    w, h = img.size
    if rng.random() < 0.5:
        w_fact, h_fact, side = factor, 1.0, "w"
    else:
        w_fact, h_fact, side = 1.0, factor, "h"

    new_w = max(int(w * w_fact), min(w, CROP_MIN_SIDE))
    new_h = max(int(h * h_fact), min(h, CROP_MIN_SIDE))

    mu_left, mu_top = (w - new_w) / 2.0, (h - new_h) / 2.0
    left = int(np.clip(rng.normal(mu_left, mu_left / 4.0 or 1e-9), 0, w - new_w))
    top = int(np.clip(rng.normal(mu_top, mu_top / 4.0 or 1e-9), 0, h - new_h))

    out = img.crop((left, top, left + new_w, top + new_h))
    return OpResult(
        out,
        None,
        {
            "op": "crop",
            "factor": factor,
            "actual_factor": min(new_w / w, new_h / h),
            "cropped_side": side,
            "box": (left, top, left + new_w, top + new_h),
            "before_size": (w, h),
            "after_size": (new_w, new_h),
        },
    )


def resize_shorter(
    img: Image.Image,
    size: int,
    backend: Literal["pil", "cv2"] = "pil",
    interp: int | None = None,
    rng: np.random.Generator | None = None,
) -> OpResult:
    """Scale so the SHORTER side becomes `size`, preserving aspect ratio.

    Note this is an unconditional resize, not a downscale-only: AncesTree draws the target
    from [256, 2048] regardless of input size, so small images get upscaled. That is
    deliberate on their part and it is what real re-posting does.
    """
    w, h = img.size
    if h < w:
        new = (int(w * size / h), size)
    else:
        new = (size, int(h * size / w))

    if backend == "cv2":
        if interp is None:
            interp = int(rng.choice(CV2_INTERP)) if rng is not None else cv2.INTER_LINEAR
        arr = cv2.resize(np.asarray(img, dtype=np.uint8), new, interpolation=interp)
        out = Image.fromarray(arr)
    else:
        if interp is None:
            interp = int(rng.choice(PIL_INTERP)) if rng is not None else Image.BILINEAR
        out = img.resize(new, interp)

    return OpResult(
        out,
        None,
        {
            "op": "resize",
            "backend": backend,
            "target_shorter": size,
            "interpolation": int(interp),
            "before_size": (w, h),
            "after_size": new,
        },
    )


def encode_jpeg(img: Image.Image, qf: int, backend: Literal["pil", "cv2"] = "pil") -> OpResult:
    """JPEG round-trip. The two backends differ at equal QF, which is why both exist."""
    if backend == "cv2":
        bgr = np.asarray(img.convert("RGB"), dtype=np.uint8)[:, :, ::-1]
        ok, buf = cv2.imencode(".jpg", bgr, [int(cv2.IMWRITE_JPEG_QUALITY), int(qf)])
        if not ok:
            raise RuntimeError("cv2 JPEG encode failed")
        raw = buf.tobytes()
        dec = cv2.imdecode(np.frombuffer(raw, np.uint8), cv2.IMREAD_COLOR)
        out = Image.fromarray(dec[:, :, ::-1])
    else:
        with io.BytesIO() as bio:
            img.convert("RGB").save(bio, format="JPEG", quality=int(qf))
            raw = bio.getvalue()
        out = Image.open(io.BytesIO(raw))
        out.load()

    return OpResult(out, raw, {"op": "compress", "format": "jpeg", "qf": int(qf), "backend": backend})


def encode_webp(img: Image.Image, qf: int) -> OpResult:
    with io.BytesIO() as bio:
        img.convert("RGB").save(bio, format="WEBP", quality=int(qf))
        raw = bio.getvalue()
    out = Image.open(io.BytesIO(raw))
    out.load()
    # Recorded QF carries the published +4 WebP offset; the encoder still gets the raw qf.
    return OpResult(
        out,
        raw,
        {"op": "compress", "format": "webp", "qf": int(qf),
         "recorded_qf": int(qf) + WEBP_QF_OFFSET, "backend": "pil"},
    )


def encode_png(img: Image.Image) -> OpResult:
    """Lossless. Used by the screenshot profile, because iOS screenshots are PNG."""
    with io.BytesIO() as bio:
        img.convert("RGB").save(bio, format="PNG")
        raw = bio.getvalue()
    out = Image.open(io.BytesIO(raw))
    out.load()
    return OpResult(out, raw, {"op": "compress", "format": "png", "qf": 200, "backend": "pil"})


# --- AncesTree-faithful random sampling ---------------------------------------------


def sample_pipeline(rng: np.random.Generator) -> list[dict]:
    """Draw one AncesTree branch pipeline. Order is always crop -> resize -> compress."""
    order = ["crop", "resize", "compress"]
    chosen = [o for o in order if rng.random() < PIPELINE_PROBS[o]]
    if not chosen:
        probs = np.array([PIPELINE_PROBS[o] for o in order], dtype=float)
        chosen = [order[int(rng.choice(len(order), p=probs / probs.sum()))]]

    ops: list[dict] = []
    for op in chosen:
        if op == "crop":
            y = rng.exponential(1.0 / CROP_LAMBDA)
            ratio = float(np.clip(100.0 * np.exp(-y), *CROP_CLIP))
            ops.append({"op": "crop", "factor": round(ratio / 100.0, 3)})
        elif op == "resize":
            ops.append({
                "op": "resize",
                "size": int(rng.integers(RESIZE_RANGE[0], RESIZE_RANGE[1] + 1)),
                "backend": "cv2" if rng.random() < 0.5 else "pil",
            })
        else:
            qfs = empirical_qfs()
            names = list(ENCODER_WEIGHTS)
            weights = np.array([ENCODER_WEIGHTS[n] for n in names], dtype=float)
            enc = names[int(rng.choice(len(names), p=weights / weights.sum()))]
            ops.append({
                "op": "compress",
                "qf": int(rng.choice(qfs)),
                "encoder": enc,
            })
    return ops


def apply_ops(img: Image.Image, ops: list[dict], rng: np.random.Generator) -> OpResult:
    """Apply a pipeline, returning the final image plus the last codec output."""
    cur, encoded, infos = img, None, []
    for spec in ops:
        kind = spec["op"]
        if kind == "crop":
            res = crop_one_side(cur, spec["factor"], rng)
        elif kind == "resize":
            res = resize_shorter(cur, spec["size"], spec.get("backend", "pil"),
                                 spec.get("interp"), rng)
        elif kind == "compress":
            enc = spec.get("encoder", "piljpg")
            if enc == "pilwebp":
                res = encode_webp(cur, spec["qf"])
            elif enc == "png":
                res = encode_png(cur)
            else:
                res = encode_jpeg(cur, spec["qf"], "cv2" if enc == "cv2jpg" else "pil")
        else:
            raise ValueError(f"unknown op {kind!r}")
        cur = res.image
        encoded = res.encoded if res.encoded is not None else encoded
        infos.append(res.info)
    return OpResult(cur, encoded, {"ops": infos})


# --- deterministic benchmark rungs --------------------------------------------------
#
# AncesTree samples a random tree, which is what calibration fitting wants but not what
# reporting wants. A benchmark needs to say "accuracy at rung N", so rungs are fixed.
# Quality factors below are anchored on the empirical distribution: QF 95 is roughly its
# top decile, 85 the median, 75 the tenth percentile.


@dataclass(frozen=True)
class Rung:
    name: str
    ops: tuple[dict, ...]
    note: str = ""
    # True when the rung can leave image dimensions unchanged. Such rungs do NOT remove
    # the resolution shortcut, so their scores carry the same caveat as `clean` and the
    # metrics layer flags them rather than letting a reader assume they are clean of it.
    resolution_preserving: bool = False

    @property
    def is_clean(self) -> bool:
        return not self.ops


# A note on `moderate`, because the first version of this ladder had a bug worth recording.
# It resized the SHORTER side to 1024, which is a no-op on a 1024x1024 image — and 21.5% of
# our fakes are exactly 1024x1024. The rung intended to destroy the resolution tell left it
# perfectly intact. Every rung that claims to remove it now includes a crop, which changes
# one dimension unconditionally, and target sizes avoid common generator canvases.
LADDER: tuple[Rung, ...] = (
    Rung("clean", (),
         "as fetched; carries the resolution shortcut, never a headline number",
         resolution_preserving=True),
    Rung("light", ({"op": "compress", "qf": 95, "encoder": "piljpg"},),
         "pure re-encode at a high real-world QF. Deliberately preserves dimensions: "
         "a platform that re-encodes without resizing is a real condition, but it means "
         "the resolution shortcut survives here too",
         resolution_preserving=True),
    Rung("moderate", (
        {"op": "crop", "factor": 0.94},
        {"op": "resize", "size": 896, "backend": "pil"},
        {"op": "compress", "qf": 85, "encoder": "piljpg"},
    ), "mild crop, downscale to a non-generator size, median-QF re-encode; "
       "one round of typical re-posting"),
    Rung("heavy", (
        {"op": "crop", "factor": 0.90},
        {"op": "resize", "size": 640, "backend": "cv2"},
        {"op": "compress", "qf": 75, "encoder": "cv2jpg"},
    ), "crop, downscale and QF at the ~10th percentile; several rounds of re-posting"),
    Rung("severe", (
        {"op": "crop", "factor": 0.75},
        {"op": "resize", "size": 384, "backend": "cv2"},
        {"op": "compress", "qf": 60, "encoder": "cv2jpg"},
        {"op": "resize", "size": 768, "backend": "pil"},
        {"op": "compress", "qf": 70, "encoder": "piljpg"},
    ), "downscale-then-upscale with two compressions; the abstention band should catch these"),
    # Added after the first real-model run, which showed the rungs above barely move AUC:
    # measured median shorter side is 1024 clean, 896 moderate, 640 heavy, 768 severe, while
    # both candidate detectors resize to 224x224 before inference. Their preprocessing was
    # discarding the degradation along with the resolution. This rung goes BELOW the model
    # input, so information is genuinely destroyed rather than resampled away.
    Rung("thumbnail", (
        {"op": "crop", "factor": 0.85},
        {"op": "resize", "size": 144, "backend": "cv2"},
        {"op": "compress", "qf": 55, "encoder": "cv2jpg"},
    ), "downscaled below a 224 model input, so the detector must upscale; models the "
       "thumbnail and heavily-reposted case that the rungs above cannot reach"),
)

LADDER_BY_NAME = {r.name: r for r in LADDER}


def seed_for(key: str) -> int:
    """Stable per-image seed, so the same image always degrades identically."""
    return int.from_bytes(hashlib.sha256(key.encode()).digest()[:8], "big")


def apply_rung(img: Image.Image, rung: Rung, key: str) -> OpResult:
    """Deterministic for a given (image key, rung)."""
    rng = np.random.default_rng(seed_for(f"{key}:{rung.name}"))
    if rung.is_clean:
        return OpResult(img, None, {"ops": []})
    return apply_ops(img, list(rung.ops), rng)


# --- iOS screenshot profile ---------------------------------------------------------


@dataclass(frozen=True)
class Device:
    """Screen geometry in physical pixels.

    Dimensions are from memory and MUST be confirmed against real hardware; Task 2's
    validation step exists precisely to do that. `content_width_frac` approximates how much
    of the screen width a social feed gives the image itself.
    """

    name: str
    width: int
    height: int
    content_width_frac: float = 1.0
    verified_on_hardware: bool = False


DEVICES: dict[str, Device] = {
    "iphone_se3": Device("iPhone SE (3rd gen)", 750, 1334, 1.0),
    "iphone_14": Device("iPhone 14", 1170, 2532, 1.0),
    "iphone_15_pro": Device("iPhone 15 Pro", 1179, 2556, 1.0),
    "iphone_15_pro_max": Device("iPhone 15 Pro Max", 1290, 2796, 1.0),
    "iphone_16_pro": Device("iPhone 16 Pro", 1206, 2622, 1.0),
    # Feed layouts inset the image; X and Instagram give it most but not all of the width.
    "iphone_15_pro_feed": Device("iPhone 15 Pro (feed inset)", 1179, 2556, 0.92),
}


def screenshot(
    img: Image.Image,
    device: Device,
    *,
    share_reencode_qf: int | None = None,
) -> OpResult:
    """Model the iOS screenshot path.

    The essential point, and one worth stating because it changes what the lane can expect:
    an iOS screenshot is a PNG, so it is LOSSLESS. The damage a screenshot does is pure
    resampling to device width, not compression. Compression only enters when the user
    subsequently shares or uploads the screenshot, which is what `share_reencode_qf` models.

    We render only the image region at its on-screen scale rather than compositing UI
    chrome, because Task 12 crops the region back out before scoring. Modelling chrome we
    would then discard would add nothing but a cropping error to reproduce.
    """
    target_w = max(1, int(device.width * device.content_width_frac))
    w, h = img.size
    scale = target_w / w
    new = (target_w, max(1, int(round(h * scale))))

    # Downscale is the common case and Lanczos is closest to what the compositor does;
    # upscale happens when a small image is shown full width.
    resample = Image.LANCZOS if scale <= 1.0 else Image.BICUBIC
    shown = img.resize(new, resample)

    res = encode_png(shown)
    info = {
        "op": "screenshot",
        "device": device.name,
        "device_px": (device.width, device.height),
        "content_width": target_w,
        "scale": scale,
        "upscaled": scale > 1.0,
        "before_size": (w, h),
        "after_size": new,
        "lossless": True,
        "verified_on_hardware": device.verified_on_hardware,
    }

    if share_reencode_qf is not None:
        res2 = encode_jpeg(res.image, share_reencode_qf, "pil")
        info["shared_qf"] = share_reencode_qf
        info["lossless"] = False
        return OpResult(res2.image, res2.encoded, info)

    return OpResult(res.image, res.encoded, info)


SCREENSHOT_RUNGS: tuple[str, ...] = ("screenshot", "screenshot_shared")

# Rungs that may leave dimensions untouched, and therefore do not clear the resolution
# shortcut. Screenshot rungs always rescale to device width, so they are not on this list.
RESOLUTION_PRESERVING: frozenset[str] = frozenset(
    r.name for r in LADDER if r.resolution_preserving
)


def apply_screenshot_rung(
    img: Image.Image, rung_name: str, device_key: str = "iphone_15_pro_feed"
) -> OpResult:
    device = DEVICES[device_key]
    qf = 85 if rung_name == "screenshot_shared" else None
    return screenshot(img, device, share_reencode_qf=qf)


ALL_RUNGS: tuple[str, ...] = tuple(r.name for r in LADDER) + SCREENSHOT_RUNGS


def degrade(img: Image.Image, rung_name: str, key: str, device_key: str = "iphone_15_pro_feed") -> OpResult:
    """Single entry point over both the synthetic ladder and the screenshot profile."""
    if rung_name in SCREENSHOT_RUNGS:
        return apply_screenshot_rung(img, rung_name, device_key)
    if rung_name not in LADDER_BY_NAME:
        raise KeyError(f"unknown rung {rung_name!r}; have {ALL_RUNGS}")
    return apply_rung(img, LADDER_BY_NAME[rung_name], key)
