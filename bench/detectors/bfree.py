"""B-Free: bias-free training paradigm (grip-unina, CVPR 2025).

The best-performing detector in our reference table by a wide margin — AUC 0.9330,
TPR@1%FPR 0.729, and an FPR at the natural threshold of 1.0%, the only acceptable value we
have measured. But that number is the authors' own run on one corpus at one degradation rung,
on data that is 56% their own collection. This adapter exists to replace it with a
measurement: B-Free across the 2026 generators and all eight rungs.

Architecture, transcribed from `code/networks/wrapper5crops.py`. It is unlike the other
candidates and the difference is the point:

  - timm DINOv2 ViT with four registers, `set_input_size(img_size=504)`
  - NO resize and NO crop in the transform. `Compose(get_list_norm(norm_type))` is
    normalisation only, so the native image goes straight in.
  - the patch-embedding convolution is applied ONCE over the whole image, then FIVE
    36x36 token windows (centre, and the four corners) are cut out of the resulting token
    grid, batched together, run through the transformer, and averaged.

So the 5-crop test-time augmentation happens in embedding space, not pixel space. That is
what lets it accept arbitrary input sizes without resizing, and it is why B-Free is the one
detector here that sees native-resolution detail. Our measured finding that 224-input models
are insensitive to the degradation ladder predicts B-Free should be the most
degradation-SENSITIVE of the three. That prediction is the reason to run it.

Cost, for the same reason: five transformer passes over 1296 tokens each, and the released
code has no batch support. Expect it to be far slower than ClipBased's single 224 pass, and
note that ClipBased is already far too heavy for a share extension. B-Free is a ceiling
reference and a source of training-recipe ideas, not a shipping candidate.
"""

from __future__ import annotations

import zipfile
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from PIL import Image
from torchvision.transforms import Compose, Normalize, ToTensor

from bench import net, paths
from bench.detectors.base import BaseModelDetector, DetectorInfo

WEIGHTS_URL = "https://www.grip.unina.it/download/prog/B-Free/weights/BFREE_dino2reg4.zip"
WEIGHTS_MD5 = "f3f53fa647848b16cf81c913f148a198"
MODEL_DIR = "BFREE_dino2reg4"
PATCH_SIZE = 504

NORMS = {
    "clip": ((0.48145466, 0.4578275, 0.40821073), (0.26862954, 0.26130258, 0.27577711)),
    "resnet": ((0.485, 0.456, 0.406), (0.229, 0.224, 0.225)),
    "xception": ((0.5, 0.5, 0.5), (0.5, 0.5, 0.5)),
}


def _device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def build_transform(norm_type: str) -> Compose:
    """Normalisation only. No resize, no crop — that is the whole design."""
    if norm_type == "none":
        return Compose([ToTensor()])
    if norm_type not in NORMS:
        raise ValueError(f"unknown norm_type {norm_type!r}; have {sorted(NORMS) + ['none']}")
    mean, std = NORMS[norm_type]
    return Compose([ToTensor(), Normalize(mean=mean, std=std)])


def fetch_weights() -> Path:
    """Download and unpack, verifying the published MD5.

    The MD5 check is not ceremonial here. The single distribution host returns an 11,939-byte
    HTML error page under load, which a naive download accepts as success and which then fails
    obscurely at `torch.load`. Verifying turns that into a clear message.
    """
    out_dir = paths.cache_dir() / MODEL_DIR
    if (out_dir / "config.yaml").exists():
        return out_dir

    archive = paths.cache_dir() / "BFREE_dino2reg4.zip"
    net.download(WEIGHTS_URL, archive, expect_md5=WEIGHTS_MD5, label="B-Free weights")

    with zipfile.ZipFile(archive) as zf:
        zf.extractall(paths.cache_dir())
    if not (out_dir / "config.yaml").exists():
        raise OSError(f"archive did not contain {MODEL_DIR}/config.yaml")
    return out_dir


def replicate_wrap(x: torch.Tensor, shape: tuple[int, int]) -> torch.Tensor:
    """Tile a too-small token grid up to the model's grid size, as upstream does."""
    rep_h = max(int(np.ceil(shape[0] / x.shape[-2])), 1)
    rep_w = max(int(np.ceil(shape[1] / x.shape[-1])), 1)
    x = x.repeat(1, 1, rep_h, rep_w)
    return x[..., : shape[0], : shape[1]]


