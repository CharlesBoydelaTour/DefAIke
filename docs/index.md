# DefAIke evidence and engineering notes

DefAIke is a frugal, private detector for **whole-image AI generation**. The intended product runs locally on iOS through Core ML, combines provenance with pixel evidence, and prefers an honest *not enough signal* outcome over a false accusation.

<div class="metric-grid">
  <div class="metric-card"><strong>10,832</strong>evaluation images</div>
  <div class="metric-card"><strong>8.01 GB</strong>measured corpus</div>
  <div class="metric-card"><strong>314,900</strong>persisted scores</div>
  <div class="metric-card"><strong>8</strong>degradation rungs</div>
  <div class="metric-card"><strong>21.8M</strong>shipping-model parameters</div>
  <div class="metric-card"><strong>99.2%</strong>Core ML ops on ANE</div>
</div>

!!! success "Phase 0 outcome"
    The selected checkpoint is [`Thermostatic/community-forensics-low-quality-detector-2026-08`](https://huggingface.co/Thermostatic/community-forensics-low-quality-detector-2026-08): an MIT-licensed ViT-S/16 at 384 px. On the full uncontaminated corpus it reaches **AUC 0.9383** and **TPR 0.624 at 1% FPR** on `screenshot_shared`. Its 43.7 MB FP16 Core ML export places 262 of 264 assigned operations on the Apple Neural Engine.

That is a model-selection result, not a claim that AI-image detection is solved. Sub-440 px inputs remain weak, no post-training generator can be evaluated yet, and the selected checkpoint is an independent non-peer-reviewed release whose low-quality continuation does not have a valid red-team report.

## Evidence labels

Every result page distinguishes where a number came from:

<span class="evidence full">Measured · full</span>
: Project inference over all eligible corpus rows. This is the only class used for the shipping decision.

<span class="evidence sample">Measured · sample</span>
: Project inference over a stratified subset. Useful for exploration and generator diagnosis, never silently promoted to a full-corpus result.

<span class="evidence author">Author logits</span>
: Metrics computed by this project over scores distributed by another project, such as ReWIND's six reference columns. The model itself was not run here.

<span class="evidence third-party">Third-party</span>
: A paper, model card, or upstream development result. It motivates a decision but does not validate this implementation.

## What has been completed

1. **Research and resource audit.** Recent papers, open repositories, weights, training data, licences, and release availability were checked against primary sources. [See the landscape and decisions.](research/landscape.md)
2. **Evaluation corpus.** A measured 10,832-image corpus stays under 10 GB and combines contemporary platform reals, 2026 commercial-generator output, in-the-wild near-duplicates, and an independent platform cross-check. [See composition and contamination rules.](methodology/corpus.md)
3. **Benchmark framework.** The harness preserves original bytes, checkpoints expensive runs, computes conservative low-FPR metrics, and applies eight deterministic degradation paths. [See the benchmark protocol.](methodology/benchmark.md)
4. **Model matrix.** Fifteen detector labels are represented in 314,900 persisted score rows; evidence provenance is tracked so locally-run inference is not conflated with author logits. [See model selection.](results/model-selection.md)
5. **Shipping-model decision.** The low-quality Community Forensics continuation dominates the frontier checkpoint in AUC across every rung and improves the actual shared-screenshot operating point. One model ships; there is no quality router. [See the model card.](results/shipping-model.md)
6. **Core ML conversion.** FP16 conversion, compiled artifact generation, per-op ANE placement, PyTorch parity, and M3 Pro relative latency have been measured. [See the deployment gate.](results/coreml.md)
7. **Reproducibility controls.** The corpus manifest and scores are persisted and hashed, image coverage is verified, scoring is resumable, and 267 tests are collected. [See the harness and reproduction guide.](engineering/reproduce.md)

## Product constraints already decided

- Inference stays on device; no inference server.
- A screenshot path and original-byte share-sheet path are both required.
- False accusation is the harmful error, so the headline is `TPR@1%FPR`, not generic accuracy.
- No new backbone is trained. Reusing existing models is preferred.
- Provenance and pixel analysis are independent evidence lanes; neither is presented as proof.
- The project is nonprofit and free because every enabled evaluation slice is non-commercial.
- Results must carry dataset, rung, coverage, evidence provenance, and uncertainty.

## Scope boundary

<div class="scope-boundary">
The pages above record the Phase 0 model-selection evidence. The iOS app itself — SwiftUI presentation, Photos/Share ingest, C2PA integration, fusion, and calibration wiring — is implemented and tested, but is documented separately under [iOS app](ios-app/index.md) rather than mixed into this evidence narrative. It is not release-ready: see its [implementation status](ios-app/status.md) for known defects and everything that still needs a physical device and signed release artifacts.
</div>

## Where to go next

- For the current ledger of done, partial, blocked, and future work: [Current status](status.md)
- For the strongest result and its confidence intervals: [Model selection](results/model-selection.md)
- To rerun or inspect artifacts: [Reproduce the work](engineering/reproduce.md)
- For the Swift app that bundles this model: [iOS app](ios-app/index.md)
- For every primary paper, repository, model, and dataset link used here: [Primary references](references.md)
