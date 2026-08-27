# Limitations and next boundary

This page is the stop line between completed Phase 0 evidence and future app work. It records what the benchmark and Core ML gate do **not** establish. It does not specify screens, architecture, APIs, or an implementation plan for the iOS app.

## Model validity and aging

### No post-cutoff generator test exists

The selected checkpoint was trained on named 2026 generator families. The evaluation uses different collections and excludes known OpenFake overlap, but some evaluated generator families are still represented in training. No fixed corpus can contain a generator released after the checkpoint.

The current result therefore supports **cross-collection generalization within a contemporary generator set**, not unseen-future-generator robustness. Recurring contamination-checked evaluation is required before any claim survives a model refresh.

### The selected release is independent and not peer-reviewed

The low-quality checkpoint is an independent continuation of the peer-reviewed Community Forensics base, not an official OwensLab release. Its configuration records `redteam_validation_valid: false`; only its low-quality promotion gate passed. The frontier checkpoint's red-team report cannot be inherited after further fine-tuning.

The project has trained no model. Upstream training declarations and model-card thresholds remain third-party evidence even when this project measures the released weights.

### Scope is whole-image synthesis

Localized AI edits, composites, VAE reconstruction edge cases, video, and audio are outside the measured task. A low synthetic score must not be described as proof that an image is authentic or untouched.

