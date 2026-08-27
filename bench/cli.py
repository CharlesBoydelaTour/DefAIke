"""bench — the Phase 0 command line.

    bench datasets            spec as declared: slices, counts, licences, capture era
    bench datasets --resolved measured counts from the manifest, against projections
    bench index               build the cheap metadata index (no image bytes)
    bench plan                what a fetch would cost, before spending it
    bench fetch               download and resolve the corpus
    bench verify              check the manifest against the filesystem
    bench eval                score detectors across the degradation ladder
    bench coreml              export to Core ML, then gate on ANE placement and parity
"""

from __future__ import annotations

import polars as pl
import typer
from rich.console import Console
from rich.table import Table

from bench import manifest, paths, spec
from bench.sources import openfaketiny, rewind, sofake

app = typer.Typer(add_completion=False, help=__doc__)
# Fixed width when stdout is not a tty, so piped/redirected output stays readable
# instead of collapsing every column to three characters.
console = Console(width=None if __import__("sys").stdout.isatty() else 118)

AVG_ITEM_BYTES = 1_474_000  # measured: So-Fake shard bytes / rows


def _gb(n: float) -> str:
    return f"{n / 1e9:.2f}"


@app.command()
def datasets(resolved: bool = typer.Option(False, "--resolved", help="show measured, not projected")) -> None:
    """Print the evaluation set: counts, balance, licences, capture era."""
    sp = spec.load()

    if resolved:
        try:
            df = manifest.read()
        except FileNotFoundError as e:
            console.print(f"[yellow]{e}[/yellow]")
            raise typer.Exit(1) from None

        t = Table(title=f"{sp.name} — RESOLVED (measured from manifest)", header_style="bold")
        for c, j in [("slice", "left"), ("images", "right"), ("real", "right"), ("fake", "right"),
                     ("GB", "right"), ("gens", "right"), ("era", "left"), ("licence", "left")]:
            t.add_column(c, justify=j)  # type: ignore[arg-type]
        for r in manifest.summarise(df).iter_rows(named=True):
            t.add_row(r["slice"], f"{r['images']:,}", f"{r['real']:,}", f"{r['fake']:,}",
                      f"{r['gb']:.2f}", str(r["generators"]), r["capture_era"], r["licence"][:26])
        n, nr = len(df), int((df["label"] == "real").sum())
        t.add_section()
        t.add_row("TOTAL", f"{n:,}", f"{nr:,}", f"{n - nr:,}", _gb(df["bytes"].sum()), "", "", "")
        console.print(t)

        console.print(f"\n[bold]projected[/bold] {sp.projected_items:,} items / "
                      f"{_gb(sp.projected_bytes)} GB")
        console.print(f"[bold]resolved [/bold] {n:,} items / {_gb(df['bytes'].sum())} GB "
                      f"({n / sp.projected_items:.1%} of projection)")
        console.print(f"[bold]balance  [/bold] {nr / n:.1%} real "
                      f"(spec target {sp.balance['real_frac']:.1%})")
        console.print(f"[bold]FPR tail [/bold] {round(nr * 0.01)} images decide the 1% operating point")

        gens = (df.filter(pl.col("generator") != "")
                  .group_by("generator").agg(n=pl.len()).sort("n", descending=True))
        if len(gens):
            console.print(f"\n[bold]generators present:[/bold] {len(gens)}")
            console.print("  " + ", ".join(f"{r['generator']}={r['n']}" for r in gens.iter_rows(named=True)))
        return

    t = Table(title=f"{sp.name} — SPEC (as declared, {sp.created})", header_style="bold")
    for c, j in [("slice", "left"), ("role", "left"), ("take", "right"), ("GB", "right"),
                 ("gated", "left"), ("comm", "left"), ("era", "left"), ("licence", "left")]:
        t.add_column(c, justify=j)  # type: ignore[arg-type]
    for s in sp.slices:
        style = None if s.enabled else "dim"
        t.add_row(s.id if s.enabled else f"{s.id} (off)", s.role, f"{s.take:,}",
                  _gb(s.est_bytes), str(s.gated), "no" if not s.commercial else "yes",
                  s.capture_era, s.licence[:26], style=style)
    t.add_section()
    t.add_row("TOTAL (enabled)", "", f"{sp.projected_items:,}", _gb(sp.projected_bytes),
              "", "", "", "", style="bold")
    console.print(t)

    console.print(f"\n[bold]budget[/bold]  {_gb(sp.projected_bytes)} GB projected / "
                  f"{_gb(sp.ceiling_bytes)} GB ceiling")
    console.print(f"[bold]balance[/bold] {sp.balance['real']:,} real / {sp.balance['fake']:,} fake "
                  f"({sp.balance['real_frac']:.1%} real), "
                  f"1%FPR tail = {sp.balance['fpr_tail_items']} images")
    nc = len(sp.licence_position.get("non_commercial_slices", []))
    console.print(f"[bold]licence[/bold] {nc}/{len(sp.slices)} slices non-commercial — "
                  f"{sp.licence_position.get('posture', 'n/a')}")
    if sp.open_questions:
        console.print(f"\n[yellow]open questions ({len(sp.open_questions)}):[/yellow]")
        for q in sp.open_questions:
            console.print(f"  · {q}")


