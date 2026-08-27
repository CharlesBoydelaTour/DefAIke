"""Detect surviving metadata in fetched images.

Answers a spec open question: because So-Fake-OOD preserves original file bytes, some rows
may still carry EXIF, XMP, or a C2PA manifest. If they do, this corpus doubles as a Lane A
fixture source and we learn the real-world survival rate of provenance on social platforms.

This is deliberately a detector of *presence*, not a validator. Confirming a manifest is
cryptographically trustworthy is Lane A's job on-device via c2pa-swift, and nothing here
should be mistaken for that. A present-but-unverified manifest is not evidence.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path

from PIL import Image

# C2PA embeds a JUMBF superbox; in JPEG it rides in APP11. Presence of these byte
# sequences is a strong hint, not proof, of a manifest.
C2PA_MARKERS = (b"jumb", b"c2pa", b"urn:uuid:", b"c2pa.assertions")
XMP_MARKERS = (b"<x:xmpmeta", b"http://ns.adobe.com/xap/1.0/")
# IPTC digitalSourceType is the field Meta and C2PA both key off for AI disclosure.
AI_DISCLOSURE_MARKERS = (
    b"trainedAlgorithmicMedia",
    b"compositeWithTrainedAlgorithmicMedia",
    b"algorithmicMedia",
    b"digitalSourceType",
    b"c2pa.ai-disclosure",
)

# Manifests live near the head of the file; cap the read so this stays cheap on 4000px
# social-media originals.
SCAN_BYTES = 512 * 1024


@dataclass(frozen=True)
class MetadataFindings:
    path: str
    bytes_scanned: int
    has_exif: bool
    exif_tags: int
    has_camera_make: bool
    camera: str
    has_xmp: bool
    has_c2pa_hint: bool
    has_ai_disclosure_hint: bool

    def as_row(self) -> dict:
        return asdict(self)


def probe(path: Path) -> MetadataFindings:
    head = path.open("rb").read(SCAN_BYTES)

    has_exif = exif_tags = 0
    make = model = ""
    try:
        with Image.open(path) as im:
            exif = im.getexif()
            exif_tags = len(exif) if exif else 0
            has_exif = bool(exif_tags)
            if exif:
                make = str(exif.get(271, "") or "").strip()
                model = str(exif.get(272, "") or "").strip()
    except Exception:
        pass

    camera = " ".join(p for p in (make, model) if p)
    return MetadataFindings(
        path=str(path.name),
        bytes_scanned=len(head),
        has_exif=bool(has_exif),
        exif_tags=exif_tags,
        has_camera_make=bool(make),
        camera=camera,
        has_xmp=any(m in head for m in XMP_MARKERS),
        has_c2pa_hint=any(m in head for m in C2PA_MARKERS),
        has_ai_disclosure_hint=any(m in head for m in AI_DISCLOSURE_MARKERS),
    )


def probe_many(paths_: list[Path]) -> list[MetadataFindings]:
    out: list[MetadataFindings] = []
    for p in paths_:
        try:
            out.append(probe(p))
        except Exception:
            continue
    return out