class Wrapper5Crops(nn.Module):
    """Five token-space crops through one transformer, averaged.

    Faithful reimplementation of the published `Wrapper5crops`. The crop order (centre,
    top-left, bottom-left, bottom-right, top-right) is preserved even though averaging makes
    it irrelevant, so a state dict transfers without surprises.
    """

    def __init__(self, model: nn.Module, patch_size: int = PATCH_SIZE):
        super().__init__()
        self.model = model
        self.model.set_input_size(img_size=patch_size)
        self.patch_embed = self.model.patch_embed
        self.model.patch_embed = nn.Identity()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        grid = self.patch_embed.grid_size
        emb = self.patch_embed.proj(x)

        pad_h = max(grid[0] - emb.shape[-2], 0)
        pad_w = max(grid[1] - emb.shape[-1], 0)
        if pad_h > 0 or pad_w > 0:
            emb = replicate_wrap(emb, grid)

        hs = max((emb.shape[-2] - grid[0]) // 2, 0)
        ws = max((emb.shape[-1] - grid[1]) // 2, 0)
        emb = torch.cat(
            (
                emb[:, :, hs : grid[0] + hs, ws : grid[1] + ws],
                emb[:, :, : grid[0], : grid[1]],
                emb[:, :, -grid[0] :, : grid[1]],
                emb[:, :, -grid[0] :, -grid[1] :],
                emb[:, :, : grid[0], -grid[1] :],
            ),
            0,
        )

        if self.patch_embed.flatten:
            emb = emb.flatten(2).transpose(1, 2)  # BCHW -> BNC
        emb = self.patch_embed.norm(emb)

        y = self.model(emb)
        return torch.mean(torch.stack(torch.split(y, y.shape[0] // 5, 0), 0), 0)

    def load_published_state(self, state: dict) -> None:
        self.patch_embed.load_state_dict(
            {k[len("patch_embed.") :]: v for k, v in state.items() if k.startswith("patch_embed.")}
        )
        self.model.load_state_dict(
            {k: v for k, v in state.items() if not k.startswith("patch_embed.")}
        )


class BFreeDetector(BaseModelDetector):
    """Positive logit means AI-generated, matching the project-wide convention."""

    def __init__(self, device: str | None = None):
        import yaml

        weights_dir = fetch_weights()
        cfg = yaml.safe_load((weights_dir / "config.yaml").read_text())
        arch = cfg["arch"]
        norm_type = cfg["norm_type"]
        ckpt_path = weights_dir / cfg["weights_file"]

        if not arch.startswith("timm_c5i504_"):
            raise ValueError(f"unexpected arch {arch!r}; only timm_c5i504_* is implemented")
        timm_name = arch[len("timm_c5i504_") :]

        import timm

        self.device = torch.device(device) if device else _device()
        base = timm.create_model(timm_name, num_classes=1, pretrained=False)
        self.model = Wrapper5Crops(base, PATCH_SIZE)

        dat = torch.load(ckpt_path, map_location="cpu", weights_only=False)
        if "model" not in dat:
            raise OSError(f"no 'model' key in {ckpt_path}; keys were {list(dat)[:8]}")
        self.model.load_published_state(dat["model"])

        self.model = self.model.eval().to(self.device)
        self.transform = build_transform(norm_type)

        n_params = sum(p.numel() for p in self.model.parameters())
        self.info = DetectorInfo(
            name="bfree:dino2reg4",
            kind="torch",
            licence="GRIP-UNINA non-commercial",
            commercial=False,
            params=n_params,
            input_resolution=None,  # native; no resize
            source="github.com/grip-unina/B-Free",
            notes=(
                f"{timm_name}, {n_params / 1e6:.0f}M params, {norm_type} normalisation. Five "
                f"{PATCH_SIZE}px token-space crops averaged, native input, NO resize. Ceiling "
                f"reference only: five transformer passes per image and no batching upstream "
                f"make it heavier than ClipBased, which already exceeds a share extension's "
                f"budget."
            ),
            trained_on=(
                "COCO reals (51,517) + Stable Diffusion 2.1 self-conditioned and inpainted "
                "generations (309,102). SD 2.1 ONLY — no commercial or 2026 generators."
            ),
        )

    @torch.no_grad()
    def score_batch(self, images: list[Image.Image]) -> list[float]:
        """One image at a time: sizes differ, and upstream has no batch support anyway."""
        out: list[float] = []
        for im in images:
            x = self.transform(im.convert("RGB")).unsqueeze(0).to(self.device)
            y = self.model(x)
            if y.shape[1] == 1:
                v = y[:, 0]
            elif y.shape[1] == 2:
                v = y[:, 1] - y[:, 0]
            else:
                raise RuntimeError(f"unexpected output width {y.shape[1]}")
            out.append(float(v.detach().cpu().numpy().astype(np.float64)[0]))
        return out