@app.command()
def index(force: bool = typer.Option(False, "--force"), workers: int = 10) -> None:
    """Build the So-Fake metadata index. Reads no image bytes (~46 MB total)."""
    console.print("[bold]indexing So-Fake-OOD (metadata columns only)[/bold]")
    df = sofake.build_index(workers=workers, force=force)
    console.print(f"\nindexed [bold]{len(df):,}[/bold] rows -> {paths.index_path('sofake_ood')}")
    comp = df.group_by("scope").agg(n=pl.len()).sort("n", descending=True)
    for r in comp.iter_rows(named=True):
        console.print(f"  {r['scope']:<16} {r['n']:>7,}")


def _selection() -> sofake.Selection:
    sp = spec.load()
    idx = pl.read_parquet(paths.index_path("sofake_ood"))
    real_sl, fake_sl = sp.slice_by_id("sofake_ood_real"), sp.slice_by_id("sofake_ood_recent5")
    return sofake.select(
        idx, real_sl,
        want_real=real_sl.take, want_fake=fake_sl.take,
        recent_generators=fake_sl.raw["filter_generator"],
        avg_item_bytes=AVG_ITEM_BYTES, seed=42,
    )


@app.command()
def plan() -> None:
    """Show what a fetch would cost before committing to it."""
    if not paths.index_path("sofake_ood").exists():
        console.print("[yellow]no index yet; run `bench index` first[/yellow]")
        raise typer.Exit(1)

    sel = _selection()
    recent = spec.load().slice_by_id("sofake_ood_recent5").raw["filter_generator"]
    console.print("[bold]So-Fake-OOD selective fetch[/bold]")
    console.print(f"  row groups      {len(sel.groups):,} of 1,381 "
                  f"(across {sel.groups['shard'].n_unique()} of 46 shards)")
    console.print(f"  images kept     {len(sel.rows):,}")
    console.print(f"    real          {len(sel.rows.filter(pl.col('scope') == 'REAL')):,}")
    console.print(f"    fake          {len(sel.rows.filter(pl.col('scope') != 'REAL')):,}")
    console.print(f"      recent-5    {len(sel.rows.filter(pl.col('generator').is_in(recent))):,}")
    console.print(f"  transfer        {_gb(sel.transfer_bytes)} GB  [dim](row groups are atomic)[/dim]")
    console.print(f"  kept on disk    {_gb(sel.keep_bytes)} GB")
    console.print(f"  efficiency      {sel.efficiency:.1%}")
    console.print("\n[bold]other slices[/bold]")
    console.print("  rewind_no_ammeba     1.50 GB archive")
    console.print("  openfaketiny_reddit  0.81 GB parquet")


