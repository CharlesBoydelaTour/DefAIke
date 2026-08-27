# Reproduce the work

This page distinguishes three reproducibility levels: documentation, data/metrics, and model/Core ML inference. The first is a clean install. The latter two require large local artifacts and research dependencies that are not yet packaged as a stable lockfile.

## Documentation

```bash
uv venv --python 3.12
uv pip install -e ".[docs]"
mkdocs serve
```

Preview at <http://127.0.0.1:8000>. Build exactly as validation does:

```bash
mkdocs build --strict
```

The `docs` extra is pinned to:

```text
mkdocs==1.6.1
mkdocs-material==9.6.18
```

## Environment and dependency boundary

The base package declares the corpus and metric stack. Model adapters import additional research dependencies that are present in the measured environment but are not yet exposed as a tested `models` extra or lockfile.

Measured model environment:

```text
Python             3.12.12, arm64
PyTorch            2.13.0
Torchvision        0.28.0
Timm                1.0.28
Transformers        5.15.1
OpenCLIP            3.3.0
Safetensors         0.8.0
coremltools         9.0
Hardware            Apple M3 Pro
MPS                 available
```

To mirror this environment after the base install:

```bash
uv pip install --python .venv/bin/python \
  torch==2.13.0 torchvision==0.28.0 timm==1.0.28 \
  transformers==5.15.1 open-clip-torch==3.3.0 safetensors==0.8.0 \
  coremltools==9.0
```

!!! warning "Reproducibility gap"
    There is no `uv.lock`, and several base dependencies still use lower bounds. A clean model-inference install has not been validated from only `pyproject.toml`. The commands above describe the measured environment; they are not yet a supported release lock. `coremltools 9.0` also warns that PyTorch 2.13 is newer than its tested range, so parity is mandatory.

## Fetch and verify the corpus

The corpus requires roughly 8.01 GB retained and more transfer because So-Fake row groups are atomic.

```bash
bench datasets
bench index
bench plan
bench fetch
bench datasets --resolved
bench verify
```

`bench verify` is non-destructive. Do **not** add `--prune` unless you intend to delete every file under `data/images/` that is not referenced by the current manifest.

Expected resolved totals:

```text
10,832 images
5,268 real / 5,564 fake
8,005,629,351 referenced bytes
manifest SHA-256:
3753b8350a710e6bb5234b04ec717d512b09a9c56ff6a7cd707929603980504d
```

## Inspect protocol before inference

```bash
bench rungs
bench probe-metadata --sample 1200
```

The first command exposes the resolution shortcut and exact rung definitions. The second is optional if `data/cache/metadata_probe.parquet` already exists.

## Run the full commfor matrix on M3

PyTorch automatically selects `mps` when available. Eight workers are the measured M3 Pro sweet spot; `caffeinate` prevents idle sleep during a long run.

```bash
caffeinate -i env BENCH_WORKERS=8 \
  .venv/bin/bench eval \
  --detectors commfor,commfor-lowq \
  --rung clean,light,moderate,heavy,severe,thumbnail,screenshot,screenshot_shared \
  --boot 400
```

Use `--resume` only when you want to keep already-completed detector/rung pairs. Omitting it intentionally recomputes and replaces those pairs. Each completed rung checkpoints into `data/scores.parquet`.

Expected coverage after contamination exclusion:

```text
commfor:frontier-2026-08  9,582 score rows per rung
commfor:lowq-2026-08      9,582 score rows per rung
```

The published paired-delta table used an ad hoc 2,000-resample analysis script over 9,569 distinct IDs. That analysis has not yet been promoted to a stable CLI command. The served [CSV snapshot](../assets/data/commfor-full-coverage.csv) and score-table hash make the current result auditable, but one-command paired-report generation remains a documentation/reproducibility task.

Current score artifact:

```text
314,900 rows / 15 detector labels / 8 rungs
SHA-256:
a200c40ad185eeed323b4b69a97ea0fe4f3b96a64d713b75bfc2d11c0fd823a9
```

## Convert and inspect Core ML

```bash
bench coreml --variant lowq --force --parity-n 96
```

Expected gates:

```text
43.7 MB FP16 mlpackage, iOS 17+
262 / 264 assigned operations on ANE (99.2%)
Spearman rho 0.999949
96 / 96 decisions agree at raw logit 1.390625
```

Generated artifacts are local and ignored:

```text
data/coreml/commfor-lowq-384.mlpackage/
data/coreml/commfor-lowq-384.mlmodelc/
```

The model weight blob SHA-256 is:

```text
f073f8a325f63e35ef0668c985ac762486a1b50e57dcf5ae33d4647bd26d4c1e
```

## Run tests

```bash
.venv/bin/python -m pytest -q
```

Expected normal result: 266 passed, one skipped. To include the expensive Core ML integration test:

```bash
RUN_COREML_TESTS=1 .venv/bin/python -m pytest tests/test_coreml.py -q
```

## What cannot yet be reproduced

- No real-iPhone Core ML Performance Report or score-parity run exists.
- Simulator fidelity against physical iPhone screenshots has not been completed.
- B-Free cannot be rerun while its sole official host returns HTTP 502.
- The app, calibration table, signed bundle, and static update manifest do not exist.
- No Git metadata or remote exists in this workspace, so documentation cannot identify a commit hash or provide hosted source links.

See [Artifact registry](artifacts.md) and [Limitations](../project/limitations.md).
