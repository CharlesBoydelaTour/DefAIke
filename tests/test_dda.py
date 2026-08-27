"""DDA adapter: LoRA plumbing and the transcribed preprocessing.

The failure this file mainly guards against is a silent one. LoRA `lora_B` matrices initialise
to zero, so an adapter that fails to load leaves the model as a plain frozen DINOv2 that still
runs, still produces plausible logits, and is simply weaker. That looks like "the paper
overclaimed" rather than "our loading is broken", so the strict-key check and these tests
matter more than usual.
"""

from __future__ import annotations

import pytest
import torch
import torch.nn as nn
from PIL import Image

from bench.detectors import dda


# --- transform ----------------------------------------------------------------------


def test_transform_crops_and_never_resizes():
    names = [type(x).__name__ for x in dda.build_transform().transforms]
    assert names == ["CenterCrop", "ToTensor", "Normalize"]
    assert "Resize" not in names


def test_transform_output_is_the_published_crop_size():
    out = dda.build_transform()(Image.new("RGB", (1024, 768), (90, 100, 110)))
    assert tuple(out.shape) == (3, dda.CROP, dda.CROP)
    assert dda.CROP == 336


def test_transform_pads_inputs_smaller_than_the_crop():
    """The thumbnail rung produces 144px images; the crop must cope rather than raise."""
    out = dda.build_transform()(Image.new("RGB", (144, 144), (10, 20, 30)))
    assert tuple(out.shape) == (3, 336, 336)


def test_uses_clip_statistics_despite_a_dinov2_backbone():
    """Taken from their inference script. ImageNet stats here would be a silent error."""
    norm = dda.build_transform().transforms[-1]
    assert tuple(norm.mean) == pytest.approx(dda.CLIP_MEAN)
    assert tuple(norm.mean) != pytest.approx((0.485, 0.456, 0.406))


# --- LoRA ---------------------------------------------------------------------------


def test_lora_layer_starts_as_a_no_op():
    """lora_B is zero-initialised, so an untrained adapter contributes nothing.

    This is exactly why an unloaded adapter is invisible without a key check.
    """
    layer = dda.LoRALayer(16, 16)
    x = torch.randn(2, 16)
    assert torch.allclose(layer(x), torch.zeros(2, 16))


def test_lora_scaling_uses_alpha_over_rank():
    layer = dda.LoRALayer(8, 8, rank=4, alpha=2.0)
    nn.init.ones_(layer.lora_A)
    nn.init.ones_(layer.lora_B)
    x = torch.ones(1, 8)
    # each output = sum_r (sum_d x_d * 1) * 1 = rank * in_dim, scaled by alpha/rank
    assert layer(x)[0, 0].item() == pytest.approx(4 * 8 * (2.0 / 4))


def test_lora_linear_is_additive_over_the_frozen_layer():
    base = nn.Linear(12, 12)
    wrapped = dda.LoRALinear(base)
    x = torch.randn(3, 12)
    assert torch.allclose(wrapped(x), base(x)), "zero-init adapter must not change the output"


def test_lora_linear_freezes_the_original_weights():
    base = nn.Linear(12, 12)
    wrapped = dda.LoRALinear(base)
    assert not any(p.requires_grad for p in wrapped.original_layer.parameters())
    assert all(p.requires_grad for p in wrapped.lora.parameters())


def tiny_transformer():
    """Minimal module whose names match DINOv2's, to test target matching."""
    m = nn.Module()
    m.blocks = nn.ModuleList([nn.Module() for _ in range(2)])
    for b in m.blocks:
        b.attn = nn.Module()
        b.attn.qkv = nn.Linear(8, 24)
        b.attn.proj = nn.Linear(8, 8)
        b.mlp = nn.Module()
        b.mlp.fc1 = nn.Linear(8, 16)
        b.mlp.fc2 = nn.Linear(16, 8)
        b.norm1 = nn.LayerNorm(8)
    m.head = nn.Linear(8, 2)
    return m


def test_apply_lora_wraps_exactly_the_published_targets():
    m = dda.apply_lora(tiny_transformer())
    wrapped = [n for n, mod in m.named_modules() if isinstance(mod, dda.LoRALinear)]
    assert len(wrapped) == 8  # 4 targets x 2 blocks
    assert all(any(t in n for t in dda.LORA_TARGETS) for n in wrapped)


def test_apply_lora_leaves_non_target_layers_alone():
    """`head` and the norms must stay untouched, or the state dict will not match."""
    m = dda.apply_lora(tiny_transformer())
    assert isinstance(m.head, nn.Linear) and not isinstance(m.head, dda.LoRALinear)
    assert isinstance(m.blocks[0].norm1, nn.LayerNorm)


def test_apply_lora_preserves_forward_behaviour_before_training():
    a, b = tiny_transformer(), tiny_transformer()
    b.load_state_dict(a.state_dict())
    dda.apply_lora(b)
    x = torch.randn(2, 8)
    assert torch.allclose(a.blocks[0].attn.proj(x), b.blocks[0].attn.proj(x))


def test_apply_lora_is_idempotent_on_targets():
    """Wrapping twice would double-count and break key names."""
    m = dda.apply_lora(tiny_transformer())
    n_first = sum(isinstance(mod, dda.LoRALinear) for _, mod in m.named_modules())
    m = dda.apply_lora(m)
    n_second = sum(isinstance(mod, dda.LoRALinear) for _, mod in m.named_modules())
    assert n_second == n_first, "already-wrapped Linears are nested, not re-wrapped"


# --- published constants ------------------------------------------------------------


def test_published_hyperparameters_are_pinned():
    assert dda.LORA_RANK == 8
    assert dda.LORA_ALPHA == 1.0
    assert dda.LORA_TARGETS == ("attn.qkv", "attn.proj", "mlp.fc1", "mlp.fc2")
    assert dda.BACKBONE == "dinov2_vitl14"
    assert dda.FEATURE_DIM == 1024


def test_weights_come_from_a_scriptable_host():
    """Unlike B-Free, whose single host was down, and SSP's Baidu/Dropbox links."""
    assert dda.WEIGHTS_REPO == "Junwei-Xi/Dual-Data-Alignment"
    assert dda.WEIGHTS_FILE.endswith(".pth")


def test_get_submodule_handles_indexed_paths():
    m = tiny_transformer()
    assert dda._get_submodule(m, "blocks.1.attn") is m.blocks[1].attn
    assert dda._get_submodule(m, "") is m
