"""No-reference quality estimation.

Two jobs. Near term it validates the degradation simulator: if a rung requests QF 75, the
estimator should read back roughly 75, and the distribution of simulated rungs should
overlap the distribution measured from ReWIND's real in-the-wild images. Later it feeds the
quality-conditioned calibration in Task 7, where the whole point is that a badly damaged
input should collapse toward zero confidence rather than producing a crisp wrong answer.

Features implemented here are cheap and reimplementable on-device in Swift, which is a hard
constraint: anything the Mac harness uses for calibration has to be computable in the app.
That rules out the learned NR-IQA models QuAD uses (QCN, LoDa, TReS) as the primary
estimator, though ReWIND ships their scores so we can check ours against them.

QF estimation note: reading a quality factor back from pixels alone is approximate. When a
JPEG's quantisation tables are present we read them directly, which is exact; for PNG or
raw pixel input we fall back to a blockiness proxy, which is not. The two are reported
distinctly rather than blended, because pretending an estimate is a measurement is how
calibration tables end up lying.
"""

from __future__ import annotations

import io
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.fft import dctn

# Standard JPEG luminance quantisation table (Annex K). Comparing an actual table against
# this recovers the quality factor the encoder used.
STD_LUMA_Q = np.array(
    [
        [16, 11, 10, 16, 24, 40, 51, 61],
        [12, 12, 14, 19, 26, 58, 60, 55],
        [14, 13, 16, 24, 40, 57, 69, 56],
        [14, 17, 22, 29, 51, 87, 80, 62],
        [18, 22, 37, 56, 68, 109, 103, 77],
        [24, 35, 55, 64, 81, 104, 113, 92],
        [49, 64, 78, 87, 103, 121, 120, 101],
        [72, 92, 95, 98, 112, 100, 103, 99],
    ],
    dtype=np.float64,
)

UNCOMPRESSED_QF = 200  # the sentinel AncesTree and ReWIND both use


@dataclass(frozen=True)
class QualityFeatures:
    width: int
    height: int
    megapixels: float
    qf_exact: int | None  # from quantisation tables; None when unavailable
    qf_estimated: float  # always populated, approximate when qf_exact is None
    qf_source: str  # "quant_table" | "blockiness_proxy" | "lossless"
    blockiness: float  # 8x8 grid discontinuity energy
    block_dct_energy: float  # mean high-frequency DCT energy per 8x8 block
    upscale_score: float  # high-frequency deficit; high => likely upscaled
    laplacian_var: float  # sharpness; low => blurred or heavily downscaled

    def as_row(self) -> dict:
        return asdict(self)


def _luma(img: Image.Image) -> np.ndarray:
    return np.asarray(img.convert("L"), dtype=np.float64)


def qf_from_quant_table(table: np.ndarray) -> int:
    """Invert the standard JPEG quality-to-table mapping.

    The encoder scales the standard table by a factor derived from quality; dividing
    elementwise recovers that factor, and the median is robust to clamped entries.
    """
    tbl = np.asarray(table, dtype=np.float64).reshape(8, 8)
    ratio = np.median(tbl / STD_LUMA_Q)
    if ratio <= 0:
        return 100

    # libjpeg: scale_factor = 5000/q when q < 50, else 200 - 2q, and
    # table = (std * scale_factor + 50) / 100, so ratio = scale_factor / 100.
    #
    #   q < 50  : ratio = 50/q            -> q = 50 / ratio
    #   q >= 50 : ratio = (200 - 2q)/100  -> q = 100 - 50 * ratio
    #
    # Both branches agree at q = 50 (ratio = 1.0). Getting the second coefficient wrong
    # (100 instead of 50) reads back 2q - 100, which looks plausible near q=95 and diverges
    # badly at low quality — the readback test is what surfaced it.
    if ratio > 1.0:
        q = 50.0 / ratio
    else:
        q = 100.0 - 50.0 * ratio
    return int(np.clip(round(q), 1, 100))


def read_jpeg_qf(data: bytes) -> int | None:
    """Exact QF when the payload is a JPEG carrying quantisation tables."""
    try:
        with Image.open(io.BytesIO(data)) as im:
            if im.format != "JPEG":
                return None
            q = getattr(im, "quantization", None)
            if not q:
                return None
            return qf_from_quant_table(np.array(q[0], dtype=np.float64))
    except Exception:
        return None


def blockiness(luma: np.ndarray) -> float:
    """Discontinuity across 8x8 boundaries relative to within-block differences.

    A JPEG leaves steps on the block grid. Ratio near 1 means no grid structure; higher
    means visible blocking, which correlates inversely with quality factor.
    """
    h, w = luma.shape
    if h < 24 or w < 24:
        return 0.0

    dh = np.abs(np.diff(luma, axis=1))
    dv = np.abs(np.diff(luma, axis=0))

    col_on = dh[:, 7::8]
    row_on = dv[7::8, :]
    mask_c = np.ones(dh.shape[1], dtype=bool)
    mask_c[7::8] = False
    mask_r = np.ones(dv.shape[0], dtype=bool)
    mask_r[7::8] = False
    col_off = dh[:, mask_c]
    row_off = dv[mask_r, :]

    on = (col_on.mean() + row_on.mean()) / 2.0
    off = (col_off.mean() + row_off.mean()) / 2.0
    return float(on / off) if off > 1e-9 else 0.0


