"""SigLIP AI-vs-human image classifier (Ateeqq/ai-vs-human-image-detector).

Apache-2.0, ungated, 92.9M parameters, loadable straight through transformers. It matters to
this project less for its accuracy than for its position: at ~93M it is an order of magnitude
smaller than the CLIP ViT-L ceiling and therefore a plausible on-device candidate, so the
gap between the two is the accuracy-per-megabyte question Task 6a has to answer.

Label mapping is read from the model config rather than assumed. Getting it backwards inverts
every score, and the failure is silent — the AUC would simply come out below 0.5 and could be
mistaken for a weak detector rather than a wiring bug. `metrics.compute` warns on sub-chance
AUC as a backstop, but resolving the mapping properly is the fix.
"""

from __future__ import annotations

import numpy as np
import torch
from PIL import Image

from bench.detectors.base import BaseModelDetector, DetectorInfo

MODEL_ID = "Ateeqq/ai-vs-human-image-detector"

# Substrings that identify the AI-generated class in a label string, checked lowercased.
AI_LABEL_HINTS = ("ai", "fake", "synthetic", "generated", "artificial")
REAL_LABEL_HINTS = ("human", "real", "authentic", "natural", "photo")


def _device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def resolve_ai_index(id2label: dict) -> tuple[int, str]:
    """Find which logit index means AI-generated. Raises rather than guessing.

    A wrong answer here silently inverts the detector, so an ambiguous config is a hard
    error: better to fail loudly at load than to publish inverted numbers.
    """
    labels = {int(k): str(v) for k, v in id2label.items()}
    if len(labels) != 2:
        raise ValueError(f"expected a binary classifier, config has {len(labels)} labels: {labels}")

    ai_matches = [i for i, name in labels.items()
                  if any(h in name.lower() for h in AI_LABEL_HINTS)]
    real_matches = [i for i, name in labels.items()
                    if any(h in name.lower() for h in REAL_LABEL_HINTS)]

    # Prefer an unambiguous single match on either side.
    if len(ai_matches) == 1 and len(real_matches) == 1 and ai_matches[0] != real_matches[0]:
        return ai_matches[0], labels[ai_matches[0]]
    if len(ai_matches) == 1:
        return ai_matches[0], labels[ai_matches[0]]
    if len(real_matches) == 1:
        other = [i for i in labels if i != real_matches[0]][0]
        return other, labels[other]

    raise ValueError(
        f"cannot determine which label means AI-generated from {labels}; "
        f"resolve explicitly rather than risking an inverted detector"
    )


class SigLIPDetector(BaseModelDetector):
    """Score = logit(AI) - logit(real), so positive means AI-generated."""

    def __init__(self, model_id: str = MODEL_ID, device: str | None = None):
        from transformers import AutoImageProcessor, AutoModelForImageClassification

        self.device = torch.device(device) if device else _device()
        self.processor = AutoImageProcessor.from_pretrained(model_id)
        self.model = AutoModelForImageClassification.from_pretrained(model_id)
        self.model = self.model.eval().to(self.device)

        self.ai_index, self.ai_label = resolve_ai_index(self.model.config.id2label)
        self.real_index = 1 - self.ai_index

        size = getattr(self.processor, "size", None) or {}
        res = (size.get("height", 224), size.get("width", 224)) if isinstance(size, dict) else (224, 224)
        n_params = sum(p.numel() for p in self.model.parameters())

        self.info = DetectorInfo(
            name="siglip:ai-vs-human",
            kind="torch",
            licence="Apache-2.0",
            commercial=True,
            params=n_params,
            input_resolution=res,
            source=f"huggingface.co/{model_id}",
            trained_on=(
                "UNDOCUMENTED. The model card states no dataset, so we cannot say which "
                "generators it has seen or whether our evaluation corpus overlaps its "
                "training set. Treat its numbers with that caveat."
            ),
            notes=(
                f"SigLIP binary classifier, {n_params / 1e6:.1f}M params. AI class resolved "
                f"from config as index {self.ai_index} ('{self.ai_label}'). Score is the "
                f"logit difference, so it is a genuine two-sided margin rather than a "
                f"single-class probability."
            ),
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
