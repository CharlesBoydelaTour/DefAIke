# Artifact registry

This registry separates small publishable evidence from large ignored local artifacts. `data/` is never copied into the documentation site.

## Served evidence snapshots

| Artifact | Purpose | Link |
|---|---|---|
| Full commfor paired comparison | Eight-rung frontier/lowq metrics and paired bootstrap intervals | [CSV](../assets/data/commfor-full-coverage.csv) |
| Core ML lowq report | Conversion, placement, parity, latency, environment, and weight hash | [JSON](../assets/data/coreml-lowq-report.json) |
| Evidence snapshot | Corpus, scores, tests, environment, and source-path inventory | [JSON](../assets/data/evidence-snapshot.json) |
| Detector inventory | Adapter/evidence/licence/decision ledger | [CSV](../assets/data/detector-inventory.csv) |

These files are documentation snapshots derived from the local artifacts below. They are deliberately small enough to publish with the site.

## Local generated artifacts

| Local path | Current size / rows | SHA-256 or identity | Regenerate / verify |
|---|---|---|---|
| `data/manifest.parquet` | 1,055,372 bytes / 10,832 rows | `3753b8350a710e6bb5234b04ec717d512b09a9c56ff6a7cd707929603980504d` | `bench fetch`; `bench verify` |
| Images referenced by manifest | 8,005,629,351 bytes | Per-image SHA-256 in manifest | `bench verify` |
| `data/scores.parquet` | 1,923,030 bytes / 314,900 rows | `a200c40ad185eeed323b4b69a97ea0fe4f3b96a64d713b75bfc2d11c0fd823a9` | `bench eval ...` |
| `data/coreml/commfor-lowq-384.mlpackage/` | 43,744,071 bytes | weight blob `f073f8a3…d4c1e` | `bench coreml --variant lowq --force` |
| `data/coreml/commfor-lowq-384.mlmodelc/` | 43,764,661 bytes | compiled from package above | same command |
| `data/cache/metadata_probe.parquet` | 2,400 rows | presence-only metadata probe | `bench probe-metadata --sample 1200` |
| `data/cache/index_sofake_ood.parquet` | 91,370 rows | source metadata index | `bench index --force` |

`data/matrix8.log` is an older console capture from a smaller score matrix. It is not canonical and should not be used for current claims.

## Source-of-truth files

| Source path | Authority |
|---|---|
| `PLAN.md` | Chronological research and planning log; contains superseded experiments |
| `datasets/testset.toml` | Corpus contract, licences, caveats, budgets, and measured composition |
| `bench/degrade.py` | Exact deterministic rung definitions |
| `bench/metrics.py` | Metric and threshold semantics |
| `bench/evaluate.py` | Coverage, checkpoint, common-subset, and slicing behavior |
| `bench/detectors/commfor.py` | Selected model identity, transform, threshold, contamination exclusion |
| `bench/coreml.py` | Conversion, compile, placement, parity, and latency implementation |
| `tests/` | Executable invariants and regressions |
| `docs/` | Curated current narrative and publishable evidence snapshots |

A repository remote has not been configured, so hosted source URLs would be guesses. Once a remote exists, `mkdocs.yml` should gain `repo_url` and `edit_uri`; this registry can then link each path directly to an immutable revision.

## Evidence provenance

| Label | What is allowed |
|---|---|
| `MEASURED · FULL` | Headline project result; all eligible rows, coverage stated |
| `MEASURED · SAMPLE` | Diagnostic project result; sample and selection stated |
| `AUTHOR LOGITS` | Project-computed metric over distributed third-party scores |
| `THIRD-PARTY` | Upstream paper/model-card claim; never phrased as a local result |

## Hash commands

```bash
shasum -a 256 data/manifest.parquet data/scores.parquet
shasum -a 256 \
  data/coreml/commfor-lowq-384.mlpackage/Data/com.apple.CoreML/weights/weight.bin
```

Directory byte counts in this registry sum regular files recursively. `.mlpackage` and `.mlmodelc` are directories, so a plain file hash does not represent the whole bundle; the weight hash is pinned until a signed release-manifest format is implemented.