@app.command()
def fetch(
    only: str = typer.Option("", "--only", help="comma-separated slice ids"),
    workers: int = typer.Option(12, "--workers", help="parallel streams; HF throttles per-connection"),
) -> None:
    """Download the corpus and write the resolved manifest."""
    sp = spec.load()
    paths.ensure_dirs()
    wanted = {s.strip() for s in only.split(",") if s.strip()} or None
    frames: list[pl.DataFrame] = []

    def want(slice_id: str) -> bool:
        return wanted is None or slice_id in wanted

    if want("sofake_ood_real") or want("sofake_ood_recent5") or want("sofake_ood"):
        if not paths.index_path("sofake_ood").exists():
            console.print("[bold]building index first[/bold]")
            sofake.build_index(workers=10)
        sel = _selection()
        console.print(f"\n[bold]So-Fake-OOD[/bold] — {len(sel.groups)} row groups, "
                      f"{_gb(sel.transfer_bytes)} GB transfer for {_gb(sel.keep_bytes)} GB kept")
        df = sofake.fetch(sel, workers=workers)
        frames.append(manifest.annotate(df, sp, "sofake_ood_real"))

    if want("rewind_no_ammeba"):
        console.print("\n[bold]ReWIND[/bold] (minus AMMeBa)")
        df = rewind.fetch(sp.slice_by_id("rewind_no_ammeba"))
        frames.append(manifest.annotate(df, sp, "rewind_no_ammeba"))

    if want("openfaketiny_reddit"):
        console.print("\n[bold]OpenFakeTiny[/bold] (reddit config)")
        df = openfaketiny.fetch(sp.slice_by_id("openfaketiny_reddit"))
        frames.append(manifest.annotate(df, sp, "openfaketiny_reddit"))

    # Merge with anything already resolved so --only runs accumulate.
    if paths.manifest_path().exists():
        existing = manifest.read()
        new_slices = {f["slice"][0] for f in frames if not f.is_empty()}
        kept = existing.filter(~pl.col("slice").is_in(list(new_slices)))
        frames.append(kept)

    combined = manifest.combine(frames)
    if combined.is_empty():
        console.print("[yellow]nothing fetched[/yellow]")
        raise typer.Exit(1)

    manifest.write(combined)
    console.print(f"\n[green]manifest written[/green] {len(combined):,} images, "
                  f"{_gb(combined['bytes'].sum())} GB -> {paths.manifest_path()}")


@app.command()
def rungs() -> None:
    """Show the degradation ladder and which rungs clear the resolution shortcut."""
    from bench import degrade, evaluate

    base = evaluate.resolution_baseline()
    console.print("[bold]resolution-only baseline[/bold] — what any detector must beat")
    console.print(f"  rule              {base['rule']}")
    console.print(f"  accuracy          {base['accuracy']:.1%}")
    console.print(f"  balanced accuracy {base['balanced_accuracy']:.1%}")
    console.print(f"  TPR / FPR         {base['tpr']:.1%} / {base['fpr']:.1%}")
    console.print("  [dim]a detector at or below this has learned canvas size, "
                  "not synthesis[/dim]\n")

    t = Table(title="degradation ladder", header_style="bold")
    for c, j in [("rung", "left"), ("ops", "right"), ("clears res. shortcut", "center"),
                 ("note", "left")]:
        t.add_column(c, justify=j)  # type: ignore[arg-type]
    for r in degrade.LADDER:
        clears = "no" if r.resolution_preserving else "yes"
        style = "yellow" if r.resolution_preserving else None
        t.add_row(r.name, str(len(r.ops)), clears, r.note, style=style)
    for name in degrade.SCREENSHOT_RUNGS:
        t.add_row(name, "-", "yes",
                  "iOS screenshot: PNG so lossless, damage is pure resampling"
                  + (" then a share-path JPEG re-encode" if name.endswith("shared") else ""))
    console.print(t)

    dev = degrade.DEVICES["iphone_15_pro_feed"]
    console.print(f"\nscreenshot device: [bold]{dev.name}[/bold] "
                  f"{dev.width}x{dev.height}px, content width {dev.content_width_frac:.0%}")
    if not dev.verified_on_hardware:
        console.print("[yellow]  device dimensions are unverified against real hardware "
                      "(PLAN.md Task 2 validation step)[/yellow]")


