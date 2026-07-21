"""Walk a Wwise-style Originals/SFX folder and emit a JSON manifest.

Assumes the top-level subfolder under --root is the game name, e.g.
    <root>/CallOfDuty/weapons/rifle_01.wav  -> game = "CallOfDuty"

Per file we record: channel count, sample rate, duration, per-channel RMS +
peak. Per game we aggregate: file count, total duration, channel-layout
histogram, sample-rate histogram.

Usage (Windows):
    python -m analyzer.scan --root "C:\\Users\\kevin\\OneDrive\\Documents\\WwiseProjects\\WwiseDemo_Master_2022_1_11\\Originals\\SFX" --out analyzer/scan.json
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf

AUDIO_EXTS = {".wav", ".flac", ".ogg", ".aiff", ".aif"}

CHANNEL_LAYOUT = {
    1: "mono",
    2: "stereo",
    4: "quad/3.1",
    6: "5.1",
    8: "7.1",
    10: "7.1.2",
    12: "7.1.4",
    16: "7.1.4+objects",
}


def _guess_game(path: Path, root: Path) -> str:
    try:
        rel = path.relative_to(root)
    except ValueError:
        return "_unknown"
    if len(rel.parts) < 2:
        return "_root"
    return rel.parts[0]


def _file_stats(path: Path, full_stats: bool) -> dict[str, Any]:
    info = sf.info(str(path))
    duration = info.frames / info.samplerate if info.samplerate else 0.0
    out: dict[str, Any] = {
        "path": str(path),
        "channels": info.channels,
        "sample_rate": info.samplerate,
        "frames": info.frames,
        "duration_s": round(duration, 3),
        "layout_guess": CHANNEL_LAYOUT.get(info.channels, f"{info.channels}ch"),
    }
    if full_stats:
        try:
            data, _ = sf.read(str(path), dtype="float32", always_2d=True)
            if data.size > 0:
                rms = np.sqrt(np.mean(data.astype(np.float64) ** 2, axis=0) + 1e-24)
                peak = np.max(np.abs(data), axis=0)
                out["rms_per_channel"] = [round(float(x), 6) for x in rms]
                out["peak_per_channel"] = [round(float(x), 6) for x in peak]
        except Exception as e:
            out["read_error"] = str(e)
    return out


def scan_folder(root: Path, full_stats: bool = True) -> dict[str, Any]:
    files: list[dict[str, Any]] = []
    all_paths = [
        p for p in root.rglob("*")
        if p.is_file() and p.suffix.lower() in AUDIO_EXTS
    ]
    total = len(all_paths)
    print(f"Found {total} audio files. Reading{' full stats' if full_stats else ' metadata only'}...",
          file=sys.stderr)

    t0 = time.time()
    for i, p in enumerate(sorted(all_paths), 1):
        try:
            stats = _file_stats(p, full_stats)
        except Exception as e:
            files.append({"path": str(p), "error": str(e), "game": _guess_game(p, root)})
            continue
        stats["game"] = _guess_game(p, root)
        files.append(stats)
        if i % 200 == 0 or i == total:
            elapsed = time.time() - t0
            print(f"  {i:>6d}/{total}  ({i / max(elapsed, 1e-3):.1f} files/s)", file=sys.stderr)

    by_game: dict[str, dict[str, Any]] = {}
    for f in files:
        game = f.get("game", "_unknown")
        agg = by_game.setdefault(game, {
            "file_count": 0,
            "total_duration_s": 0.0,
            "channel_layouts": {},
            "sample_rates": {},
            "errors": 0,
        })
        if "error" in f:
            agg["errors"] += 1
            continue
        agg["file_count"] += 1
        agg["total_duration_s"] += f.get("duration_s", 0.0)
        layout = f.get("layout_guess", "?")
        agg["channel_layouts"][layout] = agg["channel_layouts"].get(layout, 0) + 1
        sr = f.get("sample_rate", 0)
        agg["sample_rates"][str(sr)] = agg["sample_rates"].get(str(sr), 0) + 1

    for agg in by_game.values():
        agg["total_duration_s"] = round(agg["total_duration_s"], 2)

    return {
        "root": str(root),
        "total_files": len(files),
        "games": sorted(by_game.keys()),
        "per_game_summary": by_game,
        "files": files,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description="Scan an SFX library folder and emit a JSON manifest.")
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=Path("analyzer/scan.json"))
    ap.add_argument("--metadata-only", action="store_true",
                    help="Skip per-channel RMS/peak (faster, smaller output).")
    ap.add_argument("--summary-only", action="store_true",
                    help="Drop the per-file list, keep only per-game aggregate.")
    args = ap.parse_args()

    if not args.root.exists():
        raise SystemExit(f"Root does not exist: {args.root}")

    manifest = scan_folder(args.root, full_stats=not args.metadata_only)
    if args.summary_only:
        manifest.pop("files", None)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    print(f"\nFound {manifest['total_files']} files across {len(manifest['games'])} game folder(s):\n")
    for game in manifest["games"]:
        agg = manifest["per_game_summary"][game]
        layouts = ", ".join(
            f"{k}×{v}" for k, v in sorted(agg["channel_layouts"].items(), key=lambda x: -x[1])
        )
        print(f"  {game:30s} {agg['file_count']:>6d} files  "
              f"{agg['total_duration_s']/60:>7.1f} min   {layouts}")
    print(f"\nWrote {args.out}")


if __name__ == "__main__":
    main()
