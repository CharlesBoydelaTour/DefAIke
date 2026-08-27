"""Image writing: format sniffing, decode verification, corrupt-input handling.

The load-bearing requirement is that a corrupt image is skipped with a report rather than
crashing a multi-hour fetch, and that bytes are never re-encoded — compression history is
signal this project reads.
"""

from __future__ import annotations

import io

import pytest
from PIL import Image

from bench import imageio


def make(fmt: str, size=(24, 16), colour=(120, 40, 200)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, colour).save(buf, format=fmt)
    return buf.getvalue()


@pytest.mark.parametrize(
    "fmt,expected",
    [("JPEG", "jpg"), ("PNG", "png"), ("WEBP", "webp"), ("BMP", "bmp"), ("GIF", "gif")],
)
def test_sniff_ext_from_magic_bytes(fmt, expected):
    assert imageio.sniff_ext(make(fmt)) == expected


def test_sniff_prefers_magic_over_supplied_filename():
    """A source-provided path is a hint, not the truth."""
    assert imageio.sniff_ext(make("PNG"), fallback_path="lies.jpg") == "png"


def test_sniff_falls_back_to_path_then_bin():
    assert imageio.sniff_ext(b"\x00\x01\x02\x03", fallback_path="x.tiff") == "tiff"
    assert imageio.sniff_ext(b"\x00\x01\x02\x03") == "bin"


def test_write_verified_roundtrip_preserves_bytes_exactly(tmp_path):
    """No re-encoding. The file on disk must be byte-identical to the input."""
    data = make("JPEG")
    w = imageio.write_verified(data, tmp_path, "img")
    assert w is not None
    assert w.path.read_bytes() == data
    assert w.bytes == len(data)
    assert (w.width, w.height) == (24, 16)
    assert w.path.suffix == ".jpg"


def test_write_verified_records_content_hash(tmp_path):
    data = make("PNG")
    w = imageio.write_verified(data, tmp_path, "img")
    assert w is not None
    assert w.sha256 == imageio.sha256_bytes(data)
    assert len(w.sha256) == 64


def test_corrupt_image_returns_none_and_writes_nothing(tmp_path):
    assert imageio.write_verified(b"this is not an image", tmp_path, "bad") is None
    assert list(tmp_path.iterdir()) == []


def test_truncated_image_is_rejected(tmp_path):
    """Truncation is the common real-world corruption; it must not slip through."""
    assert imageio.write_verified(make("JPEG")[:40], tmp_path, "trunc") is None
    assert list(tmp_path.iterdir()) == []


def test_empty_payload_returns_none(tmp_path):
    assert imageio.write_verified(b"", tmp_path, "empty") is None


def test_overlong_stem_is_truncated_but_stays_unique(tmp_path):
    """So-Fake ids embed prompt fragments; APFS caps a filename at 255 bytes."""
    stem = "x" * 400
    a = imageio.write_verified(make("JPEG", colour=(1, 2, 3)), tmp_path, stem)
    b = imageio.write_verified(make("JPEG", colour=(9, 9, 9)), tmp_path, stem)
    assert a is not None and b is not None
    assert len(a.path.name) < 255
    assert a.path != b.path, "different content must not collide after truncation"


def test_rel_to_data_falls_back_to_absolute_outside_data_root(tmp_path):
    p = tmp_path / "img.jpg"
    p.write_bytes(b"x")
    assert imageio.rel_to_data(p) == str(p)
