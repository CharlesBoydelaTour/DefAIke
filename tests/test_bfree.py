"""B-Free adapter: the embedding-space 5-crop wrapper and the download guard.

Everything here runs without the published weights, which matters because the sole
distribution host was returning HTTP 502 when this was written. The reimplemented
`Wrapper5Crops` is tested against a randomly-initialised timm backbone of the same family, so
the tensor plumbing is verified even while the fine-tuned checkpoint is unobtainable.
"""

from __future__ import annotations

import numpy as np
import pytest
import torch
from PIL import Image

from bench.detectors import bfree


# --- transform: normalisation only --------------------------------------------------


def test_transform_does_not_resize_or_crop():
    """The whole design is native-resolution input. A resize here would defeat it."""
    t = bfree.build_transform("clip")
    names = [type(x).__name__ for x in t.transforms]
    assert names == ["ToTensor", "Normalize"]
    assert "Resize" not in names and "CenterCrop" not in names


@pytest.mark.parametrize("size", [(640, 480), (1024, 1024), (300, 1700)])
def test_transform_preserves_input_dimensions(size):
    out = bfree.build_transform("clip")(Image.new("RGB", size, (100, 110, 120)))
    assert tuple(out.shape) == (3, size[1], size[0])


def test_transform_none_is_plain_tensor_conversion():
    t = bfree.build_transform("none")
    assert [type(x).__name__ for x in t.transforms] == ["ToTensor"]


def test_transform_rejects_unknown_norm():
    with pytest.raises(ValueError, match="unknown norm_type"):
        bfree.build_transform("not_a_norm")


def test_clip_norm_constants_match_the_other_clip_detector():
    from bench.detectors import clipbased

    mean, std = bfree.NORMS["clip"]
    assert mean == pytest.approx(clipbased.CLIP_MEAN)
    assert std == pytest.approx(clipbased.CLIP_STD)


# --- replicate_wrap -----------------------------------------------------------------


def test_replicate_wrap_tiles_a_too_small_grid_up():
    x = torch.arange(2 * 3 * 4 * 5, dtype=torch.float32).reshape(2, 3, 4, 5)
    out = bfree.replicate_wrap(x, (10, 12))
    assert tuple(out.shape) == (2, 3, 10, 12)


def test_replicate_wrap_is_a_noop_when_already_large_enough():
    x = torch.randn(1, 3, 40, 40)
    out = bfree.replicate_wrap(x, (36, 36))
    assert tuple(out.shape) == (1, 3, 36, 36)
    assert torch.allclose(out, x[:, :, :36, :36])


def test_replicate_wrap_repeats_rather_than_pads_with_zeros():
    x = torch.ones(1, 1, 2, 2)
    out = bfree.replicate_wrap(x, (4, 4))
    assert torch.all(out == 1.0), "zero padding would introduce artefacts the model never saw"


# --- Wrapper5Crops ------------------------------------------------------------------


@pytest.fixture(scope="module")
def wrapped():
    """Smallest reg4 DINOv2 in the family, randomly initialised.

    Weights are irrelevant here; the point is that the token-space crop, batching, and
    averaging produce correct shapes against the real timm architecture.
    """
    timm = pytest.importorskip("timm")
    base = timm.create_model("vit_small_patch14_reg4_dinov2", num_classes=1, pretrained=False)
    return bfree.Wrapper5Crops(base, patch_size=bfree.PATCH_SIZE).eval()


def test_wrapper_moves_patch_embed_out_of_the_model(wrapped):
    """The transformer must receive tokens, not pixels, hence Identity in its place."""
    assert isinstance(wrapped.model.patch_embed, torch.nn.Identity)
    assert wrapped.patch_embed is not None
    assert wrapped.patch_embed.grid_size == (36, 36)  # 504 / 14


@torch.no_grad()
def test_wrapper_returns_one_logit_per_image(wrapped):
    out = wrapped(torch.randn(1, 3, bfree.PATCH_SIZE, bfree.PATCH_SIZE))
    assert tuple(out.shape) == (1, 1)


@torch.no_grad()
@pytest.mark.parametrize("hw", [(504, 504), (700, 900), (1024, 1024)])
def test_wrapper_accepts_arbitrary_input_sizes(wrapped, hw):
    """No resize means the wrapper itself must cope with whatever size arrives."""
    out = wrapped(torch.randn(1, 3, *hw))
    assert tuple(out.shape) == (1, 1)
    assert torch.isfinite(out).all()


@torch.no_grad()
def test_wrapper_handles_images_smaller_than_the_crop_window(wrapped):
    """Below 504px the token grid is too small and must be tiled, not rejected.

    This is the path the `thumbnail` rung exercises: 144px input against a 504px window.
    """
    out = wrapped(torch.randn(1, 3, 144, 144))
    assert tuple(out.shape) == (1, 1)
    assert torch.isfinite(out).all()


@torch.no_grad()
def test_wrapper_averages_exactly_five_crops(wrapped, monkeypatch):
    """Pin the 5-crop contract: the transformer must see 5x the batch, output 1x."""
    seen = {}
    inner = wrapped.model

    def spy(emb):
        seen["batch"] = emb.shape[0]
        return inner_forward(emb)

    inner_forward = inner.forward
    monkeypatch.setattr(inner, "forward", spy)
    out = wrapped(torch.randn(2, 3, 800, 800))
    assert seen["batch"] == 10, "2 images x 5 crops"
    assert tuple(out.shape) == (2, 1)


@torch.no_grad()
def test_wrapper_is_deterministic_in_eval(wrapped):
    x = torch.randn(1, 3, 600, 600)
    assert torch.allclose(wrapped(x), wrapped(x))


# --- download guard ----------------------------------------------------------------


def test_fetch_weights_rejects_the_html_error_page(tmp_path, monkeypatch):
    """The host served an 11,939-byte HTML 502 page that a naive fetch accepts as success.

    MD5 verification is what turns that into an actionable error instead of a confusing
    failure inside torch.load.
    """
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    (tmp_path / "data" / "cache").mkdir(parents=True)

    def fake_download(url, dest, expect_md5=None, label=None):
        dest.write_bytes(b"<!DOCTYPE html><html><body>502 Bad Gateway</body></html>")
        if expect_md5:
            raise OSError(f"{url}: md5 mismatch; file discarded")
        return dest

    monkeypatch.setattr(bfree.net, "download", fake_download)
    with pytest.raises(OSError, match="md5"):
        bfree.fetch_weights()


def test_published_md5_is_pinned():
    """Recorded from the upstream README so a corrupt mirror cannot pass silently."""
    assert bfree.WEIGHTS_MD5 == "f3f53fa647848b16cf81c913f148a198"
    assert bfree.PATCH_SIZE == 504


def test_arch_prefix_is_validated(tmp_path, monkeypatch):
    """Only the timm_c5i504_* family is implemented; anything else must not be guessed at."""
    monkeypatch.setenv("DEFAIKE_ROOT", str(tmp_path))
    d = tmp_path / "data" / "cache" / bfree.MODEL_DIR
    d.mkdir(parents=True)
    (d / "config.yaml").write_text(
        "arch: some_other_arch\nnorm_type: clip\nweights_file: model_epoch_best.pth\n"
    )
    with pytest.raises(ValueError, match="only timm_c5i504"):
        bfree.BFreeDetector()