@app.command()
def eval(
    detectors: str = typer.Option("reference", "--detectors",
                                  help="reference,siglip,clipbased or 'all'"),
    rung: str = typer.Option("", "--rung", help="comma-separated; default all supported"),
    boot: int = typer.Option(400, "--boot", help="bootstrap iterations for the CI"),
    sample: int = typer.Option(0, "--sample",
                               help="stratified subsample size; 0 = whole corpus"),
    resume: bool = typer.Option(False, "--resume",
                                help="skip (detector, rung) pairs already scored on disk"),
    max_side: int = typer.Option(0, "--max-side",
                                 help="corvi only: centre-crop cap in px; 0 = module default"),
) -> None:
    """Score detectors across degradation rungs and print the metrics tables."""
    from bench import evaluate
    from bench.detectors import reference

    mf = manifest.read()
    wanted = {d.strip() for d in detectors.split(",") if d.strip()}
    if "all" in wanted:
        # `corvi` is excluded from `all` on purpose: at ~675 ms/image it costs ~4.5 h for a
        # full matrix against ~20 min for everything else. Ask for it explicitly.
        wanted = {"reference", "siglip", "clipbased", "clipdet10k", "organika", "dima806", "bfree"}

    providers: list = []
    if "reference" in wanted:
        have = reference.available(mf)
        if have:
            providers += [reference.ReferenceDetector(n) for n in have]
            console.print(f"[bold]reference:[/bold] {', '.join(have)} "
                          f"[dim](published logits, clean rung only)[/dim]")
    if "siglip" in wanted:
        from bench.detectors.siglip import SigLIPDetector
        console.print("[bold]loading siglip...[/bold]")
        providers.append(SigLIPDetector())
    if "clipbased" in wanted:
        from bench.detectors.clipbased import ClipBasedDetector
        console.print("[bold]loading clipbased...[/bold]")
        providers.append(ClipBasedDetector())
    if "clipdet10k" in wanted:
        from bench.detectors.clipbased import ClipBasedDetector
        console.print("[bold]loading clipdet_latent10k...[/bold]")
        providers.append(ClipBasedDetector(variant="clipdet_latent10k"))
    if "corvi" in wanted:
        from bench.detectors.corvi import DEFAULT_MAX_SIDE, Corvi2023Detector
        cap = max_side or DEFAULT_MAX_SIDE
        console.print(f"[bold]loading corvi2023 (max_side={cap})...[/bold]")
        providers.append(Corvi2023Detector(max_side=cap))
    for hf_preset in ("organika", "dima806"):
        if hf_preset in wanted:
            from bench.detectors.hf_classifier import HFClassifierDetector
            console.print(f"[bold]loading hf:{hf_preset}...[/bold]")
            providers.append(HFClassifierDetector(hf_preset))
    for key, cf_variant in (("commfor", "frontier"), ("commfor-lowq", "lowq")):
        if key in wanted:
            from bench.detectors.commfor import (
                CONTAMINATED_SLICES,
                VARIANTS,
                CommForFrontierDetector,
            )
            console.print(f"[bold]loading commfor ({VARIANTS[cf_variant]['label']})...[/bold]")
            providers.append(CommForFrontierDetector(variant=cf_variant))
            console.print(f"[yellow]  excluding {', '.join(CONTAMINATED_SLICES)} — OpenFake is in "
                          f"its training manifest[/yellow]")
    if "dda" in wanted:
        from bench.detectors.dda import DDADetector
        console.print("[bold]loading dda...[/bold]")
        providers.append(DDADetector())
    if "bfree" in wanted:
        from bench.detectors.bfree import BFreeDetector
        console.print("[bold]loading bfree...[/bold]")
        try:
            providers.append(BFreeDetector())
        except OSError as e:
            console.print(f"[red]bfree unavailable:[/red] {e}")
            console.print("[yellow]  grip.unina.it is the sole distribution point for these "
                          "weights; retry when it responds.[/yellow]")

    if not providers:
        console.print("[yellow]no detectors selected[/yellow]")
        raise typer.Exit(1)

    rows = mf
    if sample:
        rows = evaluate.stratified_sample(mf, sample)
        console.print(f"[dim]stratified subsample: {len(rows):,} of {len(mf):,} images, "
                      f"{int((rows['label'] == 'real').sum()):,} real / "
                      f"{int((rows['label'] == 'fake').sum()):,} fake[/dim]")

    for p in providers:
        if p.info.params:
            console.print(f"  {p.info.name:<26} {p.info.params / 1e6:>7.1f}M params  "
                          f"{p.info.licence}")
    console.print()

    rungs_ = [r.strip() for r in rung.split(",") if r.strip()] or None
    # Checkpoint every completed (detector, rung). A slow detector's multi-hour run must
    # survive the process dying, which has already happened once.
    df = evaluate.score(providers, rungs_, rows=rows, checkpoint=True, resume=resume)
    if df.is_empty() and resume:
        console.print("[dim]nothing new to score; reporting from existing scores[/dim]")
        df = evaluate.read_scores()
    if df.is_empty():
        console.print("[yellow]no scores produced[/yellow]")
        raise typer.Exit(1)
    evaluate.write_scores(df)

    console.print(f"\n[green]scored[/green] {len(df):,} rows -> {evaluate.scores_path()}")

    head = evaluate.headline(df, n_boot=boot)
    t = Table(title="headline metrics", header_style="bold")
    for c, j in [("detector", "left"), ("rung", "left"), ("n", "right"), ("AUC", "right"),
                 ("bal.acc", "right"), ("FPR@0", "right"), ("TPR@1%FPR", "right"),
                 ("95% CI", "center"), ("ECE", "right"), ("tail", "right")]:
        t.add_column(c, justify=j)  # type: ignore[arg-type]
    for r in head.sort("tpr_at_1pct_fpr", descending=True).iter_rows(named=True):
        t.add_row(
            r["detector"], r["rung"], f"{r['n']:,}", f"{r['auc']:.4f}",
            f"{r['balanced_accuracy']:.3f}", f"{r['fpr_at_zero']:.1%}",
            f"{r['tpr_at_1pct_fpr']:.3f}",
            f"{r['tpr_at_1pct_fpr_lo']:.2f}-{r['tpr_at_1pct_fpr_hi']:.2f}",
            f"{r['ece']:.3f}", str(r["fpr_tail_n"]),
            style="yellow" if r["resolution_shortcut"] else None,
        )
    console.print(t)
    console.print("[yellow]yellow rows are resolution-preserving rungs: their scores still "
                  "carry the resolution shortcut[/yellow]")

    # The headline table spans different row sets per detector, so any cross-detector
    # reading of it is invalid. Print the restricted comparison right after it.
    cmp = evaluate.compare(df, rung="clean", n_boot=boot)
    if len(cmp) > 1:
        sub = evaluate.common_subset(df, rung="clean")
        one = sub.filter(pl.col("detector") == sub["detector"][0])
        t4 = Table(
            title=f"like-for-like comparison — {len(one):,} images every detector scored",
            header_style="bold",
        )
        for c, j in [("detector", "left"), ("AUC", "right"), ("bal.acc", "right"),
                     ("FPR@0", "right"), ("TPR@1%FPR", "right"), ("ECE", "right")]:
            t4.add_column(c, justify=j)  # type: ignore[arg-type]
        for r in cmp.iter_rows(named=True):
            t4.add_row(r["detector"], f"{r['auc']:.4f}", f"{r['balanced_accuracy']:.3f}",
                       f"{r['fpr_at_zero']:.1%}", f"{r['tpr_at_1pct_fpr']:.3f}",
                       f"{r['ece']:.3f}")
        console.print(t4)
        console.print(f"[dim]composition: {int((one['label'] == 'real').sum())} real / "
                      f"{int((one['label'] == 'fake').sum())} fake. This is the only table "
                      f"from which cross-detector claims are valid.[/dim]")

    warned = head.filter(pl.col("warnings") != "")
    if len(warned):
        console.print("\n[bold]warnings[/bold]")
        for r in warned.iter_rows(named=True):
            console.print(f"  {r['detector']} / {r['rung']}: {r['warnings']}")

    gen = evaluate.by_generator(df)
    if len(gen):
        best = gen["detector"].unique().to_list()[0]
        g = gen.filter(pl.col("detector") == best)
        t2 = Table(title=f"per-generator slice ({best}, clean rung)", header_style="bold")
        for c, j in [("generator", "left"), ("n fake", "right"), ("AUC", "right"),
                     ("TPR@1%FPR", "right")]:
            t2.add_column(c, justify=j)  # type: ignore[arg-type]
        for r in g.iter_rows(named=True):
            t2.add_row(r["generator"], f"{r['n_fake']:,}", f"{r['auc']:.4f}",
                       f"{r['tpr_at_1pct_fpr']:.3f}")
        console.print(t2)
    else:
        console.print("\n[yellow]per-generator slice unavailable:[/yellow] the reference "
                      "logits cover only ReWIND, which carries no generator attribution. "
                      "Falling back to source collection.")

    src = evaluate.by_source(df)
    if len(src):
        # Single-class collections cannot yield a ranking metric; showing rows of NaN
        # invites a reader to think something failed. Report the structure instead.
        two_class = src.filter(pl.col("n_real") > 0).filter(pl.col("n_fake") > 0)
        single = src.filter((pl.col("n_real") == 0) | (pl.col("n_fake") == 0))

        t3 = Table(title="per-source-collection slice (clean rung, two-class only)",
                   header_style="bold")
        for c, j in [("detector", "left"), ("source", "left"), ("real/fake", "right"),
                     ("AUC", "right"), ("TPR@1%FPR", "right")]:
            t3.add_column(c, justify=j)  # type: ignore[arg-type]
        for r in two_class.iter_rows(named=True):
            t3.add_row(r["detector"], r["source_platform"],
                       f"{r['n_real']}/{r['n_fake']}", f"{r['auc']:.4f}",
                       f"{r['tpr_at_1pct_fpr']:.3f}")
        console.print(t3)

        if len(single):
            coll = (single.group_by("source_platform")
                    .agg(real=pl.col("n_real").first(), fake=pl.col("n_fake").first()))
            console.print("\n[yellow]single-class collections — no ranking metric possible:"
                          "[/yellow]")
            for r in coll.iter_rows(named=True):
                console.print(f"  {r['source_platform']:<18} "
                              f"{r['real']:>5} real / {r['fake']:>5} fake")
            console.print("[yellow]  ReWIND's real/fake comparison therefore rests on "
                          "viral_bfree plus cross-collection pooling. If collections differ "
                          "systematically in quality, a detector can read collection "
                          "provenance instead of synthesis.[/yellow]")

    homes = [p for p in providers if getattr(p, "home_turf", None)]
    if homes:
        console.print()
        for p in homes:
            console.print(f"[red]confound:[/red] {p.info.name} is evaluated partly on its "
                          f"own collection ('{p.home_turf}'), so its lead is optimistic by "
                          f"an amount this corpus cannot measure.")


