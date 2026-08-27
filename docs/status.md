# Current status

**Snapshot:** August 2026. This is a state ledger, not an aspirational roadmap.

| Workstream | State | Evidence |
|---|---|---|
| Research survey and licence audit | Complete for Phase 0 | [Landscape](research/landscape.md), [references](references.md) |
| Evaluation corpus | Complete, with documented gaps | 10,832 rows / 8,005,629,351 referenced bytes; [corpus card](methodology/corpus.md) |
| Corpus integrity verification | Complete for current local snapshot | 0 missing, 0 size mismatches, 0 orphans in the last verification; manifest hash in [artifact registry](engineering/artifacts.md) |
| Metadata survival probe | Complete | 2,400-image probe; C2PA hint 0% in both classes; [corpus findings](methodology/corpus.md#metadata-survival-probe) |
| Degradation ladder | Implemented | Eight deterministic rungs; [protocol](methodology/benchmark.md#degradation-rungs) |
| Real-device simulator fidelity | Partial | ReWIND QF distribution validated; iPhone geometry and screenshot statistics still need hardware validation |
| Detector adapters | Implemented | Local adapters plus ReWIND reference providers; [harness map](engineering/harness.md#detector-adapters) |
| Full frontier/lowq comparison | Complete | 9,582 score rows per rung and 9,569 distinct IDs in paired deltas; [results](results/model-selection.md) |
| Shipping model selected | Complete | `commfor:lowq-2026-08`; [model card](results/shipping-model.md) |
| Detector fusion experiment | Complete | DDA union adds no useful gain; no ensemble selected |
| Quality router experiment | Complete | Lowq wins above and below 440 px; one model, no router |
| Core ML FP16 conversion | Complete | 43.7 MB package; [Core ML report](results/coreml.md) |
| ANE placement gate | Passed | 262/264 assigned ops on ANE (99.2%) |
| PyTorch/Core ML parity | Passed | Spearman 0.999949; 96/96 threshold decisions agree |
| Test suite | Green | 267 collected: 266 passed, one opt-in Core ML integration test skipped |
| Quality-aware calibration / abstention | Not implemented | Research direction only; FP16 drift sets a minimum ±0.131-logit band floor |
| iOS app specification | Complete | The `ios-app` spec's 16 sections and every checkpoint are implemented; see [iOS app documentation](ios-app/index.md) |
| iOS app implementation | Implemented, not release-ready | 2,882 package tests passing across every spec section; two known defects and no signed release artifacts. See [Implementation status](ios-app/status.md) |
| iOS device benchmark | Not started | No physical iPhone available; every device gate reports `not-executed` by design. See [Implementation status](ios-app/status.md#unverifiable-in-this-environment) |

## Decisions on record

### Metric and harm model

The harmful error is accusing a real image of being AI-generated. The headline operating point is therefore **true-positive rate at 1% false-positive rate**, reported as `TPR@1%FPR` with a bootstrap confidence interval. AUC remains useful for ranking but cannot select a product threshold by itself.

### Corpus posture

The evaluation set is not a training set. Contemporary platform reals are too scarce and too important to the false-positive tail to spend on fitting a model. Every enabled slice is non-commercial, which fixes the project posture as nonprofit and free.

### Robustness axis

The deterministic project simulator is the primary axis because it models the intended screenshot/share paths and is reproducible. Real-transmission datasets are sanity checks. Hardware fidelity remains an explicit open item rather than an assumed success.

### Model decision

The low-quality Community Forensics continuation is selected over the frontier checkpoint. It improves AUC at all eight rungs, significantly improves `TPR@1%FPR` on `screenshot_shared` and `thumbnail`, and is significantly worse nowhere. It uses the same 440/384 preprocessing and the same model size, so there is no tradeoff that justifies a router.

### Deployment decision

The selected checkpoint converts to a 43.7 MB FP16 `mlprogram` for iOS 17+, with 99.2% of assigned operations placed on ANE. Normalization is inside the graph; resize-short-edge 440 and center-crop 384 remain the future app's responsibility and require device parity tests.

## Superseded findings retained in the research log

`PLAN.md` is chronological and intentionally preserves experiments that changed the plan. It contains older sample-based numbers—most notably frontier clean AUC 0.9512 and `screenshot_shared` TPR 0.625—that were superseded by the full-coverage values **0.9374** and **0.601**. Result pages in this site are authoritative; the plan is useful for decision history.

The plan's final statement that no project-measured accuracy exists is also stale. Project inference now exists for multiple detectors, and the full-coverage commfor comparison is project-measured. Evidence labels on this site replace that obsolete blanket statement.

## Immediate boundary before app-spec work

Before specifying the app, the project now has:

- a fixed input contract for the selected model;
- a measured low-FPR operating profile across degradation;
- a known sub-440 px abstention requirement;
- a Core ML artifact that uses the Neural Engine;
- a list of provenance and simulator assumptions that the app cannot silently hide.

What it does **not** yet have is a calibrated abstention table, validated real-iPhone preprocessing, a model-bundle release format, or a root repository licence. These are called out in [limitations](project/limitations.md).
