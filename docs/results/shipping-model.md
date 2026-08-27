# Shipping model card

## Identity

| Field | Value |
|---|---|
| Selected checkpoint | [`Thermostatic/community-forensics-low-quality-detector-2026-08`](https://huggingface.co/Thermostatic/community-forensics-low-quality-detector-2026-08) |
| Adapter label | `commfor:lowq-2026-08` |
| Upstream continuation | [`Thermostatic/community-forensics-frontier-detector-2026-08`](https://huggingface.co/Thermostatic/community-forensics-frontier-detector-2026-08) |
| Peer-reviewed base | [`OwensLab/commfor-model-384`](https://huggingface.co/OwensLab/commfor-model-384), Community Forensics (CVPR 2025) |
| Architecture | `vit_small_patch16_384` (ViT-S/16) |
| Parameters | 21.8M |
| Released FP16 ONNX | 43.8 MB |
| Project Core ML package | 43.7 MB FP16 `mlprogram`, iOS 17+ |
| Weight licence | MIT |
| Review status | Independent fine-tune; not an official OwensLab release; not peer-reviewed |

## Why this checkpoint

<span class="evidence full">Measured · full</span>

On all eligible score rows, lowq has significantly higher AUC than frontier at every one of eight rungs. It also has significantly higher `TPR@1%FPR` at `screenshot_shared` and `thumbnail`, is statistically indistinguishable elsewhere, and is significantly worse nowhere. It carries no architecture, preprocessing, model-size, or second-model routing cost.

Headline full-corpus values:

| Rung | AUC | TPR@1%FPR | ECE |
|---|---:|---:|---:|
| clean | 0.9478 | 0.667 | 0.145 |
| severe | 0.9257 | 0.528 | 0.068 |
| screenshot | 0.9483 | 0.652 | 0.141 |
| **screenshot_shared** | **0.9383** | **0.624** | **0.129** |
| thumbnail | 0.8310 | 0.248 | 0.077 |

The slight last-digit differences from the paired table are expected: these headline values use all 9,582 score rows, while paired deltas use 9,569 distinct IDs after duplicate-ID collapse.

## Input and output contract

### App-side preprocessing

The future app must reproduce this in order:

1. decode as RGB without silently applying a different color-space policy;
2. resize so the **short edge is 440 px**, preserving aspect ratio;
3. use bilinear interpolation, matching torchvision's published/configured path;
4. center-crop **384 × 384**;
5. pass the crop to Core ML as an RGB `CVPixelBuffer` / image input.

### Graph-side preprocessing

The Core ML graph scales uint8 image values by `1/255` and applies per-channel ImageNet normalization:

```text
mean = (0.485, 0.456, 0.406)
std  = (0.229, 0.224, 0.225)
```

Normalization lives inside the model because Core ML `ImageType.scale` is scalar and cannot express three different standard deviations. This removes duplicate arithmetic from Swift and reduces one source of parity drift.

### Output

The model emits one positive-going raw logit named `logit`. The checkpoint's published calibrated boundary is:

```text
AI-generated boundary = 1.390625
```

This boundary is **not** the final product verdict. The product still needs a stricter false-positive operating threshold and a quality-aware abstention band. FP16 conversion drift sets an initial minimum abstention half-width of ±0.131 logit.

## Training provenance

According to the upstream release, frontier continues the MIT Community Forensics base over a 73,371-row legacy forensic corpus plus 40,101 frontier images from 42 buckets. Named synthetic families include GPT-image-2, nano-banana-2/pro, FLUX.2-pro, Seedream 4/5, Imagen 4 Ultra, Qwen Image 2 Pro, HunyuanImage 3, and Z-Image-Turbo. Lowq is a light continuation of that frontier checkpoint to improve low-quality behavior.

These are upstream declarations, not training performed by this project. **This project has trained no model.**

## Evaluation contamination

OpenFake appears in the training manifest. Therefore all `openfaketiny_reddit` rows are excluded by the adapter itself. So-Fake-OOD and ReWIND/QuAD are absent from the published training manifest and remain eligible.

The resulting full evaluation coverage is 9,582 score rows per rung. The comparison is within-generator/cross-collection for some families, not an unseen-post-cutoff-generator evaluation.

## Known failure modes

### Very low resolution

`thumbnail` is still weak at `TPR@1%FPR` 0.248. Native short edge below 440 px forces upscaling and sharply reduces separation. The required behavior is **abstain**, not route to frontier and not claim authenticity.

### Model aging

No dataset can contain a generator released after this checkpoint. Good performance on named 2026 families is evidence of current fit, not future robustness. The model bundle needs a versioned update/rollback path and recurring contamination-checked evaluation.

### Localized editing and composites

v0 covers whole-image synthesis. Local AI edits in a genuine photo, small composites, VAE reconstruction edge cases, video, and audio are outside scope. The upstream frontier card reports failed composite robustness gates; the app must not imply coverage it does not have.

### Red-team validity

The lowq config declares `redteam_validation_valid: false`; only `low_quality_promotion_passed` is true. The frontier release's red-team report cannot simply be inherited after further fine-tuning. This is a governance regression even though benchmark performance improves.

### Domain and provenance gaps

The evaluation real pool does not confirm phone-camera representation. Screenshots cannot carry C2PA manifests, and most platform images in the metadata probe carried no usable provenance. Pixel inference remains probabilistic evidence.

## Deployment readiness

| Gate | State |
|---|---|
| Full-corpus low-FPR benchmark | Passed for model selection |
| Contamination exclusion | Enforced in adapter |
| FP16 Core ML conversion | Passed |
| Per-op ANE placement | Passed, 99.2% |
| PyTorch/Core ML fixture parity | Passed, 96/96 decisions |
| Real iPhone score parity | Not run |
| Real iPhone latency / power / memory | Not run |
| Quality-aware abstention | Not implemented |
| Signed, versioned release bundle | Not implemented |
| Root repository licence | Missing |

See [Core ML deployment gate](coreml.md), [limitations](../project/limitations.md), and the [artifact registry](../engineering/artifacts.md).