@app.command("probe-metadata")
def probe_metadata(sample: int = typer.Option(400, "--sample", help="images per label")) -> None:
    """Measure how often EXIF / XMP / C2PA survive, split by real vs fake.

    Answers a spec open question. Detects presence only — validating a manifest is Lane A's
    job on device, and a present-but-unverified manifest is not evidence either way.
    """
    from bench.metaprobe import probe_many

    df = manifest.read()
    rows: list[dict] = []
    for label in ("real", "fake"):
        sub = df.filter(pl.col("label") == label).head(sample)
        files = [paths.data_root() / str(p) for p in sub["path"].to_list()]
        found = probe_many(files)
        for f, gen, slc in zip(found, sub["generator"].to_list(), sub["slice"].to_list()):
            rows.append({**f.as_row(), "label": label, "generator": gen, "slice": slc})

    if not rows:
        console.print("[yellow]nothing to probe[/yellow]")
        raise typer.Exit(1)

    res = pl.DataFrame(rows)
    t = Table(title="metadata survival (presence, not validity)", header_style="bold")
    for c, j in [("label", "left"), ("n", "right"), ("EXIF", "right"), ("camera make", "right"),
                 ("XMP", "right"), ("C2PA hint", "right"), ("AI disclosure", "right")]:
        t.add_column(c, justify=j)  # type: ignore[arg-type]
    for label in ("real", "fake"):
        s = res.filter(pl.col("label") == label)
        if not len(s):
            continue
        n = len(s)
        t.add_row(
            label, f"{n:,}",
            f"{s['has_exif'].sum()} ({s['has_exif'].mean():.0%})",
            f"{s['has_camera_make'].sum()} ({s['has_camera_make'].mean():.0%})",
            f"{s['has_xmp'].sum()} ({s['has_xmp'].mean():.0%})",
            f"{s['has_c2pa_hint'].sum()} ({s['has_c2pa_hint'].mean():.0%})",
            f"{s['has_ai_disclosure_hint'].sum()} ({s['has_ai_disclosure_hint'].mean():.0%})",
        )
    console.print(t)

    cams = (res.filter(pl.col("camera") != "")
              .group_by("camera").agg(n=pl.len()).sort("n", descending=True).head(8))
    if len(cams):
        console.print("\n[bold]camera makes/models seen on reals[/bold] "
                      "(evidence the real side is genuine capture, not stock):")
        for r in cams.iter_rows(named=True):
            console.print(f"  {r['n']:>4}  {r['camera']}")

    out = paths.cache_dir() / "metadata_probe.parquet"
    res.write_parquet(out)
    console.print(f"\nwrote {out}")


