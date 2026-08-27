"""Network helpers: resumable downloads and integrity checking.

Downloads here are large and slow. Everything is resumable, everything is verified,
and nothing is trusted on the strength of an HTTP 200 alone.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import httpx
from tqdm import tqdm

CHUNK = 1 << 20  # 1 MiB


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path, algo: str = "md5") -> str:
    h = hashlib.new(algo)
    with path.open("rb") as fh:
        while chunk := fh.read(CHUNK):
            h.update(chunk)
    return h.hexdigest()


def download(
    url: str,
    dest: Path,
    *,
    expect_md5: str | None = None,
    label: str | None = None,
) -> Path:
    """Download with resume. Verifies expect_md5 if given, and refuses a bad file."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")

    if dest.exists():
        if expect_md5 is None:
            return dest
        got = file_digest(dest, "md5")
        if got == expect_md5:
            return dest
        print(f"  {dest.name}: md5 mismatch on cached copy, refetching")
        dest.unlink()

    have = part.stat().st_size if part.exists() else 0
    headers = {"Range": f"bytes={have}-"} if have else {}

    with httpx.stream("GET", url, headers=headers, follow_redirects=True, timeout=120) as r:
        if have and r.status_code == 200:
            # Server ignored the range request; start over rather than corrupt the file.
            have = 0
            part.unlink(missing_ok=True)
        elif have and r.status_code == 416:
            part.rename(dest)  # already complete
            have = None  # type: ignore[assignment]
        else:
            r.raise_for_status()

        if have is not None:
            total = int(r.headers.get("content-length", 0)) + have
            mode = "ab" if have else "wb"
            with part.open(mode) as fh, tqdm(
                total=total or None,
                initial=have,
                unit="B",
                unit_scale=True,
                unit_divisor=1024,
                desc=label or dest.name,
                leave=False,
            ) as bar:
                for chunk in r.iter_bytes(CHUNK):
                    fh.write(chunk)
                    bar.update(len(chunk))
            part.rename(dest)

    if expect_md5:
        got = file_digest(dest, "md5")
        if got != expect_md5:
            dest.unlink()
            raise OSError(f"{url}: md5 {got} != expected {expect_md5}; file discarded")

    return dest
