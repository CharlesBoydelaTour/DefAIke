"""Corvi2023 res50nodown adapter, and the HF classifier presets.

Corvi2023 is the control for two hypotheses at once — CNN versus transformer, and native
resolution versus a 224 resize — so the two properties that make it a control are exactly what
these tests pin. If a future edit adds a Resize to its transform, or restores the standard
ResNet strides, the detector silently stops being a control and starts being a fifth
224-resize ViT-equivalent.
"""

from __future__ import annotations

import pytest
import torch
from PIL import Image

from bench.detectors import corvi, hf_classifier


# --- the "nodown" property ----------------------------------------------------------


def test_stem_strides_are_one_not_two():
    """This is what 'nodown' means: /8 total downsampling instead of /32."""
    m = corvi.build_res50nodown()
    assert m.conv1.stride == (1, 1)
    assert m.maxpool.stride == 1


def test_head_is_a_single_logit():
    m = corvi.build_res50nodown()
    assert m.fc.in_features == 2048
    assert m.fc.out_features == 1


@torch.no_grad()
def test_downsampling_factor_is_eight():
    """Directly measured, because it is the reason the model is expensive and sensitive."""
    m = corvi.build_res50nodown().eval()
    feats = torch.nn.Sequential(
        m.conv1, m.bn1, m.relu, m.maxpool, m.layer1, m.layer2, m.layer3, m.layer4
    )(torch.randn(1, 3, 256, 256))
    assert feats.shape[-1] == 256 // 8, "standard ResNet-50 would give 256/32 = 8"
    assert feats.shape[1] == 2048


@torch.no_grad()
def test_forward_produces_one_logit_per_image():
    m = corvi.build_res50nodown().eval()
    out = m(torch.randn(2, 3, 256, 256))
    assert tuple(out.shape) == (2, 1)


# --- transform: crop, never resize --------------------------------------------------


def test_transform_crops_and_never_resizes():
    """Resizing would destroy the high-frequency evidence the architecture reads."""
    names = [type(x).__name__ for x in corvi.build_transform(768).transforms]
    assert names == ["CenterCrop", "ToTensor", "Normalize"]
    assert "Resize" not in names


def test_transform_can_be_uncapped_to_match_upstream_exactly():
    names = [type(x).__name__ for x in corvi.build_transform(None).transforms]
    assert names == ["ToTensor", "Normalize"]


def test_cap_bounds_large_inputs():
    out = corvi.build_transform(768)(Image.new("RGB", (4000, 2666), (80, 90, 100)))
    assert tuple(out.shape) == (3, 768, 768)


def test_small_inputs_survive_the_cap():
    """CenterCrop pads when the image is smaller, which the thumbnail rung relies on."""
    out = corvi.build_transform(768)(Image.new("RGB", (144, 144), (10, 20, 30)))
    assert tuple(out.shape) == (3, 768, 768)


def test_normalization_is_imagenet_not_clip():
    """config.yaml says norm_type: resnet. Using CLIP stats here is a silent accuracy loss."""
    from bench.detectors import clipbased

    norm = corvi.build_transform(512).transforms[-1]
    assert tuple(norm.mean) == pytest.approx(corvi.RESNET_MEAN)
    assert tuple(norm.mean) != pytest.approx(clipbased.CLIP_MEAN)


def test_default_cap_is_the_measured_compromise():
    """768 was chosen from a measured speed/accuracy table; pin it so it stays deliberate."""
    assert corvi.DEFAULT_MAX_SIDE == 768


def test_weight_size_guard_rejects_an_lfs_pointer(tmp_path, monkeypatch):
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    cache = tmp_path / "data" / "cache"
    cache.mkdir(parents=True)
    (cache / f"corvi2023_{corvi.VARIANT}_weights.pth").write_bytes(b"version https://git-lfs")
    with pytest.raises(OSError, match="expected ~283 MB"):
        corvi.fetch_weights()


# --- HF classifier presets ----------------------------------------------------------


def test_presets_cover_the_widely_deployed_baseline():
    """Organika has ~141k downloads, which makes it the practical real-world baseline."""
    assert "organika" in hf_classifier.PRESETS
    assert hf_classifier.PRESETS["organika"].model_id == "Organika/sdxl-detector"


def test_every_preset_declares_licence_and_training_data():
    for name, p in hf_classifier.PRESETS.items():
        assert p.licence and p.licence != "", name
        assert p.trained_on and p.trained_on != "", name
        assert isinstance(p.commercial, bool), name


def test_non_commercial_preset_is_flagged_as_such():
    assert hf_classifier.PRESETS["organika"].commercial is False
    assert "NC" in hf_classifier.PRESETS["organika"].licence


def test_unknown_preset_is_rejected():
    with pytest.raises(KeyError, match="unknown preset"):
        hf_classifier.HFClassifierDetector("not_a_preset")


def test_requires_either_preset_or_model_id():
    with pytest.raises(ValueError, match="either preset or model_id"):
        hf_classifier.HFClassifierDetector()


def test_label_resolution_is_shared_with_the_siglip_adapter():
    """One implementation, so a fix to the inversion guard applies everywhere."""
    from bench.detectors import siglip

    assert hf_classifier.resolve_ai_index is siglip.resolve_ai_index