@app.command()
def verify(prune: bool = typer.Option(False, "--prune", help="delete orphan image files")) -> None:
    """Check the manifest against the filesystem in both directions."""
    df = manifest.read()
    res = manifest.verify(df)
    for k, v in res.items():
        if k.endswith(("_sample", "_paths")):
            continue
        shown = f"{v:,}" if isinstance(v, int) else v
        console.print(f"  {k:<28} {shown}")

    if res["orphan_files"] and prune:
        n, freed = manifest.prune_orphans(df)
        console.print(f"\n[yellow]pruned {n:,} orphan file(s), freed {_gb(freed)} GB[/yellow]")
        res = manifest.verify(df)

    bad = int(res["missing_files"]) + int(res["size_mismatch"])  # type: ignore[arg-type]
    if bad:
        console.print(f"\n[red]{bad} problem row(s)[/red]")
        console.print(f"  missing:  {res['missing_sample']}")
        console.print(f"  mismatch: {res['mismatch_sample']}")
        raise typer.Exit(1)
    if res["orphan_files"]:
        console.print(f"\n[yellow]{res['orphan_files']:,} orphan file(s) on disk "
                      f"({_gb(res['orphan_bytes'])} GB) not referenced by the manifest — "
                      f"rerun with --prune[/yellow]")
        raise typer.Exit(1)
    console.print("\n[green]manifest and filesystem agree, no orphans[/green]")


