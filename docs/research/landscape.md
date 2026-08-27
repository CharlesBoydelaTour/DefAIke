# Research landscape and decisions

The survey was driven by one product question: **which existing detector can preserve useful recall at 1% FPR after the transformations an iOS user actually supplies, while remaining small enough for on-device inference?** Recency, stars, and paper venue were discovery signals, not selection metrics.

## What changed during the survey

### Frozen-feature probes are the useful baseline

Two 2026 works independently made frozen visual features the most credible starting point:

- [SSAFE](https://arxiv.org/abs/2606.08634) reports competitive detection with frozen vision encoders and a linear head, and argues that representation-aware curation of roughly 10K images can beat much larger training sets.
- [Simplicity Prevails](https://arxiv.org/abs/2602.01738) reports strong generalization from linear probes over Perception Encoder, MetaCLIP 2, and DINOv3, while documenting degradation under recapture and transmission.

That is structurally the same pattern as [ClipBased](https://github.com/grip-unina/ClipBased-SyntheticImageDetection): a frozen CLIP ViT-L backbone and a small linear probe. The benchmark confirmed the pattern's strengths—stable ranking and logits that tend to soften under damage—but also showed that a 2024 training distribution is blind to multiple 2026 generators.

### Recent paper does not imply recent training data

The open-weight 2025–2026 field often evaluates on recent generators while training on ProGAN, Stable Diffusion 1.x/2.x, COCO reconstructions, or open autoregressive models. That distinction explained more than paper date or parameter count:

- DDA, a 307M-parameter 2025 method, was anti-correlated on GPT-image-1.5/2 in the sampled generator slices.
- A 21.8M-parameter Community Forensics continuation trained on frontier 2026 generators closed that measured gap.

The conclusion is not “newer is always better.” It is narrower: **generator exposure was the dominant variable in the measured GPT-image failure.**

### AUC cannot select a product operating point

Several candidates ranked images reasonably but had unusable false-positive behavior. Examples from the common ReWIND subset include DRCT at AUC 0.7937 but `TPR@1%FPR` 0.092, and ClipBased at AUC 0.8038 but `TPR@1%FPR` 0.025. This moved selection from generic accuracy/AUC to the low-FPR operating point, calibration, degradation behavior, size, and ANE placement.

## Candidate ledger

| Candidate | Evidence here | Size / input | Licence | Decision |
|---|---|---|---|---|
| [Community Forensics low-quality](https://huggingface.co/Thermostatic/community-forensics-low-quality-detector-2026-08) | <span class="evidence full">Measured · full</span> | 21.8M, 384 px | MIT | **Selected**; dominates frontier AUC on all rungs and passes Core ML gate |
| [Community Forensics frontier](https://huggingface.co/Thermostatic/community-forensics-frontier-detector-2026-08) | <span class="evidence full">Measured · full</span> | 21.8M, 384 px | MIT | Full-coverage reference; lowq continuation is better |
| [OwensLab Community Forensics base](https://huggingface.co/OwensLab/commfor-model-384) | <span class="evidence third-party">Third-party</span> | ViT-S/16, 384 px | MIT | Peer-reviewed upstream base; not yet run independently |
| DDA | <span class="evidence sample">Measured · sample</span> | 307M, 336 crop | Apache-2.0 | Accuracy ceiling; too large and fails sampled GPT-image slices |
| Corvi2023 | <span class="evidence sample">Measured · sample</span> | 23.5M, native crop | Apache-2.0 | Useful native-resolution control; collapses under recompression |
| [ClipBased](https://github.com/grip-unina/ClipBased-SyntheticImageDetection) | <span class="evidence sample">Measured · sample</span> | 303M, 224 px | Apache-2.0 code | Frozen-probe ceiling; stale generator exposure and too large |
| [Ateeqq SigLIP](https://huggingface.co/Ateeqq/ai-vs-human-image-detector) | <span class="evidence sample">Measured · sample</span> | 92.9M, 224 px | Apache-2.0 | Weak low-FPR behavior; training data undocumented |
| Organika / dima806 classifiers | <span class="evidence sample">Measured · sample</span> | 224 px classifiers | mixed | Weak low-FPR behavior; no reason to test more similar Hub fine-tunes |
| [B-Free](https://github.com/grip-unina/B-Free) | <span class="evidence author">Author logits</span> | DINOv2 reg4, 504 multi-crop | non-commercial | Best imported ReWIND number, but home-turf confound; official host remains HTTP 502 |
| [PGC](https://arxiv.org/abs/2605.21207) | <span class="evidence third-party">Third-party</span> | large checkpoints | Apache-2.0 | Calibration alternative; not run |
| D3QE | <span class="evidence third-party">Third-party</span> | about 92 MB | MIT | Lower-priority completeness check; not run |
| [SSP](https://github.com/bcmi/SSP-AI-Generated-Image-Detection) / ESSP | <span class="evidence third-party">Third-party</span> | ResNet-50 / patch | MIT | Weights not scriptably obtainable; ESSP unreleased |
| Tiny-LaDeDa | <span class="evidence third-party">Third-party</span> | four conv layers | undeclared | Attractive cost floor, but code/weights unreleased |
| haywoodsloan Swin | Metadata audit only | 195M | none declared | Dropped; size and licence were initially misstated |
| OmniAID | Metadata audit only | about 13 GB | inconsistent | Dropped pending licence resolution; impractical for iOS |

## Why fusion was rejected

A union rule between frontier commfor and DDA gave no useful gain. At 0.5% FPR per model, the union was worse than commfor alone on every rung except a clean tie. DDA's errors are not complementary where the product needs them: its sampled GPT-image scores are systematically wrong, not merely uncertain. Adding a 307M model would increase memory and latency without improving the deployment operating point.

## Why routing was rejected

Both commfor releases use the same `resize short edge to 440 → center crop 384` pipeline. The low-quality model is a continuation of frontier, not a separate low-resolution architecture. Full-coverage AUC is higher for lowq at every rung; its `TPR@1%FPR` is significantly higher on `screenshot_shared` and `thumbnail` and statistically indistinguishable elsewhere. There is no measured quality regime where frontier is a better route.

A hard 440 px router would also recreate the inconsistency described by [QuAD](https://arxiv.org/abs/2604.15027): two copies of the same image could cross a threshold and receive different model logic. The product should use one model and abstain when evidence is insufficient.

## Robustness and calibration work that informed the plan

- [DINO-Detect](https://arxiv.org/abs/2511.12511) motivates degradation-axis distillation between clean teacher features and degraded student inputs. No usable public weights were found.
- [LaDeDa / Tiny-LaDeDa / WildRF](https://arxiv.org/abs/2406.09398) demonstrates the value of local patches and real-world platform data, but the edge release remains unavailable.
- [RRDataset](https://arxiv.org/abs/2509.09172) and [AIGIBench](https://arxiv.org/abs/2505.12335) motivate transmission, redigitization, and preprocessing checks.
- [QuAD](https://github.com/grip-unina/QuAD) motivates quality-conditioned calibration, but its demonstrated gains aggregate multiple web-retrieved near-duplicates. A single-image app does not inherit that validation.
- [PGC](https://arxiv.org/abs/2605.21207) remains the permissive calibration alternative to compare before implementing abstention.

## Provenance research boundary

Pixel detection is only one lane. [c2pa-swift](https://github.com/contentauth/c2pa-swift) can validate Content Credentials locally, and [C2PA public test files](https://github.com/c2pa-org/public-testfiles) provide fixtures. But screenshots structurally remove manifests, platform CDNs strip metadata, and [formal analysis of C2PA](https://arxiv.org/abs/2604.24890) argues against treating a signed camera claim as unquestionable proof. These findings constrain future fusion semantics; no provenance code has been implemented yet.

## Survey maintenance

The actively maintained [Awesome AIGC Image and Video Detection list](https://github.com/ant-research/Awesome-AIGC-Image-Video-Detection) is the standing discovery source. A model refresh must repeat four checks before benchmarking:

1. weights are public and provenance is verifiable;
2. code and weights have compatible licences;
3. training sources do not contaminate evaluation slices;
4. model shape and operations are plausible for Core ML / ANE.
