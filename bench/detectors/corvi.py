"""Corvi2023: ResNet-50 "nodown", from the ClipBased repo's weights directory.

The most informative addition available, for three reasons that have nothing to do with its
expected accuracy.

**It is a CNN, not a transformer.** Every other candidate measured so far is a ViT. If CNN and
ViT detectors fail on the same generators, that says something about the generators; if they
fail on different ones, an ensemble becomes interesting.

**It does not resize.** `config.yaml` sets `patch_size: null`, and upstream's `main.py`
applies normalisation only for that case. This is the direct test of the finding that dominated
the last matrix run: ClipBased and SigLIP were insensitive to the degradation ladder because
they resize to 224 first, discarding the damage. Corvi2023 sees native pixels, so it should be
the architecture that actually degrades. If it does not, the flatness is a property of the task
rather than of input resolution.

**It is genuinely small.** ResNet-50 is ~25M parameters against ClipBased's 303M, which puts it
in the range a share extension could plausibly hold. SSP was supposed to be the cost floor and
its weights turned out to be unobtainable; this is the replacement candidate.

"nodown" is the Gragnaniello/Corvi design: `stride0=1` sets BOTH the stem convolution and the
max-pool to stride 1, so the network downsamples by 8 instead of 32 and high-frequency forensic
traces survive into the feature map. That is the point, and it is also expensive — a 1024px
input yields a 128x128x2048 activation, and a 4000px camera original would yield ~500x333x2048.
Hence the `max_side` cap below.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from PIL import Image
from torchvision.models import resnet50
from torchvision.transforms import CenterCrop, Compose, Normalize, ToTensor

from bench import net, paths
from bench.detectors.base import BaseModelDetector, DetectorInfo

REPO = "grip-unina/ClipBased-SyntheticImageDetection"
LFS_BASE = f"https://media.githubusercontent.com/media/{REPO}/main/weights"
VARIANT = "Corvi2023"

# From utils/processing.py make_normalize('resnet'). Note these are ImageNet statistics, NOT
# the CLIP ones the other grip-unina detector uses; swapping them silently costs accuracy.
RESNET_MEAN = (0.485, 0.456, 0.406)
RESNET_STD = (0.229, 0.224, 0.225)

# Upstream applies no size limit. We cap by CENTRE CROP, never by resize: resampling would
# destroy the high-frequency evidence this architecture exists to read, which is the one
# deviation that would invalidate the comparison. Cropping is also within upstream's own
# transform vocabulary — `patch_size: <int>` selects exactly CenterCrop(n).
#
# MEASURED tradeoff on a 40-image probe (M3 Pro, MPS), which is why 768 is the default:
#
#   max_side   ms/image   AUC     full 8-rung matrix over 2,998 images
#       1536       2710   0.8775                              18.1 h
#       1024       1205   0.8525                               8.0 h
#        768        675   0.8450                               4.5 h
#        512        296   0.8175                               2.0 h
#
# 768 costs ~0.03 AUC against 1536 and runs 4x faster. Any published number from this
# detector must state the cap, because it is a real deviation from upstream's uncapped
# configuration and it moves the score.
DEFAULT_MAX_SIDE = 768


def _device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def build_transform(max_side: int | None = DEFAULT_MAX_SIDE) -> Compose:
    steps: list = []
    if max_side:
        steps.append(CenterCrop(max_side))  # pads if smaller, which upstream also tolerates
    steps += [ToTensor(), Normalize(mean=RESNET_MEAN, std=RESNET_STD)]
    return Compose(steps)


def build_res50nodown() -> nn.Module:
    """torchvision ResNet-50 with the stem strides set to 1.

    Layer and parameter names match the published implementation (`conv1`, `bn1`, `layer1..4`,
    `fc`), so the released state dict loads without remapping. Their `ChannelLinear` on the
    post-pool 2-D tensor is arithmetically a plain `nn.Linear`, so we use one — the weight
    shape (1, 2048) is identical either way.
    """
    m = resnet50(weights=None)
    m.conv1 = nn.Conv2d(3, 64, kernel_size=7, stride=1, padding=3, bias=False)
    m.maxpool = nn.MaxPool2d(kernel_size=3, stride=1, padding=1)
    m.fc = nn.Linear(2048, 1)
    return m


def fetch_weights() -> Path:
    dest = paths.cache_dir() / f"corvi2023_{VARIANT}_weights.pth"
    if not dest.exists():
        net.download(f"{LFS_BASE}/{VARIANT}/weights.pth", dest, label=f"{VARIANT} weights")
    if dest.stat().st_size < 1_000_000:
        raise OSError(
            f"{dest} is only {dest.stat().st_size} bytes — expected ~283 MB. A Git LFS "
            f"pointer or an error page, not the weights."
        )
    return dest


class Corvi2023Detector(BaseModelDetector):
    """Positive logit means AI-generated, matching the project-wide convention."""

    def __init__(self, device: str | None = None, max_side: int | None = DEFAULT_MAX_SIDE):
        self.device = torch.device(device) if device else _device()
        self.max_side = max_side
        self.transform = build_transform(max_side)
        self.model = build_res50nodown()

        dat = torch.load(fetch_weights(), map_location="cpu", weights_only=False)
        state = dat.get("model", dat) if isinstance(dat, dict) else dat
        state = {k[7:] if k.startswith("module.") else k: v for k, v in state.items()}
        missing, unexpected = self.model.load_state_dict(state, strict=False)
        if missing:
            raise OSError(f"state dict missing {len(missing)} key(s), first few: {missing[:5]}")

        self.model = self.model.eval().to(self.device)
        n_params = sum(p.numel() for p in self.model.parameters())

        cap = f"centre-cropped to {max_side}px" if max_side else "native size, uncapped"
        self.info = DetectorInfo(
            name="corvi2023:res50nodown",
            kind="torch",
            licence="Apache-2.0",
            commercial=True,
            params=n_params,
            input_resolution=None,  # no resize by design
            source=f"github.com/{REPO} (weights/{VARIANT})",
            notes=(
                f"ResNet-50 'nodown' (stem and max-pool at stride 1, so /8 not /32), "
                f"{n_params / 1e6:.1f}M params, ImageNet normalisation, NO resize — {cap}. "
                f"A CNN and a native-resolution model, so it is the control for both the "
                f"architecture and the resize hypotheses. Smallest measured candidate: 12x "
                f"fewer parameters than ClipBased."
            ),
            trained_on=(
                "Not documented in the ClipBased repo, which redistributes these weights. "
                "The Corvi et al. line of work trained on ProGAN/latent-diffusion era data; "
                "no 2026 generators either way. Treat as unverified."
            ),
        )

    @torch.no_grad()
    def score_batch(self, images: list[Image.Image]) -> list[float]:
        """One at a time: without a resize the tensors differ in shape, so batching is out.

        Also the safer choice given the activation sizes a stride-1 stem produces.
        """
        out: list[float] = []
        for im in images:
            x = self.transform(im.convert("RGB")).unsqueeze(0).to(self.device)
            y = self.model(x)
            v = y[:, 0] if y.shape[1] == 1 else y[:, 1] - y[:, 0]
            out.append(float(v.detach().cpu().numpy().astype(np.float64)[0]))
        return out
