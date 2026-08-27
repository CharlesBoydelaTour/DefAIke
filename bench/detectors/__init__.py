"""Detector implementations, all measured through the same interface."""

from bench.detectors.base import (
    BaseModelDetector,
    Detector,
    DetectorInfo,
    ScoreProvider,
)
from bench.detectors.reference import ReferenceDetector

__all__ = [
    "BaseModelDetector",
    "Detector",
    "DetectorInfo",
    "ScoreProvider",
    "ReferenceDetector",
]
