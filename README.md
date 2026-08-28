# DefAIke

A frugal, private detector for whole-image AI generation, designed for on-device iOS inference. The project is nonprofit, open-source in intent, and free to users.

**Current state:** the Phase 0 corpus, benchmark harness, detector evaluation, shipping-model decision, and Core ML deployment gate are complete. The iOS app is specified and its project skeleton exists under [`ios/`](ios/README.md); no app behavior is implemented yet.

## What is complete

- **10,832-image / 8.01 GB evaluation corpus** with contemporary reals and 2026 generators.
- **Eight deterministic degradation rungs**, including screenshot and shared-screenshot paths.
- **314,900 persisted scores** from 15 detector labels, with `TPR@1%FPR` as the headline metric.
- **Shipping candidate selected:** `Thermostatic/community-forensics-low-quality-detector-2026-08` (MIT, ViT-S/16, 21.8M parameters).
- **Core ML gate passed:** 43.7 MB FP16 package, 99.2% ANE operation placement, 100% decision agreement with PyTorch on 96 parity fixtures.
- **267 tests collected:** 266 pass; the opt-in Core ML integration test is skipped by default.

The authoritative narrative is the [MkDocs documentation](docs/index.md). `PLAN.md` remains the chronological research and planning log; some early tables there are deliberately retained even though later full-coverage runs supersede them.

## Documentation

```bash
uv venv --python 3.12
uv pip install -e ".[docs]"
mkdocs serve
```

Open <http://127.0.0.1:8000>. Build the publishable site with warnings treated as errors:

```bash
mkdocs build --strict
```

Start with:

- [Current status](docs/status.md)
- [Corpus and contamination rules](docs/methodology/corpus.md)
- [Benchmark protocol](docs/methodology/benchmark.md)
- [Full-coverage model selection](docs/results/model-selection.md)
- [Shipping model card](docs/results/shipping-model.md)
- [Core ML / ANE results](docs/results/coreml.md)
- [Reproducing the work](docs/engineering/reproduce.md)
- [Known limitations](docs/project/limitations.md)
- [Primary references](docs/references.md)
- [Loading the iOS app onto an iPhone](ON_IPHONE_SETUP.md)

## Benchmark quick start

```bash
uv venv --python 3.12
uv pip install -e ".[dev]"

bench datasets             # declared corpus and licences
bench fetch                # download and resolve into ./data (about 8 GB)
bench verify               # non-destructive integrity check
bench rungs                # exact degradation ladder
bench eval --help          # detector matrix runner
bench coreml --help        # conversion, ANE placement, parity, latency
```

Model adapters use additional research dependencies present in the measured environment but not yet formalized as a clean-install extra; see the [reproducibility notes](docs/engineering/reproduce.md#environment-and-dependency-boundary) before rerunning inference.

## Licence position

Every enabled dataset slice is non-commercial. The evaluation corpus is therefore for nonprofit research and calibration; it is **not** a training set. The selected model weights are MIT-licensed, but the repository does not yet contain a root code licence file—this must be resolved before public release. See the [corpus licence table](docs/methodology/corpus.md#licence-and-distribution-boundary) and [known limitations](docs/project/limitations.md#licensing-and-release-readiness).
