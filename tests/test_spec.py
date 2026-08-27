"""Spec loading and validation.

The validator earns its keep: it caught a real typo (`8_690_general`) on the first run of
the actual spec file. These tests pin that behaviour so a future edit that breaks the
arithmetic fails here rather than silently skewing a benchmark.
"""

from __future__ import annotations

import textwrap

import pytest

from bench import spec

MINIMAL = """
[meta]
name = "t"
created = "2026-01-01"

[budget]
ceiling_bytes = 1000
projected_bytes = 300
projected_items = 30

[[slice]]
id = "a"
source = "hf:org/ds"
role = "real"
licence = "MIT"
commercial = true
capture_era = "2026"
take = 10
est_bytes = 100

[[slice]]
id = "b"
source = "https://example.com/x.zip"
role = "fake"
licence = "MIT"
commercial = true
capture_era = "2026"
take = 20
est_bytes = 200

[balance]
items = 30
real = 10
fake = 20
real_frac = 0.333
"""


def write(tmp_path, text):
    p = tmp_path / "testset.toml"
    p.write_text(textwrap.dedent(text))
    return p


def test_loads_minimal_spec(tmp_path):
    sp = spec.load(write(tmp_path, MINIMAL))
    assert sp.name == "t"
    assert len(sp.slices) == 2
    assert sp.projected_items == 30


def test_source_scheme_drives_fetcher_dispatch(tmp_path):
    sp = spec.load(write(tmp_path, MINIMAL))
    assert sp.slice_by_id("a").kind == "hf_parquet"
    assert sp.slice_by_id("a").hf_repo == "org/ds"
    assert sp.slice_by_id("b").kind == "archive"


def test_disabled_slices_excluded_from_budget(tmp_path):
    """A disabled slice must not count toward the projection.

    Note the key has to sit inside slice b's own table: appending it to the end of the
    document would attach it to [balance] instead, which is how this test first failed.
    """
    text = MINIMAL.replace(
        'est_bytes = 200\n',
        'est_bytes = 200\nenabled = false\n',
    ).replace("projected_bytes = 300", "projected_bytes = 100").replace(
        "projected_items = 30", "projected_items = 10"
    )
    sp = spec.load(write(tmp_path, text))
    assert [s.id for s in sp.enabled] == ["a"]
    assert [s.id for s in sp.disabled] == ["b"]


def test_rejects_byte_sum_mismatch(tmp_path):
    bad = MINIMAL.replace("projected_bytes = 300", "projected_bytes = 999")
    with pytest.raises(spec.SpecError, match="est_bytes sum"):
        spec.load(write(tmp_path, bad))


def test_rejects_item_sum_mismatch(tmp_path):
    bad = MINIMAL.replace("projected_items = 30", "projected_items = 77")
    with pytest.raises(spec.SpecError, match="take sum"):
        spec.load(write(tmp_path, bad))


def test_rejects_projection_over_ceiling(tmp_path):
    bad = MINIMAL.replace("ceiling_bytes = 1000", "ceiling_bytes = 50")
    with pytest.raises(spec.SpecError, match="exceeds ceiling"):
        spec.load(write(tmp_path, bad))


def test_rejects_balance_that_does_not_sum(tmp_path):
    bad = MINIMAL.replace("fake = 20\nreal_frac", "fake = 99\nreal_frac")
    with pytest.raises(spec.SpecError, match="balance"):
        spec.load(write(tmp_path, bad))


def test_rejects_take_exceeding_pool(tmp_path):
    bad = MINIMAL + "\n[[slice]]\n" + textwrap.dedent("""
        id = "c"
        source = "hf:o/d"
        role = "fake"
        licence = "MIT"
        commercial = true
        capture_era = "2026"
        take = 500
        est_bytes = 0
        pool_total = 10
        enabled = false
    """)
    with pytest.raises(spec.SpecError, match="exceeds pool_total"):
        spec.load(write(tmp_path, bad))


def test_rejects_duplicate_slice_ids(tmp_path):
    bad = MINIMAL.replace('id = "b"', 'id = "a"')
    with pytest.raises(spec.SpecError, match="duplicate slice ids"):
        spec.load(write(tmp_path, bad))


def test_rejects_bad_role(tmp_path):
    bad = MINIMAL.replace('role = "real"', 'role = "banana"')
    with pytest.raises(spec.SpecError, match="role must be"):
        spec.load(write(tmp_path, bad))


def test_missing_file_is_clear(tmp_path):
    with pytest.raises(spec.SpecError, match="spec not found"):
        spec.load(tmp_path / "nope.toml")


# --- the real spec, not a fixture ---------------------------------------------------


def test_shipped_spec_is_valid():
    """datasets/testset.toml must always load and validate."""
    sp = spec.load()
    assert sp.name == "defaike-v0-testset"
    assert sp.projected_bytes < sp.ceiling_bytes
    assert len(sp.enabled) >= 1


def test_shipped_spec_every_slice_declares_licence_and_era():
    """Task 1 requires per-image provenance; it starts with per-slice provenance."""
    for s in spec.load().slices:
        assert s.licence, f"{s.id} has no licence"
        assert s.capture_era, f"{s.id} has no capture_era"
        assert isinstance(s.commercial, bool)


def test_shipped_spec_enabled_slices_are_ungated():
    """The whole point of this composition is that it fetches without approval waits."""
    for s in spec.load().enabled:
        assert s.gated is False, f"{s.id} is gated ({s.gated}) but enabled"
