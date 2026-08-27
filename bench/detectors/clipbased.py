"""ClipBased-SyntheticImageDetection: CLIP ViT-L/14 with a linear probe.

The plan's ceiling reference and the strongest permissively-licensed academic baseline
(Apache-2.0, "Raising the Bar of AI-generated Image Detection with CLIP"). Also the most
interesting candidate scientifically, because it is exactly the architecture SSAFE and
"Simplicity Prevails" independently found to be state of the art in 2026: a linear head on
frozen foundation-model features.

Everything below is transcribed from the published implementation rather than inferred,
because preprocessing drift is the standard silent failure in these ports and a wrong
resize would quietly cost several AUC points:

  weights/clipdet_latent10k_plus/config.yaml
    arch: opencliplinearnext_clipL14commonpool, norm_type: clip, patch_size: Clip224

  networks/__init__.py
    'opencliplinearnext_' -> OpenClipLinear(normalize=True, next_to_last=True)

  networks/openclipnet.py
    clipL14commonpool -> ViT-L-14 with weights from
      hf_hub_download("laion/CLIP-ViT-L-14-CommonPool.XL-s13B-b90K",
                      "open_clip_pytorch_model.bin")
    next_to_last=True  -> visual.proj = None, so features are 1024-d PRE-projection
    normalize=True     -> encode_image(..., normalize=True), L2-normalised

  main.py
    Resize(224, BICUBIC) -> CenterCrop(224, 224) -> ToTensor -> Normalize(CLIP stats)

Two details that are easy to get wrong. `next_to_last` means the feature width is 1024, not
the 768 of CLIP's projected embedding — which is confirmed by the released head being 5,155
bytes, i.e. 1025 float32 values plus pickle overhead. And `ChannelLinear` on a 2-D input
reduces to a plain `nn.Linear`, so we use one rather than reimplementing the transpose dance.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from PIL import Image
from torchvision.transforms import CenterCrop, Compose, InterpolationMode, Normalize, Resize, ToTensor

from bench import net, paths
from bench.detectors.base import BaseModelDetector, DetectorInfo

REPO = "grip-unina/ClipBased-SyntheticImageDetection"
# The weights are stored via Git LFS, so the raw.githubusercontent path returns a 129-byte
# pointer. The media host serves the real payload.
LFS_BASE = f"https://media.githubusercontent.com/media/{REPO}/main/weights"

VARIANTS = {
    "clipdet_latent10k_plus": "trained on latent-diffusion data plus commercial tools",
    "clipdet_latent10k": "trained on latent-diffusion data only",
    "Corvi2023": "the earlier ResNet-based detector; different architecture, not wired up",
}

OPENCLIP_MODEL = "ViT-L-14"
OPENCLIP_HF_REPO = "laion/CLIP-ViT-L-14-CommonPool.XL-s13B-b90K"
OPENCLIP_HF_FILE = "open_clip_pytorch_model.bin"

CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)
FEATURE_DIM = 1024  # pre-projection width for ViT-L-14


def _device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def build_transform() -> Compose:
    """Exactly the published inference transform."""
    return Compose([
        Resize(224, interpolation=InterpolationMode.BICUBIC),
        CenterCrop((224, 224)),
        ToTensor(),
        Normalize(mean=CLIP_MEAN, std=CLIP_STD),
    ])


def fetch_head(variant: str = "clipdet_latent10k_plus") -> Path:
    dest = paths.cache_dir() / f"clipbased_{variant}_weights.pth"
    if not dest.exists():
        net.download(f"{LFS_BASE}/{variant}/weights.pth", dest, label=f"{variant} head")
    if dest.stat().st_size < 1000:
        raise OSError(
            f"{dest} is {dest.stat().st_size} bytes — that is a Git LFS pointer, not the "
            f"weights. The media.githubusercontent.com host is required."
        )
    return dest


class ClipBasedDetector(BaseModelDetector):
    """Frozen CLIP ViT-L/14 features into a one-dimensional linear probe."""

    def __init__(self, variant: str = "clipdet_latent10k_plus", device: str | None = None):
        if variant not in VARIANTS or variant == "Corvi2023":
            raise ValueError(
                f"variant must be clipdet_latent10k or clipdet_latent10k_plus, got {variant!r}"
            )
        self.variant = variant
        self.device = torch.device(device) if device else _device()
        self.transform = build_transform()

        import open_clip
        from huggingface_hub import hf_hub_download

        ckpt = hf_hub_download(OPENCLIP_HF_REPO, OPENCLIP_HF_FILE)
        backbone = open_clip.create_model(OPENCLIP_MODEL, pretrained=ckpt)
        # next_to_last: drop the projection so features stay 1024-d.
        proj_in = backbone.visual.proj.shape[0]
        backbone.visual.proj = None
        if proj_in != FEATURE_DIM:
            raise RuntimeError(f"expected {FEATURE_DIM}-d features, backbone reports {proj_in}")

        self.backbone = backbone.eval().to(self.device)
        for p in self.backbone.parameters():
            p.requires_grad_(False)

        self.head = nn.Linear(FEATURE_DIM, 1)
        self._load_head(fetch_head(variant))
        self.head = self.head.eval().to(self.device)

        n_backbone = sum(p.numel() for p in self.backbone.visual.parameters())
        self.info = DetectorInfo(
            name=f"clipbased:{variant}",
            kind="torch",
            licence="Apache-2.0",
            commercial=True,
            params=n_backbone + FEATURE_DIM + 1,
            input_resolution=(224, 224),
            source=f"github.com/{REPO}",
            trained_on=(
                "backbone: LAION CommonPool-XL (frozen, not trained by anyone for detection). "
                "probe: latent-diffusion data"
                + (" plus commercial tools" if "plus" in variant else " only")
                + ". No 2026 generators."
            ),
            notes=(
                f"CLIP ViT-L/14 CommonPool frozen, {FEATURE_DIM}-d pre-projection features, "
                f"L2-normalised, into a linear probe. {VARIANTS[variant]}. Image encoder is "
                f"{n_backbone / 1e6:.0f}M params — far too large for a share extension, so this "
                f"is a ceiling reference rather than a shipping candidate."
            ),
        )

    def _load_head(self, path: Path) -> None:
        """Load the 5 KB probe, tolerating the several state-dict shapes upstream emits."""
        dat = torch.load(path, map_location="cpu", weights_only=False)
        state = dat
        for key in ("model", "state_dict", "net"):
            if isinstance(dat, dict) and key in dat:
                state = dat[key]
                break
        if not isinstance(state, dict):
            raise OSError(f"unexpected checkpoint structure in {path}: {type(state)}")

        # Strip DataParallel prefixes and locate the fc weight/bias.
        cleaned = {k[7:] if k.startswith("module.") else k: v for k, v in state.items()}
        weight = next((v for k, v in cleaned.items() if k.endswith("fc.weight")), None)
        bias = next((v for k, v in cleaned.items() if k.endswith("fc.bias")), None)
        if weight is None:
            raise OSError(f"no fc.weight in {path}; keys were {sorted(cleaned)[:10]}")

        with torch.no_grad():
            self.head.weight.copy_(weight.reshape(1, FEATURE_DIM))
            if bias is not None:
                self.head.bias.copy_(bias.reshape(1))
            else:
                self.head.bias.zero_()

    @torch.no_grad()
    def score_batch(self, images: list[Image.Image]) -> list[float]:
        """Positive logit means AI-generated, matching the project-wide convention."""
        if not images:
            return []
        batch = torch.stack([self.transform(im.convert("RGB")) for im in images]).to(self.device)
        feats = self.backbone.encode_image(batch, normalize=True)
        logits = self.head(feats.float()).squeeze(-1)
        return [float(v) for v in logits.detach().cpu().numpy().astype(np.float64)]