@app.command("coreml")
def coreml_cmd(
    variant: str = typer.Option("lowq", "--variant", help="lowq | frontier"),
    force: bool = typer.Option(False, "--force", help="re-convert even if cached"),
    parity_n: int = typer.Option(96, "--parity-n", help="images for the parity check"),
    skip_latency: bool = typer.Option(False, "--skip-latency"),
) -> None:
    """Export to Core ML, then run the ANE-placement gate and the PyTorch parity check.

    PLAN.md Task 4. Placement is the gate that can kill the design: a model that silently
    falls back to CPU keeps every accuracy number intact while losing the power budget the
    share extension depends on, so it is read from the compute plan rather than guessed from
    a stopwatch.
    """
    from collections import Counter

    from bench import coreml

    console.print(f"[bold]exporting commfor:{variant} to Core ML...[/bold]")
    path, rep = coreml.export(variant, force=force)
    if rep.get("status") == "cached":
        console.print(f"[dim]using cached package at {path}[/dim]")
    else:
        console.print(f"  converted in {rep['convert_seconds']}s -> {rep['package_mb']} MB "
                      f"(FP16 mlprogram, {coreml.DEPLOYMENT_TARGET}+)")
    console.print(f"  calibrated boundary: raw logit {rep.get('decision_threshold', '?')}")

    console.print("\n[bold]ANE placement — the Task 4 gate[/bold]")
    pl_ = coreml.placement(path)
    t = Table(header_style="bold")
    t.add_column("compute device", justify="left")
    t.add_column("ops", justify="right")
    t.add_column("share", justify="right")
    for k, v in sorted(pl_.counts.items(), key=lambda kv: -kv[1]):
        t.add_row(k, f"{v:,}", f"{100 * v / max(pl_.total, 1):.1f}%")
    console.print(t)
    colour = "green" if pl_.ane_fraction >= 0.9 else "yellow" if pl_.ane_fraction > 0 else "red"
    console.print(f"  [{colour}]{pl_.verdict()}[/{colour}]  "
                  f"({pl_.counts.get('ANE', 0)}/{pl_.total} ops)")
    if pl_.unsupported_by_ane:
        listed = ", ".join(f"{n} x{c}" for n, c in Counter(pl_.unsupported_by_ane).most_common(6))
        console.print(f"  [dim]ops the ANE cannot take: {listed}[/dim]")

    console.print("\n[bold]parity against PyTorch[/bold]")
    r = coreml.parity(variant, path, n=parity_n)
    console.print(f"  n={r['n']}  max|delta| {r['max_abs_delta']:.5f}  "
                  f"mean|delta| {r['mean_abs_delta']:.5f}  bias {r['bias']:+.5f}")
    console.print(f"  Spearman rho {r['spearman_rho']:.6f} "
                  f"[dim](AUC is rank-only, so this is the AUC-relevant figure)[/dim]")
    ok = r["decision_agreement"] == 1.0
    console.print(f"  decision agreement [{'green' if ok else 'red'}]{r['decision_agreement']:.4f}"
                  f"[/] at threshold {r['threshold']}")
    console.print(f"  [dim]FP16 drift can only matter within +/-{r['max_abs_delta']:.3f} of the "
                  f"boundary; Task 7's abstention band should be at least that wide[/dim]")

    if not skip_latency:
        console.print("\n[bold]latency[/bold] [dim](M3 Pro, INDICATIVE ONLY — not iPhone. "
                      "Absolute on-device numbers need a tethered Xcode Performance "
                      "Report; the relative ordering is the signal.)[/dim]")
        for u in ("CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE", "ALL"):
            try:
                ms = coreml.latency(path, units=u, n=30)["ms_per_image"]
                console.print(f"  {u:<14} {ms:>7.2f} ms")
            except Exception as e:  # a compute unit may be unavailable on some machines
                console.print(f"  {u:<14} [dim]unavailable ({type(e).__name__})[/dim]")

    console.print(f"\n[green]package [/green] {path}")
    console.print(f"[green]compiled[/green] {coreml.compile_package(path)}")


if __name__ == "__main__":
    app()
