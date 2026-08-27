"""Metadata presence detection.

Scope discipline matters here: this module detects that metadata *exists*, and must never
be mistaken for validating it. Cryptographic verification of a C2PA manifest is Lane A's
job on device. A present-but-unverified manifest is not evidence in either direction.
"""

from __future__ import annotations

import io

import piexif  # type: ignore
import pytest
from PIL import Image

from bench import metaprobe

pytest.importorskip("piexif", reason="piexif only needed to synthesise EXIF fixtures")


def jpeg(exif: bytes | None = None, extra: bytes = b"") -> bytes:
    buf = io.BytesIO()
    im = Image.new("RGB", (16, 16), (10, 20, 30))
    if exif:
        im.save(buf, format="JPEG", exif=exif)
    else:
        im.save(buf, format="JPEG")
    data = buf.getvalue()
    if extra:
        # Splice a payload after SOI so the head scan sees it, as a real APP segment would.
        data = data[:2] + extra + data[2:]
    return data


def write(tmp_path, data: bytes, name="i.jpg"):
    p = tmp_path / name
    p.write_bytes(data)
    return p


def test_clean_image_reports_no_metadata(tmp_path):
    f = metaprobe.probe(write(tmp_path, jpeg()))
    assert not f.has_exif
    assert not f.has_xmp
    assert not f.has_c2pa_hint
    assert not f.has_ai_disclosure_hint
    assert f.camera == ""


def test_detects_exif_and_camera_make(tmp_path):
    exif = piexif.dump({"0th": {piexif.ImageIFD.Make: b"Apple", piexif.ImageIFD.Model: b"iPhone 17 Pro"}})
    f = metaprobe.probe(write(tmp_path, jpeg(exif=exif)))
    assert f.has_exif
    assert f.exif_tags > 0
    assert f.has_camera_make
    assert "Apple" in f.camera and "iPhone" in f.camera


def test_detects_xmp_block(tmp_path):
    f = metaprobe.probe(write(tmp_path, jpeg(extra=b'<x:xmpmeta xmlns:x="adobe:ns:meta/">')))
    assert f.has_xmp


def test_detects_c2pa_jumbf_hint(tmp_path):
    f = metaprobe.probe(write(tmp_path, jpeg(extra=b"\x00\x00\x00\x18jumbc2pa")))
    assert f.has_c2pa_hint


@pytest.mark.parametrize(
    "marker",
    [b"trainedAlgorithmicMedia", b"digitalSourceType", b"c2pa.ai-disclosure"],
)
def test_detects_ai_disclosure_markers(tmp_path, marker):
    f = metaprobe.probe(write(tmp_path, jpeg(extra=marker)))
    assert f.has_ai_disclosure_hint


def test_scan_is_capped_so_large_originals_stay_cheap(tmp_path):
    """Social-media originals run to 4000px; the probe must not read whole files."""
    big = jpeg() + b"\x00" * (2 * metaprobe.SCAN_BYTES)
    f = metaprobe.probe(write(tmp_path, big))
    assert f.bytes_scanned <= metaprobe.SCAN_BYTES


def test_marker_beyond_scan_window_is_missed_by_design(tmp_path):
    """Documents the tradeoff rather than pretending the cap is free."""
    data = jpeg() + b"\x00" * metaprobe.SCAN_BYTES + b"trainedAlgorithmicMedia"
    assert not metaprobe.probe(write(tmp_path, data)).has_ai_disclosure_hint


def test_probe_many_skips_unreadable_files_without_raising(tmp_path):
    good = write(tmp_path, jpeg(), "good.jpg")
    bad = write(tmp_path, b"not an image", "bad.jpg")
    missing = tmp_path / "gone.jpg"
    out = metaprobe.probe_many([good, bad, missing])
    # `bad` still probes (bytes are readable, just not decodable); `missing` cannot.
    assert len(out) == 2
    assert all(isinstance(f, metaprobe.MetadataFindings) for f in out)


def test_findings_serialise_for_the_manifest(tmp_path):
    row = metaprobe.probe(write(tmp_path, jpeg())).as_row()
    assert set(row) >= {"path", "has_exif", "has_c2pa_hint", "has_ai_disclosure_hint"}
