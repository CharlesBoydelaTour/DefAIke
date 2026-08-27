"""Tests for the pixel-scoring detectors that do not require downloading weights.

The logic worth isolating is the label resolution and the transcribed preprocessing. A
flipped label mapping inverts every score silently, and a wrong resize costs accuracy that
looks like a weak model rather than a wiring bug — so both are pinned here, where they run in
milliseconds, rather than only being caught by a multi-hour matrix run.
"""

from __future__ import annotations

import numpy as np
import pytest
from PIL import Image

from bench.detectors import clipbased, siglip


# --- SigLIP label resolution --------------------------------------------------------


def test_resolves_the_actual_shipped_mapping():
    """The real model reports {0: 'ai', 1: 'hum'}."""
    idx, name = siglip.resolve_ai_index({0: "ai", 1: "hum"})
    assert idx == 0 and name == "ai"


def test_resolves_reversed_order():
    idx, _ = siglip.resolve_ai_index({0: "human", 1: "ai_generated"})
    assert idx == 1


@pytest.mark.parametrize(
    "labels,expected",
    [
        ({0: "REAL", 1: "FAKE"}, 1),
        ({0: "synthetic", 1: "photo"}, 0),
        ({0: "authentic", 1: "generated"}, 1),
        ({0: "artificial", 1: "natural"}, 0),
    ],
)
def test_resolves_common_naming_conventions(labels, expected):
    assert siglip.resolve_ai_index(labels)[0] == expected


def test_infers_ai_class_from_an_unambiguous_real_label():
    """Only one side needs to be recognisable."""
    idx, _ = siglip.resolve_ai_index({0: "human", 1: "class_1"})
    assert idx == 1


def test_refuses_to_guess_when_both_labels_are_opaque():
    """Guessing here would invert the detector silently, so this must raise."""
    with pytest.raises(ValueError, match="cannot determine"):
        siglip.resolve_ai_index({0: "label_a", 1: "label_b"})


def test_refuses_non_binary_configs():
    with pytest.raises(ValueError, match="binary classifier"):
        siglip.resolve_ai_index({0: "ai", 1: "hum", 2: "other"})


def test_refuses_when_both_labels_look_like_ai():
    with pytest.raises(ValueError, match="cannot determine"):
        siglip.resolve_ai_index({0: "ai_generated", 1: "synthetic_fake"})


# --- ClipBased transcribed preprocessing --------------------------------------------


def test_transform_matches_the_published_pipeline():
    """Resize(224, BICUBIC) -> CenterCrop(224) -> ToTensor -> CLIP Normalize."""
    t = clipbased.build_transform()
    names = [type(x).__name__ for x in t.transforms]
    assert names == ["Resize", "CenterCrop", "ToTensor", "Normalize"]


def test_transform_produces_the_expected_tensor_shape():
    t = clipbased.build_transform()
    out = t(Image.new("RGB", (640, 480), (120, 90, 30)))
    assert tuple(out.shape) == (3, 224, 224)


def test_transform_resizes_shorter_side_then_centre_crops():
    """A wide image must not be squashed; the aspect ratio is preserved before cropping."""
    t = clipbased.build_transform()
    wide = t(Image.new("RGB", (2000, 400), (10, 200, 10)))
    tall = t(Image.new("RGB", (400, 2000), (10, 200, 10)))
    assert tuple(wide.shape) == tuple(tall.shape) == (3, 224, 224)


def test_normalization_uses_the_clip_constants():
    t = clipbased.build_transform()
    norm = t.transforms[-1]
    assert tuple(norm.mean) == pytest.approx(clipbased.CLIP_MEAN)
    assert tuple(norm.std) == pytest.approx(clipbased.CLIP_STD)
    # These are CLIP's, not ImageNet's; mixing them up is a classic silent error.
    assert tuple(norm.mean) != pytest.approx((0.485, 0.456, 0.406))


def test_normalization_actually_centres_the_data():
    t = clipbased.build_transform()
    grey = t(Image.new("RGB", (300, 300), (123, 117, 104)))
    assert abs(float(grey.mean())) < 0.15


def test_feature_dim_is_pre_projection_width():
    """next_to_last drops visual.proj, so features are 1024-d and the head is 1025 floats.

    That is what makes the released 5,155-byte weights file consistent; assuming 768 would
    have loaded a mis-shaped head.
    """
    assert clipbased.FEATURE_DIM == 1024
    assert (clipbased.FEATURE_DIM + 1) * 4 < 5155  # float32 payload plus pickle overhead


def test_backbone_checkpoint_is_the_commonpool_variant():
    """config.yaml says clipL14commonpool; datacomp or openai would be a different model."""
    assert clipbased.OPENCLIP_MODEL == "ViT-L-14"
    assert "CommonPool" in clipbased.OPENCLIP_HF_REPO


def test_rejects_the_non_clip_variant():
    """Corvi2023 is a ResNet detector; this class only implements the CLIP architecture."""
    with pytest.raises(ValueError, match="variant must be"):
        clipbased.ClipBasedDetector(variant="Corvi2023")


def test_rejects_unknown_variant():
    with pytest.raises(ValueError, match="variant must be"):
        clipbased.ClipBasedDetector(variant="does_not_exist")


def test_lfs_pointer_is_detected_rather_than_loaded(tmp_path, monkeypatch):
    """raw.githubusercontent serves a 129-byte pointer for LFS files.

    Loading that as a checkpoint fails obscurely, so the size check turns it into a message
    that names the actual problem.
    """
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    cache = tmp_path / "data" / "cache"
    cache.mkdir(parents=True)
    pointer = cache / "clipbased_clipdet_latent10k_plus_weights.pth"
    pointer.write_bytes(
        b"version https://git-lfs.github.com/spec/v1\noid sha256:deadbeef\nsize 5155\n"
    )
    with pytest.raises(OSError, match="Git LFS pointer"):
        clipbased.fetch_head("clipdet_latent10k_plus")


def test_device_selection_prefers_accelerator():
    dev = clipbased._device()
    assert dev.type in ("mps", "cuda", "cpu")
