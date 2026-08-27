"""Load and validate datasets/testset.toml.

The spec is the contract. Everything downstream reads it rather than hardcoding
counts, licences, or filters. Validation is deliberately strict: a spec whose
arithmetic doesn't close is a spec that will silently mislead a benchmark.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from bench import paths


class SpecError(ValueError):
    """The spec is internally inconsistent or missing something required."""


@dataclass(frozen=True)
class Slice:
    """One source of images in the evaluation set."""

    id: str
    source: str
    role: str  # real | fake | mixed
    licence: str
    commercial: bool
    capture_era: str
    take: int
    est_bytes: int
    enabled: bool = True
    gated: bool | str = False
    verified: bool = True
    revision: str | None = None
    config: str | None = None
    split: str | None = None
    manifest: str | None = None
    archive_md5: str | None = None
    notes: str = ""
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @property
    def kind(self) -> str:
        """Fetcher dispatch key, derived from the source URI scheme."""
        if self.source.startswith("hf:"):
            return "hf_parquet"
        if self.source.startswith(("http://", "https://")):
            return "archive"
        raise SpecError(f"{self.id}: unrecognised source scheme: {self.source!r}")

    @property
    def hf_repo(self) -> str:
        if not self.source.startswith("hf:"):
            raise SpecError(f"{self.id}: not a Hugging Face source")
        return self.source[3:]

    def filters(self) -> dict[str, list[str]]:
        """Column -> allowed values. Empty list means 'no constraint'."""
        return {
            "scope_include": self.raw.get("filter_label", []),
            "scope_exclude": self.raw.get("filter_scope_exclude", []),
            "generator": self.raw.get("filter_generator", []),
            "release_form": self.raw.get("filter_release_form", []),
            "platform_exclude": self.raw.get("excluded_platforms", []),
        }


@dataclass(frozen=True)
class Spec:
    name: str
    created: str
    ceiling_bytes: int
    projected_bytes: int
    projected_items: int
    slices: tuple[Slice, ...]
    balance: dict[str, Any]
    fetch: dict[str, Any]
    licence_position: dict[str, Any]
    open_questions: list[str]
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @property
    def enabled(self) -> tuple[Slice, ...]:
        return tuple(s for s in self.slices if s.enabled)

    @property
    def disabled(self) -> tuple[Slice, ...]:
        return tuple(s for s in self.slices if not s.enabled)

    def slice_by_id(self, slice_id: str) -> Slice:
        for s in self.slices:
            if s.id == slice_id:
                return s
        raise KeyError(f"no slice {slice_id!r}; have {[s.id for s in self.slices]}")


_REQUIRED = ("id", "source", "role", "licence", "commercial", "capture_era", "take", "est_bytes")


def load(path: Path | None = None) -> Spec:
    """Parse and validate the spec. Raises SpecError on any inconsistency."""
    path = path or paths.spec_path()
    if not path.exists():
        raise SpecError(f"spec not found at {path}")

    with path.open("rb") as fh:
        raw = tomllib.load(fh)

    for section in ("meta", "budget", "slice", "balance"):
        if section not in raw:
            raise SpecError(f"spec missing required section [{section}]")

    slices: list[Slice] = []
    for entry in raw["slice"]:
        missing = [k for k in _REQUIRED if k not in entry]
        if missing:
            raise SpecError(f"slice {entry.get('id', '<unnamed>')!r} missing keys: {missing}")
        known = {f for f in Slice.__dataclass_fields__ if f != "raw"}
        slices.append(Slice(**{k: v for k, v in entry.items() if k in known}, raw=entry))

    ids = [s.id for s in slices]
    if len(ids) != len(set(ids)):
        raise SpecError(f"duplicate slice ids: {ids}")

    budget = raw["budget"]
    spec = Spec(
        name=raw["meta"]["name"],
        created=raw["meta"]["created"],
        ceiling_bytes=budget["ceiling_bytes"],
        projected_bytes=budget["projected_bytes"],
        projected_items=budget["projected_items"],
        slices=tuple(slices),
        balance=raw["balance"],
        fetch=raw.get("fetch", {}),
        licence_position=raw.get("licence_position", {}),
        open_questions=raw.get("open_questions", {}).get("items", []),
        raw=raw,
    )
    _validate(spec)
    return spec


def _validate(spec: Spec) -> None:
    """Check the spec's arithmetic closes. These caught a real typo on first run."""
    errs: list[str] = []

    got_bytes = sum(s.est_bytes for s in spec.enabled)
    got_items = sum(s.take for s in spec.enabled)
    if got_bytes != spec.projected_bytes:
        errs.append(f"est_bytes sum {got_bytes:,} != projected_bytes {spec.projected_bytes:,}")
    if got_items != spec.projected_items:
        errs.append(f"take sum {got_items:,} != projected_items {spec.projected_items:,}")
    if got_bytes > spec.ceiling_bytes:
        errs.append(f"projection {got_bytes:,} exceeds ceiling {spec.ceiling_bytes:,}")

    bal = spec.balance
    if {"real", "fake", "items"} <= bal.keys():
        if bal["real"] + bal["fake"] != bal["items"]:
            errs.append(f"balance {bal['real']}+{bal['fake']} != {bal['items']}")
        if "real_frac" in bal:
            actual = bal["real"] / bal["items"]
            if abs(actual - bal["real_frac"]) > 0.001:
                errs.append(f"real_frac {bal['real_frac']} != computed {actual:.3f}")

    for s in spec.slices:
        if s.role not in ("real", "fake", "mixed"):
            errs.append(f"{s.id}: role must be real|fake|mixed, got {s.role!r}")
        if s.take <= 0:
            errs.append(f"{s.id}: take must be positive")
        pool = s.raw.get("pool_total")
        if pool is not None and s.take > pool:
            errs.append(f"{s.id}: take {s.take} exceeds pool_total {pool}")
        by_gen = s.raw.get("pool_by_generator")
        if by_gen and pool is not None and sum(by_gen.values()) != pool:
            errs.append(f"{s.id}: pool_by_generator sums to {sum(by_gen.values())}, pool_total {pool}")
        by_plat = s.raw.get("pool_by_platform")
        usable = s.raw.get("pool_usable")
        if by_plat and usable is not None and sum(by_plat.values()) != usable:
            errs.append(f"{s.id}: pool_by_platform sums to {sum(by_plat.values())}, pool_usable {usable}")

    if errs:
        raise SpecError("spec validation failed:\n  - " + "\n  - ".join(errs))
