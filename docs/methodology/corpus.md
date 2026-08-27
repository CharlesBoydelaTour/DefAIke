# Corpus, licences, and contamination

<span class="evidence full">Measured · full</span>

The evaluation corpus is a measured 10,832-image snapshot occupying 8,005,629,351 referenced bytes (8.01 decimal GB). Its machine-readable contract is `datasets/testset.toml`; resolved rows are persisted locally in `data/manifest.parquet`.

## Composition

| Resolved slice | Images | Real | Fake | Role | Source / licence |
|---|---:|---:|---:|---|---|
| `sofake_ood` | 4,000 | 2,600 | 1,400 | Contemporary platform reals plus five recent generator strata | [So-Fake-OOD](https://huggingface.co/datasets/saberzl/So-Fake-OOD), CC-BY-NC-4.0 |
| `rewind_no_ammeba` | 5,582 | 2,438 | 3,144 | In-the-wild near-duplicates, IQA columns, and six reference detector logits | [ReWIND / QuAD](https://github.com/grip-unina/QuAD), GRIP-UNINA nonprofit terms |
| `openfaketiny_reddit` | 1,250 | 230 | 1,020 | Independent Reddit cross-check | [OpenFakeTiny](https://huggingface.co/datasets/ComplexDataLab/OpenFakeTiny), undeclared upstream; conservatively treated as inherited CC-BY-NC |
| **Total** | **10,832** | **5,268** | **5,564** | 48.6% real | Every enabled slice is non-commercial |

The So-Fake fake quota contains generator-direct output from GPT-image-2, GPT-image-1.5, nano_banana_2, Seedream 4.5, and FLUX.2. The resolved source also contains smaller samples from ten other 2026-era generators used in exploratory generator slicing.

The optional [Scam-AI GPT-image-2 dataset](https://huggingface.co/datasets/Scam-AI/gpt-image-2) is declared but disabled. It would add post-X-CDN images, but is gated and no source adapter has been implemented. It is not part of any number on this site.

## Commfor eligibility and contamination

The selected model's published training manifest contains OpenFake but not So-Fake-OOD or ReWIND/QuAD. The adapter enforces that boundary in code: every `openfaketiny_reddit` score is returned as `NaN` and excluded by the evaluation runner.

| Slice | Model-training overlap | Eligible for commfor headline? |
|---|---|---|
| So-Fake-OOD | Source absent from published manifest | Yes |
| ReWIND / QuAD | Source absent from published manifest | Yes |
| OpenFakeTiny | OpenFake present in training | **No; structurally excluded** |

That leaves **9,582 eligible score rows: 5,038 real and 4,544 fake** per rung. It demonstrates cross-collection generalization within some known generator families; it does **not** demonstrate generalization to a generator released after the checkpoint.

!!! note "The upstream recent holdout is not unseen-generator evidence"
    The model release's 189-image `recent_holdout` has zero SHA-256 or pHash overlap with its training rows, which is good image-level hygiene. All four generators in that holdout—Sana Sprint 1.6B, Z-Image-Turbo, Qwen-Image-2512, and FLUX.2-klein-4B—also appear in training. It is a held-out-image, seen-generator split.

## Integrity controls

The loader and verifier preserve and check:

- original encoded bytes—no corpus-time resize, crop, or recompression;
- source, generator, label, licence, dimensions, format, byte count, and SHA-256;
- ReWIND's source MD5, IQA values, and reference logits;
- exact archive paths for ReWIND joins, because basenames collide and can carry conflicting labels;
- manifest-to-filesystem and filesystem-to-manifest coverage;
- deterministic source selection with fixed seeds and resumable downloads.

The current local snapshot records:

| Artifact | Rows | SHA-256 |
|---|---:|---|
| `data/manifest.parquet` | 10,832 | `3753b8350a710e6bb5234b04ec717d512b09a9c56ff6a7cd707929603980504d` |
| Referenced image bytes | 8,005,629,351 | per-image hashes live in the manifest |

`data/` is intentionally ignored and is not part of the documentation site. See the [artifact registry](../engineering/artifacts.md) for regeneration and hash policy.

### Known identifier issue found during documentation

The manifest has **10,819 distinct IDs for 10,832 rows**: 13 duplicate ID groups, all in ReWIND's `viral_bfree` subset and all same-label. The stem generator removes the extension, so archive members that differ only by extension can collide. The image rows and paths remain separate, but paired model deltas de-duplicate by ID and therefore use **9,569 distinct eligible IDs**, not 9,582.

This does not retroactively change the score-row headline tables, but it must be fixed before publishing an archival manifest. The full-coverage comparison page reports both numbers rather than hiding the distinction.

The spec also records four duplicate content hashes. Near-duplicates are expected in ReWIND, but those four remain unconfirmed.

## Bias and shortcut audit

### Resolution shortcut

A rule using only whether dimensions match known generator canvases reaches **63.1% accuracy / 64.1% balanced accuracy**. Exact 1024×1024 images account for 21.5% of fakes but 0.2% of reals. Therefore clean/native results are never the deployment headline, and every metric is tagged with a degradation rung.

### False-positive tail is thin

Only 53 real images define 1% FPR in the full corpus, and about 50 after commfor contamination exclusion. `TPR@1%FPR` must therefore include bootstrap uncertainty; point estimates alone overstate precision.

### Contemporary does not mean representative phone capture

The identifiable real cameras in the metadata probe were professional DSLR/mirrorless bodies. Only 3% of reals expose a camera make, and no phone could be confirmed. The remaining 97% may include phone images, but that is unknown. Real iPhone photos remain a domain gap.

### Collection provenance can be a feature

ReWIND combines collections with different source and damage histories. Its real/fake comparison rests heavily on `viral_bfree` plus cross-collection pooling, and B-Free's authors assembled that largest subset. Source-collection slices are reported so collection provenance cannot masquerade as synthesis evidence.

## Metadata survival probe

A 2,400-image probe (1,200 real / 1,200 fake) measured presence, not cryptographic validity:

| Signal | Real | Fake |
|---|---:|---:|
| EXIF present | 11% | 5% |
| Camera make | 3% | 0% |
| XMP present | 7% | 1% |
| C2PA hint | 0% | 0% |
| AI disclosure hint | 0% | 0.08% (1 image) |

Original bytes do preserve EXIF/XMP when present, so zero C2PA is not a packaging artifact. For social-media inputs, **absent provenance is the normal case**. C2PA implementation will need separate signed fixtures from [c2pa-org/public-testfiles](https://github.com/c2pa-org/public-testfiles).

## Licence and distribution boundary

Every enabled data slice forbids commercial use. The corpus can support a nonprofit, free, open-source effort but not a paid product or commercial derivative. It is an evaluation/calibration corpus and must not quietly become training data.

The selected model weights are MIT-licensed. That does not override dataset restrictions, and the repository still needs a root code licence before public release. Written clarification from GRIP-UNINA about free nonprofit App Store distribution remains open.

## Loader map

| Source path | Responsibility |
|---|---|
| `datasets/testset.toml` | Counts, filters, budgets, licences, caveats, and open questions |
| `bench/spec.py` | Parse and validate the TOML contract |
| `bench/manifest.py` | Canonical schema, combine, summarize, verify, and orphan pruning |
| `bench/sources/sofake.py` | Metadata-first selective row-group fetch from 46 shards |
| `bench/sources/rewind.py` | Archive verification, exact-path metadata join, AMMeBa exclusion |
| `bench/sources/openfaketiny.py` | Reddit Parquet extraction and measured labels |
| `bench/imageio.py` | Original-byte decode verification and content hashing |

See [Benchmark harness](../engineering/harness.md) for the execution path and [Reproduce the work](../engineering/reproduce.md) for commands.
