"""Scan training/data/raw/<category>/ and emit a CSV manifest of usable clips."""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

import soundfile as sf

AUDIO_EXTS = {".wav", ".flac", ".ogg", ".mp3", ".m4a", ".aiff", ".aif"}
MIN_DURATION_S = 1.0


def scan(root: Path, categories: list[str]) -> list[dict]:
    rows: list[dict] = []
    for cat in categories:
        cat_dir = root / cat
        if not cat_dir.exists():
            print(f"[warn] missing directory: {cat_dir}")
            continue
        for path in sorted(cat_dir.rglob("*")):
            if not path.is_file() or path.suffix.lower() not in AUDIO_EXTS:
                continue
            try:
                info = sf.info(str(path))
            except Exception as e:
                print(f"[skip] {path}: {e}")
                continue
            if not info.samplerate:
                continue
            duration = info.frames / info.samplerate
            if duration < MIN_DURATION_S:
                continue
            rows.append({
                "category": cat,
                "path": str(path.resolve()),
                "samplerate": info.samplerate,
                "channels": info.channels,
                "duration_s": round(duration, 3),
            })
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=Path("training/data/raw"))
    ap.add_argument("--out", type=Path, default=Path("training/data/manifest.csv"))
    ap.add_argument("--categories", nargs="+", default=["dialog", "music", "sfx"])
    args = ap.parse_args()

    rows = scan(args.root, args.categories)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["category", "path", "samplerate", "channels", "duration_s"],
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nWrote {len(rows)} entries → {args.out}")
    by_cat: dict[str, list[float]] = {}
    for r in rows:
        by_cat.setdefault(r["category"], []).append(r["duration_s"])
    for cat in sorted(by_cat):
        durs = by_cat[cat]
        total_h = sum(durs) / 3600.0
        print(f"  {cat:8s}  {len(durs):>6d} files  {total_h:>6.1f} h total")


if __name__ == "__main__":
    main()
