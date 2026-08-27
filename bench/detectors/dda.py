"""DDA — Dual Data Alignment (NeurIPS 2025 Spotlight, Apache-2.0).

The most promising detector found, and it is promising for a reason specific to what we
measured rather than for its headline numbers.

Our diagnosis was that detectors either read high-frequency evidence and lose it to
recompression (Corvi2023: AUC 0.716 -> 0.522 across the ladder), or survive degradation by
resizing to 224 and discarding the evidence along with it (everything else: flat and
mediocre). DDA's training method attacks exactly that. It aligns real and fake in BOTH the
pixel and frequency domains: fake images are VAE reconstructions of real ones, and each
reconstruction is JPEG-compressed online at the quality factor *estimated from its paired
real image*, so compression history cannot act as a shortcut. Their README is explicit that
this step is what makes the frequency alignment work.

Reported in-the-wild results, from the paper's own table:

  benchmark      best prior          DDA
  Chameleon      71.0 (AlignedFor.)  82.4
  Synthwildx     78.8 +/- 17.8       90.9 +/- 3.1
  WildRF         80.1 +/- 10.3       90.3 +/- 3.5

WildRF is the Reddit/X/Facebook set from the LaDeDa work — the closest published proxy to this
app's input distribution, and where AIDE, DRCT, NPR and UnivFD all sit at 50-63%.

Architecture, transcribed from `Inference/inference.py` and `Inference/models/`:
  - DINOv2 ViT-L/14, LoRA rank 8 alpha 1 on ['attn.qkv', 'attn.proj', 'mlp.fc1', 'mlp.fc2']
  - linear head on the CLS token (`x_norm_clstoken`), 1024 -> 1
  - CenterCrop(336) with NO resize, then CLIP normalisation
  - checkpoint under key 'model'

Note the input handling: a 336px centre crop at native resolution, so like Corvi2023 and
B-Free it sees native pixels. Under our resize hypothesis that predicts DDA should be
degradation-sensitive — but its training is built to prevent exactly that, so this is the
first candidate where the two forces oppose each other. That is the interesting measurement.
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from PIL import Image
from torchvision.transforms import CenterCrop, Compose, Normalize, ToTensor

from bench import net, paths
from bench.detectors.base import BaseModelDetector, DetectorInfo

WEIGHTS_REPO = "Junwei-Xi/Dual-Data-Alignment"
WEIGHTS_FILE = "DDA_ckpt.pth"
BACKBONE = "dinov2_vitl14"
FEATURE_DIM = 1024
CROP = 336
LORA_RANK = 8
LORA_ALPHA = 1.0
LORA_TARGETS = ("attn.qkv", "attn.proj", "mlp.fc1", "mlp.fc2")

# Same CLIP statistics the other candidates use, despite the DINOv2 backbone — taken from
# their inference script, not assumed.
CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)


def _device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def build_transform(crop: int = CROP) -> Compose:
    """CenterCrop then normalise. No resize, matching upstream."""
    return Compose([
        CenterCrop(crop),
        ToTensor(),
        Normalize(mean=CLIP_MEAN, std=CLIP_STD),
    ])


class LoRALayer(nn.Module):
    """Low-rank update, reimplemented to match their parameter names so weights load."""

    def __init__(self, in_dim: int, out_dim: int, rank: int = LORA_RANK, alpha: float = LORA_ALPHA):
        super().__init__()
        self.alpha, self.rank = alpha, rank
        self.lora_A = nn.Parameter(torch.zeros((rank, in_dim)))
        self.lora_B = nn.Parameter(torch.zeros((out_dim, rank)))
        nn.init.kaiming_uniform_(self.lora_A, a=math.sqrt(5))
        nn.init.zeros_(self.lora_B)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        h = torch.einsum("...d, rd -> ...r", x, self.lora_A)
        h = torch.einsum("...r, or -> ...o", h, self.lora_B)
        return h * (self.alpha / self.rank)


class LoRALinear(nn.Module):
    def __init__(self, original: nn.Linear, rank: int = LORA_RANK, alpha: float = LORA_ALPHA):
        super().__init__()
        self.original_layer = original
        for p in self.original_layer.parameters():
            p.requires_grad_(False)
        self.lora = LoRALayer(original.in_features, original.out_features, rank, alpha)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.original_layer(x) + self.lora(x)


def _get_submodule(model: nn.Module, name: str) -> nn.Module:
    if not name:
        return model
    cur = model
    for part in name.split("."):
        cur = cur[int(part)] if part.isdigit() else getattr(cur, part)
    return cur


def apply_lora(model: nn.Module, targets: tuple[str, ...] = LORA_TARGETS) -> nn.Module:
    """Wrap every matching nn.Linear. Collected first, since we mutate during iteration.

    Idempotent. A second pass would otherwise re-wrap the `original_layer` inside each
    existing LoRALinear — its name still contains the target substring — producing keys like
    `attn.qkv.original_layer.original_layer.weight` that no published checkpoint matches.
    """
    to_wrap = [
        (n, m) for n, m in model.named_modules()
        if isinstance(m, nn.Linear)
        and any(t in n for t in targets)
        and not n.endswith(".original_layer")
    ]
    for name, module in to_wrap:
        parent_name, _, child = name.rpartition(".")
        setattr(_get_submodule(model, parent_name), child, LoRALinear(module))
    return model


class DDAModel(nn.Module):
    """Mirrors DINOv2ModelWithLoRA so the published state dict loads without remapping."""

    def __init__(self) -> None:
        super().__init__()
        self.base_model = nn.Module()
        # pretrained=False: the 1.26 GB checkpoint carries the full backbone, so downloading
        # DINOv2's own weights first would be wasted bandwidth that we then overwrite.
        backbone = torch.hub.load(
            "facebookresearch/dinov2", BACKBONE, pretrained=False, trust_repo=True, verbose=False
        )
        self.base_model.model = apply_lora(backbone)
        self.base_model.fc = nn.Linear(FEATURE_DIM, 1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        feats = self.base_model.model.forward_features(x)["x_norm_clstoken"]
        return self.base_model.fc(feats)


def fetch_weights() -> Path:
    from huggingface_hub import hf_hub_download

    dest = paths.cache_dir() / WEIGHTS_FILE
    if dest.exists() and dest.stat().st_size > 1_000_000:
        return dest
    got = hf_hub_download(WEIGHTS_REPO, WEIGHTS_FILE)
    return Path(got)


class DDADetector(BaseModelDetector):
    """Positive logit means AI-generated, matching the project-wide convention."""

    def __init__(self, device: str | None = None, crop: int = CROP):
        self.device = torch.device(device) if device else _device()
        self.transform = build_transform(crop)
        self.crop = crop
        self.model = DDAModel()

        ckpt = torch.load(fetch_weights(), map_location="cpu", weights_only=False)
        state = ckpt.get("model", ckpt) if isinstance(ckpt, dict) else ckpt
        state = {k[7:] if k.startswith("module.") else k: v for k, v in state.items()}
        missing, unexpected = self.model.load_state_dict(state, strict=False)
        # LoRA B matrices initialise to zero, so a silently unloaded adapter would leave the
        # model as a plain frozen DINOv2 and look merely weak rather than broken.
        if missing:
            raise OSError(f"checkpoint missing {len(missing)} key(s); first: {missing[:5]}")

        self.model = self.model.eval().to(self.device)
        n_params = sum(p.numel() for p in self.model.parameters())

        self.info = DetectorInfo(
            name="dda:dinov2-lora",
            kind="torch",
            licence="Apache-2.0",
            commercial=True,
            params=n_params,
            input_resolution=(crop, crop),
            source="github.com/roy-ch/Dual-Data-Alignment",
            notes=(
                f"DINOv2 ViT-L/14 + LoRA r={LORA_RANK}, {n_params / 1e6:.0f}M params, "
                f"CenterCrop({crop}) with NO resize. NeurIPS 2025 Spotlight. Reports 90.3% on "
                f"WildRF and 82.4% on Chameleon, both roughly 10-20 points above the prior "
                f"best, so this is the first candidate whose published in-the-wild numbers "
                f"would be good enough for the product if they hold up."
            ),
            trained_on=(
                "DDA-COCO: real COCO images paired with their own VAE reconstructions as "
                "fakes, each reconstruction JPEG-compressed at the quality factor estimated "
                "from its paired real image so compression history cannot be a shortcut. "
                "No 2026 generators in training — generalisation is the claim."
            ),
        )

    @torch.no_grad()
    def score_batch(self, images: list[Image.Image]) -> list[float]:
        if not images:
            return []
        batch = torch.stack([self.transform(im.convert("RGB")) for im in images]).to(self.device)
        logits = self.model(batch).squeeze(-1)
        return [float(v) for v in logits.detach().cpu().numpy().astype(np.float64)]
