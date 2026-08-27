"""Write image bytes to disk, verifying they decode.

Every image lands as its original bytes. We never re-encode: the compression history is
signal this project reads, not noise to normalise away. Verification therefore decodes to
check validity and then throws the decoded pixels away.
"""

from __future__ import annotations

import io
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from bench.net import sha256_bytes

Image.MAX_IMAGE_PIXELS = None  # these are native-resolution social media images

_MAGIC: list[tuple[bytes, str]] = [
    (b"\xff\xd8\xff", "jpg"),
    (b"\x89PNG\r\n\x1a\n", "png"),
    (b"GIF87a", "gif"),
    (b"GIF89a", "gif"),
    (b"BM", "bmp"),
]


def sniff_ext(data: bytes, fallback_path: str | None = None) -> str:
    """Extension from magic bytes, not from a filename we were handed."""
    for magic, ext in _MAGIC:
        if data.startswith(magic):
            return ext
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    if data[4:12] in (b"ftypheic", b"ftypheix", b"ftyphevc", b"ftypmif1"):
        return "heic"
    if fallback_path and "." in fallback_path:
        return fallback_path.rsplit(".", 1)[-1].lower()
    return "bin"


@dataclass(frozen=True)
class Written:
    path: Path
    sha256: str
    bytes: int
    width: int
    height: int
    format: str


def write_verified(data: bytes, out_dir: Path, stem: str) -> Written | None:
    """Write bytes and confirm they decode. Returns None on a corrupt image.

    Corrupt inputs are a normal occurrence in web-scraped corpora, so this reports and
    continues rather than aborting a multi-hour fetch.
    """
    if not data:
        return None

    try:
        with Image.open(io.BytesIO(data)) as im:
            im.verify()  # cheap structural check
        with Image.open(io.BytesIO(data)) as im:
            width, height = im.size
            fmt = (im.format or "").lower()
    except Exception:
        return None

    ext = sniff_ext(data)
    out_dir.mkdir(parents=True, exist_ok=True)
    # Some source ids embed a prompt fragment and run long; APFS caps a name at 255
    # bytes. Truncate the stem but keep it unique by appending a hash prefix.
    digest = sha256_bytes(data)
    if len(stem) > 180:
        stem = f"{stem[:170]}_{digest[:8]}"
    path = out_dir / f"{stem}.{ext}"
    path.write_bytes(data)

    return Written(
        path=path,
        sha256=digest,
        bytes=len(data),
        width=width,
        height=height,
        format=fmt or ext,
    )


def rel_to_data(path: Path) -> str:
    """Path relative to the data root when it lives there, absolute otherwise.

    Keeps the manifest portable for real fetches without breaking tests that write
    into a tmpdir.
    """
    from bench import paths

    try:
        return str(path.relative_to(paths.data_root()))
    except ValueError:
        return str(path)
