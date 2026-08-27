# Model selection

<span class="evidence full">Measured · full</span>

The shipping decision is based on a paired full-coverage comparison of the two Community Forensics checkpoints. Both produced **9,582 eligible score rows per rung**; because the manifest currently contains 13 duplicate ID groups, paired deltas use **9,569 distinct IDs**.

## Authoritative full-coverage comparison

`TPR` below means true-positive rate at **1% false-positive rate**. Confidence intervals are 95% percentile intervals from 2,000 paired stratified bootstrap resamples of `lowq − frontier`.

| Rung | Frontier AUC | Lowq AUC | ΔAUC (95% CI) | Frontier TPR | Lowq TPR | ΔTPR (95% CI) | Significant |
|---|---:|---:|---:|---:|---:|---:|---|
| clean | 0.9373 | **0.9478** | +0.0104 [+0.0088, +0.0121] | 0.653 | **0.667** | +0.014 [−0.022, +0.025] | AUC |
| light | 0.9299 | **0.9402** | +0.0102 [+0.0086, +0.0118] | 0.637 | **0.646** | +0.009 [−0.021, +0.026] | AUC |
| moderate | 0.9228 | **0.9332** | +0.0104 [+0.0088, +0.0122] | 0.578 | **0.587** | +0.009 [−0.006, +0.034] | AUC |
| heavy | 0.9213 | **0.9332** | +0.0119 [+0.0102, +0.0137] | 0.609 | **0.617** | +0.008 [−0.017, +0.022] | AUC |
| severe | 0.9128 | **0.9258** | +0.0130 [+0.0110, +0.0153] | **0.531** | 0.528 | −0.004 [−0.021, +0.020] | AUC |
| screenshot | 0.9383 | **0.9483** | +0.0100 [+0.0084, +0.0115] | **0.658** | 0.651 | −0.007 [−0.021, +0.022] | AUC |
| **screenshot_shared** | 0.9267 | **0.9382** | +0.0115 [+0.0099, +0.0132] | 0.601 | **0.624** | **+0.023 [+0.002, +0.039]** | **AUC + TPR** |
| **thumbnail** | 0.7518 | **0.8313** | +0.0795 [+0.0733, +0.0860] | 0.075 | **0.249** | **+0.173 [+0.142, +0.197]** | **AUC + TPR** |

[Download the machine-readable full comparison CSV.](../assets/data/commfor-full-coverage.csv)

### Interpretation

- Lowq improves AUC at every rung; every ΔAUC interval excludes zero.
- On `TPR@1%FPR`, it is significantly better on `screenshot_shared`—the actual deployment condition—and `thumbnail`.
- It is statistically indistinguishable on TPR elsewhere and significantly worse nowhere.
- It is the same 21.8M-parameter architecture and uses the same preprocessing, so the improvement has no bundle-size or routing cost.

This is enough to choose lowq. It is **not** enough to say tiny images are solved: `thumbnail` TPR remains only 0.249.

## Calibration behavior

Headline ECE from all 9,582 score rows per rung also favors lowq:

| Rung | Frontier ECE | Lowq ECE |
|---|---:|---:|
| clean | 0.159 | **0.145** |
| screenshot_shared | 0.148 | **0.129** |
| thumbnail | 0.405 | **0.077** |

On thumbnails, frontier pushes both real and synthetic images strongly negative, so it becomes confidently wrong rather than merely uncertain. The low-quality continuation restores separation and substantially more honest confidence. A quality-aware abstention layer is still required, but lowq provides a much better starting distribution.

## Resolution boundary and router decision

Both models resize the short edge to 440 and center-crop 384. Below 440, the model must upscale and is outside its interpolation regime. The exploratory clean-rung split showed lowq ahead on both sides:

<span class="evidence sample">Measured · sample</span>

| Native short edge | Distinct rows | Frontier AUC / TPR | Lowq AUC / TPR |
|---|---:|---:|---:|
| < 440 | 201 | 0.7088 / 0.329 | **0.7903 / 0.342** |
| ≥ 440 | 2,460 | 0.9663 / 0.714 | **0.9689 / 0.727** |

There is no measured regime in which routing to frontier helps. The design decision is **one lowq model, no router**. Sub-440 px inputs should enter an abstention policy, not a second weak model.

## Generator diagnosis

The per-generator analysis came from the earlier stratified sample and must not be mistaken for full-corpus evidence:

<span class="evidence sample">Measured · sample</span>

| Generator | Frontier AUC | Frontier TPR@1%FPR | DDA AUC |
|---|---:|---:|---:|
| GPT-image-2 | 0.9141 | 0.386 | 0.3741 |
| GPT-image-1.5 | 0.9026 | 0.301 | 0.4242 |
| nano_banana | 0.9897 | 0.818 | 0.4848 |
| nano_banana_2 | 0.9454 | 0.442 | 0.7814 |
| Ideogram3 | 0.9984 | 0.962 | 0.8808 |
| HiDream | 0.9933 | 0.903 | 0.9502 |

This diagnosed why commfor changed the decision: it closed the sampled GPT-image hole that older training distributions missed. It does **not** prove unseen-generator generalization. The string-based train-manifest split also showed no mean AUC advantage for named generators found in training (0.9552 seen vs 0.9600 not found), but that remains approximate and sample-based.

## Earlier common-subset comparison

The 1,350-row ReWIND clean subset is the only like-for-like table spanning imported reference logits and early local models. It established why AUC alone was insufficient, but it did not select the final model.

| Detector | AUC | Balanced accuracy | FPR@threshold 0 | TPR@1%FPR | ECE | Provenance |
|---|---:|---:|---:|---:|---:|---|
| B-Free | 0.9330 | 0.864 | 1.0% | 0.729 | 0.120 | <span class="evidence author">Author logits</span> |
| ClipBased | 0.8038 | 0.565 | 7.9% | 0.025 | 0.228 | <span class="evidence sample">Project inference</span> |
| DRCT | 0.7937 | 0.607 | 75.7% | 0.092 | 0.324 | <span class="evidence author">Author logits</span> |
| DMID | 0.6603 | 0.602 | 0.9% | 0.221 | 0.360 | <span class="evidence author">Author logits</span> |
| D3 | 0.6436 | 0.599 | 31.3% | 0.000 | 0.337 | <span class="evidence author">Author logits</span> |
| SigLIP | 0.6395 | 0.624 | 63.7% | 0.000 | 0.367 | <span class="evidence sample">Project inference</span> |
| CoDE | 0.6211 | 0.584 | 18.0% | 0.089 | 0.323 | <span class="evidence author">Author logits</span> |
| CO-SPY | 0.5964 | 0.553 | 33.1% | 0.003 | 0.276 | <span class="evidence author">Author logits</span> |

B-Free's number remains unverified independently. Its official host continues to return HTTP 502, its architecture is too large for the intended extension, and 3,112 of 5,582 ReWIND rows come from its authors' own `viral_bfree` collection.

## Decision

The selected detector is [`Thermostatic/community-forensics-low-quality-detector-2026-08`](https://huggingface.co/Thermostatic/community-forensics-low-quality-detector-2026-08).

It wins because it is the only measured candidate that combines:

- useful full-corpus `TPR@1%FPR` on the shared-screenshot condition;
- contemporary generator exposure;
- better AUC and calibration than its immediate predecessor;
- 21.8M parameters and a 43.7 MB FP16 Core ML package;
- essentially complete ANE placement;
- MIT-licensed weights.

The [shipping model card](shipping-model.md) records the contract and failure modes; the [Core ML page](coreml.md) records deployability.
