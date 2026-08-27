"""Community Forensics frontier detector, August 2026 (MIT).

The first detector found that was trained on the generators this project actually fails on.
Its training manifest names `gpt-image-2`, `nano-banana-2`, `nano-banana-pro`, `FLUX.2-pro`,
`Seedream-5.0`, `Imagen-4.0-Ultra`, `Qwen-Image-2.0-pro`, `HunyuanImage-3.0` and
`Z-Image-Turbo` among 42 frontier buckets — 40,101 frontier images on top of a 73,371-row
legacy corpus. Every other candidate measured here saw 2019-2022 data at best, which is the
structural reason they are blind to GPT-image; this one is the test of whether that
explanation is right.

It is also the first candidate that could plausibly ship. `vit_small_patch16_384` is ~22M
parameters and the released FP16 ONNX is 43.8 MB, against ClipBased's 303M and DDA's 307M.

Provenance and skepticism, both of which matter here:

  - It is an INDEPENDENT fine-tune of the MIT-licensed `OwensLab/commfor-model-384`
    (Community Forensics, CVPR 2025), explicitly "not an official OwensLab release". Not
    peer-reviewed.
  - Its published numbers (clean BA 0.9568, web 0.9385, hard 0.9047) are development and
    calibration results. The card says so plainly, and also that the calibration set was used
    for checkpoint selection, so they are optimistic.
  - The card publishes its FAILED robustness gates rather than hiding them: worst declared
    attack BA 0.5100 on a 5%-synthetic-composite condition, minimum critical fake recall
    0.0492, per-image worst-of-all-attacks BA 0.2766. That candour is a mark in its favour,
    and the composite weakness is out of scope for v0 anyway (localized editing is excluded).

CONTAMINATION, checked before trusting any result. Its manifest was searched for every
corpus we evaluate on:

  So-Fake-OOD   absent  -> our 4,000-image 2026-generator slice is CLEAN
  ReWIND / QuAD absent  -> our 5,582-image in-the-wild slice is CLEAN
  OpenFake      PRESENT -> `openfaketiny_reddit` is CONTAMINATED and must be excluded

Its GPT-image-2 images therefore came from a different collection than ours, which makes a
strong result within-generator generalisation rather than memorisation.

Unlike every other detector here it ships a CALIBRATED decision boundary at raw logit
1.359375 (probability 0.65), not zero. Our `fpr_at_zero` metric would misrepresent it, so the
boundary is exposed as `decision_threshold` for the metrics layer to use.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from torchvision.transforms import CenterCrop, Compose, InterpolationMode, Normalize, Resize, ToTensor

from bench.detectors.base import BaseModelDetector, DetectorInfo

REPO = "Thermostatic/community-forensics-frontier-detector-2026-08"
TIMM_ARCH = "vit_small_patch16_384"
RESIZE_SHORT_EDGE = 440
CROP = 384
# ImageNet statistics, per config.json — not CLIP's, despite several neighbours using those.
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)
# Published calibrated boundary. Positive-going, so >= means AI-generated.
DECISION_THRESHOLD = 1.359375
CONTAMINATED_SLICES = ("openfaketiny_reddit",)

# Two releases, one day apart, same architecture and IDENTICAL preprocessing (both declare
# `resize_short_edge: 440`, `input_size: 384`, ImageNet stats, `single_raw_logit`). The
# low-quality variant is a further fine-tune OF the frontier detector, not a parallel sibling
# from the shared base — so it is strictly downstream and can only be judged against it.
#
# The identical `resize_short_edge` is the important detail for routing: the low-quality model
# does NOT accept smaller inputs. It upscales sub-440px images exactly as the frontier model
# does, and was trained to tolerate the resulting artifacts. So a router would not be choosing
# between input resolutions, only between two sets of weights over the same 384px tensor.
VARIANTS: dict[str, dict] = {
    "frontier": {
        "repo": REPO,
        "name": "commfor:frontier-2026-08",
        "label": "frontier 2026-08",
        "fallback_threshold": DECISION_THRESHOLD,
    },
    "lowq": {
        "repo": "Thermostatic/community-forensics-low-quality-detector-2026-08",
        "name": "commfor:lowq-2026-08",
        "label": "low-quality 2026-08",
        "fallback_threshold": 1.390625,
    },
}


def _device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def build_transform() -> Compose:
    """Resize short edge to 440, centre-crop 384, ImageNet normalise. Per config.json."""
    return Compose([
        Resize(RESIZE_SHORT_EDGE, interpolation=InterpolationMode.BILINEAR),
        CenterCrop(CROP),
        ToTensor(),
        Normalize(mean=MEAN, std=STD),
    ])


def fetch_assets(repo: str = REPO) -> tuple[Path, dict]:
    from huggingface_hub import hf_hub_download

    weights = Path(hf_hub_download(repo, "model.safetensors"))
    cfg = json.loads(Path(hf_hub_download(repo, "config.json")).read_text())
    return weights, cfg


class CommForFrontierDetector(BaseModelDetector):
    """Positive logit means AI-generated, matching the project-wide convention."""

    def __init__(self, variant: str = "frontier", device: str | None = None):
        import timm
        from safetensors.torch import load_file

        if variant not in VARIANTS:
            raise KeyError(f"unknown commfor variant {variant!r}; have {sorted(VARIANTS)}")
        spec = VARIANTS[variant]
        self.variant = variant

        weights, cfg = fetch_assets(spec["repo"])
        self.device = torch.device(device) if device else _device()
        self.transform = build_transform()
        self.decision_threshold = float(
            cfg.get("raw_logit_boundary", spec["fallback_threshold"])
        )

        # Both variants must agree with the shared transform, or the router would be comparing
        # scores computed over different tensors. Checked rather than assumed.
        if cfg.get("resize_short_edge") not in (None, RESIZE_SHORT_EDGE):
            raise ValueError(
                f"{variant} declares resize_short_edge={cfg['resize_short_edge']}, "
                f"transform uses {RESIZE_SHORT_EDGE}"
            )
        if cfg.get("input_size") not in (None, CROP):
            raise ValueError(
                f"{variant} declares input_size={cfg['input_size']}, transform crops {CROP}"
            )

        if cfg.get("id2label", {}).get("1") != "ai_generated":
            raise ValueError(f"unexpected label mapping {cfg.get('id2label')}; sign may invert")

        self.model = timm.create_model(TIMM_ARCH, num_classes=1, pretrained=False)
        state = load_file(str(weights))
        state = {k[len("model."):] if k.startswith("model.") else k: v for k, v in state.items()}
        missing, unexpected = self.model.load_state_dict(state, strict=False)
        if missing:
            raise OSError(f"checkpoint missing {len(missing)} key(s); first: {missing[:5]}")

        self.model = self.model.eval().to(self.device)
        n_params = sum(p.numel() for p in self.model.parameters())

        lowq_note = (
            ""
            if variant == "frontier"
            else (
                " LOW-QUALITY VARIANT: a further fine-tune of the frontier detector "
                "(base_revision 16db1352), released one day later. Same 440/384 preprocessing, "
                "so it does not take smaller inputs — it was trained to tolerate the upscaling. "
                "Its config declares `redteam_validation_valid: false`, so its red-team report "
                "does not stand; only `low_quality_promotion_passed` does."
            )
        )
        self.info = DetectorInfo(
            name=spec["name"],
            kind="torch",
            licence="MIT",
            commercial=True,
            params=n_params,
            input_resolution=(CROP, CROP),
            source=f"huggingface.co/{spec['repo']}",
            notes=(
                f"{TIMM_ARCH}, {n_params / 1e6:.1f}M params, 43.8 MB FP16 ONNX released. "
                f"Ships a CALIBRATED boundary at raw logit {self.decision_threshold} "
                f"(p=0.65), so FPR at logit 0 understates it. Independent fine-tune of "
                f"OwensLab/commfor-model-384, not peer-reviewed; its published numbers are "
                f"development results on a calibration set also used for checkpoint "
                f"selection. Its manifest includes OpenFake, so `openfaketiny_reddit` is "
                f"contaminated; So-Fake-OOD and ReWIND are not.{lowq_note}"
            ),
            trained_on=(
                "73,371-row legacy forensic corpus + 40,101 frontier images from 42 buckets "
                "INCLUDING gpt-image-2, nano-banana-2/pro, FLUX.2-pro, Seedream-4/5, "
                "Imagen-4.0-Ultra, Qwen-Image-2.0-pro, HunyuanImage-3.0, Z-Image-Turbo. "
                "Reals from COCO, OpenFake(LAION/Pexels), ImageNet, WikiArt. The only "
                "candidate here trained on post-April-2026 generators."
            ),
        )

    @torch.no_grad()
    def score_batch(self, images: list[Image.Image]) -> list[float]:
        if not images:
            return []
        batch = torch.stack([self.transform(im.convert("RGB")) for im in images]).to(self.device)
        logits = self.model(batch).squeeze(-1)
        return [float(v) for v in logits.detach().cpu().numpy().astype(np.float64)]

    def scores_for(self, rows, rung: str, *, workers: int | None = None):
        """Refuse to score slices this model may have trained on.

        Enforced here rather than left to the caller. OpenFake appears in its training
        manifest, so any `openfaketiny_reddit` number would be a train-on-test result — and a
        flattering one, which is exactly the kind that survives review. Returning NaN makes
        the exclusion structural: the runner drops those rows and reports the reduced coverage.
        """
        import numpy as np
        import polars as pl

        out = super().scores_for(rows, rung, workers=workers)
        if "slice" in rows.columns:
            blocked = rows["slice"].is_in(list(CONTAMINATED_SLICES)).to_numpy()
            out = np.where(blocked, np.nan, out)
        return out
