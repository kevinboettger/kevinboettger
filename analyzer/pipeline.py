"""End-to-end analyzer: scan.json -> features -> aggregates + labels -> classifier.

Sub-commands:
    features    : read scan.json, extract per-file features, write features.json
    aggregate   : bucket per-file features by game, compute per-game fingerprints
                  and match against curated genre labels; write aggregates.json
    train       : train the genre classifier and print the CV report
    all         : run features -> aggregate -> train in one shot
"""
from __future__ import annotations

import argparse
import json
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

from .aggregate import aggregate_game
from .classifier import train as train_classifier
from .features import extract_features
from .games import lookup_genre


def _extract_one(entry: dict) -> dict | None:
    try:
        feat = extract_features(entry["path"])
    except Exception as e:
        return {"path": entry["path"], "game": entry.get("game", "_unknown"),
                "error": f"{type(e).__name__}: {e}"}
    feat["game"] = entry.get("game", "_unknown")
    return feat


def cmd_features(scan_path: Path, out_path: Path, workers: int) -> None:
    with scan_path.open() as f:
        scan = json.load(f)
    files = [f for f in scan.get("files", []) if "error" not in f]
    if not files:
        raise SystemExit(f"No usable file entries in {scan_path} "
                         f"(re-run analyzer.scan without --summary-only).")
    print(f"Extracting features for {len(files)} files with {workers} workers...")
    results: list[dict] = []
    with ProcessPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(_extract_one, e) for e in files]
        for i, fut in enumerate(as_completed(futures), 1):
            r = fut.result()
            if r is not None:
                results.append(r)
            if i % 200 == 0 or i == len(futures):
                print(f"  {i}/{len(futures)}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        json.dump(results, f, indent=2)
    print(f"Wrote {out_path} ({len(results)} records)")


def cmd_aggregate(features_path: Path, out_path: Path) -> None:
    with features_path.open() as f:
        per_file = json.load(f)
    by_game: dict[str, list[dict]] = {}
    for entry in per_file:
        if "error" in entry:
            continue
        by_game.setdefault(entry["game"], []).append(entry)
    per_game = {g: aggregate_game(files) for g, files in by_game.items()}

    labels: dict[str, str] = {}
    unmapped: list[str] = []
    for g in per_game:
        genre = lookup_genre(g)
        if genre is None:
            unmapped.append(g)
            labels[g] = "unknown"
        else:
            labels[g] = genre

    payload = {"per_game": per_game, "labels": labels, "unmapped": unmapped}
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        json.dump(payload, f, indent=2)

    print(f"Wrote {out_path}: {len(per_game)} games")
    print("Labeled by genre:")
    genre_counts: dict[str, int] = {}
    for g in labels.values():
        genre_counts[g] = genre_counts.get(g, 0) + 1
    for genre, count in sorted(genre_counts.items(), key=lambda kv: -kv[1]):
        print(f"  {genre:<20s} {count}")
    if unmapped:
        print(f"\nUnmapped ({len(unmapped)}) — add these to analyzer/games.py:")
        for name in unmapped:
            print(f"  - {name}")


def cmd_train(aggregates_path: Path, out_path: Path) -> None:
    with aggregates_path.open() as f:
        blob = json.load(f)
    result = train_classifier(blob["per_game"], blob["labels"])
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        json.dump(result, f, indent=2)

    if "error" in result:
        print(f"[classifier] {result['error']}")
        return

    print(f"Trained on {result['n_games']} games across {len(result['class_order'])} genres.")
    print("\nCV report:")
    print(result["report"])
    print("Top features distinguishing genres:")
    for name, imp in result["top_features"]:
        print(f"  {name:<45s} {imp:.4f}")
    print("\nConfusion matrix (rows = truth, cols = predicted):")
    header = "     " + " ".join(f"{c[:7]:>8s}" for c in result["class_order"])
    print(header)
    for cls, row in zip(result["class_order"], result["confusion_matrix"]):
        cells = " ".join(f"{v:>8d}" for v in row)
        print(f"  {cls[:5]:<5s} {cells}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["features", "aggregate", "train", "all"])
    ap.add_argument("--scan", type=Path, default=Path("analyzer/scan.json"))
    ap.add_argument("--features", type=Path, default=Path("analyzer/features.json"))
    ap.add_argument("--aggregates", type=Path, default=Path("analyzer/aggregates.json"))
    ap.add_argument("--report", type=Path, default=Path("analyzer/report.json"))
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()

    if args.action in {"features", "all"}:
        cmd_features(args.scan, args.features, args.workers)
    if args.action in {"aggregate", "all"}:
        cmd_aggregate(args.features, args.aggregates)
    if args.action in {"train", "all"}:
        cmd_train(args.aggregates, args.report)


if __name__ == "__main__":
    main()
