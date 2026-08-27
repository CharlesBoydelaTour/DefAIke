# Primary references

This index links the primary papers, repositories, model cards, datasets, and tools used in the August 2026 research pass. A link here does not make an upstream claim a project measurement; evidence provenance remains defined on the [overview](index.md#evidence-labels).

## Project evidence index

| Area | Curated record | Machine-readable evidence |
|---|---|---|
| Current completion state | [Current status](status.md) | [Evidence snapshot](assets/data/evidence-snapshot.json) |
| Research and candidate decisions | [Landscape](research/landscape.md) | [Detector inventory](assets/data/detector-inventory.csv) |
| Corpus, licences, and integrity | [Corpus card](methodology/corpus.md) | Manifest identity in the [evidence snapshot](assets/data/evidence-snapshot.json) |
| Benchmark and degradation protocol | [Benchmark protocol](methodology/benchmark.md) | Exact implementation paths in the [artifact registry](engineering/artifacts.md) |
| Full frontier/lowq result | [Model selection](results/model-selection.md) | [Paired comparison CSV](assets/data/commfor-full-coverage.csv) |
| Selected checkpoint contract | [Shipping model card](results/shipping-model.md) | Adapter and upstream identities in the [detector inventory](assets/data/detector-inventory.csv) |
| Core ML conversion and ANE gate | [Core ML deployment gate](results/coreml.md) | [Core ML report JSON](assets/data/coreml-lowq-report.json) |
| Commands and local artifacts | [Reproduction guide](engineering/reproduce.md), [artifact registry](engineering/artifacts.md) | Paths, sizes, and SHA-256 values in both records |
| Open evidence and governance gaps | [Limitations and next boundary](project/limitations.md) | Known-integrity fields in the [evidence snapshot](assets/data/evidence-snapshot.json) |

`PLAN.md` is the chronological local research log. It intentionally retains superseded experiments; the pages above are the current record. This workspace has no Git remote, so local source paths cannot yet be linked to an immutable hosted revision.

## Provenance and C2PA

- [C2PA 2.4 specifications index](https://spec.c2pa.org/specifications/specifications/2.4/index.html) — normative Content Credentials specifications; version 2.4 was the current implementation reference in this research snapshot.
- [Content Authenticity Initiative `c2pa-swift`](https://github.com/contentauth/c2pa-swift) — Apache-2.0 Swift bindings considered for future local iOS validation; not implemented here.
- [C2PA public test files](https://github.com/c2pa-org/public-testfiles) — signed fixtures required because the measured corpus contains no C2PA-positive image.
- [Google Credentio announcement](https://developers.googleblog.com/en/introducing-credentio-open-source-c-library-for-c2pa-content-credentials-from-google/) — a lower-level C++ validation alternative surveyed for constrained clients; not implemented here.
- [Verifying Provenance of Digital Media: Why the C2PA Specifications Fall Short](https://arxiv.org/abs/2604.24890) — formal security analysis motivating asymmetric trust and explicit conflict handling.

No provenance implementation or fusion policy has been built. These links document research inputs and future constraints only.

## Selected model lineage

- [Community Forensics low-quality checkpoint](https://huggingface.co/Thermostatic/community-forensics-low-quality-detector-2026-08) — selected MIT checkpoint; project inference is recorded in [model selection](results/model-selection.md).
- [Community Forensics frontier checkpoint](https://huggingface.co/Thermostatic/community-forensics-frontier-detector-2026-08) — full-coverage predecessor used in the paired comparison.
- [OwensLab Community Forensics base model](https://huggingface.co/OwensLab/commfor-model-384) — peer-reviewed upstream base.
- [Community Forensics repository](https://github.com/JeongsooP/Community-Forensics) and [paper](https://arxiv.org/abs/2411.04125) — original training/evaluation implementation and publication.

The Thermostatic releases are independent continuations, not official OwensLab checkpoints. Upstream training statements remain model-card evidence; this project trained no model.

## Detectors run or imported

### Project inference

- [Dual Data Alignment repository](https://github.com/roy-ch/Dual-Data-Alignment) and [released checkpoint](https://huggingface.co/Junwei-Xi/Dual-Data-Alignment) — DDA, sampled project inference.
- [ClipBased Synthetic Image Detection](https://github.com/grip-unina/ClipBased-SyntheticImageDetection) — ClipBased and Corvi2023 weights used for sampled project inference.
- [Ateeqq SigLIP detector](https://huggingface.co/Ateeqq/ai-vs-human-image-detector) — sampled project inference.
- [Organika SDXL detector](https://huggingface.co/Organika/sdxl-detector) — sampled project inference.
- [dima806 ViT detector](https://huggingface.co/dima806/ai_vs_human_generated_image_detection) — sampled project inference.

### Distributed author scores or blocked reruns

- [QuAD / ReWIND](https://github.com/grip-unina/QuAD) distributes the six reference-logit columns—DMID, CoDE, D3, B-Free, DRCT, and CO-SPY—used in the common 1,350-row table. Those rows are `AUTHOR LOGITS` because this project did not run the models.
- [B-Free](https://github.com/grip-unina/B-Free) — strongest imported ReWIND reference. The [official weight endpoint](https://www.grip.unina.it/download/prog/B-Free/weights/BFREE_dino2reg4.zip) returned HTTP 502 at this snapshot, so the adapter could not be independently run.

## Surveyed detector research

These sources informed candidate selection, robustness strategy, or rejection; they are not all locally measured.

- [Simplicity Prevails](https://arxiv.org/abs/2602.01738) — frozen visual-foundation-model probes and recapture/transmission limitations.
- [SSAFE](https://arxiv.org/abs/2606.08634) — frozen encoders and representation-aware curation.
- [DINO-Detect](https://arxiv.org/abs/2511.12511) — degradation-axis teacher/student consistency.
- [LaDeDa, Tiny-LaDeDa, and WildRF](https://arxiv.org/abs/2406.09398) — local-patch detection, edge-efficiency direction, and in-the-wild evaluation.
- [SSP repository](https://github.com/bcmi/SSP-AI-Generated-Image-Detection) — patch-based candidate whose released weights were not scriptably obtainable.
- [ZED repository](https://github.com/grip-unina/ZED) — non-commercial zero-shot reference, not run.
- [D³QE](https://arxiv.org/abs/2510.05891) — autoregressive-image candidate identified but not run.
- [Apple Core ML MobileCLIP](https://github.com/apple/ml-mobileclip) — surveyed ANE-oriented backbone; not used in the selected model.

The maintained [Awesome AIGC Image and Video Detection](https://github.com/ant-research/Awesome-AIGC-Image-Video-Detection) list is the standing discovery source for future refreshes.

## Calibration and quality

- [QuAD repository](https://github.com/grip-unina/QuAD) and [paper](https://arxiv.org/abs/2604.15027) — quality-conditioned detector calibration over ReWIND/AncesTree and multiple retrieved copies. Its reported aggregation result is not treated as validation for a single-image app.
- [PGC repository](https://github.com/xiaoyu6868/PGC) and [paper](https://arxiv.org/abs/2605.21207) — permissive peak-guided calibration alternative; surveyed but not run.

No quality-aware calibration or abstention layer has been implemented. The only current thresholds are detector metadata and benchmark operating points.

## Datasets and benchmarks

### Included in the measured corpus

- [So-Fake-OOD](https://huggingface.co/datasets/saberzl/So-Fake-OOD) — contemporary platform reals and recent generator-direct images; CC-BY-NC-4.0.
- [QuAD / ReWIND](https://github.com/grip-unina/QuAD) — in-the-wild near-duplicates, quality estimates, and reference logits; GRIP-UNINA non-commercial terms.
- [OpenFakeTiny](https://huggingface.co/datasets/ComplexDataLab/OpenFakeTiny) — independent Reddit cross-check; upstream licence is undeclared and conservatively treated as inherited non-commercial.

### Declared or surveyed, not included in headline numbers

- [Scam-AI GPT-image-2](https://huggingface.co/datasets/Scam-AI/gpt-image-2) and its [paper](https://arxiv.org/abs/2604.25370) — post-X-CDN GPT-image-2 data; declared but disabled and no loader is implemented.
- [RRDataset](https://arxiv.org/abs/2509.09172) — transmission and redigitization benchmark; a subset arrives through ReWIND.
- [AIGIBench](https://arxiv.org/abs/2505.12335) — degradation and test-time preprocessing benchmark.
- [AI-GenBench](https://github.com/MI-BioLab/AI-GenBench) — rolling benchmark surveyed as a future external check.
- [AIDE / Chameleon](https://github.com/shilinyan99/AIDE) — benchmark and detector surveyed but excluded as too heavy for the target.

Dataset inclusion, exact resolved counts, contamination handling, and licence caveats are authoritative on the [corpus page](methodology/corpus.md), not in upstream headline tables.

## Conversion, execution, and documentation tools

- [Apple `coremltools`](https://github.com/apple/coremltools) — FP16 `mlprogram` conversion and model compilation.
- [Apple `MLComputePlan`](https://developer.apple.com/documentation/coreml/mlcomputeplan) — per-operation compute-device assignment used for the ANE gate.
- [PyTorch MPS backend](https://pytorch.org/docs/stable/notes/mps.html) — Metal execution used for Mac benchmark inference.
- [MkDocs](https://www.mkdocs.org/) — static documentation generator, pinned to 1.6.1.
- [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/) — site theme and navigation, pinned to 9.6.18.

## Link and evidence status

External links can move after this snapshot. The B-Free 502 is a documented upstream availability failure rather than a silent validation pass. Large local artifacts are indexed by path and SHA-256 in the [artifact registry](engineering/artifacts.md); small publishable snapshots are served from `docs/assets/data/`.

Descriptions on this page summarize the project's August 2026 source audit; linked upstream pages remain authoritative for their own claims and licences.
