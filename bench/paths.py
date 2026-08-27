"""Filesystem layout. One place that knows where things live."""

from __future__ import annotations

import os
from pathlib import Path


def repo_root() -> Path:
    """Repo root, overridable so tests can point at a tmpdir."""
    if env := os.environ.get("DEFAIKE_ROOT"):
        return Path(env).resolve()
    return Path(__file__).resolve().parent.parent


def spec_path() -> Path:
    return repo_root() / "datasets" / "testset.toml"


def data_root() -> Path:
    return repo_root() / "data"


def cache_dir() -> Path:
    """Intermediate artifacts: indexes, archives, partial state. Resumable, disposable."""
    return data_root() / "cache"


def images_dir(slice_id: str) -> Path:
    """Extracted images for one slice."""
    return data_root() / "images" / slice_id


def manifest_path() -> Path:
    """Resolved manifest: one row per image actually on disk."""
    return data_root() / "manifest.parquet"


def index_path(slice_id: str) -> Path:
    """Metadata-only index for a slice, built before any image bytes are fetched."""
    return cache_dir() / f"index_{slice_id}.parquet"


def state_path(slice_id: str) -> Path:
    """Fetch progress, so an interrupted run resumes instead of restarting."""
    return cache_dir() / f"state_{slice_id}.json"


def ensure_dirs() -> None:
    for p in (data_root(), cache_dir(), data_root() / "images"):
        p.mkdir(parents=True, exist_ok=True)
