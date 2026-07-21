"""Aggregate per-file features into per-game fingerprints and flat vectors."""
from __future__ import annotations

import statistics
from typing import Any


PERCENTILES = [10, 25, 50, 75, 90]
FEATURE_GROUPS: dict[str, list[str]] = {
    "spatial": ["front", "back", "sides", "tops", "lfe"],
    "level": ["rms", "crest_db"],
    "spectral": ["centroid_hz", "rolloff_hz", "flatness"],
    "temporal": ["onset_rate_per_sec"],
}
STATS = ["mean", "std"] + [f"p{p}" for p in PERCENTILES]


def _stats(values: list[float]) -> dict[str, float]:
    if not values:
        return {k: 0.0 for k in STATS}
    out: dict[str, float] = {
        "mean": round(statistics.fmean(values), 5),
        "std": round(statistics.pstdev(values), 5) if len(values) > 1 else 0.0,
    }
    values_sorted = sorted(values)
    n = len(values_sorted)
    for p in PERCENTILES:
        idx = int(round((p / 100.0) * (n - 1)))
        out[f"p{p}"] = round(values_sorted[idx], 5)
    return out


def _collect(files: list[dict], group: str, feat: str) -> list[float]:
    out: list[float] = []
    for f in files:
        v = f.get(group, {}).get(feat)
        if isinstance(v, (int, float)):
            out.append(float(v))
    return out


def aggregate_game(files: list[dict]) -> dict[str, Any]:
    total_duration = sum(f.get("duration_s", 0.0) for f in files)
    channels_hist: dict[str, int] = {}
    for f in files:
        c = str(f.get("channels", 0))
        channels_hist[c] = channels_hist.get(c, 0) + 1

    result: dict[str, Any] = {
        "file_count": len(files),
        "total_duration_s": round(total_duration, 2),
        "channels_hist": channels_hist,
    }
    for group, feats in FEATURE_GROUPS.items():
        result[group] = {feat: _stats(_collect(files, group, feat)) for feat in feats}
    return result


def feature_vector(agg: dict) -> tuple[list[str], list[float]]:
    """Flatten one game's aggregate into a labeled numeric vector."""
    names: list[str] = []
    values: list[float] = []
    for group, feats in FEATURE_GROUPS.items():
        for feat in feats:
            stats = agg.get(group, {}).get(feat, {})
            for s in STATS:
                names.append(f"{group}.{feat}.{s}")
                values.append(float(stats.get(s, 0.0)))
    return names, values