See the [shipping model card](../results/shipping-model.md#known-failure-modes) for the exact model contract.

## Input and domain gaps

### Sub-440 px evidence is weak

The selected model resizes the short edge to 440 px and center-crops 384 px. Inputs below 440 px must be upscaled and are outside that interpolation regime. On the 144 px `thumbnail` rung, full-corpus AUC is 0.8313 but `TPR@1%FPR` is only 0.249.

Lowq is still better than frontier below 440 px, so routing to the older checkpoint does not solve the problem. The unresolved requirement is an evidence-based abstention policy—not a second model and not an “authentic” verdict.

### Real phone-photo coverage is unverified

Only 3% of real images in the metadata probe expose a camera make. Every identifiable body was a professional DSLR or mirrorless camera; no phone was confirmed. The remaining 97% may contain phone captures, but that is unknown. The false-positive tail has therefore not been validated on a dedicated contemporary iPhone-photo set.

### Provenance is usually absent

The 2,400-image metadata probe found no C2PA hint in either class. Screenshots structurally remove manifests, and platform processing often strips metadata. Separate signed fixtures can test a future validator, but the current corpus cannot measure end-to-end C2PA verdict behavior. Absence of provenance must remain “no evidence,” never evidence of authenticity.

## Evaluation and statistical limits

### The 1% FPR tail is thin

Only 53 real images define 1% FPR in the full corpus, and roughly 50 do so after commfor contamination exclusion. Bootstrap intervals are mandatory, but resampling cannot manufacture domain coverage that is not present. Small changes to the extreme real-score tail can move the operating threshold materially.

### Thirteen manifest IDs collide

The manifest has 10,832 rows but only 10,819 distinct IDs. All 13 duplicate-ID groups are same-label rows in ReWIND's `viral_bfree` subset. `bench/sources/rewind.py::_stem_for()` strips the file extension, so archive members that differ only by extension can receive the same ID.

The files, paths, hashes, and score rows remain separate. However, paired deltas collapse by ID and therefore use **9,569 distinct eligible IDs**, while per-rung coverage tables contain **9,582 eligible score rows**. Both counts are reported throughout the site. The ID construction must be corrected and artifacts regenerated before an archival corpus release.

The corpus contract also records four duplicate content hashes. Near-duplicates are expected in ReWIND, but those four cases have not been individually classified as expected or erroneous.

### Collection and resolution shortcuts remain possible

Native dimensions alone reach 64.1% balanced accuracy because generator canvases are highly concentrated. The degradation ladder clears that shortcut for deployment rungs, but clean/native results remain diagnostic only. ReWIND also pools collections with different histories, and B-Free's authors assembled its largest included subset; source-sliced results are necessary to expose collection provenance.

### The simulator is not a physical iPhone

The deterministic screenshot path models a cropped image region using remembered iPhone 15 Pro geometry. ReWIND quality-factor statistics match the simulator's compression distribution, but device geometry, interpolation, color management, screenshot encoding, and crop behavior have not been validated on hardware.

M3 Pro timings are useful relative measurements. They are not iPhone latency, memory, energy, thermal, or extension-budget evidence.

See the [benchmark protocol](../methodology/benchmark.md) for exact rungs and [corpus card](../methodology/corpus.md#bias-and-shortcut-audit) for the measured biases.

## Calibration and verdict gaps

The checkpoint's raw-logit boundary of 1.390625 is an upstream calibrated boundary, not a finished product policy. This project has not yet produced:

- a held-out quality-aware threshold or abstention table;
- uncertainty intervals for a final user-facing verdict policy;
- a rule for inputs below the model's information floor;
- physical-device parity for preprocessing and logits;
- validation that single-image calibration inherits any benefit reported for multi-copy QuAD aggregation.

Core ML FP16 conversion measured a maximum absolute logit delta of 0.13058 on 96 fixtures. That supports a minimum conversion-safety envelope of approximately ±0.131 logit; it does not choose the wider quality-aware abstention band.

## Deployment evidence still missing

The 43.7 MB FP16 package passed conversion, ANE placement, and Mac parity gates. The following remain unmeasured:

| Missing evidence | Current boundary |
|---|---|
| Physical-iPhone score parity | Only PyTorch/Core ML parity on 96 Mac fixtures exists |
| iPhone latency and cold load | M3 Pro relative timings do not transfer numerically |
| Memory, power, and thermal behavior | No tethered-device report or soak run exists |
| Orientation, color-space, interpolation, and crop parity | Python preprocessing is fixed; an iOS implementation does not exist |
| Extension memory viability | No share extension exists |
| Int8 behavior | Not attempted because FP16 currently fits the size target |

The ANE result answers a narrower question: the converted transformer graph can place on Neural Engine. It does not certify phone readiness. See the [Core ML deployment gate](../results/coreml.md).

## Licensing and release readiness

Every enabled evaluation slice is non-commercial. The corpus supports the project's current nonprofit, free research posture, but it cannot silently become a commercial training or evaluation asset. Written clarification for free nonprofit App Store distribution under the GRIP-UNINA terms remains open.

The selected weights are MIT-licensed, but that does not override dataset terms. The repository also lacks a root `LICENSE` file, so the intended open-source code licence is not yet legally expressed.

Large generated artifacts are ignored under `data/`. The site publishes compact evidence snapshots and hashes, not the corpus, scores, or Core ML bundle. A signed, versioned model bundle, integrity manifest, update/rollback contract, and immutable source revision do not exist. There is no Git metadata or remote in this workspace, so hosted source links and commit-pinned evidence links cannot be provided yet.

B-Free remains independently unverified because its only official weight endpoint returned HTTP 502 at the August 2026 snapshot. Its imported ReWIND logits are labelled `AUTHOR LOGITS`, not project inference.

## Boundary before app specification

Phase 0 has fixed the candidate model, preprocessing contract, benchmark evidence, and Core ML feasibility. Before app-spec design begins, the unresolved evidence and governance items are:

1. correct the 13 ReWIND ID collisions and regenerate affected evidence;
2. define and validate quality-aware calibration and abstention on held-out data;
3. validate screenshot and preprocessing parity on physical iPhones;
4. measure score parity, latency, memory, power, and thermal behavior on target devices;
5. add representative contemporary phone-camera reals to the false-positive audit;
6. resolve repository and dataset-distribution licensing;
7. define a reproducible, signed model/calibration release artifact.

No SwiftUI flow, Photos or share-sheet ingest, C2PA integration, fusion presentation, network policy, bundle updater, or app architecture is designed in this documentation pass. Those are deliberately deferred rather than implied by the research prototype.

For the exact done/partial/future ledger, see [Current status](../status.md). For reproducibility gaps, see [Reproduce the work](../engineering/reproduce.md#what-cannot-yet-be-reproduced).
