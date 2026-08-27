"""Generic adapter for HuggingFace image-classification detectors.

Several credible detectors ship as plain `AutoModelForImageClassification` checkpoints, so one
adapter covers them all. What varies and must be resolved per model is the label mapping —
getting it backwards inverts the detector silently — so that logic is shared with the SigLIP
adapter rather than duplicated.

Presets below were selected on three criteria: ungated, permissively or non-commercially (not
un-) licensed, and actually used. `Organika/sdxl-detector` has 141k downloads, which makes it
the most widely deployed open AI-image detector found in the survey and therefore the most
meaningful "what people actually run" baseline, whatever its measured quality turns out to be.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import torch
from PIL import Image

from bench.detectors.base import BaseModelDetector, DetectorInfo
from bench.detectors.siglip import resolve_ai_index


@dataclass(frozen=True)
class Preset:
    model_id: str
    licence: str
    commercial: bool
    trained_on: str
    note: str = ""


PRESETS: dict[str, Preset] = {
    "organika": Preset(
        model_id="Organika/sdxl-detector",
        licence="CC-BY-NC-3.0",
        commercial=False,
        trained_on=(
            "Colby/autotrain-data-sdxl-detection. SDXL-era data only; no 2026 generators."
        ),
        note=(
            "Swin. 141k downloads makes it the most widely deployed open detector in the "
            "survey, so its numbers are the practical baseline users are already exposed to."
        ),
    ),
    "dima806": Preset(
        model_id="dima806/ai_vs_human_generated_image_detection",
        licence="Apache-2.0",
        commercial=True,
        trained_on="Undocumented. Fine-tuned from google/vit-base-patch16-224-in21k.",
        note="ViT-base/16 at 224. Permissively licensed and small; a clean-licence comparison "
             "point against the CC-BY-NC and non-commercial candidates.",
    ),
}


def _device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


class HFClassifierDetector(BaseModelDetector):
    """Score is the AI-class logit minus the real-class logit, so positive means AI."""

    def __init__(self, preset: str | None = None, model_id: str | None = None,
                 device: str | None = None):
        from transformers import AutoImageProcessor, AutoModelForImageClassification

        if preset is not None:
            if preset not in PRESETS:
                raise KeyError(f"unknown preset {preset!r}; have {sorted(PRESETS)}")
            cfg = PRESETS[preset]
            model_id = cfg.model_id
        elif model_id is not None:
            cfg = Preset(model_id, "unknown", False, "unknown")
            preset = model_id.split("/")[-1]
        else:
            raise ValueError("pass either preset or model_id")

        self.device = torch.device(device) if device else _device()
        self.processor = AutoImageProcessor.from_pretrained(model_id)
        self.model = AutoModelForImageClassification.from_pretrained(model_id)
        self.model = self.model.eval().to(self.device)

        self.ai_index, self.ai_label = resolve_ai_index(self.model.config.id2label)
        self.real_index = 1 - self.ai_index

        size = getattr(self.processor, "size", None) or {}
        if isinstance(size, dict):
            res = (size.get("height") or size.get("shortest_edge") or 224,
                   size.get("width") or size.get("shortest_edge") or 224)
        else:
            res = (224, 224)
        n_params = sum(p.numel() for p in self.model.parameters())

        self.info = DetectorInfo(
            name=f"hf:{preset}",
            kind="torch",
            licence=cfg.licence,
            commercial=cfg.commercial,
            params=n_params,
            input_resolution=res,
            source=f"huggingface.co/{model_id}",
            notes=(
                f"{self.model.config.model_type}, {n_params / 1e6:.1f}M params. AI class "
                f"resolved from config as index {self.ai_index} ('{self.ai_label}'). {cfg.note}"
            ),
            trained_on=cfg.trained_on,
        )

    @torch.no_grad()
    def score_batch(self, images: list[Image.Image]) -> list[float]:
        if not images:
            return []
        inputs = self.processor(images=[im.convert("RGB") for im in images], return_tensors="pt")
        inputs = {k: v.to(self.device) for k, v in inputs.items()}
        logits = self.model(**inputs).logits
        margin = logits[:, self.ai_index] - logits[:, self.real_index]
        return [float(v) for v in margin.detach().cpu().numpy().astype(np.float64)]