def block_dct_energy(luma: np.ndarray, max_blocks: int = 4096) -> float:
    """Mean high-frequency DCT energy over 8x8 blocks.

    Quantisation zeroes high-frequency coefficients, so this falls as quality falls.
    Subsampled because we run it over thousands of images.
    """
    h, w = luma.shape
    bh, bw = h // 8, w // 8
    if bh < 1 or bw < 1:
        return 0.0

    blocks = luma[: bh * 8, : bw * 8].reshape(bh, 8, bw, 8).transpose(0, 2, 1, 3)
    blocks = blocks.reshape(-1, 8, 8)
    if len(blocks) > max_blocks:
        idx = np.linspace(0, len(blocks) - 1, max_blocks).astype(int)
        blocks = blocks[idx]

    coef = np.abs(dctn(blocks - 128.0, axes=(1, 2), norm="ortho"))
    hf = np.ones((8, 8), dtype=bool)
    hf[:4, :4] = False  # keep only the high-frequency quadrant band
    return float(coef[:, hf].mean())


def upscale_score(luma: np.ndarray) -> float:
    """High-frequency deficit in the FFT spectrum.

    Upscaling invents no detail, so the outer spectrum stays empty relative to the inner.
    Returns roughly 0 for a natively sharp image and rises as interpolation dominates.
    """
    h, w = luma.shape
    if h < 64 or w < 64:
        return 0.0
    win = np.hanning(h)[:, None] * np.hanning(w)[None, :]
    mag = np.abs(np.fft.fftshift(np.fft.fft2(luma * win)))
    cy, cx = h // 2, w // 2
    yy, xx = np.ogrid[:h, :w]
    r = np.sqrt(((yy - cy) / cy) ** 2 + ((xx - cx) / cx) ** 2)

    inner = mag[(r > 0.15) & (r <= 0.45)].mean()
    outer = mag[r > 0.75].mean()
    if inner <= 1e-9:
        return 0.0
    return float(np.clip(1.0 - (outer / inner), 0.0, 1.0))


def laplacian_var(luma: np.ndarray) -> float:
    """Variance of the Laplacian: the standard cheap sharpness measure."""
    k = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]], dtype=np.float64)
    a = luma
    if a.shape[0] < 3 or a.shape[1] < 3:
        return 0.0
    # Valid-region convolution without pulling in scipy.signal.
    out = (
        k[0, 1] * a[:-2, 1:-1]
        + k[1, 0] * a[1:-1, :-2]
        + k[1, 1] * a[1:-1, 1:-1]
        + k[1, 2] * a[1:-1, 2:]
        + k[2, 1] * a[2:, 1:-1]
    )
    return float(out.var())


def qf_from_blockiness(b: float) -> float:
    """Crude monotone map from blockiness to an apparent QF.

    Explicitly a proxy, reported as such via `qf_source`. Anchored so that blockiness ~1
    (no grid structure) reads as high quality and strong blocking reads as low.
    """
    if b <= 1.02:
        return 100.0
    return float(np.clip(100.0 - 55.0 * np.log1p(b - 1.0) / np.log1p(1.0), 30.0, 100.0))


def features(
    image: Image.Image | Path | str,
    *,
    raw_bytes: bytes | None = None,
) -> QualityFeatures:
    """Compute all features. Pass `raw_bytes` to enable exact QF from quantisation tables."""
    if isinstance(image, (str, Path)):
        path = Path(image)
        if raw_bytes is None:
            raw_bytes = path.read_bytes()
        img = Image.open(io.BytesIO(raw_bytes))
        img.load()
    else:
        img = image

    luma = _luma(img)
    w, h = img.size

    exact = read_jpeg_qf(raw_bytes) if raw_bytes else None
    blk = blockiness(luma)

    if exact is not None:
        qf_est, src = float(exact), "quant_table"
    elif raw_bytes and raw_bytes[:8] == b"\x89PNG\r\n\x1a\n":
        # Lossless container. It may still carry the artefacts of an earlier lossy step,
        # so the proxy is reported rather than claiming QF 200.
        qf_est, src = qf_from_blockiness(blk), "lossless"
    else:
        qf_est, src = qf_from_blockiness(blk), "blockiness_proxy"

    return QualityFeatures(
        width=w,
        height=h,
        megapixels=round(w * h / 1e6, 4),
        qf_exact=exact,
        qf_estimated=round(qf_est, 2),
        qf_source=src,
        blockiness=round(blk, 5),
        block_dct_energy=round(block_dct_energy(luma), 4),
        upscale_score=round(upscale_score(luma), 5),
        laplacian_var=round(laplacian_var(luma), 3),
    )
